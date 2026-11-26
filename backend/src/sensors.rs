//! Reading fans and temperature sensors, and naming the sensors.

use std::collections::HashMap;
use crate::smc::SmcAccess;

/// One fan as the SMC reports it.
#[derive(Debug, Clone, PartialEq)]
pub struct FanReading {
    pub index: usize,
    pub minimum_rpm: f64,
    pub maximum_rpm: f64,
    pub current_rpm: f64,
    pub target_rpm: f64,
    /// True while something other than the system holds the fan's speed.
    pub is_manual: bool,
}

/// The part of the Mac a sensor belongs to. The numbers are the ones in airflow.h.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub enum Group {
    Cpu = 0,
    Gpu = 1,
    Memory = 2,
    Storage = 3,
    Battery = 4,
    Enclosure = 5,
    Power = 6,
    Wireless = 7,
    Other = 8,
}

impl Group {
    /// The group's bit in a set of groups, as `Reader::sensors_in` takes one.
    pub const fn bit(self) -> u32 {
        1 << self as u8
    }
}

/// Every group, as a set.
pub const ALL_GROUPS: u32 = (1 << (Group::Other as u8 + 1)) - 1;

#[derive(Debug, Clone, PartialEq)]
pub struct Definition {
    pub key: String,
    pub name: String,
    pub group: Group,
    /// False for a key whose meaning is not known: it has its group's name and a number.
    pub is_known: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SensorReading {
    pub key: String,
    pub name: String,
    pub group: Group,
    pub is_known: bool,
    pub celsius: f64,
}

/// A temperature outside this range is a sensor that is off or a key that is not a temperature.
pub const PLAUSIBLE_CELSIUS: std::ops::RangeInclusive<f64> = 5.0..=130.0;

/// The key for the power the whole Mac draws, in watts.
pub const SYSTEM_POWER_KEY: &str = "PSTR";
/// A value outside this range is not a reading of a Mac's power.
pub const PLAUSIBLE_WATTS: std::ops::RangeInclusive<f64> = 0.5..=1000.0;

const KNOWN: &[(&str, &str, Group)] = &[
    ("TaLP", "Airflow Left", Group::Enclosure),
    ("TaRF", "Airflow Right", Group::Enclosure),
    ("Ts0P", "Trackpad", Group::Enclosure),
    ("Ts1P", "Palm Rest", Group::Enclosure),
    ("TW0P", "Wi-Fi", Group::Wireless),
    ("TB0T", "Battery Gas Gauge", Group::Battery),
    ("TB1T", "Battery Cell 1", Group::Battery),
    ("TB2T", "Battery Cell 2", Group::Battery),
    ("TH0x", "SSD", Group::Storage),
    ("TH0a", "SSD Sensor A", Group::Storage),
    ("TH0b", "SSD Sensor B", Group::Storage),
    ("TPSP", "Power Supply", Group::Power),
    ("TPMP", "Power Manager", Group::Power),
    ("TMVR", "Memory Regulator", Group::Memory),
    // Intel
    ("TC0P", "CPU Proximity", Group::Cpu),
    ("TC0D", "CPU Diode", Group::Cpu),
    ("TC0H", "CPU Heatsink", Group::Cpu),
    ("TCAD", "CPU Package", Group::Cpu),
    ("TG0P", "GPU Proximity", Group::Gpu),
    ("TG0D", "GPU Diode", Group::Gpu),
    ("TG0H", "GPU Heatsink", Group::Gpu),
    ("Tm0P", "Mainboard", Group::Other),
    ("TA0P", "Ambient", Group::Enclosure),
    ("TL0P", "Display", Group::Other),
];

/// Names a temperature key. The SMC publishes no names, and the keys differ by chip, so a key
/// gets a name only where its meaning is known. Every other key is grouped by its prefix and
/// named for its group. `Reader::discover` then numbers the keys that share a name.
pub fn definition(key: &str, apple_silicon: bool) -> Option<Definition> {
    if key.len() != 4 || !key.starts_with('T') || !key.is_ascii() {
        return None;
    }
    if let Some((_, name, group)) = KNOWN.iter().find(|(known, _, _)| *known == key) {
        return Some(Definition { key: key.into(), name: (*name).into(), group: *group, is_known: true });
    }
    let group = if apple_silicon { apple_silicon_group(key) } else { intel_group(key) };
    Some(Definition { key: key.into(), name: noun(group, key).into(), group, is_known: false })
}

fn apple_silicon_group(key: &str) -> Group {
    match &key[..2] {
        "Tp" | "Te" => Group::Cpu,
        "Tg" => Group::Gpu,
        // The first M3 chips report performance cores under Tf0 and Tf4, and the GPU under the rest.
        "Tf" => {
            if matches!(&key[2..3], "0" | "4") {
                Group::Cpu
            } else {
                Group::Gpu
            }
        }
        "Tm" | "TM" => Group::Memory,
        "TH" => Group::Storage,
        "TB" => Group::Battery,
        "Ta" => Group::Enclosure,
        "TW" => Group::Wireless,
        "TP" | "TR" => Group::Power,
        _ => Group::Other,
    }
}

fn intel_group(key: &str) -> Group {
    match &key[..2] {
        "TC" => Group::Cpu,
        "TG" => Group::Gpu,
        "TM" | "Tm" => Group::Memory,
        "TH" => Group::Storage,
        "TB" => Group::Battery,
        "TA" | "Ts" => Group::Enclosure,
        "TW" => Group::Wireless,
        "Tp" | "TP" => Group::Power,
        _ => Group::Other,
    }
}

fn noun(group: Group, key: &str) -> &'static str {
    match group {
        Group::Cpu if key.starts_with("Te") => "Efficiency Core Sensor",
        Group::Cpu if key.starts_with("Tp") || key.starts_with("Tf") => "Performance Core Sensor",
        Group::Cpu => "CPU Sensor",
        Group::Gpu => "GPU Sensor",
        Group::Memory => "Memory Sensor",
        Group::Storage => "Storage Sensor",
        Group::Battery => "Battery Sensor",
        Group::Enclosure => "Enclosure Sensor",
        Group::Power => "Power Sensor",
        Group::Wireless => "Wireless Sensor",
        Group::Other => "Sensor",
    }
}

