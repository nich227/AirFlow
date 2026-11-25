// A command line tool has no bundle, so the helper's Info.plist travels inside its binary.
// launchd and the system's list of background items read the helper's name from it.
fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR");
    let plist = format!("{manifest}/helper-Info.plist");
    println!("cargo:rerun-if-changed={plist}");
    println!("cargo:rustc-link-arg-bin=AirFlowHelper=-Wl,-sectcreate,__TEXT,__info_plist,{plist}");
}
