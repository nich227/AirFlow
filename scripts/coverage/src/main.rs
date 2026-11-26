//! Reads what the tests ran (LCOV files from `llvm-cov export`) and checks that every line and
//! every function of the gated folders ran at least once.
//!
//! A part that no test can run is marked in the source, with the reason:
//!
//! ```text
//! // coverage:off Only SwiftUI can make a ReadConfiguration.
//! ...
//! // coverage:on
//! ```
//!
//! A marked part in which every line ran is reported too, so a mark never outlives its reason.

#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used))]

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const OFF: &str = "// coverage:off";
const ON: &str = "// coverage:on";

/// What the tests ran in one source file.
#[derive(Debug, Default, PartialEq)]
struct FileCoverage {
    /// How many times each line ran, by line number.
    lines: BTreeMap<usize, u64>,
    /// How many times each function ran, by the line it starts on and its name.
    functions: BTreeMap<(usize, String), u64>,
}

/// What tells one function of a line from another. A Rust function is compiled once for each
/// type it is used with and once for each build of its crate, each copy under its own name, so
/// the copies that start on a line count as one function. A Swift function has one name.
fn function_name(name: &str) -> &str {
    if name.starts_with("_R") || name.starts_with("_ZN") {
        ""
    } else {
        name
    }
}

/// Adds one LCOV file to what is known. Counts for a line or a function that appears twice
/// are added up.
fn read_lcov(text: &str, into: &mut BTreeMap<PathBuf, FileCoverage>) -> Result<(), String> {
    let mut current: Option<PathBuf> = None;
    // A function's line comes in an FN record, and its count in a later FNDA record.
    let mut starts: BTreeMap<String, usize> = BTreeMap::new();
    for (index, line) in text.lines().enumerate() {
        let bad = || format!("line {} is not an LCOV record: {line}", index + 1);
        if let Some(path) = line.strip_prefix("SF:") {
            current = Some(PathBuf::from(path));
            starts.clear();
            continue;
        }
        if line == "end_of_record" {
            current = None;
            continue;
        }
        let Some(path) = &current else { continue };
        let file = into.entry(path.clone()).or_default();
        if let Some(rest) = line.strip_prefix("DA:") {
            let (number, count) = rest.split_once(',').ok_or_else(bad)?;
            let count = count.split(',').next().unwrap_or(count);
            *file
                .lines
                .entry(number.parse().map_err(|_| bad())?)
                .or_default() += count.parse::<u64>().map_err(|_| bad())?;
        } else if let Some(rest) = line.strip_prefix("FN:") {
            let (number, name) = rest.split_once(',').ok_or_else(bad)?;
            let number: usize = number.parse().map_err(|_| bad())?;
            starts.insert(name.to_owned(), number);
            file.functions
                .entry((number, function_name(name).to_owned()))
                .or_default();
        } else if let Some(rest) = line.strip_prefix("FNDA:") {
            let (count, name) = rest.split_once(',').ok_or_else(bad)?;
            let number = *starts.get(name).ok_or_else(bad)?;
            *file
                .functions
                .entry((number, function_name(name).to_owned()))
                .or_default() += count.parse::<u64>().map_err(|_| bad())?;
        }
    }
    Ok(())
}

/// A part of a source file that is marked as one no test can run.
#[derive(Debug, PartialEq)]
struct Exclusion {
    first: usize,
    last: usize,
    reason: String,
}

/// The marked parts of a source file. A mark needs a reason, and each part needs its end.
fn exclusions(source: &str) -> Result<Vec<Exclusion>, String> {
    let mut found = Vec::new();
    let mut open: Option<(usize, String)> = None;
    for (index, line) in source.lines().enumerate() {
        let number = index + 1;
        let text = line.trim();
        if let Some(reason) = text.strip_prefix(OFF) {
            if open.is_some() {
                return Err(format!("line {number} starts a marked part inside another"));
            }
            let reason = reason.trim();
            if reason.is_empty() {
                return Err(format!("the mark on line {number} gives no reason"));
            }
            open = Some((number, reason.to_owned()));
        } else if text == ON {
            let (first, reason) = open
                .take()
                .ok_or_else(|| format!("line {number} ends a marked part that did not start"))?;
            found.push(Exclusion {
                first,
                last: number,
                reason,
            });
        }
    }
    match open {
        Some((first, _)) => Err(format!(
            "the marked part that starts on line {first} has no end"
        )),
        None => Ok(found),
    }
}