/// Reads fans and temperature sensors through the SMC.
pub struct Reader<S: SmcAccess> {
    smc: S,
    apple_silicon: bool,
    definitions: Option<Vec<Definition>>,
    /// The last reading of each sensor, in the order of `definitions`. None for one that is off.
    last: Vec<Option<f64>>,
    /// Each fan's lowest and highest speed. A fan's limits do not change, so they are read once.
    limits: Option<Vec<(f64, f64)>>,
}

impl<S: SmcAccess> Reader<S> {
    pub fn new(smc: S, apple_silicon: bool) -> Self {
        Self { smc, apple_silicon, definitions: None, last: Vec::new(), limits: None }
    }

    /// Lists every temperature key once. The SMC holds a few thousand keys, so this walk is
    /// the one slow read, and its result is kept.
    pub fn discover(&mut self) -> &[Definition] {
        if self.definitions.is_none() {
            // The reading that shows a key to be a sensor is kept, so a group that is read
            // later has a value from the start.
            let mut read: Vec<(Definition, f64)> = (0..self.smc.key_count())
                .filter_map(|index| self.smc.key_at(index))
                .filter_map(|key| definition(&key, self.apple_silicon))
                .filter_map(|definition| {
                    let celsius = self.smc.number(&definition.key).filter(|celsius| PLAUSIBLE_CELSIUS.contains(celsius))?;
                    Some((definition, celsius))
                })
                .collect();
            read.sort_by(|(a, _), (b, _)| (a.group, !a.is_known, &a.name, &a.key).cmp(&(b.group, !b.is_known, &b.name, &b.key)));
            self.last = read.iter().map(|(_, celsius)| Some(*celsius)).collect();
            let mut found: Vec<Definition> = read.into_iter().map(|(definition, _)| definition).collect();
            // Keys with no known meaning share their group's name, so each gets a number, in
            // the order of the keys.
            let mut numbers: HashMap<String, u32> = HashMap::new();
            for definition in found.iter_mut().filter(|definition| !definition.is_known) {
                let number = numbers.entry(definition.name.clone()).or_insert(0);
                *number += 1;
                definition.name = format!("{} {number}", definition.name);
            }
            self.definitions = Some(found);
        }
        self.definitions.as_deref().unwrap_or_default()
    }

