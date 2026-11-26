//! What each running app costs the Mac: processor time and memory, added over the app's
//! processes. An app such as a browser or an editor does most of its work in helper processes
//! inside its bundle, so a process counts for the outermost app bundle that holds it.

use std::collections::HashMap;

/// One running process that this user may ask about.
#[derive(Debug, Clone, PartialEq)]
pub struct ProcessSample {
    /// The program's path.
    pub path: String,
    /// The processor time the process has used since it started.
    pub cpu_seconds: f64,
    /// How long ago the process started.
    pub running_seconds: f64,
    pub memory_bytes: u64,
}

/// One app's processes, added up.
#[derive(Debug, Clone, PartialEq)]
pub struct AppUsage {
    /// The app's bundle, such as `/Applications/Xcode.app`.
    pub bundle_path: String,
    pub cpu_seconds: f64,
    /// How long ago the app's oldest process started.
    pub running_seconds: f64,
    pub memory_bytes: u64,
    pub processes: usize,
}

/// The outermost app bundle that holds a program, or none for a program outside any app.
pub fn bundle_of(path: &str) -> Option<&str> {
    let end = path.find(".app/")? + ".app".len();
    Some(&path[..end])
}

/// The processes added up by app, the app with the most processor time first.
pub fn by_app(samples: &[ProcessSample]) -> Vec<AppUsage> {
    let mut apps: HashMap<&str, AppUsage> = HashMap::new();
    for sample in samples {
        let Some(bundle) = bundle_of(&sample.path) else { continue };
        let app = apps.entry(bundle).or_insert_with(|| AppUsage {
            bundle_path: bundle.to_owned(),
            cpu_seconds: 0.0,
            running_seconds: 0.0,
            memory_bytes: 0,
            processes: 0,
        });
        app.cpu_seconds += sample.cpu_seconds;
        app.running_seconds = app.running_seconds.max(sample.running_seconds);
        app.memory_bytes = app.memory_bytes.saturating_add(sample.memory_bytes);
        app.processes += 1;
    }
    let mut apps: Vec<AppUsage> = apps.into_values().collect();
    apps.sort_by(|a, b| b.cpu_seconds.total_cmp(&a.cpu_seconds).then_with(|| a.bundle_path.cmp(&b.bundle_path)));
    apps
}

/// A count of the Mac's clock ticks as seconds. The kernel reports a process's times in ticks,
/// and a tick is `numer / denom` nanoseconds.
pub fn seconds(ticks: u64, numer: u32, denom: u32) -> f64 {
    if denom == 0 {
        return 0.0;
    }
    ticks as f64 * f64::from(numer) / f64::from(denom) / 1e9
}

#[repr(C)]
struct Timebase {
    numer: u32,
    denom: u32,
}

extern "C" {
    fn mach_timebase_info(info: *mut Timebase) -> libc::c_int;
    fn mach_absolute_time() -> u64;
}

/// Every running app with what its processes use now. Reading this needs no privilege: a
/// process of another user is left out.
pub fn apps() -> Vec<AppUsage> {
    by_app(&samples())
}

/// Every process this user may ask about.
pub fn samples() -> Vec<ProcessSample> {
    // A clock whose rate cannot be read leaves the rate at zero, and `seconds` then gives
    // every time as zero.
    let mut timebase = Timebase { numer: 0, denom: 0 };
    // SAFETY: the call fills the structure it is given, which lives until the call returns.
    unsafe { mach_timebase_info(&mut timebase) };
    // SAFETY: the call takes no argument and returns a number.
    let now = unsafe { mach_absolute_time() };
    process_ids().into_iter().filter_map(|pid| sample(pid, now, &timebase)).collect()
}

fn process_ids() -> Vec<libc::c_int> {
    // SAFETY: a null buffer of no bytes only asks how many processes there are.
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    // Room for processes that start between the two calls.
    let mut pids = vec![0 as libc::c_int; usize::try_from(count).unwrap_or(0) + 64];
    let bytes = libc::c_int::try_from(std::mem::size_of_val(pids.as_slice())).unwrap_or(0);
    // SAFETY: the buffer holds `bytes` bytes, and the call writes no more than that.
    let filled = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
    pids.truncate(usize::try_from(filled).unwrap_or(0).min(pids.len()));
    pids
}

