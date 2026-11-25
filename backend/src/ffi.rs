//! The C interface the Swift app links. backend/include/airflow.h declares it.
//!
//! Every function checks its pointers, and none of them unwinds into Swift: the library is
//! built with `panic = "abort"`.

use crate::sensors::{FanReading, Reader, SensorReading};
use crate::smc::{SmcAccess, SmcConnection};
use crate::testing::FakeSmc;
use crate::{power, protocol, signing};
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

#[no_mangle]
pub extern "C" fn airflow_reader_open() -> *mut AirflowReader {
    match SmcConnection::open() {
        Ok(connection) => boxed(Box::new(connection)),
        Err(_) => std::ptr::null_mut(),
    }
}

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
    let (Some(reader), false, Ok(capacity)) = (reader.as_mut(), sensors.is_null(), usize::try_from(capacity)) else {
        return 0;
    };
    let readings = reader.reader.sensors();
    let count = readings.len().min(capacity);
    for (offset, reading) in readings.iter().take(count).enumerate() {
        sensors.add(offset).write(sensor(reading));
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
    let requirement = signing::own_team_identifier().and_then(|team| signing::requirement(&[protocol::HELPER_IDENTIFIER], &team));
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
            assert_eq!(airflow_reader_read_fans(reader, std::ptr::null_mut(), 8), 0);
            assert_eq!(airflow_reader_read_fans(reader, fans.as_mut_ptr(), -1), 0);
            assert_eq!(airflow_reader_read_fans(std::ptr::null_mut(), fans.as_mut_ptr(), 8), 0);
            airflow_reader_close(reader);
            airflow_reader_close(std::ptr::null_mut());
        }
    }

    #[test]
    fn text_is_cut_to_fit_and_terminated() {
        let mut field = [1 as c_char; 8];
        fill(&mut field, "Performance");
        assert_eq!(unsafe { CStr::from_ptr(field.as_ptr()) }.to_str(), Ok("Perform"));
        fill(&mut field, "ab°cdefg");
        assert_eq!(unsafe { CStr::from_ptr(field.as_ptr()) }.to_str(), Ok("ab°cde"));
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
            "airflow_reader_read_fans(", "airflow_reader_read_sensors(", "airflow_power_source_is_battery(void)",
            "airflow_helper_requirement(",
        ] {
            assert!(header.contains(name), "{name} is missing from airflow.h");
        }
    }
}
