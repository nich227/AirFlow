//! Setting fan targets. Only the helper uses this against real hardware, because writes
//! need root. Every speed is clamped to the limits the fan itself reports.

use crate::smc::SmcAccess;
use std::collections::BTreeSet;
use std::fmt;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub enum FanWriteError {
    NoSuchFan(i64),
    InvalidLimits(usize),
    InvalidSpeed,
    ControlRefused(usize),
    ReleaseRefused(usize),
    WriteFailed(String),
}

impl fmt::Display for FanWriteError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoSuchFan(index) => write!(formatter, "This Mac has no fan {}.", index + 1),
            Self::InvalidLimits(index) => write!(formatter, "Fan {} reports the same minimum and maximum speed.", index + 1),
            Self::InvalidSpeed => write!(formatter, "The speed is not a number."),
            Self::ControlRefused(index) => write!(formatter, "The system did not hand over fan {}.", index + 1),
            Self::ReleaseRefused(index) => write!(formatter, "The system did not take back fan {}.", index + 1),
            Self::WriteFailed(key) => write!(formatter, "The SMC refused a write to {key}."),
        }
    }
}

/// How long to wait for the system to hand a fan over after it is asked to.
pub const HANDOVER_ATTEMPTS: usize = 100;
pub const HANDOVER_DELAY: Duration = Duration::from_millis(100);
/// How many times to look for a fan that was given back to read as the system's again.
pub const RELEASE_ATTEMPTS: usize = 30;

pub struct FanWriter<S: SmcAccess> {
    smc: S,
    sleep: fn(Duration),
    manual: BTreeSet<usize>,
}

impl<S: SmcAccess> FanWriter<S> {
    pub fn new(smc: S) -> Self {
        Self::with_sleep(smc, std::thread::sleep)
    }

    pub fn with_sleep(smc: S, sleep: fn(Duration)) -> Self {
        Self { smc, sleep, manual: BTreeSet::new() }
    }

    /// The fans this writer holds.
    pub fn manual_fans(&self) -> &BTreeSet<usize> {
        &self.manual
    }

    pub fn fan_count(&self) -> usize {
        self.smc.number("FNum").map_or(0, |count| count as usize)
    }

    fn index(&self, fan: i64) -> Result<usize, FanWriteError> {
        usize::try_from(fan).ok().filter(|index| *index < self.fan_count()).ok_or(FanWriteError::NoSuchFan(fan))
    }

    /// The fan's own minimum and maximum speed.
    pub fn limits(&self, fan: i64) -> Result<(f64, f64), FanWriteError> {
        let index = self.index(fan)?;
        match (self.smc.number(&format!("F{index}Mn")), self.smc.number(&format!("F{index}Mx"))) {
            (Some(minimum), Some(maximum)) if minimum < maximum => Ok((minimum, maximum)),
            _ => Err(FanWriteError::InvalidLimits(index)),
        }
    }

    /// Holds the fan at the speed and returns the speed actually written.
    pub fn set_target(&mut self, fan: i64, rpm: f64) -> Result<f64, FanWriteError> {
        if !rpm.is_finite() {
            return Err(FanWriteError::InvalidSpeed);
        }
        let (minimum, maximum) = self.limits(fan)?;
        let index = self.index(fan)?;
        let target = rpm.clamp(minimum, maximum).round();
        self.take_control(index)?;
        let key = format!("F{index}Tg");
        self.smc.write_number(&key, target).map_err(|_| FanWriteError::WriteFailed(key))?;
        Ok(target)
    }

    /// Gives the fan back to the system.
    pub fn set_automatic(&mut self, fan: i64) -> Result<(), FanWriteError> {
        let index = self.index(fan)?;
        // The fan stops counting as held before the SMC agrees, so the last fan to be returned
        // always gives the system its control back.
        self.manual.remove(&index);
        if self.manual.is_empty() {
            // A fan's mode can keep reading as manual while the system's control is off, so the
            // system gets its control back first.
            let _ = self.set_mode(index, false);
            self.release_system_override();
        }
        self.give_back(index)
    }