/// What the check found in one gated folder.
#[derive(Debug, Default, PartialEq)]
struct Tally {
    lines: usize,
    lines_run: usize,
    functions: usize,
    functions_run: usize,
}

#[derive(Debug, Default)]
struct Findings {
    tallies: BTreeMap<String, Tally>,
    /// Lines and functions that did not run, as `path:line` and what is there.
    missed: Vec<String>,
    /// Marked parts, as `path:line`, the number of lines left out, and the reason.
    excluded: Vec<String>,
    /// Marked parts that the tests ran in full.
    stale: Vec<String>,
}

/// Checks one file's coverage against its source. `shown` is the path as a person reads it.
fn check_file(
    shown: &str,
    source: &str,
    coverage: &FileCoverage,
    tally: &mut Tally,
    findings: &mut Findings,
) -> Result<(), String> {
    let marked = exclusions(source).map_err(|problem| format!("{shown}: {problem}"))?;
    let part = |line: usize| {
        marked
            .iter()
            .position(|exclusion| (exclusion.first..=exclusion.last).contains(&line))
    };
    let text: Vec<&str> = source.lines().collect();
    let code = |line: usize| {
        text.get(line.wrapping_sub(1))
            .map_or("", |code| code.trim())
    };
    let mut left_out = vec![0usize; marked.len()];
    let mut left_out_run = vec![0usize; marked.len()];

    let mut missed_lines: Vec<usize> = Vec::new();
    for (&line, &count) in &coverage.lines {
        if let Some(index) = part(line) {
            left_out[index] += 1;
            left_out_run[index] += usize::from(count > 0);
            continue;
        }
        tally.lines += 1;
        if count > 0 {
            tally.lines_run += 1;
        } else {
            missed_lines.push(line);
            findings
                .missed
                .push(format!("{shown}:{line}  {}", code(line)));
        }
    }
    for (&(line, _), &count) in &coverage.functions {
        if part(line).is_some() {
            continue;
        }
        tally.functions += 1;
        if count > 0 {
            tally.functions_run += 1;
        } else if !missed_lines.contains(&line) {
            // A line that ran can hold a closure that did not, such as the right side of `??`.
            findings.missed.push(format!(
                "{shown}:{line}  a closure or function on this line never ran: {}",
                code(line)
            ));
        }
    }
    for (index, exclusion) in marked.iter().enumerate() {
        let place = format!("{shown}:{}", exclusion.first);
        if left_out[index] > 0 && left_out[index] == left_out_run[index] {
            findings.stale.push(format!(
                "{place}  every marked line ran, so the mark can go"
            ));
        } else {
            findings.excluded.push(format!(
                "{place}  {} lines  {}",
                left_out[index], exclusion.reason
            ));
        }
    }
    Ok(())
}

/// The lines of a source file that start a function: a Rust `fn` or a Swift `func`.
fn function_lines(source: &str) -> Vec<usize> {
    let starts = |line: &str| {
        let code = line.trim();
        !code.starts_with("//")
            && code
                .split(|letter: char| !letter.is_alphanumeric())
                .any(|word| word == "fn" || word == "func")
    };
    source
        .lines()
        .enumerate()
        .filter(|(_, line)| starts(line))
        .map(|(index, _)| index + 1)
        .collect()
}

