//! Whether the Mac is running on its battery.

use std::ffi::{c_char, c_void, CStr};

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOPSCopyPowerSourcesInfo() -> *const c_void;
    fn IOPSGetProvidingPowerSourceType(snapshot: *const c_void) -> *const c_void;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(object: *const c_void);
    fn CFStringGetCString(string: *const c_void, buffer: *mut c_char, size: isize, encoding: u32) -> u8;
}

const UTF8: u32 = 0x0800_0100;
const BATTERY_POWER: &str = "Battery Power";

/// True when the Mac draws from its battery. A Mac with no battery, or one that is plugged
/// in, is on its adapter.
pub fn is_on_battery() -> bool {
    // SAFETY: the snapshot is released after the string it owns has been copied out.
    unsafe {
        let snapshot = IOPSCopyPowerSourcesInfo();
        if snapshot.is_null() {
            return false;
        }
        let kind = IOPSGetProvidingPowerSourceType(snapshot);
        let mut buffer = [0 as c_char; 64];
        let copied = !kind.is_null() && CFStringGetCString(kind, buffer.as_mut_ptr(), buffer.len() as isize, UTF8) != 0;
        CFRelease(snapshot);
        copied && CStr::from_ptr(buffer.as_ptr()).to_str() == Ok(BATTERY_POWER)
    }
}