    /// How many fans the Mac has, with each one's limits. They are kept once every one of
    /// them was read, because a Mac's fans and their limits do not change while it runs.
    fn fan_limits(&mut self) -> Vec<(f64, f64)> {
        if let Some(limits) = &self.limits {
            return limits.clone();
        }
        let count = self.smc.number("FNum").map_or(0, |count| count as usize);
        let read: Vec<(Option<f64>, Option<f64>)> = (0..count)
            .map(|index| (self.smc.number(&format!("F{index}Mn")), self.smc.number(&format!("F{index}Mx"))))
            .collect();
        let limits: Vec<(f64, f64)> = read.iter().map(|(minimum, maximum)| (minimum.unwrap_or(0.0), maximum.unwrap_or(0.0))).collect();
        if count > 0 && read.iter().all(|(minimum, maximum)| minimum.is_some() && maximum.is_some()) {
            self.limits = Some(limits.clone());
        }
        limits
    }

    pub fn fans(&mut self) -> Vec<FanReading> {
        self.fan_limits()
            .into_iter()
            .enumerate()
            .filter_map(|(index, (minimum_rpm, maximum_rpm))| {
                let current = self.smc.number(&format!("F{index}Ac"))?;
                Some(FanReading {
                    index,
                    minimum_rpm,
                    maximum_rpm,
                    current_rpm: current.max(0.0),
                    target_rpm: self.smc.number(&format!("F{index}Tg")).unwrap_or(current),
                    is_manual: self.is_manual(index),
                })
            })
            .collect()
    }

    /// Every sensor, each read now.
    pub fn sensors(&mut self) -> Vec<SensorReading> {
        self.sensors_in(ALL_GROUPS)
    }

    /// Every sensor. The sensors of the groups in `groups` (see `Group::bit`) are read now, and
    /// each other sensor has its last reading. One key costs about a tenth of a millisecond, and
    /// a Mac has a few hundred, so a caller reads often only the groups it acts on.
    pub fn sensors_in(&mut self, groups: u32) -> Vec<SensorReading> {
        self.discover();
        let smc = &self.smc;
        let definitions = self.definitions.as_deref().unwrap_or_default();
        for (definition, last) in definitions.iter().zip(self.last.iter_mut()) {
            if groups & definition.group.bit() != 0 {
                *last = smc.number(&definition.key).filter(|celsius| PLAUSIBLE_CELSIUS.contains(celsius));
            }
        }
        definitions
            .iter()
            .zip(self.last.iter())
            .filter_map(|(definition, last)| {
                let celsius = (*last)?;
                Some(SensorReading {
                    key: definition.key.clone(),
                    name: definition.name.clone(),
                    group: definition.group,
                    is_known: definition.is_known,
                    celsius,
                })
            })
            .collect()
    }

    /// The power the whole Mac draws, in watts, or none where the SMC does not report it.
    pub fn system_power(&self) -> Option<f64> {
        self.smc.number(SYSTEM_POWER_KEY).filter(|watts| PLAUSIBLE_WATTS.contains(watts))
    }

