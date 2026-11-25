//! AirFlow's backend: everything that talks to the Mac itself.
//!
//! - `smc` opens the system management controller and reads and writes its keys.
//! - `sensors` reads the fans and the temperature sensors and names them.
//! - `fans` sets fan targets, clamped to each fan's own limits. Only the helper runs it.
//! - `power` says whether the Mac is on its battery.
//! - `signing` decides which code the app and the helper trust.
//! - `protocol` names the messages the app sends the helper.
//! - `ffi` is the C interface the Swift app links.
//!
//! The helper itself is `src/bin/helper.rs`.

// Outside tests, nothing may stop the program on a value that is missing.
#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used))]

pub mod fans;
pub mod ffi;
pub mod power;
pub mod protocol;
pub mod sensors;
pub mod signing;
pub mod smc;
pub mod testing;
