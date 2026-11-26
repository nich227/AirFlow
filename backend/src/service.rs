//! What the helper does with each request, each client, and each silence. The helper program
//! (`src/bin/helper.rs`) receives the messages and keeps the time. This decides.

use crate::fans::FanWriter;
use crate::protocol;
use crate::smc::{SmcAccess, SmcError};
use std::time::Instant;

/// What one request asks for.
#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    pub operation: String,
    pub fan: i64,
    pub rpm: f64,
}

impl Request {
    /// A request with no fan must not read as fan 0, and one with no speed must not read as
    /// a speed of zero. So a missing fan is out of range, and a missing speed is not a number.
    pub fn new(operation: &str, fan: Option<i64>, rpm: Option<f64>) -> Self {
        Self { operation: operation.to_owned(), fan: fan.unwrap_or(-1), rpm: rpm.unwrap_or(f64::NAN) }
    }
}

const CANNOT_OPEN: &str = "The helper can't open the SMC.";

/// Everything the helper knows: the fans it holds, how many clients it has, and when one last
/// spoke. `open` opens the SMC for writing the first time a request needs it.
pub struct Service<S: SmcAccess, O: FnMut() -> Result<FanWriter<S>, SmcError>> {
    open: O,
    writer: Option<FanWriter<S>>,
    clients: usize,
    last_contact: Instant,
}

impl<S: SmcAccess, O: FnMut() -> Result<FanWriter<S>, SmcError>> Service<S, O> {
    pub fn new(open: O, now: Instant) -> Self {
        Self { open, writer: None, clients: 0, last_contact: now }
    }

    fn writer(&mut self) -> Result<&mut FanWriter<S>, String> {
        let writer = match self.writer.take() {
            Some(writer) => writer,
            None => (self.open)().map_err(|_| CANNOT_OPEN.to_owned())?,
        };
        Ok(self.writer.insert(writer))
    }

    /// Does what the request asks. The answer is the speed written, when there is one.
    pub fn perform(&mut self, request: &Request, now: Instant) -> Result<Option<f64>, String> {
        self.last_contact = now;
        match request.operation.as_str() {
            protocol::OP_VERSION | protocol::OP_KEEP_ALIVE => Ok(None),
            protocol::OP_SET_FAN => self.writer()?.set_target(request.fan, request.rpm).map(Some).map_err(|error| error.to_string()),
            protocol::OP_SET_AUTOMATIC => self.writer()?.set_automatic(request.fan).map(|()| None).map_err(|error| error.to_string()),
            protocol::OP_RESET_ALL => {
                self.give_every_fan_back();
                Ok(None)
            }
            other => Err(format!("The helper doesn't know the request “{other}”.")),
        }
    }

    /// Gives every fan back to the system. A helper that never opened the SMC holds none.
    pub fn give_every_fan_back(&mut self) {
        if let Some(writer) = self.writer.as_mut() {
            writer.reset_all();
        }
    }

    pub fn holds_a_fan(&self) -> bool {
        self.writer.as_ref().is_some_and(|writer| !writer.manual_fans().is_empty())
    }

    pub fn has_clients(&self) -> bool {
        self.clients > 0
    }

    pub fn client_arrived(&mut self, now: Instant) {
        self.clients += 1;
        self.last_contact = now;
    }

    /// A client quit, crashed, or closed its connection. When it was the last one, its fans
    /// go back to the system, and the answer is true: the helper has nobody left to serve.
    pub fn client_left(&mut self) -> bool {
        self.clients = self.clients.saturating_sub(1);
        if self.clients > 0 {
            return false;
        }
        self.give_every_fan_back();
        true
    }