    fn is_manual(&self, index: usize) -> bool {
        if let Some(mode) = self.smc.number(&format!("F{index}Md")) {
            return mode == 1.0;
        }
        self.smc.number("FS! ").is_some_and(|bits| (bits as u32) & (1 << index) != 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::FakeSmc;

    fn smc_with_sensors() -> FakeSmc {
        let smc = FakeSmc::two_fans();
        smc.set("F0Ac", 2400.0, b"flt ");
        smc.set("F0Md", 1.0, b"ui8 ");
        for (key, celsius) in [("Tp01", 61.0), ("Te05", 55.0), ("Tg0D", 48.0), ("TaLP", 39.0), ("TB1T", 31.0), ("TH0x", 35.0)] {
            smc.set(key, celsius, b"flt ");
        }
        smc.set("Tp99", 0.0, b"flt "); // a sensor that is off
        smc.set("TXXX", 400.0, b"flt "); // not a temperature
        smc
    }

    #[test]
    fn only_the_groups_asked_for_are_read_and_the_others_keep_their_last_reading() {
        let smc = smc_with_sensors();
        let mut reader = Reader::new(&smc, true);
        assert_eq!(reader.sensors_in(0).len(), 6, "The first reading of every sensor comes from finding it");
        smc.clear_reads();
        for (key, celsius) in [("Tp01", 70.0), ("Tg0D", 58.0), ("TB1T", 33.0), ("TH0x", 45.0)] {
            smc.set(key, celsius, b"flt ");
        }
        let sensors = reader.sensors_in(Group::Cpu.bit() | Group::Gpu.bit());
        let celsius = |sensors: &[SensorReading], key: &str| sensors.iter().find(|sensor| sensor.key == key).map(|sensor| sensor.celsius);
        assert_eq!(celsius(&sensors, "Tp01"), Some(70.0));
        assert_eq!(celsius(&sensors, "Tg0D"), Some(58.0));
        assert_eq!(celsius(&sensors, "TB1T"), Some(31.0), "The battery was not read, so it has its last reading");
        assert_eq!(celsius(&sensors, "TH0x"), Some(35.0));
        let mut read = smc.reads();
        read.sort_unstable();
        assert_eq!(read, ["Te05", "Tg0D", "Tp01"], "No key of another group is read");

        let sensors = reader.sensors_in(Group::Battery.bit());
        assert_eq!(celsius(&sensors, "TB1T"), Some(33.0));
        assert_eq!(celsius(&sensors, "TH0x"), Some(35.0));
        assert_eq!(celsius(&sensors, "Tp01"), Some(70.0), "A group that is not read keeps what it had");
        assert_eq!(reader.sensors().len(), 6);
        assert_eq!(celsius(&reader.sensors(), "TH0x"), Some(45.0));

        // A sensor that goes off drops out when its group is read, and not before.
        smc.set("TB1T", 0.0, b"flt ");
        assert_eq!(reader.sensors_in(Group::Cpu.bit()).len(), 6);
        assert_eq!(reader.sensors_in(Group::Battery.bit()).len(), 5);
        assert_eq!(ALL_GROUPS, 0b1_1111_1111);
        assert_eq!(Group::Other.bit(), 0b1_0000_0000);
    }

    #[test]
    fn a_fans_limits_and_the_number_of_fans_are_read_once() {
        let smc = smc_with_sensors();
        let mut reader = Reader::new(&smc, true);
        assert_eq!(reader.fans().len(), 2);
        smc.clear_reads();
        smc.set("F1Ac", 3000.0, b"flt ");
        let fans = reader.fans();
        assert_eq!(fans[1].current_rpm, 3000.0);
        assert_eq!((fans[1].minimum_rpm, fans[1].maximum_rpm), (1458.0, 5777.0));
        let mut read = smc.reads();
        read.sort_unstable();
        assert_eq!(read, ["F0Ac", "F0Md", "F0Tg", "F1Ac", "F1Md", "F1Tg"], "The speed, the target, and the mode of each fan, and nothing else");

        // Limits that could not all be read are asked for again.
        let partial = FakeSmc::two_fans();
        partial.remove("F1Mx");
        let mut reader = Reader::new(&partial, true);
        assert_eq!(reader.fans()[1].maximum_rpm, 0.0);
        partial.set("F1Mx", 5777.0, b"flt ");
        assert_eq!(reader.fans()[1].maximum_rpm, 5777.0);
        // A Mac that reports no fans yet is asked again too.
        let none = FakeSmc::default();
        let mut reader = Reader::new(&none, true);
        assert!(reader.fans().is_empty());
        none.set("FNum", 1.0, b"ui8 ");
        for key in ["F0Ac", "F0Mn", "F0Mx"] {
            none.set(key, 1200.0, b"flt ");
        }
        assert_eq!(reader.fans().len(), 1);
    }

    #[test]
    fn fans_are_read_with_their_limits_and_mode() {
        let fans = Reader::new(smc_with_sensors(), true).fans();
        assert_eq!(fans.len(), 2);
        assert_eq!(fans[0].current_rpm, 2400.0);
        assert_eq!(fans[0].minimum_rpm, 1350.0);
        assert_eq!(fans[0].maximum_rpm, 5349.0);
        assert!(fans[0].is_manual);
        assert!(!fans[1].is_manual);
    }

    #[test]
    fn a_mac_with_no_fans_reads_as_none() {
        let smc = FakeSmc::default();
        smc.set("Tp01", 40.0, b"flt ");
        assert!(Reader::new(smc, true).fans().is_empty());
    }

    #[test]
    fn only_plausible_temperature_keys_become_sensors() {
        let mut reader = Reader::new(smc_with_sensors(), true);
        let mut keys: Vec<&str> = reader.discover().iter().map(|definition| definition.key.as_str()).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["TB1T", "TH0x", "TaLP", "Te05", "Tg0D", "Tp01"]);
    }

    #[test]
    fn sensors_are_grouped_named_and_ordered() {
        let sensors = Reader::new(smc_with_sensors(), true).sensors();
        let find = |key: &str| sensors.iter().find(|sensor| sensor.key == key).expect("sensor");
        assert_eq!(find("Tp01").group, Group::Cpu);
        assert_eq!(find("Tp01").celsius, 61.0);
        assert_eq!(find("Tg0D").group, Group::Gpu);
        assert_eq!(find("TaLP").name, "Airflow Left");
        assert_eq!(find("TH0x").name, "SSD");
        assert_eq!(sensors.first().map(|sensor| sensor.group), Some(Group::Cpu), "The CPU's sensors come first");
    }

    #[test]
    fn system_power_is_read_only_when_it_is_plausible() {
        let smc = smc_with_sensors();
        assert_eq!(Reader::new(&smc, true).system_power(), None, "a Mac with no power key reports none");
        smc.set(SYSTEM_POWER_KEY, 34.5, b"flt ");
        assert_eq!(Reader::new(&smc, true).system_power(), Some(34.5));
        smc.set(SYSTEM_POWER_KEY, 0.0, b"flt ");
        assert_eq!(Reader::new(&smc, true).system_power(), None);
        smc.set(SYSTEM_POWER_KEY, 5000.0, b"flt ");
        assert_eq!(Reader::new(&smc, true).system_power(), None);
    }

    #[test]
    fn a_sensor_that_goes_off_drops_out() {
        let smc = smc_with_sensors();
        let mut reader = Reader::new(&smc, true);
        assert_eq!(reader.sensors().len(), 6);
        smc.set("Tg0D", 0.0, b"flt ");
        assert_eq!(reader.sensors().len(), 5);
    }

    #[test]
    fn apple_silicon_prefixes() {
        let group = |key: &str| definition(key, true).map(|definition| definition.group);
        assert_eq!(group("Tp0V"), Some(Group::Cpu));
        assert_eq!(group("Te0S"), Some(Group::Cpu));
        assert_eq!(group("Tf04"), Some(Group::Cpu));
        assert_eq!(group("Tf4E"), Some(Group::Cpu));
        assert_eq!(group("Tf14"), Some(Group::Gpu));
        assert_eq!(group("Tg0L"), Some(Group::Gpu));
        assert_eq!(group("TPD0"), Some(Group::Power));
        assert_eq!(group("TD00"), Some(Group::Other));
    }

    #[test]
    fn intel_prefixes() {
        let group = |key: &str| definition(key, false).map(|definition| definition.group);
        assert_eq!(group("TC1C"), Some(Group::Cpu));
        assert_eq!(group("TG1D"), Some(Group::Gpu));
        assert_eq!(group("Tp0P"), Some(Group::Power));
        assert_eq!(group("TC0P"), Some(Group::Cpu));
    }

    #[test]
    fn only_temperature_keys_are_sensors() {
        assert_eq!(definition("F0Ac", true), None);
        assert_eq!(definition("T", true), None);
        assert_eq!(definition("Tp°", true), None);
    }

    #[test]
    fn a_key_with_no_known_meaning_is_named_for_its_group() {
        let unknown = definition("Te0S", true).expect("definition");
        assert_eq!((unknown.name.as_str(), unknown.is_known), ("Efficiency Core Sensor", false));
        assert_eq!(definition("TD00", true).map(|d| d.name).as_deref(), Some("Sensor"));
        assert_eq!(definition("TB1T", true).map(|d| d.is_known), Some(true));
    }

    #[test]
    fn keys_with_no_known_meaning_are_numbered_in_key_order_after_the_known_ones() {
        let smc = smc_with_sensors();
        for key in ["Te0S", "Te0G", "Tp0V"] {
            smc.set(key, 50.0, b"flt ");
        }
        let mut reader = Reader::new(&smc, true);
        let cpu: Vec<(String, String, bool)> = reader
            .discover()
            .iter()
            .filter(|definition| definition.group == Group::Cpu && !definition.is_known)
            .map(|definition| (definition.key.clone(), definition.name.clone(), definition.is_known))
            .collect();
        let names: Vec<(&str, &str)> = cpu.iter().map(|(key, name, _)| (key.as_str(), name.as_str())).collect();
        assert!(names.contains(&("Te05", "Efficiency Core Sensor 1")), "{names:?}");
        assert!(names.contains(&("Te0G", "Efficiency Core Sensor 2")), "{names:?}");
        assert!(names.contains(&("Te0S", "Efficiency Core Sensor 3")), "{names:?}");
        let definitions = reader.discover();
        let first_unknown = definitions.iter().position(|d| d.group == Group::Cpu && !d.is_known).expect("unknown");
        assert!(definitions[first_unknown..].iter().filter(|d| d.group == Group::Cpu).all(|d| !d.is_known));
    }
}