/// Checks a source file that no test program holds. Its functions were not measured, so each
/// one has to be inside a marked part.
fn check_unmeasured(shown: &str, source: &str, findings: &mut Findings) -> Result<(), String> {
    let marked = exclusions(source).map_err(|problem| format!("{shown}: {problem}"))?;
    let unmarked = |line: &usize| {
        !marked
            .iter()
            .any(|exclusion| (exclusion.first..=exclusion.last).contains(line))
    };
    if let Some(line) = function_lines(source).into_iter().find(unmarked) {
        findings.missed.push(format!(
            "{shown}:{line}  no test program holds this file, so nothing in it was measured"
        ));
    }
    for exclusion in &marked {
        findings.excluded.push(format!(
            "{shown}:{}  not measured  {}",
            exclusion.first, exclusion.reason
        ));
    }
    Ok(())
}

/// Checks every source file inside a gated folder of the root: the measured ones against what
/// ran, and the others for functions that nothing measured.
fn check(
    root: &Path,
    gates: &[String],
    coverage: &BTreeMap<PathBuf, FileCoverage>,
    sources: &dyn Fn(&Path) -> Result<Vec<PathBuf>, String>,
    read: &dyn Fn(&Path) -> Result<String, String>,
) -> Result<Findings, String> {
    let mut findings = Findings::default();
    for gate in gates {
        let folder = root.join(gate);
        let mut tally = Tally::default();
        for path in sources(&folder)? {
            let Ok(inside) = path.strip_prefix(&folder) else {
                continue;
            };
            let shown = Path::new(gate).join(inside).display().to_string();
            match coverage.get(&path) {
                Some(file) => check_file(&shown, &read(&path)?, file, &mut tally, &mut findings)?,
                None => check_unmeasured(&shown, &read(&path)?, &mut findings)?,
            }
        }
        if tally.lines == 0 {
            return Err(format!("nothing was measured in {gate}"));
        }
        findings.tallies.insert(gate.clone(), tally);
    }
    Ok(findings)
}

/// Every Rust and Swift file in a folder and the folders inside it, in order.
fn source_files(folder: &Path) -> Result<Vec<PathBuf>, String> {
    let mut found = Vec::new();
    let mut folders = vec![folder.to_path_buf()];
    while let Some(next) = folders.pop() {
        let unreadable = |problem: std::io::Error| format!("{}: {problem}", next.display());
        for entry in std::fs::read_dir(&next).map_err(unreadable)? {
            let path = entry.map_err(unreadable)?.path();
            if path.is_dir() {
                folders.push(path);
            } else if path
                .extension()
                .is_some_and(|extension| extension == "rs" || extension == "swift")
            {
                found.push(path);
            }
        }
    }
    found.sort();
    Ok(found)
}

fn report(findings: &Findings) -> String {
    let mut out = String::new();
    for (gate, tally) in &findings.tallies {
        let _ = writeln!(
            out,
            "{gate:<24} lines {:>5}/{:<5} functions {:>4}/{:<4}",
            tally.lines_run, tally.lines, tally.functions_run, tally.functions
        );
    }
    for (title, rows) in [
        ("Not run", &findings.missed),
        ("Marked, and run in full", &findings.stale),
        ("Marked as not testable", &findings.excluded),
    ] {
        if !rows.is_empty() {
            let _ = writeln!(out, "\n{title}:");
            for row in rows {
                let _ = writeln!(out, "  {row}");
            }
        }
    }
    out
}

fn passes(findings: &Findings) -> bool {
    findings.missed.is_empty() && findings.stale.is_empty()
}

#[derive(Debug)]
struct Arguments {
    root: PathBuf,
    gates: Vec<String>,
    files: Vec<PathBuf>,
}

fn arguments(mut given: impl Iterator<Item = String>) -> Result<Arguments, String> {
    let usage = "usage: airflow-coverage --root <folder> --gate <folder in the root> [--gate ...] <file.lcov> ...";
    let mut root = None;
    let mut gates = Vec::new();
    let mut files = Vec::new();
    while let Some(argument) = given.next() {
        match argument.as_str() {
            "--root" => root = Some(PathBuf::from(given.next().ok_or(usage)?)),
            "--gate" => gates.push(given.next().ok_or(usage)?),
            _ => files.push(PathBuf::from(argument)),
        }
    }
    match root {
        Some(root) if !gates.is_empty() && !files.is_empty() => {
            Ok(Arguments { root, gates, files })
        }
        _ => Err(usage.to_owned()),
    }
}

