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
    is_battery(providing_source().as_deref())
}

fn is_battery(source: Option<&str>) -> bool {
    source == Some(BATTERY_POWER)
}

/// What the Mac draws from now, in IOKit's words: "AC Power", "Battery Power", or "UPS Power".
fn providing_source() -> Option<String> {
    // SAFETY: the snapshot is released after the string it owns has been copied out.
    unsafe {
        let snapshot = IOPSCopyPowerSourcesInfo();
        // coverage:off IOKit gives a snapshot of the power sources on every Mac.
        if snapshot.is_null() {
            return None;
        }
        // coverage:on
        let kind = IOPSGetProvidingPowerSourceType(snapshot);
        let mut buffer = [0 as c_char; 64];
        let copied = !kind.is_null() && CFStringGetCString(kind, buffer.as_mut_ptr(), buffer.len() as isize, UTF8) != 0;
        CFRelease(snapshot);
        copied.then(|| CStr::from_ptr(buffer.as_ptr()).to_string_lossy().into_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_battery_power_is_the_battery() {
        assert!(is_battery(Some("Battery Power")));
        assert!(!is_battery(Some("AC Power")));
        assert!(!is_battery(Some("UPS Power")));
        assert!(!is_battery(None));
    }

    #[test]
    fn the_mac_says_what_it_draws_from() {
        let source = providing_source();
        assert!(matches!(source.as_deref(), Some("AC Power" | "Battery Power" | "UPS Power")), "{source:?}");
        assert_eq!(is_on_battery(), source.as_deref() == Some("Battery Power"));
    }
}
