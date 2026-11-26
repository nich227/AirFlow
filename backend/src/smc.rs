//! The SMC is the Mac's system management controller, reached through the AppleSMC kernel service.
//! Reading needs no privilege. Writing needs root.

use std::collections::HashMap;
use std::ffi::{c_char, c_void};
use std::sync::{Mutex, MutexGuard};

/// A value read from the SMC: its four-character type and its raw bytes.
#[derive(Debug, Clone, PartialEq)]
pub struct SmcValue {
    pub kind: [u8; 4],
    pub bytes: Vec<u8>,
}

impl SmcValue {
    /// The value as a number, or None when the type is not numeric.
    pub fn number(&self) -> Option<f64> {
        decode(&self.bytes, &self.kind)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SmcError {
    ServiceNotFound,
    OpenFailed(i32),
    CallFailed(i32),
    /// The SMC answered with its own result code. 0x84 means the key does not exist.
    Rejected(u8),
    InvalidKey,
    UnsupportedType,
}

/// The reads and writes the reader and the fan writer need. Tests supply a made-up SMC.
pub trait SmcAccess {
    fn read(&self, key: &str) -> Result<SmcValue, SmcError>;
    fn write(&self, key: &str, bytes: &[u8]) -> Result<(), SmcError>;
    fn key_count(&self) -> usize;
    fn key_at(&self, index: usize) -> Option<String>;

    fn number(&self, key: &str) -> Option<f64> {
        self.read(key).ok()?.number()
    }

    fn has(&self, key: &str) -> bool {
        self.read(key).is_ok()
    }

    /// Writes a number in the key's own type and size.
    fn write_number(&self, key: &str, number: f64) -> Result<(), SmcError> {
        let current = self.read(key)?;
        let bytes = encode(number, &current.kind, current.bytes.len()).ok_or(SmcError::UnsupportedType)?;
        self.write(key, &bytes)
    }
}

impl<T: SmcAccess + ?Sized> SmcAccess for &T {
    fn read(&self, key: &str) -> Result<SmcValue, SmcError> {
        (**self).read(key)
    }
    fn write(&self, key: &str, bytes: &[u8]) -> Result<(), SmcError> {
        (**self).write(key, bytes)
    }
    fn key_count(&self) -> usize {
        (**self).key_count()
    }
    fn key_at(&self, index: usize) -> Option<String> {
        (**self).key_at(index)
    }
}

impl<T: SmcAccess + ?Sized> SmcAccess for Box<T> {
    fn read(&self, key: &str) -> Result<SmcValue, SmcError> {
        (**self).read(key)
    }
    fn write(&self, key: &str, bytes: &[u8]) -> Result<(), SmcError> {
        (**self).write(key, bytes)
    }
    fn key_count(&self) -> usize {
        (**self).key_count()
    }
    fn key_at(&self, index: usize) -> Option<String> {
        (**self).key_at(index)
    }
}

/// Converts SMC bytes to a number.
pub fn decode(bytes: &[u8], kind: &[u8; 4]) -> Option<f64> {
    match kind {
        b"flt " => {
            let raw: [u8; 4] = bytes.get(..4)?.try_into().ok()?;
            let value = f32::from_le_bytes(raw);
            value.is_finite().then_some(f64::from(value))
        }
        b"fpe2" => {
            let raw: [u8; 2] = bytes.get(..2)?.try_into().ok()?;
            Some(f64::from(u16::from_be_bytes(raw)) / 4.0)
        }
        b"sp78" => {
            let raw: [u8; 2] = bytes.get(..2)?.try_into().ok()?;
            Some(f64::from(i16::from_be_bytes(raw)) / 256.0)
        }
        b"ui8 " | b"ui16" | b"ui32" | b"flag" => {
            if bytes.is_empty() || bytes.len() > 4 {
                return None;
            }
            Some(f64::from(bytes.iter().fold(0u32, |total, byte| total << 8 | u32::from(*byte))))
        }
        _ => None,
    }
}

/// Converts a number to SMC bytes of a type and size, or None when it does not fit.
pub fn encode(number: f64, kind: &[u8; 4], size: usize) -> Option<Vec<u8>> {
    match kind {
        b"flt " => (size == 4 && number.is_finite()).then(|| (number as f32).to_le_bytes().to_vec()),
        b"fpe2" => (size == 2 && (0.0..=16383.0).contains(&number)).then(|| ((number * 4.0) as u16).to_be_bytes().to_vec()),
        b"ui8 " | b"ui16" | b"ui32" | b"flag" => {
            if !(1..=4).contains(&size) || !number.is_finite() || number < 0.0 || number >= 256f64.powi(size as i32) {
                return None;
            }
            Some((number as u32).to_be_bytes()[4 - size..].to_vec())
        }
        _ => None,
    }
}

/// A four-character key as the number the kernel takes.
pub fn code(key: &str) -> Option<u32> {
    let bytes: [u8; 4] = key.as_bytes().try_into().ok()?;
    Some(u32::from_be_bytes(bytes))
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Version {
    major: u8,
    minor: u8,
    build: u8,
    reserved: u8,
    release: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Limits {
    version: u16,
    length: u16,
    cpu: u32,
    gpu: u32,
    memory: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct KeyInfo {
    data_size: u32,
    data_type: u32,
    data_attributes: u8,
}

/// The kernel's SMCKeyData_t.
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Param {
    key: u32,
    version: Version,
    limits: Limits,
    key_info: KeyInfo,
    result: u8,
    status: u8,
    data8: u8,
    data32: u32,
    bytes: [u8; 32],
}

// The kernel rejects a structure of any other size.
const _: () = assert!(std::mem::size_of::<Param>() == 80);

const COMMAND_READ: u8 = 5;
const COMMAND_WRITE: u8 = 6;
const COMMAND_KEY_AT_INDEX: u8 = 8;
const COMMAND_KEY_INFO: u8 = 9;
const SELECTOR_HANDLE_EVENT: u32 = 2;

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOServiceMatching(name: *const c_char) -> *mut c_void;
    fn IOServiceGetMatchingService(main_port: u32, matching: *mut c_void) -> u32;
    fn IOServiceOpen(service: u32, owning_task: u32, kind: u32, connection: *mut u32) -> i32;
    fn IOServiceClose(connection: u32) -> i32;
    fn IOObjectRelease(object: u32) -> i32;
    fn IOConnectCallStructMethod(
        connection: u32,
        selector: u32,
        input: *const c_void,
        input_size: usize,
        output: *mut c_void,
        output_size: *mut usize,
    ) -> i32;
}

extern "C" {
    static mach_task_self_: u32;
}

/// What carries one request to the SMC and brings back its answer.
trait Port {
    fn call(&self, input: &Param) -> Result<Param, SmcError>;
}

// coverage:off This is the AppleSMC kernel service itself, which a test must not depend on.
/// A Mach port to the AppleSMC kernel service.
struct KernelPort {
    connection: u32,
}

impl KernelPort {
    fn open() -> Result<Self, SmcError> {
        // SAFETY: the name is a NUL-terminated string, IOServiceGetMatchingService consumes
        // the matching dictionary, and the service is released once the connection is open.
        unsafe {
            let service = IOServiceGetMatchingService(0, IOServiceMatching(c"AppleSMC".as_ptr()));
            if service == 0 {
                return Err(SmcError::ServiceNotFound);
            }
            let mut connection = 0u32;
            let result = IOServiceOpen(service, mach_task_self_, 0, &mut connection);
            IOObjectRelease(service);
            if result != 0 {
                return Err(SmcError::OpenFailed(result));
            }
            Ok(Self { connection })
        }
    }
}

impl Port for KernelPort {
    fn call(&self, input: &Param) -> Result<Param, SmcError> {
        let mut output = Param::default();
        let mut output_size = std::mem::size_of::<Param>();
        // SAFETY: both structures are the size the kernel expects and outlive the call.
        let result = unsafe {
            IOConnectCallStructMethod(
                self.connection,
                SELECTOR_HANDLE_EVENT,
                (input as *const Param).cast(),
                std::mem::size_of::<Param>(),
                (&mut output as *mut Param).cast(),
                &mut output_size,
            )
        };
        if result != 0 {
            return Err(SmcError::CallFailed(result));
        }
        Ok(output)
    }
}

impl Drop for KernelPort {
    fn drop(&mut self) {
        // SAFETY: the connection was opened by this value and is closed once.
        unsafe {
            IOServiceClose(self.connection);
        }
    }
}

impl SmcConnection {
    pub fn open() -> Result<Self, SmcError> {
        KernelPort::open().map(|port| Self::over(Box::new(port)))
    }
}
// coverage:on

/// A connection to the SMC.
pub struct SmcConnection {
    port: Box<dyn Port + Send + Sync>,
    /// The size and type of each key already asked about. The lock also keeps one call at a
    /// time on the connection.
    info: Mutex<HashMap<u32, (u32, u32)>>,
}

impl SmcConnection {
    fn over(port: Box<dyn Port + Send + Sync>) -> Self {
        Self { port, info: Mutex::new(HashMap::new()) }
    }

    /// What is known about each key. A thread that stopped while it held the lock leaves
    /// nothing half-written, so the lock is taken all the same.
    fn info(&self) -> MutexGuard<'_, HashMap<u32, (u32, u32)>> {
        self.info.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn call(&self, input: &Param) -> Result<Param, SmcError> {
        let output = self.port.call(input)?;
        if output.result != 0 {
            return Err(SmcError::Rejected(output.result));
        }
        Ok(output)
    }

    fn key_info(&self, info: &mut HashMap<u32, (u32, u32)>, code: u32) -> Result<(u32, u32), SmcError> {
        if let Some(known) = info.get(&code) {
            return Ok(*known);
        }
        let output = self.call(&Param { key: code, data8: COMMAND_KEY_INFO, ..Param::default() })?;
        let found = (output.key_info.data_size, output.key_info.data_type);
        info.insert(code, found);
        Ok(found)
    }
}

impl SmcAccess for SmcConnection {
    fn read(&self, key: &str) -> Result<SmcValue, SmcError> {
        let code = code(key).ok_or(SmcError::InvalidKey)?;
        let mut info = self.info();
        let (size, kind) = self.key_info(&mut info, code)?;
        let mut input = Param { key: code, data8: COMMAND_READ, ..Param::default() };
        input.key_info.data_size = size;
        let output = self.call(&input)?;
        let count = (size as usize).min(32);
        Ok(SmcValue { kind: kind.to_be_bytes(), bytes: output.bytes[..count].to_vec() })
    }

    fn write(&self, key: &str, bytes: &[u8]) -> Result<(), SmcError> {
        let code = code(key).ok_or(SmcError::InvalidKey)?;
        let mut info = self.info();
        let (size, _) = self.key_info(&mut info, code)?;
        if size as usize != bytes.len() || bytes.len() > 32 {
            return Err(SmcError::UnsupportedType);
        }
        let mut input = Param { key: code, data8: COMMAND_WRITE, ..Param::default() };
        input.key_info.data_size = size;
        input.bytes[..bytes.len()].copy_from_slice(bytes);
        self.call(&input).map(|_| ())
    }

    fn key_count(&self) -> usize {
        self.number("#KEY").map_or(0, |count| count as usize)
    }

    fn key_at(&self, index: usize) -> Option<String> {
        let _guard = self.info();
        let output = self
            .call(&Param { data8: COMMAND_KEY_AT_INDEX, data32: u32::try_from(index).ok()?, ..Param::default() })
            .ok()?;
        String::from_utf8(output.key.to_be_bytes().to_vec()).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn float_is_little_endian() {
        // 1350.0 as the SMC of an Apple silicon Mac stores it.
        assert_eq!(decode(&[0x00, 0xC0, 0xA8, 0x44], b"flt "), Some(1350.0));
        assert_eq!(encode(1350.0, b"flt ", 4), Some(vec![0x00, 0xC0, 0xA8, 0x44]));
    }

    #[test]
    fn fixed_point_speed_is_big_endian_in_quarter_turns() {
        assert_eq!(decode(&[0x15, 0x18], b"fpe2"), Some(1350.0));
        assert_eq!(encode(1350.0, b"fpe2", 2), Some(vec![0x15, 0x18]));
    }

    #[test]
    fn signed_temperature() {
        assert_eq!(decode(&[0x3E, 0x80], b"sp78"), Some(62.5));
        assert_eq!(decode(&[0xFF, 0x00], b"sp78"), Some(-1.0));
    }

    #[test]
    fn unsigned_integers() {
        assert_eq!(decode(&[0x02], b"ui8 "), Some(2.0));
        assert_eq!(decode(&[0x01, 0x00], b"ui16"), Some(256.0));
        assert_eq!(encode(1.0, b"ui8 ", 1), Some(vec![1]));
        assert_eq!(encode(3.0, b"ui16", 2), Some(vec![0, 3]));
    }

    #[test]
    fn values_that_do_not_fit_are_refused() {
        assert_eq!(encode(256.0, b"ui8 ", 1), None);
        assert_eq!(encode(-1.0, b"ui8 ", 1), None);
        assert_eq!(encode(1350.0, b"flt ", 2), None);
        assert_eq!(encode(f64::NAN, b"flt ", 4), None);
        assert_eq!(encode(1.0, b"ch8*", 1), None);
        assert_eq!(decode(&[1, 2], b"flt "), None);
        assert_eq!(decode(&[0, 0, 0xC0, 0x7F], b"flt "), None, "NaN is not a reading");
    }

    #[test]
    fn key_codes() {
        assert_eq!(code("F0Ac"), Some(0x4630_4163));
        assert_eq!(code("F0"), None);
        assert_eq!(code("F0Acx"), None);
    }

    #[test]
    fn bytes_that_are_not_a_number_of_their_type_are_not_a_reading() {
        assert_eq!(decode(&[], b"ui8 "), None);
        assert_eq!(decode(&[1, 2, 3, 4, 5], b"ui32"), None);
        assert_eq!(decode(&[1], b"fpe2"), None);
        assert_eq!(decode(&[1], b"sp78"), None);
        assert_eq!(decode(&[1, 2, 3, 4], b"ch8*"), None);
        assert_eq!(SmcValue { kind: *b"ch8*", bytes: vec![1] }.number(), None);
        assert_eq!(SmcValue { kind: *b"flag", bytes: vec![1] }.number(), Some(1.0));
        assert_eq!(encode(1.0, b"ui8 ", 0), None);
        assert_eq!(encode(1.0, b"ui32", 5), None);
        assert_eq!(encode(f64::INFINITY, b"ui8 ", 1), None);
        assert_eq!(encode(16384.0, b"fpe2", 2), None);
        assert_eq!(encode(1.0, b"fpe2", 4), None);
    }

    struct FakeKey {
        code: u32,
        size: u32,
        kind: u32,
        bytes: Vec<u8>,
    }

    /// An SMC as the kernel presents it: keys with a size, a type, and bytes.
    #[derive(Default)]
    struct FakePort {
        keys: Mutex<Vec<FakeKey>>,
        calls: Mutex<Vec<u8>>,
        /// The kernel's own result for every call, when it is not 0.
        failure: Option<i32>,
        /// True while a call stops its thread.
        stops: std::sync::atomic::AtomicBool,
    }

    impl FakePort {
        fn with(keys: &[(&str, &[u8; 4], &[u8])]) -> Self {
            let keys = keys.iter().map(|(key, kind, bytes)| FakeKey {
                code: code(key).unwrap(),
                size: bytes.len() as u32,
                kind: u32::from_be_bytes(**kind),
                bytes: bytes.to_vec(),
            });
            Self { keys: Mutex::new(keys.collect()), ..Self::default() }
        }
    }

    impl Port for std::sync::Arc<FakePort> {
        fn call(&self, input: &Param) -> Result<Param, SmcError> {
            if let Some(result) = self.failure {
                return Err(SmcError::CallFailed(result));
            }
            assert!(!self.stops.load(std::sync::atomic::Ordering::SeqCst), "the port stopped");
            self.calls.lock().unwrap().push(input.data8);
            let mut keys = self.keys.lock().unwrap();
            let mut output = Param::default();
            if input.data8 == COMMAND_KEY_AT_INDEX {
                match keys.get(input.data32 as usize) {
                    Some(found) => output.key = found.code,
                    None => output.result = 0x84,
                }
                return Ok(output);
            }
            let Some(found) = keys.iter_mut().find(|found| found.code == input.key) else {
                output.result = 0x84;
                return Ok(output);
            };
            if input.data8 == COMMAND_KEY_INFO {
                output.key_info.data_size = found.size;
                output.key_info.data_type = found.kind;
            } else if input.data8 == COMMAND_READ {
                let count = found.bytes.len().min(32);
                output.bytes[..count].copy_from_slice(&found.bytes[..count]);
            } else {
                found.bytes = input.bytes[..input.key_info.data_size as usize].to_vec();
            }
            Ok(output)
        }
    }

    fn connection(port: FakePort) -> (SmcConnection, std::sync::Arc<FakePort>) {
        let port = std::sync::Arc::new(port);
        (SmcConnection::over(Box::new(port.clone())), port)
    }

    const LONG: [u8; 40] = [7; 40];

    fn sample_port() -> FakePort {
        FakePort::with(&[("F0Ac", b"flt ", &[0x00, 0xC0, 0xA8, 0x44]), ("F0Md", b"ui8 ", &[0]), ("#KEY", b"ui32", &[0, 0, 0, 4]), ("LONG", b"ch8*", &LONG)])
    }

    #[test]
    fn a_read_asks_for_the_keys_size_and_type_once() {
        let (smc, port) = connection(sample_port());
        assert_eq!(smc.read("F0Ac"), Ok(SmcValue { kind: *b"flt ", bytes: vec![0x00, 0xC0, 0xA8, 0x44] }));
        assert_eq!(smc.number("F0Ac"), Some(1350.0));
        assert_eq!(*port.calls.lock().unwrap(), [COMMAND_KEY_INFO, COMMAND_READ, COMMAND_READ]);
        assert_eq!(smc.read("LONG").map(|value| value.bytes.len()), Ok(32), "No more bytes than the kernel's structure holds");
        assert!(smc.has("F0Md"));
        assert!(!smc.has("F9Md"));
    }

    #[test]
    fn a_key_that_is_missing_or_malformed_is_an_error() {
        let (smc, port) = connection(sample_port());
        assert_eq!(smc.read("F9Ac"), Err(SmcError::Rejected(0x84)));
        assert_eq!(smc.read("F0"), Err(SmcError::InvalidKey));
        assert_eq!(smc.write("F0", &[1]), Err(SmcError::InvalidKey));
        assert_eq!(smc.write("F9Md", &[1]), Err(SmcError::Rejected(0x84)));
        assert_eq!(smc.number("F9Ac"), None);
        assert_eq!(port.calls.lock().unwrap().iter().filter(|command| **command == COMMAND_READ).count(), 0);
    }

    #[test]
    fn a_write_has_to_be_the_keys_own_size() {
        let (smc, port) = connection(sample_port());
        assert_eq!(smc.write("F0Md", &[1]), Ok(()));
        assert_eq!(smc.number("F0Md"), Some(1.0));
        assert_eq!(smc.write("F0Md", &[0, 1]), Err(SmcError::UnsupportedType));
        assert_eq!(smc.write("LONG", &LONG), Err(SmcError::UnsupportedType), "A value longer than the structure is not written");
        assert_eq!(smc.write_number("F0Ac", 2000.0), Ok(()));
        assert_eq!(smc.number("F0Ac"), Some(2000.0));
        assert_eq!(smc.write_number("F0Md", 300.0), Err(SmcError::UnsupportedType));
        assert_eq!(smc.write_number("F9Md", 1.0), Err(SmcError::Rejected(0x84)));
        assert_eq!(port.calls.lock().unwrap().iter().filter(|command| **command == COMMAND_WRITE).count(), 2);
    }

    #[test]
    fn the_keys_are_listed_by_index() {
        let (smc, _) = connection(sample_port());
        assert_eq!(smc.key_count(), 4);
        assert_eq!(smc.key_at(0).as_deref(), Some("F0Ac"));
        assert_eq!(smc.key_at(3).as_deref(), Some("LONG"));
        assert_eq!(smc.key_at(4), None);
        assert_eq!(smc.key_at(usize::MAX), None, "An index the kernel's structure cannot hold");
        let (unnamed, _) = connection(FakePort { keys: Mutex::new(vec![FakeKey { code: 0xFFFF_FFFF, size: 1, kind: 0, bytes: vec![0] }]), ..FakePort::default() });
        assert_eq!(unnamed.key_at(0), None, "A key that is not text has no name");
        assert_eq!(unnamed.key_count(), 0);
    }

    #[test]
    fn a_call_the_kernel_refuses_is_an_error() {
        let (smc, _) = connection(FakePort { failure: Some(-5), ..sample_port() });
        assert_eq!(smc.read("F0Ac"), Err(SmcError::CallFailed(-5)));
        assert_eq!(smc.write("F0Md", &[1]), Err(SmcError::CallFailed(-5)));
        assert_eq!(smc.key_at(0), None);
        assert_eq!(smc.key_count(), 0);
    }

    #[test]
    fn a_thread_that_stopped_in_a_call_does_not_stop_the_next() {
        let (smc, port) = connection(sample_port());
        port.stops.store(true, std::sync::atomic::Ordering::SeqCst);
        let stopped = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| smc.read("F0Ac")));
        assert!(stopped.is_err());
        port.stops.store(false, std::sync::atomic::Ordering::SeqCst);
        assert_eq!(smc.number("F0Ac"), Some(1350.0));
        assert_eq!(smc.write("F0Md", &[1]), Ok(()));
        assert_eq!(smc.key_at(1).as_deref(), Some("F0Md"));
    }

    #[test]
    fn a_borrowed_and_a_boxed_smc_are_the_smc() {
        let (smc, _) = connection(sample_port());
        let borrowed = &smc;
        assert_eq!(borrowed.number("F0Ac"), Some(1350.0));
        assert_eq!(SmcAccess::write(&borrowed, "F0Md", &[1]), Ok(()));
        assert_eq!(SmcAccess::key_count(&borrowed), 4);
        assert_eq!(SmcAccess::key_at(&borrowed, 1).as_deref(), Some("F0Md"));
        let boxed: Box<dyn SmcAccess> = Box::new(smc);
        assert_eq!(boxed.number("F0Md"), Some(1.0));
        assert_eq!(boxed.write("F0Md", &[0]), Ok(()));
        assert_eq!(boxed.key_count(), 4);
        assert_eq!(boxed.key_at(0).as_deref(), Some("F0Ac"));
    }
}
