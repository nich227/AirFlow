//! AirFlow's helper. It runs as root because only root may write to the SMC, and launchd
//! starts it when the app connects. It does one job: it holds fans at the speeds the signed
//! app asks for, and gives them back to the system when the app goes away or goes quiet.

use airflow_backend::fans::FanWriter;
use airflow_backend::smc::SmcConnection;
use airflow_backend::{protocol, signing};
use block2::{Block, RcBlock};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

type XpcObject = *mut c_void;

#[repr(C)]
struct XpcType {
    _private: [u8; 0],
}

extern "C" {
    static _xpc_type_connection: XpcType;
    static _xpc_type_dictionary: XpcType;

    fn xpc_connection_create_mach_service(name: *const c_char, queue: *mut c_void, flags: u64) -> XpcObject;
    fn xpc_connection_set_event_handler(connection: XpcObject, handler: &Block<dyn Fn(XpcObject)>);
    fn xpc_connection_set_peer_code_signing_requirement(connection: XpcObject, requirement: *const c_char) -> c_int;
    fn xpc_connection_activate(connection: XpcObject);
    fn xpc_connection_cancel(connection: XpcObject);
    fn xpc_connection_send_message(connection: XpcObject, message: XpcObject);
    fn xpc_get_type(object: XpcObject) -> *const XpcType;
    fn xpc_dictionary_get_string(dictionary: XpcObject, key: *const c_char) -> *const c_char;
    fn xpc_dictionary_get_int64(dictionary: XpcObject, key: *const c_char) -> i64;
    fn xpc_dictionary_get_double(dictionary: XpcObject, key: *const c_char) -> f64;
    fn xpc_dictionary_get_value(dictionary: XpcObject, key: *const c_char) -> XpcObject;
    fn xpc_dictionary_create_reply(original: XpcObject) -> XpcObject;
    fn xpc_dictionary_get_remote_connection(dictionary: XpcObject) -> XpcObject;
    fn xpc_dictionary_set_string(dictionary: XpcObject, key: *const c_char, value: *const c_char);
    fn xpc_dictionary_set_bool(dictionary: XpcObject, key: *const c_char, value: bool);
    fn xpc_dictionary_set_double(dictionary: XpcObject, key: *const c_char, value: f64);
    fn xpc_release(object: XpcObject);
    fn dispatch_main() -> !;
}

const LISTENER: u64 = 1 << 0;

/// Everything the helper knows. One lock guards it, so one SMC write runs at a time.
struct State {
    writer: Option<FanWriter<SmcConnection>>,
    clients: usize,
    last_contact: Instant,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

fn state() -> MutexGuard<'static, State> {
    STATE
        .get_or_init(|| Mutex::new(State { writer: None, clients: 0, last_contact: Instant::now() }))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl State {
    fn writer(&mut self) -> Result<&mut FanWriter<SmcConnection>, String> {
        if self.writer.is_none() {
            let connection = SmcConnection::open().map_err(|_| "The helper can't open the SMC.".to_owned())?;
            self.writer = Some(FanWriter::new(connection));
        }
        self.writer.as_mut().ok_or_else(|| "The helper can't open the SMC.".to_owned())
    }

    fn reset_all(&mut self) {
        if let Some(writer) = self.writer.as_mut() {
            writer.reset_all();
        }
    }

    fn holds_a_fan(&self) -> bool {
        self.writer.as_ref().is_some_and(|writer| !writer.manual_fans().is_empty())
    }
}

fn key(name: &str) -> CString {
    CString::new(name).unwrap_or_default()
}

/// What one request asks for, read out of its dictionary before any lock is taken.
struct Request {
    operation: String,
    fan: i64,
    rpm: f64,
}

unsafe fn request(message: XpcObject) -> Option<Request> {
    let operation = xpc_dictionary_get_string(message, key(protocol::KEY_OPERATION).as_ptr());
    if operation.is_null() {
        return None;
    }
    // A request with no fan must not read as fan 0, so a missing number is out of range.
    let fan_key = key(protocol::KEY_FAN);
    let fan = if xpc_dictionary_get_value(message, fan_key.as_ptr()).is_null() {
        -1
    } else {
        xpc_dictionary_get_int64(message, fan_key.as_ptr())
    };
    let rpm_key = key(protocol::KEY_RPM);
    let rpm = if xpc_dictionary_get_value(message, rpm_key.as_ptr()).is_null() {
        f64::NAN
    } else {
        xpc_dictionary_get_double(message, rpm_key.as_ptr())
    };
    Some(Request { operation: CStr::from_ptr(operation).to_str().ok()?.to_owned(), fan, rpm })
}

/// Does what the request asks. The answer is the speed written, when there is one.
fn perform(request: &Request) -> Result<Option<f64>, String> {
    let mut state = state();
    state.last_contact = Instant::now();
    match request.operation.as_str() {
        protocol::OP_VERSION | protocol::OP_KEEP_ALIVE => Ok(None),
        protocol::OP_SET_FAN => {
            state.writer()?.set_target(request.fan, request.rpm).map(Some).map_err(|error| error.to_string())
        }
        protocol::OP_SET_AUTOMATIC => state.writer()?.set_automatic(request.fan).map(|()| None).map_err(|error| error.to_string()),
        protocol::OP_RESET_ALL => {
            state.reset_all();
            Ok(None)
        }
        other => Err(format!("The helper doesn't know the request “{other}”.")),
    }
}

unsafe fn answer(message: XpcObject) {
    let reply = xpc_dictionary_create_reply(message);
    if reply.is_null() {
        // The sender did not ask for a reply.
        if let Some(request) = request(message) {
            let _ = perform(&request);
        }
        return;
    }
    let result = request(message).map_or_else(|| Err("The request names no operation.".to_owned()), |request| perform(&request));
    match result {
        Ok(written) => {
            xpc_dictionary_set_bool(reply, key(protocol::KEY_OK).as_ptr(), true);
            xpc_dictionary_set_string(reply, key(protocol::KEY_VERSION).as_ptr(), key(protocol::PROTOCOL_VERSION).as_ptr());
            if let Some(rpm) = written {
                xpc_dictionary_set_double(reply, key(protocol::KEY_RPM).as_ptr(), rpm);
            }
        }
        Err(error) => {
            xpc_dictionary_set_bool(reply, key(protocol::KEY_OK).as_ptr(), false);
            xpc_dictionary_set_string(reply, key(protocol::KEY_ERROR).as_ptr(), key(&error).as_ptr());
        }
    }
    xpc_connection_send_message(xpc_dictionary_get_remote_connection(message), reply);
    xpc_release(reply);
}

fn client_arrived() {
    let mut state = state();
    state.clients += 1;
    state.last_contact = Instant::now();
}

/// The app quit, crashed, or closed its connection. Its fans go back to the system, and the
/// helper exits a little later if nobody else has connected.
fn client_left() {
    {
        let mut state = state();
        state.clients = state.clients.saturating_sub(1);
        if state.clients > 0 {
            return;
        }
        state.reset_all();
    }
    std::thread::spawn(|| {
        std::thread::sleep(protocol::IDLE_EXIT);
        if state().clients == 0 {
            std::process::exit(0);
        }
    });
}

/// An app that hangs keeps its connection open but stops talking. Fans it pinned must not
/// stay pinned, so silence past the limit returns them to the system.
fn watch_for_silence() {
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(5));
        let mut state = state();
        if state.holds_a_fan() && state.last_contact.elapsed() > protocol::WATCHDOG {
            state.reset_all();
        }
    });
}

