//! The C interface the Swift app links. backend/include/airflow.h declares it.
//!
//! Every function checks its pointers. None of them unwinds into Swift, as the library is built
//! with `panic = "abort"`.

use crate::sensors::{FanReading, Reader, SensorReading, ALL_GROUPS};
use crate::smc::{SmcAccess, SmcConnection};
use crate::testing::FakeSmc;
use crate::usage::AppUsage;
use crate::{power, protocol, signing, usage};
use std::ffi::c_char;

#[repr(C)]
pub struct AirflowFan {
    pub index: i32,
    pub minimum_rpm: f64,
    pub maximum_rpm: f64,
    pub current_rpm: f64,
    pub target_rpm: f64,
    pub is_manual: bool,
}

#[repr(C)]
pub struct AirflowSensor {
    pub key: [c_char; 8],
    pub name: [c_char; 56],
    pub group: u8,
    pub is_known: bool,
    pub celsius: f64,
}

#[repr(C)]
pub struct AirflowAppUsage {
    pub bundle_path: [c_char; 1024],
    pub cpu_seconds: f64,
    pub running_seconds: f64,
    pub memory_bytes: u64,
    pub processes: i32,
}

fn app_usage(app: &AppUsage) -> AirflowAppUsage {
    let mut out = AirflowAppUsage {
        bundle_path: [0; 1024],
        cpu_seconds: app.cpu_seconds,
        running_seconds: app.running_seconds,
        memory_bytes: app.memory_bytes,
        processes: i32::try_from(app.processes).unwrap_or(i32::MAX),
    };
    fill(&mut out.bundle_path, &app.bundle_path);
    out
}

pub struct AirflowReader {
    reader: Reader<Box<dyn SmcAccess + Send>>,
}

fn boxed(smc: Box<dyn SmcAccess + Send>) -> *mut AirflowReader {
    Box::into_raw(Box::new(AirflowReader { reader: Reader::new(smc, cfg!(target_arch = "aarch64")) }))
}

/// Copies text into a fixed field, cut to fit, always NUL-terminated.
fn fill(field: &mut [c_char], text: &str) {
    let room = field.len() - 1;
    let mut end = text.len().min(room);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    for (slot, byte) in field.iter_mut().zip(text.as_bytes()[..end].iter()) {
        *slot = *byte as c_char;
    }
    field[end] = 0;
}

fn fan(reading: &FanReading) -> AirflowFan {
    AirflowFan {
        index: reading.index as i32,
        minimum_rpm: reading.minimum_rpm,
        maximum_rpm: reading.maximum_rpm,
        current_rpm: reading.current_rpm,
        target_rpm: reading.target_rpm,
        is_manual: reading.is_manual,
    }
}

fn sensor(reading: &SensorReading) -> AirflowSensor {
    let mut out = AirflowSensor {
        key: [0; 8],
        name: [0; 56],
        group: reading.group as u8,
        is_known: reading.is_known,
        celsius: reading.celsius,
    };
    fill(&mut out.key, &reading.key);
    fill(&mut out.name, &reading.name);
    out
}

// coverage:off It opens the Mac's own SMC, which a test must not depend on.
#[no_mangle]
pub extern "C" fn airflow_reader_open() -> *mut AirflowReader {
    match SmcConnection::open() {
        Ok(connection) => boxed(Box::new(connection)),
        Err(_) => std::ptr::null_mut(),
    }
}
// coverage:on

#[no_mangle]
pub extern "C" fn airflow_reader_open_sample() -> *mut AirflowReader {
    boxed(Box::new(FakeSmc::sample()))
}

/// # Safety
/// `reader` is null or a pointer from `airflow_reader_open` that has not been closed.
#[no_mangle]
pub unsafe extern "C" fn airflow_reader_close(reader: *mut AirflowReader) {
    if !reader.is_null() {
        drop(Box::from_raw(reader));
    }
}

/// # Safety
/// `reader` is null or an open reader, and `fans` is null or points at `capacity` entries.
#[no_mangle]
pub unsafe extern "C" fn airflow_reader_read_fans(reader: *mut AirflowReader, fans: *mut AirflowFan, capacity: i32) -> i32 {
    let (Some(reader), false, Ok(capacity)) = (reader.as_mut(), fans.is_null(), usize::try_from(capacity)) else {
        return 0;
    };
    let readings = reader.reader.fans();
    let count = readings.len().min(capacity);
    for (offset, reading) in readings.iter().take(count).enumerate() {
        fans.add(offset).write(fan(reading));
    }
    count as i32
}

/// # Safety
/// `reader` is null or an open reader, and `sensors` is null or points at `capacity` entries.
#[no_mangle]
pub unsafe extern "C" fn airflow_reader_read_sensors(reader: *mut AirflowReader, sensors: *mut AirflowSensor, capacity: i32) -> i32 {
    airflow_reader_read_sensors_in(reader, sensors, capacity, ALL_GROUPS)
}