fn run(given: impl Iterator<Item = String>) -> Result<(String, bool), String> {
    let arguments = arguments(given)?;
    let read = |path: &Path| {
        std::fs::read_to_string(path).map_err(|problem| format!("{}: {problem}", path.display()))
    };
    let mut coverage = BTreeMap::new();
    for file in &arguments.files {
        read_lcov(&read(file)?, &mut coverage)
            .map_err(|problem| format!("{}: {problem}", file.display()))?;
    }
    let findings = check(
        &arguments.root,
        &arguments.gates,
        &coverage,
        &source_files,
        &read,
    )?;
    Ok((report(&findings), passes(&findings)))
}

fn main() -> ExitCode {
    match run(std::env::args().skip(1)) {
        Ok((text, true)) => {
            print!("{text}");
            ExitCode::SUCCESS
        }
        Ok((text, false)) => {
            print!("{text}");
            ExitCode::from(1)
        }
        Err(problem) => {
            eprintln!("{problem}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = "fn a() {\n    one();\n    // coverage:off The system calls this.\n    two();\n    three();\n    // coverage:on\n    four();\n}\n";

    fn coverage(lcov: &str) -> BTreeMap<PathBuf, FileCoverage> {
        let mut found = BTreeMap::new();
        read_lcov(lcov, &mut found).unwrap();
        found
    }

    /// Checks a root whose only source files are the ones that were measured.
    fn checked(lcov: &str, source: &'static str) -> Result<Findings, String> {
        let measured = coverage(lcov);
        let sources = |_: &Path| Ok(measured.keys().cloned().collect());
        check(
            Path::new("/r"),
            &["src".to_owned()],
            &measured,
            &sources,
            &|_| Ok(source.to_owned()),
        )
    }

    #[test]
    fn counts_for_the_same_line_and_function_are_added_up() {
        let found = coverage("SF:/r/src/a.rs\nFN:1,a\nFNDA:0,a\nDA:1,0\nDA:2,3,abc\nend_of_record\nSF:/r/src/a.rs\nFN:1,a\nFNDA:2,a\nDA:1,4\nend_of_record\n");
        let file = &found[Path::new("/r/src/a.rs")];
        assert_eq!(file.lines, BTreeMap::from([(1, 4), (2, 3)]));
        assert_eq!(file.functions, BTreeMap::from([((1, "a".to_owned()), 2)]));
    }

    #[test]
    fn a_record_that_is_not_lcov_is_refused_with_its_line() {
        for text in [
            "SF:/a\nDA:x,1\n",
            "SF:/a\nDA:1\n",
            "SF:/a\nDA:1,x\n",
            "SF:/a\nFN:1\n",
            "SF:/a\nFN:x,a\n",
            "SF:/a\nFNDA:1,a\n",
            "SF:/a\nFN:1,a\nFNDA:x,a\n",
            "SF:/a\nFNDA:1\n",
        ] {
            let problem = read_lcov(text, &mut BTreeMap::new()).unwrap_err();
            assert!(problem.starts_with("line "), "{text:?} gave {problem}");
        }
        // Records outside a file, and kinds this check does not use, are passed over.
        assert!(
            coverage("TN:\nDA:1,1\nSF:/a\nLF:3\nend_of_record\nDA:9,9\n")[Path::new("/a")]
                .lines
                .is_empty()
        );
    }

    #[test]
    fn the_copies_of_a_rust_function_are_one_function() {
        assert_eq!(
            function_name("_RNvNtCscsPqgZpGQm7_15airflow_backend5usage6by_app"),
            ""
        );
        assert_eq!(function_name("_ZN4fans6Writer3new17h0123456789abcdefE"), "");
        assert_eq!(
            function_name("$s7AirFlow3FanV2idSivg"),
            "$s7AirFlow3FanV2idSivg"
        );
        let found = coverage("SF:/a\nFN:5,_RNvCsaaa_1a1b\nFN:5,_RNvCsbbb_1a1b\nFN:6,$sa\nFN:6,$sb\nFNDA:0,_RNvCsaaa_1a1b\nFNDA:7,_RNvCsbbb_1a1b\nFNDA:1,$sa\nFNDA:0,$sb\nend_of_record\n");
        assert_eq!(
            found[Path::new("/a")].functions,
            BTreeMap::from([
                ((5, String::new()), 7),
                ((6, "$sa".to_owned()), 1),
                ((6, "$sb".to_owned()), 0)
            ])
        );
    }

    #[test]
    fn a_marked_part_has_a_reason_and_an_end() {
        assert_eq!(
            exclusions(SOURCE),
            Ok(vec![Exclusion {
                first: 3,
                last: 6,
                reason: "The system calls this.".to_owned()
            }])
        );
        assert_eq!(exclusions("a\nb\n"), Ok(vec![]));
        assert_eq!(
            exclusions("// coverage:off\n// coverage:on\n").unwrap_err(),
            "the mark on line 1 gives no reason"
        );
        assert_eq!(
            exclusions("x\n// coverage:off why\n").unwrap_err(),
            "the marked part that starts on line 2 has no end"
        );
        assert_eq!(
            exclusions("// coverage:on\n").unwrap_err(),
            "line 1 ends a marked part that did not start"
        );
        assert_eq!(
            exclusions("// coverage:off a\n// coverage:off b\n// coverage:on\n").unwrap_err(),
            "line 2 starts a marked part inside another"
        );
    }

    #[test]
    fn every_line_and_function_outside_a_marked_part_has_to_run() {
        let all = checked("SF:/r/src/a.rs\nFN:1,a\nFNDA:1,a\nDA:2,1\nDA:4,0\nDA:5,0\nDA:7,1\nend_of_record\nSF:/r/other/b.rs\nDA:1,0\nend_of_record\n", SOURCE).unwrap();
        assert!(passes(&all));
        assert_eq!(
            all.tallies["src"],
            Tally {
                lines: 2,
                lines_run: 2,
                functions: 1,
                functions_run: 1
            }
        );
        assert_eq!(
            all.excluded,
            ["src/a.rs:3  2 lines  The system calls this."]
        );

        let line = checked(
            "SF:/r/src/a.rs\nFN:1,a\nFNDA:1,a\nDA:2,1\nDA:4,0\nDA:7,0\nend_of_record\n",
            SOURCE,
        )
        .unwrap();
        assert!(!passes(&line));
        assert_eq!(line.missed, ["src/a.rs:7  four();"]);
        assert_eq!(
            line.tallies["src"],
            Tally {
                lines: 2,
                lines_run: 1,
                functions: 1,
                functions_run: 1
            }
        );

        // A closure that never ran on a line that did is named. A function on a line that
        // did not run is named once, by its line.
        let closure = checked("SF:/r/src/a.rs\nFN:2,a\nFN:2,b\nFN:7,c\nFN:4,d\nFNDA:1,a\nFNDA:0,b\nFNDA:0,c\nFNDA:0,d\nDA:2,1\nDA:7,0\nend_of_record\n", SOURCE).unwrap();
        assert_eq!(
            closure.missed,
            [
                "src/a.rs:7  four();",
                "src/a.rs:2  a closure or function on this line never ran: one();"
            ]
        );
        assert_eq!(
            closure.tallies["src"],
            Tally {
                lines: 2,
                lines_run: 1,
                functions: 3,
                functions_run: 1
            }
        );
    }

    #[test]
    fn a_mark_whose_lines_all_ran_is_reported() {
        let stale = checked(
            "SF:/r/src/a.rs\nDA:2,1\nDA:4,1\nDA:5,2\nend_of_record\n",
            SOURCE,
        )
        .unwrap();
        assert!(!passes(&stale));
        assert_eq!(
            stale.stale,
            ["src/a.rs:3  every marked line ran, so the mark can go"]
        );
        assert!(stale.excluded.is_empty());
        // A marked part with no measured line, such as a declaration, stays.
        let empty = checked("SF:/r/src/a.rs\nDA:2,1\nend_of_record\n", SOURCE).unwrap();
        assert!(passes(&empty));
        assert_eq!(
            empty.excluded,
            ["src/a.rs:3  0 lines  The system calls this."]
        );
    }

    #[test]
    fn a_gate_with_nothing_measured_and_a_bad_mark_are_errors() {
        assert_eq!(
            checked("SF:/r/elsewhere/a.rs\nDA:1,1\nend_of_record\n", SOURCE).unwrap_err(),
            "nothing was measured in src"
        );
        assert_eq!(
            checked(
                "SF:/r/src/a.rs\nDA:1,1\nend_of_record\n",
                "// coverage:off\n"
            )
            .unwrap_err(),
            "src/a.rs: the mark on line 1 gives no reason"
        );
        let measured = coverage("SF:/r/src/a.rs\nDA:1,1\nend_of_record\n");
        let gone = |_: &Path| Err("gone".to_owned());
        let gates = ["src".to_owned()];
        let unreadable = check(
            Path::new("/r"),
            &gates,
            &measured,
            &|_| Ok(vec![PathBuf::from("/r/src/a.rs")]),
            &gone,
        );
        assert_eq!(unreadable.unwrap_err(), "gone");
        let unlisted = check(
            Path::new("/r"),
            &gates,
            &measured,
            &|_| Err("no folder".to_owned()),
            &gone,
        );
        assert_eq!(unlisted.unwrap_err(), "no folder");
    }

    #[test]
    fn a_file_that_was_not_measured_may_hold_no_function_outside_a_mark() {
        assert_eq!(function_lines("pub mod a;\n// fn old() {}\nfn a() {}\n    private func b() {}\nlet function = 1;\n"), [3, 4]);
        let measured = coverage("SF:/r/src/a.rs\nDA:2,1\nDA:7,1\nend_of_record\n");
        let sources = |_: &Path| {
            Ok(["a.rs", "b.rs", "lib.rs", "glue.rs", "bad.rs"]
                .iter()
                .map(|name| Path::new("/r/src").join(name))
                .collect())
        };
        let read = |path: &Path| {
            Ok(match path.file_name().and_then(|name| name.to_str()) {
                Some("a.rs") => SOURCE,
                Some("b.rs") => "use a;\n\nfn forgotten() {}\n",
                Some("lib.rs") => "pub mod a;\npub mod b;\n",
                Some("glue.rs") => {
                    "// coverage:off Only launchd runs it.\nfn main() {}\n// coverage:on\n"
                }
                _ => "// coverage:off\nfn main() {}\n",
            }
            .to_owned())
        };
        let gates = ["src".to_owned()];
        let sound = check(
            Path::new("/r"),
            &gates,
            &measured,
            &|folder| sources(folder).map(|mut all: Vec<PathBuf>| all.drain(..4).collect()),
            &read,
        )
        .unwrap();
        assert_eq!(
            sound.missed,
            ["src/b.rs:3  no test program holds this file, so nothing in it was measured"]
        );
        assert_eq!(
            sound.excluded,
            [
                "src/a.rs:3  0 lines  The system calls this.",
                "src/glue.rs:1  not measured  Only launchd runs it."
            ]
        );
        assert!(!passes(&sound));
        let bad = check(Path::new("/r"), &gates, &measured, &sources, &read);
        assert_eq!(
            bad.unwrap_err(),
            "src/bad.rs: the mark on line 1 gives no reason"
        );
        // A file outside the gate's folder is passed over.
        let outside = check(
            Path::new("/r"),
            &gates,
            &measured,
            &|_| {
                Ok(vec![
                    PathBuf::from("/elsewhere/c.rs"),
                    PathBuf::from("/r/src/a.rs"),
                ])
            },
            &read,
        )
        .unwrap();
        assert!(passes(&outside));
    }

    #[test]
    fn source_files_are_found_in_every_folder_inside() {
        let folder =
            std::env::temp_dir().join(format!("airflow-coverage-files-{}", std::process::id()));
        std::fs::create_dir_all(folder.join("deep/er")).unwrap();
        for name in [
            "b.swift",
            "a.rs",
            "notes.md",
            "deep/c.rs",
            "deep/er/d.swift",
        ] {
            std::fs::write(folder.join(name), "").unwrap();
        }
        let found = source_files(&folder).unwrap();
        let names: Vec<_> = found
            .iter()
            .map(|path| path.strip_prefix(&folder).unwrap().display().to_string())
            .collect();
        assert_eq!(names, ["a.rs", "b.swift", "deep/c.rs", "deep/er/d.swift"]);
        std::fs::remove_dir_all(&folder).unwrap();
        assert!(source_files(&folder)
            .unwrap_err()
            .starts_with(&folder.display().to_string()));
    }

    #[test]
    fn the_report_lists_each_folder_and_each_finding() {
        let findings = checked(
            "SF:/r/src/a.rs\nFN:1,a\nFNDA:1,a\nDA:2,1\nDA:4,0\nDA:7,0\nend_of_record\n",
            SOURCE,
        )
        .unwrap();
        assert_eq!(
            report(&findings),
            "src                      lines     1/2     functions    1/1   \n\nNot run:\n  src/a.rs:7  four();\n\nMarked as not testable:\n  src/a.rs:3  1 lines  The system calls this.\n"
        );
    }

    #[test]
    fn the_command_needs_a_root_a_gate_and_a_file() {
        let words = |text: &str| {
            text.split(' ')
                .map(str::to_owned)
                .collect::<Vec<_>>()
                .into_iter()
        };
        let given = arguments(words("--root /r --gate a --gate b x.lcov y.lcov")).unwrap();
        assert_eq!(
            (given.root, given.gates, given.files),
            (
                PathBuf::from("/r"),
                vec!["a".to_owned(), "b".to_owned()],
                vec![PathBuf::from("x.lcov"), PathBuf::from("y.lcov")]
            )
        );
        for bad in [
            "--gate a x.lcov",
            "--root /r x.lcov",
            "--root /r --gate a",
            "--root",
            "--root /r --gate",
        ] {
            assert!(
                arguments(words(bad)).unwrap_err().starts_with("usage:"),
                "{bad}"
            );
        }
        assert!(run(words("--root /r --gate a /nonexistent/x.lcov"))
            .unwrap_err()
            .starts_with("/nonexistent/x.lcov: "));
    }

    #[test]
    fn a_run_reads_the_files_it_is_given() {
        let folder = std::env::temp_dir().join(format!("airflow-coverage-{}", std::process::id()));
        std::fs::create_dir_all(folder.join("src")).unwrap();
        std::fs::write(folder.join("src/a.rs"), SOURCE).unwrap();
        let source = folder.join("src/a.rs").display().to_string();
        let lcov = folder.join("a.lcov");
        let given = |lcov: &Path| {
            vec![
                "--root".to_owned(),
                folder.display().to_string(),
                "--gate".to_owned(),
                "src".to_owned(),
                lcov.display().to_string(),
            ]
            .into_iter()
        };

        std::fs::write(
            &lcov,
            format!("SF:{source}\nDA:2,1\nDA:7,1\nend_of_record\n"),
        )
        .unwrap();
        let (text, passed) = run(given(&lcov)).unwrap();
        assert!(passed);
        assert!(text.starts_with("src "), "{text}");

        std::fs::write(
            &lcov,
            format!("SF:{source}\nDA:2,1\nDA:7,0\nend_of_record\n"),
        )
        .unwrap();
        assert!(!run(given(&lcov)).unwrap().1);

        std::fs::write(&lcov, format!("SF:{source}\nDA:x\n")).unwrap();
        assert!(run(given(&lcov))
            .unwrap_err()
            .contains("line 2 is not an LCOV record"));
        std::fs::remove_dir_all(&folder).unwrap();
    }
}