/// launchd stops the helper with SIGTERM. A thread waits for it, so the fans can be given
/// back with ordinary code and not inside a signal handler.
fn give_fans_back_on_termination() {
    // SAFETY: the signal set is initialized before use, and the mask is set before any other
    // thread exists, so every thread inherits it and only `sigwait` receives the signal.
    unsafe {
        let mut signals: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut signals);
        libc::sigaddset(&mut signals, libc::SIGTERM);
        libc::pthread_sigmask(libc::SIG_BLOCK, &signals, std::ptr::null_mut());
        std::thread::spawn(move || {
            let mut received: c_int = 0;
            libc::sigwait(&signals, &mut received);
            state().reset_all();
            std::process::exit(0);
        });
    }
}

fn main() {
    give_fans_back_on_termination();
    watch_for_silence();

    // The helper accepts only the app that the helper's own team signed. A helper with no
    // team, such as an ad hoc build, accepts no one.
    let requirement = signing::own_team_identifier()
        .and_then(|team| signing::requirement(&protocol::CLIENT_IDENTIFIERS, &team))
        .and_then(|requirement| CString::new(requirement).ok());

    let on_client = RcBlock::new(move |peer: XpcObject| {
        // SAFETY: XPC hands the listener live objects, and each peer is configured before it
        // is activated. The peer's handler copies nothing but the pointer XPC keeps alive.
        unsafe {
            if xpc_get_type(peer) != std::ptr::addr_of!(_xpc_type_connection) {
                return;
            }
            let trusted = requirement
                .as_ref()
                .is_some_and(|requirement| xpc_connection_set_peer_code_signing_requirement(peer, requirement.as_ptr()) == 0);
            if !trusted {
                xpc_connection_cancel(peer);
                return;
            }
            client_arrived();
            let gone = AtomicBool::new(false);
            let on_message = RcBlock::new(move |event: XpcObject| {
                if xpc_get_type(event) == std::ptr::addr_of!(_xpc_type_dictionary) {
                    answer(event);
                } else if !gone.swap(true, Ordering::SeqCst) {
                    // Anything else is an error: the connection is gone. It can be reported
                    // more than once, and the client leaves only once.
                    client_left();
                }
            });
            xpc_connection_set_event_handler(peer, &on_message);
            xpc_connection_activate(peer);
        }
    });

    // SAFETY: the service name is NUL-terminated, a null queue means the default queue, and
    // the listener lives for the life of the process.
    unsafe {
        let name = key(protocol::SERVICE);
        let listener = xpc_connection_create_mach_service(name.as_ptr(), std::ptr::null_mut(), LISTENER);
        xpc_connection_set_event_handler(listener, &on_client);
        xpc_connection_activate(listener);
        dispatch_main();
    }
}
