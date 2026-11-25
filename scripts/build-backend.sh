#!/bin/zsh
# Builds the Rust backend: the static library the app links and the helper binary. Xcode runs
# this before it compiles the app, with CONFIGURATION set. By hand it builds the debug profile.
set -euo pipefail
cd "${0:A:h}/../backend"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

if ! command -v cargo >/dev/null; then
    print -u2 "error: AirFlow's backend is Rust. Install it from https://rustup.rs and build again."
    exit 1
fi

flags=()
[[ "${CONFIGURATION:-Debug}" == Release ]] && flags=(--release)

# The linker warns when an object file is newer than the app's minimum macOS.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
# Cargo.lock pins every crate, so the build never picks up a version nobody reviewed.
cargo build --locked --jobs "${AIRFLOW_BUILD_JOBS:-4}" "${flags[@]}"
