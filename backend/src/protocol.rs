//! The names the app and the helper must agree on. backend/include/airflow.h repeats them
//! for the Swift app, and a test below fails if the two disagree.

use std::time::Duration;

pub const SERVICE: &str = "com.kevster.airflow.helper";
pub const HELPER_IDENTIFIER: &str = "com.kevster.airflow.helper";
pub const CLIENT_IDENTIFIERS: [&str; 2] = ["com.kevster.airflow", "com.kevster.airflow.debug"];
/// Raise this when the messages change, so the app can tell an older helper apart.
pub const PROTOCOL_VERSION: &str = "1";

pub const KEY_OPERATION: &str = "op";
pub const KEY_FAN: &str = "fan";
pub const KEY_RPM: &str = "rpm";
pub const KEY_OK: &str = "ok";
pub const KEY_ERROR: &str = "error";
pub const KEY_VERSION: &str = "version";

pub const OP_VERSION: &str = "version";
pub const OP_SET_FAN: &str = "set_fan";
pub const OP_SET_AUTOMATIC: &str = "set_automatic";
pub const OP_RESET_ALL: &str = "reset_all";
pub const OP_KEEP_ALIVE: &str = "keep_alive";

/// The helper returns every fan to the system when the app is silent for this long.
pub const WATCHDOG: Duration = Duration::from_secs(30);
/// The helper exits this long after its last client leaves. launchd starts it again on demand.
pub const IDLE_EXIT: Duration = Duration::from_secs(10);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_header_names_the_same_things() {
        let header = include_str!("../include/airflow.h");
        for (name, value) in [
            ("AIRFLOW_HELPER_SERVICE", SERVICE),
            ("AIRFLOW_HELPER_PROTOCOL_VERSION", PROTOCOL_VERSION),
            ("AIRFLOW_KEY_OPERATION", KEY_OPERATION),
            ("AIRFLOW_KEY_FAN", KEY_FAN),
            ("AIRFLOW_KEY_RPM", KEY_RPM),
            ("AIRFLOW_KEY_OK", KEY_OK),
            ("AIRFLOW_KEY_ERROR", KEY_ERROR),
            ("AIRFLOW_KEY_VERSION", KEY_VERSION),
            ("AIRFLOW_OP_VERSION", OP_VERSION),
            ("AIRFLOW_OP_SET_FAN", OP_SET_FAN),
            ("AIRFLOW_OP_SET_AUTOMATIC", OP_SET_AUTOMATIC),
            ("AIRFLOW_OP_RESET_ALL", OP_RESET_ALL),
            ("AIRFLOW_OP_KEEP_ALIVE", OP_KEEP_ALIVE),
        ] {
            assert!(header.contains(&format!("#define {name} \"{value}\"")), "{name} differs from airflow.h");
        }
        for (name, group) in [
            ("CPU", 0), ("GPU", 1), ("MEMORY", 2), ("STORAGE", 3), ("BATTERY", 4),
            ("ENCLOSURE", 5), ("POWER", 6), ("WIRELESS", 7), ("OTHER", 8),
        ] {
            assert!(header.contains(&format!("AIRFLOW_GROUP_{name} = {group},")), "group {name} differs from airflow.h");
        }
    }

    #[test]
    fn the_helper_trusts_only_the_app() {
        assert_eq!(SERVICE, HELPER_IDENTIFIER);
        assert!(!CLIENT_IDENTIFIERS.contains(&HELPER_IDENTIFIER));
    }
}