    /// Gives every fan back to the system. It keeps going past a fan that fails.
    pub fn reset_all(&mut self) {
        for index in 0..self.fan_count() {
            let _ = self.set_mode(index, false);
        }
        self.manual.clear();
        self.release_system_override();
        // A fan whose mode did not change while the system's control was off is asked again.
        for index in 0..self.fan_count() {
            let _ = self.set_mode(index, false);
        }
    }

    /// Asks for the fan's mode to be the system's until it reads that way. The SMC can take a
    /// moment to follow a write.
    fn give_back(&self, index: usize) -> Result<(), FanWriteError> {
        for attempt in 0..RELEASE_ATTEMPTS {
            if self.set_mode(index, false).is_ok() {
                return Ok(());
            }
            if attempt + 1 < RELEASE_ATTEMPTS {
                (self.sleep)(HANDOVER_DELAY);
            }
        }
        Err(FanWriteError::ReleaseRefused(index))
    }

    fn take_control(&mut self, index: usize) -> Result<(), FanWriteError> {
        if self.set_mode(index, true).is_ok() {
            self.manual.insert(index);
            return Ok(());
        }
        // On Apple silicon the system's thermal manager owns the fans until this key asks it to
        // yield. It takes a few seconds to let go.
        if !self.smc.has("Ftst") {
            return Err(FanWriteError::ControlRefused(index));
        }
        let _ = self.smc.write_number("Ftst", 1.0);
        for _ in 0..HANDOVER_ATTEMPTS {
            if self.set_mode(index, true).is_ok() {
                self.manual.insert(index);
                return Ok(());
            }
            (self.sleep)(HANDOVER_DELAY);
        }
        // Nothing was handed over, so the system keeps the control it was asked to give up.
        if self.manual.is_empty() {
            self.release_system_override();
        }
        Err(FanWriteError::ControlRefused(index))
    }

    /// Writes the fan's mode and reads it back, because the SMC can accept a write it ignores.
    /// Manual is 1. A fan is the system's at any other number, because the SMC does not always
    /// report 0 for a fan the system controls.
    fn set_mode(&self, index: usize, manual: bool) -> Result<(), FanWriteError> {
        let mode_key = format!("F{index}Md");
        if self.smc.has(&mode_key) {
            let reads_as_wanted = |smc: &S| smc.number(&mode_key).is_some_and(|mode| (mode == 1.0) == manual);
            if reads_as_wanted(&self.smc) {
                return Ok(());
            }
            let _ = self.smc.write_number(&mode_key, if manual { 1.0 } else { 0.0 });
            return if reads_as_wanted(&self.smc) { Ok(()) } else { Err(FanWriteError::ControlRefused(index)) };
        }
        // Intel Macs keep one bit per fan in a shared key.
        let current = self.smc.number("FS! ").ok_or(FanWriteError::ControlRefused(index))? as u32;
        let mask = 1u32 << index;
        let wanted = if manual { current | mask } else { current & !mask };
        if wanted == current {
            return Ok(());
        }
        let _ = self.smc.write_number("FS! ", f64::from(wanted));
        if self.smc.number("FS! ") == Some(f64::from(wanted)) {
            Ok(())
        } else {
            Err(FanWriteError::ControlRefused(index))
        }
    }

