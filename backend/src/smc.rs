//! The SMC is the Mac's system management controller, reached through the AppleSMC kernel service.
//! Reading needs no privilege. Writing needs root.

use std::collections::HashMap;
use std::ffi::{c_char, c_void};
use std::sync::Mutex;

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

/// A connection to the AppleSMC kernel service.
pub struct SmcConnection {
    connection: u32,
    /// The size and type of each key already asked about. The lock also keeps one call at a
    /// time on the connection.
    info: Mutex<HashMap<u32, (u32, u32)>>,
}

// The connection is a Mach port, and every call on it holds the lock.
unsafe impl Send for SmcConnection {}
unsafe impl Sync for SmcConnection {}

impl SmcConnection {
    pub fn open() -> Result<Self, SmcError> {
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
            Ok(Self { connection, info: Mutex::new(HashMap::new()) })
        }
    }

    fn call(&self, input: &Param) -> Result<Param, SmcError> {
        let mut output = Param::default();
        let mut output_size = std::mem::size_of::<Param>();
        // SAFETY: both structures are the size the kernel expects, and both outlive the call.
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

impl Drop for SmcConnection {
    fn drop(&mut self) {
        // SAFETY: the connection was opened by `open` and is closed once.
        unsafe {
            IOServiceClose(self.connection);
        }
    }
}

impl SmcAccess for SmcConnection {
    fn read(&self, key: &str) -> Result<SmcValue, SmcError> {
        let code = code(key).ok_or(SmcError::InvalidKey)?;
        let mut info = self.info.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let (size, kind) = self.key_info(&mut info, code)?;
        let mut input = Param { key: code, data8: COMMAND_READ, ..Param::default() };
        input.key_info.data_size = size;
        let output = self.call(&input)?;
        let count = (size as usize).min(32);
        Ok(SmcValue { kind: kind.to_be_bytes(), bytes: output.bytes[..count].to_vec() })
    }

    fn write(&self, key: &str, bytes: &[u8]) -> Result<(), SmcError> {
        let code = code(key).ok_or(SmcError::InvalidKey)?;
        let mut info = self.info.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
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
        let _guard = self.info.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
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
}
