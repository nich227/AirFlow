//! An SMC made of a map, for tests and for the sample reader the app's own tests use.

use crate::smc::{decode, encode, SmcAccess, SmcError, SmcValue};
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Default)]
pub struct FakeSmc {
    values: RefCell<BTreeMap<String, SmcValue>>,
    writes: RefCell<Vec<(String, Option<f64>)>>,
    /// The key of every read, in order.
    reads: RefCell<Vec<String>>,
    refused: RefCell<BTreeSet<String>>,
    /// While this is above zero, the system holds every fan's mode key. Each attempt to take
    /// a fan lowers it by one.
    held: RefCell<usize>,
    /// While this is above zero, a write that gives a fan back is accepted and ignored. Each
    /// such write lowers it by one.
    late_releases: RefCell<usize>,
    /// True if a fan's mode stays manual while the system's control is off (Ftst is 1).
    keeps_modes: RefCell<bool>,
    /// The number the SMC stores for a fan that was given back, if it is not 0.
    system_mode: RefCell<Option<f64>>,
}

// The sample reader crosses the C interface, where one thread at a time uses it.
unsafe impl Send for FakeSmc {}

impl FakeSmc {
    /// A Mac with two fans on Apple silicon, as the development Mac reports them.
    pub fn two_fans() -> Self {
        let smc = Self::default();
        smc.set("FNum", 2.0, b"ui8 ");
        smc.set("Ftst", 0.0, b"ui8 ");
        for (index, (minimum, maximum)) in [(1350.0, 5349.0), (1458.0, 5777.0)].into_iter().enumerate() {
            smc.set(&format!("F{index}Ac"), minimum, b"flt ");
            smc.set(&format!("F{index}Mn"), minimum, b"flt ");
            smc.set(&format!("F{index}Mx"), maximum, b"flt ");
            smc.set(&format!("F{index}Tg"), minimum, b"flt ");
            smc.set(&format!("F{index}Md"), 0.0, b"ui8 ");
        }
        smc
    }

    /// Two fans and a few sensors, one of them hot.
    pub fn sample() -> Self {
        let smc = Self::two_fans();
        smc.set("F0Ac", 2400.0, b"flt ");
        smc.set("F1Ac", 2600.0, b"flt ");
        smc.set("F0Md", 1.0, b"ui8 ");
        smc.set("PSTR", 28.5, b"flt ");
        for (key, celsius) in [("Tp01", 61.0), ("Tp05", 63.0), ("Te05", 55.0), ("Tg0D", 48.0), ("TaLP", 39.0), ("TB1T", 31.0), ("TH0x", 35.0)] {
            smc.set(key, celsius, b"flt ");
        }
        smc
    }

    pub fn set(&self, key: &str, number: f64, kind: &[u8; 4]) {
        let size = match kind {
            b"flt " | b"ui32" => 4,
            b"ui8 " | b"flag" => 1,
            _ => 2,
        };
        let bytes = encode(number, kind, size).unwrap_or_default();
        self.values.borrow_mut().insert(key.into(), SmcValue { kind: *kind, bytes });
    }

    pub fn remove(&self, key: &str) {
        self.values.borrow_mut().remove(key);
    }

    /// Makes every write to the key fail.
    pub fn refuse(&self, key: &str) {
        self.refused.borrow_mut().insert(key.into());
    }

    pub fn hold_fans_for(&self, attempts: usize) {
        *self.held.borrow_mut() = attempts;
    }

    /// Makes the next writes that give a fan back have no effect, as an SMC that follows late.
    pub fn ignore_releases_for(&self, writes: usize) {
        *self.late_releases.borrow_mut() = writes;
    }

    /// Makes a fan's mode stay manual until the system has its control back.
    pub fn keep_modes_while_overridden(&self) {
        *self.keeps_modes.borrow_mut() = true;
    }

    /// Makes the SMC report a fan under the system's control with this number.
    pub fn report_system_mode_as(&self, mode: f64) {
        *self.system_mode.borrow_mut() = Some(mode);
    }

    pub fn writes(&self) -> Vec<(String, Option<f64>)> {
        self.writes.borrow().clone()
    }

    /// The key of every read since the last `clear_reads`.
    pub fn reads(&self) -> Vec<String> {
        self.reads.borrow().clone()
    }

    pub fn clear_reads(&self) {
        self.reads.borrow_mut().clear();
    }
}

impl SmcAccess for FakeSmc {
    fn read(&self, key: &str) -> Result<SmcValue, SmcError> {
        self.reads.borrow_mut().push(key.into());
        self.values.borrow().get(key).cloned().ok_or(SmcError::Rejected(0x84))
    }

    fn write(&self, key: &str, bytes: &[u8]) -> Result<(), SmcError> {
        let kind = self.read(key)?.kind;
        let number = decode(bytes, &kind);
        self.writes.borrow_mut().push((key.into(), number));
        if self.refused.borrow().contains(key) {
            return Err(SmcError::Rejected(0x82));
        }
        if key.ends_with("Md") && number == Some(1.0) && *self.held.borrow() > 0 {
            *self.held.borrow_mut() -= 1;
            return Err(SmcError::Rejected(0x82));
        }
        if key.ends_with("Md") && number == Some(0.0) {
            if *self.late_releases.borrow() > 0 {
                *self.late_releases.borrow_mut() -= 1;
                return Ok(());
            }
            if *self.keeps_modes.borrow() && self.number("Ftst") == Some(1.0) {
                return Ok(());
            }
            if let Some(mode) = *self.system_mode.borrow() {
                self.set(key, mode, &kind);
                return Ok(());
            }
        }
        self.values.borrow_mut().insert(key.into(), SmcValue { kind, bytes: bytes.to_vec() });
        Ok(())
    }

    fn key_count(&self) -> usize {
        self.values.borrow().len()
    }

    fn key_at(&self, index: usize) -> Option<String> {
        self.values.borrow().keys().nth(index).cloned()
    }
}