    fn release_system_override(&self) {
        if self.smc.number("Ftst") == Some(1.0) {
            let _ = self.smc.write_number("Ftst", 0.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::FakeSmc;

    fn writer(smc: &FakeSmc) -> FanWriter<&FakeSmc> {
        FanWriter::with_sleep(smc, |_| {})
    }

    #[test]
    fn target_is_clamped_to_the_fans_own_limits() {
        let smc = FakeSmc::two_fans();
        let mut writer = writer(&smc);
        assert_eq!(writer.set_target(0, 99_999.0), Ok(5349.0));
        assert_eq!(smc.number("F0Tg"), Some(5349.0));
        assert_eq!(writer.set_target(1, 0.0), Ok(1458.0));
        assert_eq!(smc.number("F1Tg"), Some(1458.0));
        assert_eq!(writer.set_target(0, 2400.4), Ok(2400.0));
        assert_eq!(writer.set_target(0, -5000.0), Ok(1350.0));
    }

    #[test]
    fn setting_a_target_takes_the_fan_from_the_system() {
        let smc = FakeSmc::two_fans();
        let mut writer = writer(&smc);
        writer.set_target(0, 3000.0).expect("set");
        assert_eq!(smc.number("F0Md"), Some(1.0));
        assert_eq!(smc.number("F1Md"), Some(0.0), "The other fan stays with the system");
        assert_eq!(writer.manual_fans().iter().copied().collect::<Vec<_>>(), [0]);
    }

    #[test]
    fn a_fan_that_does_not_exist_is_refused() {
        let smc = FakeSmc::two_fans();
        let mut writer = writer(&smc);
        assert_eq!(writer.set_target(2, 3000.0), Err(FanWriteError::NoSuchFan(2)));
        assert_eq!(writer.set_target(-1, 3000.0), Err(FanWriteError::NoSuchFan(-1)));
        assert_eq!(writer.set_target(i64::MAX, 3000.0), Err(FanWriteError::NoSuchFan(i64::MAX)));
        assert_eq!(writer.set_automatic(7), Err(FanWriteError::NoSuchFan(7)));
        assert!(smc.writes().is_empty());
    }

    #[test]
    fn a_speed_that_is_not_a_number_is_refused() {
        let smc = FakeSmc::two_fans();
        let mut writer = writer(&smc);
        assert_eq!(writer.set_target(0, f64::NAN), Err(FanWriteError::InvalidSpeed));
        assert_eq!(writer.set_target(0, f64::INFINITY), Err(FanWriteError::InvalidSpeed));
        assert!(smc.writes().is_empty());
    }

    #[test]
    fn a_fan_with_no_range_is_refused() {
        let smc = FakeSmc::two_fans();
        smc.set("F0Mx", 1350.0, b"flt ");
        assert_eq!(writer(&smc).set_target(0, 3000.0), Err(FanWriteError::InvalidLimits(0)));
        assert_eq!(smc.number("F0Md"), Some(0.0), "A refused fan is never taken from the system");
    }

    #[test]
    fn the_system_is_asked_to_yield_when_it_holds_the_fan() {
        let smc = FakeSmc::two_fans();
        smc.hold_fans_for(3);
        writer(&smc).set_target(0, 3000.0).expect("set");
        assert_eq!(smc.number("Ftst"), Some(1.0));
        assert_eq!(smc.number("F0Md"), Some(1.0));
        assert_eq!(smc.number("F0Tg"), Some(3000.0));
    }

    #[test]
    fn a_fan_the_system_never_yields_is_reported_and_left_alone() {
        let smc = FakeSmc::two_fans();
        smc.hold_fans_for(usize::MAX);
        assert_eq!(writer(&smc).set_target(0, 3000.0), Err(FanWriteError::ControlRefused(0)));
        assert_eq!(smc.number("F0Tg"), Some(1350.0), "No target is written to a fan that was not handed over");
        assert_eq!(smc.number("Ftst"), Some(0.0), "The system gets its control back");
    }

    #[test]
    fn the_last_fan_returned_gives_the_system_its_control_back() {
        let smc = FakeSmc::two_fans();
        smc.hold_fans_for(1);
        let mut writer = writer(&smc);
        writer.set_target(0, 3000.0).expect("set");
        writer.set_target(1, 3000.0).expect("set");
        writer.set_automatic(0).expect("automatic");
        assert_eq!(smc.number("Ftst"), Some(1.0), "One fan is still held");
        writer.set_automatic(1).expect("automatic");
        assert_eq!(smc.number("Ftst"), Some(0.0));
        assert_eq!(smc.number("F0Md"), Some(0.0));
        assert_eq!(smc.number("F1Md"), Some(0.0));
        assert!(writer.manual_fans().is_empty());
    }

    #[test]
    fn a_fan_whose_mode_follows_late_is_still_given_back() {
        let smc = FakeSmc::two_fans();
        let mut writer = writer(&smc);
        writer.set_target(0, 3000.0).expect("set");
        writer.set_target(1, 3000.0).expect("set");
        smc.ignore_releases_for(4);
        writer.set_automatic(0).expect("automatic");
        assert_eq!(smc.number("F0Md"), Some(0.0));
        assert_eq!(smc.number("F1Md"), Some(1.0), "The other fan is still held");
    }

    #[test]
    fn a_fan_that_stays_manual_while_the_systems_control_is_off_is_given_back_with_the_last_fan() {
        let smc = FakeSmc::two_fans();
        smc.hold_fans_for(1);
        let mut writer = writer(&smc);
        writer.set_target(0, 3000.0).expect("set");
        writer.set_target(1, 3000.0).expect("set");
        smc.keep_modes_while_overridden();
        assert_eq!(writer.set_automatic(0), Err(FanWriteError::ReleaseRefused(0)), "The system's control is still off");
        assert_eq!(writer.manual_fans().iter().copied().collect::<Vec<_>>(), [1], "The fan no longer counts as held");
        writer.set_automatic(1).expect("the last fan");
        assert_eq!(smc.number("Ftst"), Some(0.0), "The system has its control back");
        assert_eq!(smc.number("F1Md"), Some(0.0));
        writer.set_automatic(0).expect("the first fan, asked again");
        assert_eq!(smc.number("F0Md"), Some(0.0));
        assert!(writer.manual_fans().is_empty());
    }

    #[test]
    fn a_fan_the_system_reports_with_another_number_counts_as_given_back() {
        let smc = FakeSmc::two_fans();
        let mut writer = writer(&smc);
        writer.set_target(0, 3000.0).expect("set");
        smc.report_system_mode_as(3.0);
        writer.set_automatic(0).expect("automatic");
        assert_eq!(smc.number("F0Md"), Some(3.0));
        assert!(writer.manual_fans().is_empty());
    }

    #[test]
    fn a_fan_the_system_never_takes_back_is_reported() {
        let smc = FakeSmc::two_fans();
        let mut writer = writer(&smc);
        writer.set_target(0, 3000.0).expect("set");
        smc.refuse("F0Md");
        let error = writer.set_automatic(0).expect_err("refused");
        assert_eq!(error, FanWriteError::ReleaseRefused(0));
        assert_eq!(error.to_string(), "The system did not take back fan 1.");
        assert!(writer.manual_fans().is_empty(), "The watchdog has nothing left to hold");
    }

    #[test]
    fn reset_asks_again_for_a_fan_that_stayed_manual_while_the_systems_control_was_off() {
        let smc = FakeSmc::two_fans();
        smc.hold_fans_for(1);
        let mut writer = writer(&smc);
        writer.set_target(0, 3000.0).expect("set");
        writer.set_target(1, 3000.0).expect("set");
        smc.keep_modes_while_overridden();
        writer.reset_all();
        assert_eq!(smc.number("Ftst"), Some(0.0));
        assert_eq!(smc.number("F0Md"), Some(0.0));
        assert_eq!(smc.number("F1Md"), Some(0.0));
    }

    #[test]
    fn reset_returns_every_fan_even_when_one_fails() {
        let smc = FakeSmc::two_fans();
        smc.hold_fans_for(1);
        let mut writer = writer(&smc);
        writer.set_target(0, 3000.0).expect("set");
        writer.set_target(1, 3000.0).expect("set");
        smc.refuse("F0Md");
        writer.reset_all();
        assert_eq!(smc.number("F1Md"), Some(0.0));
        assert_eq!(smc.number("Ftst"), Some(0.0));
        assert!(writer.manual_fans().is_empty());
    }

    #[test]
    fn intel_macs_use_one_bit_per_fan() {
        let smc = FakeSmc::two_fans();
        for key in ["F0Md", "F1Md", "Ftst"] {
            smc.remove(key);
        }
        smc.set("FS! ", 0.0, b"ui16");
        let mut writer = writer(&smc);
        writer.set_target(1, 3000.0).expect("set");
        assert_eq!(smc.number("FS! "), Some(2.0));
        writer.set_target(0, 3000.0).expect("set");
        assert_eq!(smc.number("FS! "), Some(3.0));
        writer.set_automatic(1).expect("automatic");
        assert_eq!(smc.number("FS! "), Some(1.0));
    }
}
