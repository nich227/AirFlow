#!/bin/zsh
# This runs the backend's tests and the app's tests with coverage, then checks that every line and
# every function of the logic ran: the backend, the app's Models, Controllers, Hardware, and
# Intelligence folders, and the check itself (scripts/coverage). A part that no test can run is marked in its source with
# "// coverage:off <reason>" and "// coverage:on". The views are measured and not checked.
#
# It needs the llvm-tools component of the Rust toolchain: rustup component add llvm-tools
#
#   scripts/coverage.sh            everything
#   scripts/coverage.sh backend    the backend only
#   scripts/coverage.sh app        the app only
#   scripts/coverage.sh checker    the check itself only
set -euo pipefail
cd "${0:A:h}/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
root=$PWD
out=$root/build/coverage
jobs=${AIRFLOW_BUILD_JOBS:-4}
half=${1:-all}
mkdir -p $out
gates=()
files=()
# The halves whose tests failed. What a failed run measured is not checked.
failed=()

# Runs a Rust crate's tests with coverage and adds what they ran to the check.
#   rust_half <name> <crate folder> <folder to check> <pattern of the test programs' names>
rust_half() {
    local name=$1 crate=$2 gate=$3 pattern=$4
    local tools="$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | sed -n 's/^host: //p')/bin"
    [[ -x $tools/llvm-cov ]] || { echo "The Rust toolchain has no llvm-cov. Run: rustup component add llvm-tools" >&2; exit 2 }
    rm -rf $out/$name-profiles
    (cd $crate && RUSTFLAGS="-C instrument-coverage" LLVM_PROFILE_FILE="$out/$name-profiles/%p-%m.profraw" \
        cargo test --locked --jobs $jobs --target-dir $out/$name-target > $out/$name-tests.log 2>&1) || failed+=($name)
    grep -E '^test result|FAILED|panicked|^error' $out/$name-tests.log || true
    $tools/llvm-profdata merge -sparse $out/$name-profiles/*.profraw -o $out/$name.profdata
    # A crate is built more than once: with its tests, and for the program that uses it. Each
    # program is read on its own, and the check adds them up, so one build's zeros never hide
    # another's counts.
    rm -f $out/$name-*.lcov(N)
    local binary
    for binary in $(find $out/$name-target/debug -type f -perm +111 -name $pattern ! -name '*.*'); do
        $tools/llvm-cov export -format=lcov -instr-profile $out/$name.profdata $binary \
            -ignore-filename-regex '/\.cargo/|/rustc/|/\.rustup/|/tests/' 2> >(grep -v 'mismatched data' >&2) > $out/$name-${binary:t}.lcov
        files+=($out/$name-${binary:t}.lcov)
    done
    gates+=(--gate $gate)
}

if [[ $half == all || $half == backend ]]; then
    rust_half backend backend backend/src '[Aa]ir[Ff]low*'
fi

# The check checks itself too.
if [[ $half == all || $half == checker ]]; then
    rust_half checker scripts/coverage scripts/coverage/src '*'
fi

if [[ $half == all || $half == app ]]; then
    # Its own derived data, so a build with coverage does not replace the Debug build.
    xcodegen generate > /dev/null
    xcodebuild -project AirFlow.xcodeproj -scheme AirFlow -configuration Debug \
        -derivedDataPath $out/DerivedData -jobs $jobs -enableCodeCoverage YES test > $out/app-tests.log 2>&1 || failed+=(app)
    grep -E '^/.*(error|warning):|: error:|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)|\] failed|BUILD FAILED' $out/app-tests.log \
        | grep -vE 'appintentsmetadataprocessor|^[0-9]{4}-' | tail -20 || true
    profile=$(ls -t $out/DerivedData/Build/ProfileData/*/Coverage.profdata | head -1)
    xcrun llvm-cov export -format=lcov -instr-profile $profile \
        $out/DerivedData/Build/Products/Debug/AirFlow.app/Contents/MacOS/AirFlow.debug.dylib > $out/app.lcov
    gates+=(--gate AirFlow/Models --gate AirFlow/Controllers --gate AirFlow/Hardware --gate AirFlow/Intelligence)
    files+=($out/app.lcov)
fi

[[ ${#files} -gt 0 ]] || { echo "usage: scripts/coverage.sh [backend|app|checker]" >&2; exit 2 }
[[ ${#failed} -eq 0 ]] || { echo "The tests failed: $failed. See $out/<half>-tests.log." >&2; exit 1 }
cargo run --quiet --release --locked --manifest-path scripts/coverage/Cargo.toml -- --root $root $gates $files
