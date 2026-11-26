//! The check as a command: what it prints and how it ends.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const SOURCE: &str = "fn a() {\n    one();\n}\n";

/// A root with one source file in `src`, and an LCOV file that says how often line 2 ran.
fn root(name: &str, count: u32) -> PathBuf {
    let folder = std::env::temp_dir().join(format!(
        "airflow-coverage-command-{name}-{}",
        std::process::id()
    ));
    std::fs::create_dir_all(folder.join("src")).unwrap();
    std::fs::write(folder.join("src/a.rs"), SOURCE).unwrap();
    let source = folder.join("src/a.rs").display().to_string();
    std::fs::write(
        folder.join("a.lcov"),
        format!("SF:{source}\nFN:1,a\nFNDA:{count},a\nDA:2,{count}\nend_of_record\n"),
    )
    .unwrap();
    folder
}

fn check(root: &Path, gate: &str) -> Output {
    let output = Command::new(env!("CARGO_BIN_EXE_airflow-coverage"))
        .args([
            "--root",
            &root.display().to_string(),
            "--gate",
            gate,
            &root.join("a.lcov").display().to_string(),
        ])
        .output()
        .unwrap();
    std::fs::remove_dir_all(root).unwrap();
    output
}

#[test]
fn it_ends_with_0_when_everything_ran() {
    let output = check(&root("ran", 3), "src");
    assert_eq!(output.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&output.stdout).starts_with("src "));
    assert!(output.stderr.is_empty());
}

#[test]
fn it_ends_with_1_and_names_the_line_that_did_not_run() {
    let output = check(&root("missed", 0), "src");
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stdout).contains("Not run:\n  src/a.rs:2  one();"));
}

#[test]
fn it_knows_a_file_that_is_named_through_a_link() {
    // The coverage names the file through a link to the root, and the root is given as it is.
    let real = root("linked", 2);
    let link = real.with_extension("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let through = link.join("src/a.rs").display().to_string();
    std::fs::write(
        real.join("a.lcov"),
        format!("SF:{through}\nFN:1,a\nFNDA:2,a\nDA:2,2\nend_of_record\n"),
    )
    .unwrap();
    let output = check(&real, "src");
    std::fs::remove_file(&link).unwrap();
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("lines     1/1"));
}

#[test]
fn it_ends_with_2_when_it_cannot_check() {
    let output = check(&root("nothing", 1), "elsewhere");
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("elsewhere"));
}
