//! The app and the helper trust each other only when one team signed both.

use std::ffi::{c_char, c_void, CStr};

#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SecCodeCopySelf(flags: u32, code: *mut *const c_void) -> i32;
    fn SecCodeCopySigningInformation(code: *const c_void, flags: u32, information: *mut *const c_void) -> i32;
    static kSecCodeInfoTeamIdentifier: *const c_void;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(object: *const c_void);
    fn CFDictionaryGetValue(dictionary: *const c_void, key: *const c_void) -> *const c_void;
    fn CFStringGetCString(string: *const c_void, buffer: *mut c_char, size: isize, encoding: u32) -> u8;
}

const SIGNING_INFORMATION: u32 = 1 << 1;
const UTF8: u32 = 0x0800_0100;

/// A team identifier is ten capital letters and digits.
pub fn is_team_identifier(value: &str) -> bool {
    value.len() == 10 && value.bytes().all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
}

/// The team that signed the running program, or None for an ad hoc or unsigned build.
pub fn own_team_identifier() -> Option<String> {
    // SAFETY: each object the Security framework returns is checked for null and released,
    // and the team identifier is copied out of the dictionary before the dictionary goes.
    unsafe {
        let mut code: *const c_void = std::ptr::null();
        if SecCodeCopySelf(0, &mut code) != 0 || code.is_null() {
            return None;
        }
        let mut information: *const c_void = std::ptr::null();
        let status = SecCodeCopySigningInformation(code, SIGNING_INFORMATION, &mut information);
        CFRelease(code);
        if status != 0 || information.is_null() {
            return None;
        }
        let team = CFDictionaryGetValue(information, kSecCodeInfoTeamIdentifier);
        let mut buffer = [0 as c_char; 32];
        let copied = !team.is_null() && CFStringGetCString(team, buffer.as_mut_ptr(), buffer.len() as isize, UTF8) != 0;
        CFRelease(information);
        if !copied {
            return None;
        }
        let team = CStr::from_ptr(buffer.as_ptr()).to_str().ok()?.to_owned();
        is_team_identifier(&team).then_some(team)
    }
}

/// A requirement that only code with one of the identifiers, signed by the team through an
/// Apple-issued certificate, satisfies. None when the team or an identifier is malformed.
pub fn requirement(identifiers: &[&str], team: &str) -> Option<String> {
    let well_formed = |identifier: &&str| {
        !identifier.is_empty() && identifier.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'.')
    };
    if !is_team_identifier(team) || identifiers.is_empty() || !identifiers.iter().all(well_formed) {
        return None;
    }
    let names: Vec<String> = identifiers.iter().map(|identifier| format!("identifier \"{identifier}\"")).collect();
    Some(format!("anchor apple generic and certificate leaf[subject.OU] = \"{team}\" and ({})", names.join(" or ")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requirement_names_the_team_and_every_identifier() {
        assert_eq!(
            requirement(&["com.kevster.airflow", "com.kevster.airflow.debug"], "ABCDE12345").as_deref(),
            Some("anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and (identifier \"com.kevster.airflow\" or identifier \"com.kevster.airflow.debug\")")
        );
    }

    #[test]
    fn anything_that_is_not_a_team_identifier_makes_no_requirement() {
        let app = ["com.kevster.airflow"];
        assert_eq!(requirement(&app, ""), None);
        assert_eq!(requirement(&app, "abcde12345"), None);
        assert_eq!(requirement(&app, "ABCDE1234\""), None);
        assert_eq!(requirement(&app, "ABCDE12345 or anchor apple"), None);
        assert_eq!(requirement(&[], "ABCDE12345"), None);
        assert_eq!(requirement(&["x\" or identifier \"y"], "ABCDE12345"), None);
        assert_eq!(requirement(&[""], "ABCDE12345"), None);
    }

    #[test]
    fn a_test_binary_has_no_team() {
        // cargo signs test binaries ad hoc, which is the case the helper must refuse.
        assert_eq!(own_team_identifier(), None);
    }
}