fn sample(pid: libc::c_int, now: u64, timebase: &Timebase) -> Option<ProcessSample> {
    let mut buffer = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: the buffer holds as many bytes as the call is told, and the call writes no more.
    let length = unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    let length = usize::try_from(length).ok().filter(|length| *length > 0 && *length <= buffer.len())?;
    // SAFETY: the structure is plain numbers, for which all zeros is a value.
    let mut info: libc::rusage_info_v4 = unsafe { std::mem::zeroed() };
    // SAFETY: `info` is the structure that flavor 4 fills, and it lives until the call returns.
    let status = unsafe { libc::proc_pid_rusage(pid, libc::RUSAGE_INFO_V4, std::ptr::addr_of_mut!(info).cast()) };
    if status != 0 {
        return None;
    }
    Some(ProcessSample {
        path: String::from_utf8_lossy(&buffer[..length]).into_owned(),
        cpu_seconds: seconds(info.ri_user_time.saturating_add(info.ri_system_time), timebase.numer, timebase.denom),
        running_seconds: seconds(now.saturating_sub(info.ri_proc_start_abstime), timebase.numer, timebase.denom),
        memory_bytes: info.ri_phys_footprint,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(path: &str, cpu: f64, running: f64, memory: u64) -> ProcessSample {
        ProcessSample { path: path.into(), cpu_seconds: cpu, running_seconds: running, memory_bytes: memory }
    }

    #[test]
    fn a_helper_counts_for_the_outermost_app_that_holds_it() {
        assert_eq!(bundle_of("/Applications/Xcode.app/Contents/MacOS/Xcode"), Some("/Applications/Xcode.app"));
        assert_eq!(
            bundle_of("/Applications/OpenCode.app/Contents/Frameworks/OpenCode Helper (Renderer).app/Contents/MacOS/OpenCode Helper (Renderer)"),
            Some("/Applications/OpenCode.app")
        );
        assert_eq!(bundle_of("/usr/libexec/thermalmonitord"), None);
        assert_eq!(bundle_of("/Users/me/notes.app.txt"), None);
        assert_eq!(bundle_of(""), None);
        assert_eq!(bundle_of("/Applications/Caf\u{e9}.app/Contents/MacOS/Caf\u{e9}"), Some("/Applications/Caf\u{e9}.app"));
    }

    #[test]
    fn processes_are_added_up_by_app_with_the_busiest_first() {
        let apps = by_app(&[
            process("/Applications/Light.app/Contents/MacOS/Light", 5.0, 900.0, 100),
            process("/Applications/Heavy.app/Contents/MacOS/Heavy", 60.0, 300.0, 1_000),
            process("/Applications/Heavy.app/Contents/Frameworks/Heavy Helper.app/Contents/MacOS/Heavy Helper", 240.0, 280.0, 4_000),
            process("/usr/sbin/daemon", 9_000.0, 9_000.0, 1),
            process("/Applications/Heavy.app/Contents/MacOS/Tool", 1.0, 500.0, u64::MAX),
        ]);
        assert_eq!(apps.len(), 2, "A program outside any app is left out");
        assert_eq!(apps[0].bundle_path, "/Applications/Heavy.app");
        assert_eq!(apps[0].cpu_seconds, 301.0);
        assert_eq!(apps[0].running_seconds, 500.0, "An app has been open as long as its oldest process");
        assert_eq!(apps[0].memory_bytes, u64::MAX, "Memory that does not fit stops at the largest number");
        assert_eq!(apps[0].processes, 3);
        assert_eq!(apps[1], AppUsage { bundle_path: "/Applications/Light.app".into(), cpu_seconds: 5.0, running_seconds: 900.0, memory_bytes: 100, processes: 1 });
        assert!(by_app(&[]).is_empty());
        // Apps with the same time come in the order of their paths, so the list does not shuffle.
        let even = by_app(&[process("/B.app/x", 1.0, 1.0, 1), process("/A.app/x", 1.0, 1.0, 1)]);
        assert_eq!(even.iter().map(|app| app.bundle_path.as_str()).collect::<Vec<_>>(), ["/A.app", "/B.app"]);
    }

    #[test]
    fn ticks_become_seconds() {
        assert_eq!(seconds(24_000_000, 125, 3), 1.0, "An Apple silicon Mac counts 24 million ticks a second");
        assert_eq!(seconds(1_000_000_000, 1, 1), 1.0);
        assert_eq!(seconds(5, 1, 0), 0.0, "A clock with no rate gives no time");
        assert_eq!(seconds(0, 125, 3), 0.0);
    }

    #[test]
    fn this_process_is_among_the_samples() {
        let own = std::env::current_exe().expect("this program's path");
        let own = own.canonicalize().unwrap_or(own);
        let samples = samples();
        let found = samples.iter().find(|sample| std::path::Path::new(&sample.path).canonicalize().is_ok_and(|path| path == own));
        let found = found.expect("the test's own process");
        assert!(found.cpu_seconds >= 0.0 && found.cpu_seconds < 3_600.0, "{found:?}");
        assert!(found.running_seconds >= 0.0 && found.running_seconds < 3_600.0, "{found:?}");
        assert!(found.memory_bytes > 0);
        assert!(samples.len() > 10, "A Mac runs more than a handful of processes");
        assert!(apps().iter().all(|app| app.bundle_path.ends_with(".app") && app.processes > 0));
    }
}