/// Every sensor, as `airflow_reader_read_sensors` gives them. Only the sensors of the groups in
/// `groups` are read now: bit `n` is the group numbered `n`. Each other sensor has its last
/// reading.
///
/// # Safety
/// `reader` is null or an open reader, and `sensors` is null or points at `capacity` entries.
#[no_mangle]
pub unsafe extern "C" fn airflow_reader_read_sensors_in(
    reader: *mut AirflowReader, sensors: *mut AirflowSensor, capacity: i32, groups: u32,
) -> i32 {
    let (Some(reader), false, Ok(capacity)) = (reader.as_mut(), sensors.is_null(), usize::try_from(capacity)) else {
        return 0;
    };
    let readings = reader.reader.sensors_in(groups);
    let count = readings.len().min(capacity);
    for (offset, reading) in readings.iter().take(count).enumerate() {
        sensors.add(offset).write(sensor(reading));
    }
    count as i32
}

/// The power the whole Mac draws, in watts, or a negative number where it is not reported.
///
/// # Safety
/// `reader` is null or an open reader.
#[no_mangle]
pub unsafe extern "C" fn airflow_reader_read_system_power(reader: *mut AirflowReader) -> f64 {
    reader.as_mut().and_then(|reader| reader.reader.system_power()).unwrap_or(-1.0)
}

/// The running apps with the processor time and the memory each one's processes use, the app
/// with the most processor time first.
///
/// # Safety
/// `apps` is null or points at `capacity` entries.
#[no_mangle]
pub unsafe extern "C" fn airflow_app_usage(apps: *mut AirflowAppUsage, capacity: i32) -> i32 {
    let (false, Ok(capacity)) = (apps.is_null(), usize::try_from(capacity)) else {
        return 0;
    };
    let running = usage::apps();
    let count = running.len().min(capacity);
    for (offset, app) in running.iter().take(count).enumerate() {
        apps.add(offset).write(app_usage(app));
    }
    count as i32
}

#[no_mangle]
pub extern "C" fn airflow_power_source_is_battery() -> i32 {
    i32::from(power::is_on_battery())
}

/// # Safety
/// `buffer` is null or points at `capacity` bytes.
#[no_mangle]
pub unsafe extern "C" fn airflow_helper_requirement(buffer: *mut c_char, capacity: i32) -> i32 {
    write_requirement(signing::own_requirement(&[protocol::HELPER_IDENTIFIER]), buffer, capacity)
}