    /// An app that hangs keeps its connection open and stops talking. A fan it holds must not
    /// stay held, so silence longer than `protocol::WATCHDOG` gives every fan back. True when
    /// it did.
    pub fn give_fans_back_if_silent(&mut self, now: Instant) -> bool {
        if self.holds_a_fan() && now.saturating_duration_since(self.last_contact) > protocol::WATCHDOG {
            self.give_every_fan_back();
            return true;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::FakeSmc;
    use std::time::Duration;

    type Opened<'a> = Result<FanWriter<&'a FakeSmc>, SmcError>;

    // The made-up SMC hands a fan over at once, so the writer never waits.
    fn service<'a>(smc: &'a FakeSmc) -> Service<&'a FakeSmc, impl FnMut() -> Opened<'a>> {
        Service::new(move || Ok(FanWriter::new(smc)), Instant::now())
    }

    fn set(fan: i64, rpm: f64) -> Request {
        Request::new(protocol::OP_SET_FAN, Some(fan), Some(rpm))
    }

    fn modes(smc: &FakeSmc) -> (Option<f64>, Option<f64>, Option<f64>) {
        (smc.number("Ftst"), smc.number("F0Md"), smc.number("F1Md"))
    }

    #[test]
    fn a_request_with_no_fan_or_no_speed_names_neither() {
        let empty = Request::new(protocol::OP_SET_FAN, None, None);
        assert_eq!(empty.fan, -1);
        assert!(empty.rpm.is_nan());
        assert_eq!(Request::new("x", Some(1), Some(2000.0)), Request { operation: "x".to_owned(), fan: 1, rpm: 2000.0 });

        let smc = FakeSmc::two_fans();
        let mut service = service(&smc);
        let now = Instant::now();
        assert_eq!(service.perform(&empty, now), Err("The speed is not a number.".to_owned()));
        assert_eq!(service.perform(&Request::new(protocol::OP_SET_FAN, None, Some(2000.0)), now), Err("This Mac has no fan 0.".to_owned()));
        assert_eq!(service.perform(&Request::new(protocol::OP_SET_AUTOMATIC, None, None), now), Err("This Mac has no fan 0.".to_owned()));
        assert!(smc.writes().is_empty(), "Nothing was written for a request that names no fan");
    }

    #[test]
    fn a_fan_is_held_at_the_speed_asked_for_within_its_limits() {
        let smc = FakeSmc::two_fans();
        let mut service = service(&smc);
        let now = Instant::now();
        assert!(!service.holds_a_fan());
        assert_eq!(service.perform(&set(0, 3000.0), now), Ok(Some(3000.0)));
        assert_eq!(service.perform(&set(1, 99_999.0), now), Ok(Some(5777.0)));
        assert!(service.holds_a_fan());
        assert_eq!(modes(&smc), (Some(0.0), Some(1.0), Some(1.0)));
        assert_eq!(service.perform(&Request::new(protocol::OP_SET_AUTOMATIC, Some(0), None), now), Ok(None));
        assert_eq!(modes(&smc).1, Some(0.0));
        assert!(service.holds_a_fan(), "The other fan is still held");
        assert_eq!(service.perform(&Request::new(protocol::OP_SET_AUTOMATIC, Some(1), None), now), Ok(None));
        assert!(!service.holds_a_fan());
    }

    #[test]
    fn version_and_keep_alive_write_nothing_and_an_unknown_request_is_refused() {
        let smc = FakeSmc::two_fans();
        let mut opened = 0;
        let mut service = Service::new(
            || {
                opened += 1;
                Ok(FanWriter::new(&smc))
            },
            Instant::now(),
        );
        let now = Instant::now();
        assert_eq!(service.perform(&Request::new(protocol::OP_VERSION, None, None), now), Ok(None));
        assert_eq!(service.perform(&Request::new(protocol::OP_KEEP_ALIVE, None, None), now), Ok(None));
        assert_eq!(service.perform(&Request::new(protocol::OP_RESET_ALL, None, None), now), Ok(None));
        assert_eq!(service.perform(&Request::new("format_disk", Some(0), Some(1.0)), now), Err("The helper doesn't know the request “format_disk”.".to_owned()));
        assert!(smc.writes().is_empty());
        assert_eq!(service.perform(&set(0, 2000.0), now), Ok(Some(2000.0)));
        assert_eq!(service.perform(&set(1, 2000.0), now), Ok(Some(2000.0)));
        drop(service);
        assert_eq!(opened, 1, "The SMC is opened when a request first needs it, and once");
    }

    #[test]
    fn reset_all_gives_every_fan_back() {
        let smc = FakeSmc::two_fans();
        let mut service = service(&smc);
        let now = Instant::now();
        assert_eq!(service.perform(&set(0, 3000.0), now), Ok(Some(3000.0)));
        assert_eq!(service.perform(&set(1, 3000.0), now), Ok(Some(3000.0)));
        assert_eq!(service.perform(&Request::new(protocol::OP_RESET_ALL, None, None), now), Ok(None));
        assert_eq!(modes(&smc), (Some(0.0), Some(0.0), Some(0.0)));
        assert!(!service.holds_a_fan());
    }

    #[test]
    fn a_helper_that_cannot_open_the_smc_says_so_and_tries_again() {
        let smc = FakeSmc::two_fans();
        let mut attempts = 0;
        let mut service = Service::new(
            || {
                attempts += 1;
                if attempts == 1 {
                    Err(SmcError::ServiceNotFound)
                } else {
                    Ok(FanWriter::new(&smc))
                }
            },
            Instant::now(),
        );
        let now = Instant::now();
        assert_eq!(service.perform(&set(0, 3000.0), now), Err("The helper can't open the SMC.".to_owned()));
        assert!(!service.holds_a_fan());
        service.give_every_fan_back();
        assert!(service.client_left(), "Leaving with no SMC open gives nothing back and fails nothing");
        assert_eq!(service.perform(&set(0, 3000.0), now), Ok(Some(3000.0)));
    }

    #[test]
    fn the_last_client_to_leave_gives_the_fans_back() {
        let smc = FakeSmc::two_fans();
        let mut service = service(&smc);
        let now = Instant::now();
        assert!(!service.has_clients());
        service.client_arrived(now);
        service.client_arrived(now);
        assert!(service.has_clients());
        assert_eq!(service.perform(&set(0, 3000.0), now), Ok(Some(3000.0)));
        assert!(!service.client_left(), "Another client is still connected");
        assert_eq!(modes(&smc).1, Some(1.0), "Its fan stays held");
        assert!(service.client_left());
        assert_eq!(modes(&smc), (Some(0.0), Some(0.0), Some(0.0)));
        assert!(!service.has_clients());
        assert!(service.client_left(), "A second report that the client left does not count below zero");
        service.client_arrived(now);
        assert!(service.has_clients());
    }

    #[test]
    fn silence_past_the_limit_gives_the_fans_back() {
        let smc = FakeSmc::two_fans();
        let mut service = service(&smc);
        let start = Instant::now();
        service.client_arrived(start);
        assert!(!service.give_fans_back_if_silent(start + protocol::WATCHDOG * 10), "With no fan held there is nothing to give back");
        assert_eq!(service.perform(&set(0, 3000.0), start), Ok(Some(3000.0)));
        assert!(!service.give_fans_back_if_silent(start + protocol::WATCHDOG));
        assert_eq!(modes(&smc).1, Some(1.0));

        // Any request counts as contact, a keep-alive included.
        let later = start + protocol::WATCHDOG;
        assert_eq!(service.perform(&Request::new(protocol::OP_KEEP_ALIVE, None, None), later), Ok(None));
        assert!(!service.give_fans_back_if_silent(later + protocol::WATCHDOG));
        // A clock reading from before the last contact is no silence at all.
        assert!(!service.give_fans_back_if_silent(start));

        assert!(service.give_fans_back_if_silent(later + protocol::WATCHDOG + Duration::from_millis(1)));
        assert_eq!(modes(&smc), (Some(0.0), Some(0.0), Some(0.0)));
        assert!(!service.holds_a_fan());
        assert!(!service.give_fans_back_if_silent(later + protocol::WATCHDOG * 3), "The fans are given back once");

        // A client that arrives is contact too.
        assert_eq!(service.perform(&set(1, 3000.0), later), Ok(Some(3000.0)));
        let arrival = later + protocol::WATCHDOG * 2;
        service.client_arrived(arrival);
        assert!(!service.give_fans_back_if_silent(arrival + protocol::WATCHDOG));
        assert!(service.give_fans_back_if_silent(arrival + protocol::WATCHDOG + Duration::from_secs(1)));
    }
}