/// Writes a requirement as a NUL-terminated string and returns its length, or 0 when there is
/// none or it does not fit.
///
/// # Safety
/// `buffer` is null or points at `capacity` bytes.
unsafe fn write_requirement(requirement: Option<String>, buffer: *mut c_char, capacity: i32) -> i32 {
    let (Some(requirement), false, Ok(capacity)) = (requirement, buffer.is_null(), usize::try_from(capacity)) else {
        return 0;
    };
    // A requirement that does not fit must not be cut short into a weaker one.
    if requirement.len() + 1 > capacity {
        return 0;
    }
    std::ptr::copy_nonoverlapping(requirement.as_ptr().cast::<c_char>(), buffer, requirement.len());
    buffer.add(requirement.len()).write(0);
    requirement.len() as i32
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn the_sample_reader_crosses_the_interface() {
        unsafe {
            let reader = airflow_reader_open_sample();
            let mut fans: [AirflowFan; 8] = std::mem::zeroed();
            assert_eq!(airflow_reader_read_fans(reader, fans.as_mut_ptr(), 8), 2);
            assert_eq!(fans[0].current_rpm, 2400.0);
            assert!(fans[0].is_manual);
            assert_eq!(fans[1].maximum_rpm, 5777.0);

            let mut sensors: [AirflowSensor; 16] = std::mem::zeroed();
            let count = airflow_reader_read_sensors(reader, sensors.as_mut_ptr(), 16);
            assert_eq!(count, 7);
            let names: Vec<String> = sensors[..count as usize]
                .iter()
                .map(|sensor| CStr::from_ptr(sensor.name.as_ptr()).to_str().expect("utf8").to_owned())
                .collect();
            assert!(names.contains(&"Airflow Left".to_owned()));
            assert_eq!(CStr::from_ptr(sensors[0].key.as_ptr()).to_bytes().len(), 4);

            assert_eq!(airflow_reader_read_sensors(reader, sensors.as_mut_ptr(), 3), 3, "No more than the caller has room for");
            assert_eq!(airflow_reader_read_sensors_in(reader, sensors.as_mut_ptr(), 16, 1), 7, "Every sensor comes back, whichever groups are read");
            assert_eq!(airflow_reader_read_sensors_in(reader, sensors.as_mut_ptr(), 16, 0), 7);
            assert_eq!(airflow_reader_read_sensors_in(reader, std::ptr::null_mut(), 16, 1), 0);
            assert_eq!(airflow_reader_read_sensors_in(std::ptr::null_mut(), sensors.as_mut_ptr(), 16, 1), 0);
            assert_eq!(airflow_reader_read_sensors_in(reader, sensors.as_mut_ptr(), -1, 1), 0);
            assert_eq!(airflow_reader_read_fans(reader, std::ptr::null_mut(), 8), 0);
            assert_eq!(airflow_reader_read_fans(reader, fans.as_mut_ptr(), -1), 0);
            assert_eq!(airflow_reader_read_fans(std::ptr::null_mut(), fans.as_mut_ptr(), 8), 0);
            assert_eq!(airflow_reader_read_system_power(reader), 28.5);
            assert!(airflow_reader_read_system_power(std::ptr::null_mut()) < 0.0);
            airflow_reader_close(reader);
            airflow_reader_close(std::ptr::null_mut());
        }
    }

    #[test]
    fn the_running_apps_cross_the_interface() {
        unsafe {
            let mut apps: Vec<AirflowAppUsage> = (0..64).map(|_| std::mem::zeroed()).collect();
            let count = airflow_app_usage(apps.as_mut_ptr(), 64);
            assert!((0..=64).contains(&count));
            for app in &apps[..count as usize] {
                let path = CStr::from_ptr(app.bundle_path.as_ptr()).to_str().expect("utf8");
                assert!(path.ends_with(".app"), "{path}");
                assert!(app.processes > 0 && app.cpu_seconds >= 0.0 && app.running_seconds >= 0.0);
            }
            assert!(apps[..count as usize].windows(2).all(|pair| pair[0].cpu_seconds >= pair[1].cpu_seconds), "The busiest app is first");
            assert!(airflow_app_usage(apps.as_mut_ptr(), 1) <= 1, "No more than the caller has room for");
            assert_eq!(airflow_app_usage(std::ptr::null_mut(), 64), 0);
            assert_eq!(airflow_app_usage(apps.as_mut_ptr(), -1), 0);
        }
        let long = AppUsage { bundle_path: "/".to_owned() + &"a".repeat(2_000) + ".app", cpu_seconds: 1.0, running_seconds: 2.0, memory_bytes: 3, processes: usize::MAX };
        let out = app_usage(&long);
        assert_eq!(unsafe { CStr::from_ptr(out.bundle_path.as_ptr()) }.to_bytes().len(), 1023, "A path that does not fit is cut, and still ends");
        assert_eq!(out.processes, i32::MAX);
    }

    #[test]
    fn text_is_cut_to_fit_and_terminated() {
        let mut field = [1 as c_char; 8];
        fill(&mut field, "Performance");
        assert_eq!(unsafe { CStr::from_ptr(field.as_ptr()) }.to_str(), Ok("Perform"));
        fill(&mut field, "ab°cdefg");
        assert_eq!(unsafe { CStr::from_ptr(field.as_ptr()) }.to_str(), Ok("ab°cde"));
        fill(&mut field, "abcdef°g");
        assert_eq!(unsafe { CStr::from_ptr(field.as_ptr()) }.to_str(), Ok("abcdef"), "A character is never cut in half");
        fill(&mut field, "");
        assert_eq!(unsafe { CStr::from_ptr(field.as_ptr()) }.to_str(), Ok(""));
    }

    #[test]
    fn a_requirement_is_written_whole_or_not_at_all() {
        let requirement = || Some("anchor apple".to_owned());
        let mut buffer = [1 as c_char; 32];
        unsafe {
            assert_eq!(write_requirement(requirement(), buffer.as_mut_ptr(), 32), 12);
            assert_eq!(CStr::from_ptr(buffer.as_ptr()).to_str(), Ok("anchor apple"));
            assert_eq!(write_requirement(requirement(), buffer.as_mut_ptr(), 13), 12, "It fits with its terminator");
            let mut small = [1 as c_char; 12];
            assert_eq!(write_requirement(requirement(), small.as_mut_ptr(), 12), 0, "A requirement cut short would be a weaker one");
            assert_eq!(small, [1; 12], "Nothing is written");
            assert_eq!(write_requirement(requirement(), std::ptr::null_mut(), 32), 0);
            assert_eq!(write_requirement(requirement(), buffer.as_mut_ptr(), -1), 0);
            assert_eq!(write_requirement(None, buffer.as_mut_ptr(), 32), 0);
        }
    }

    #[test]
    fn the_power_source_is_one_of_two() {
        assert!((0..=1).contains(&airflow_power_source_is_battery()));
    }

    #[test]
    fn an_unsigned_program_gets_no_requirement() {
        let mut buffer = [0 as c_char; 256];
        assert_eq!(unsafe { airflow_helper_requirement(buffer.as_mut_ptr(), 256) }, 0);
    }

    #[test]
    fn the_header_declares_every_function() {
        let header = include_str!("../include/airflow.h");
        for name in [
            "airflow_reader_open(void)", "airflow_reader_open_sample(void)", "airflow_reader_close(",
            "airflow_reader_read_fans(", "airflow_reader_read_sensors(", "airflow_reader_read_sensors_in(",
            "airflow_reader_read_system_power(",
            "airflow_power_source_is_battery(void)", "airflow_app_usage(",
            "airflow_helper_requirement(",
        ] {
            assert!(header.contains(name), "{name} is missing from airflow.h");
        }
    }
}
