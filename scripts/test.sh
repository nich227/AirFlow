#!/bin/zsh
# Runs the backend's tests, then generates the Xcode project and runs the AirFlowTests unit
# tests. The backend's tests use a made-up SMC, and the app's tests use a recorder in place of
# the helper, so no test reads or changes a real fan.
set -euo pipefail
cd "${0:A:h}/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

# The backend first: the SMC's byte formats, the sensor names, the fan writer, and the trust rule.
(cd backend && cargo test --locked --jobs "${AIRFLOW_BUILD_JOBS:-4}" 2>&1 | grep -E '^test result|FAILED|panicked|^error' \
    && cargo clippy --locked --all-targets -- -D warnings 2>&1 | grep -E '^(warning|error)' || true)

xcodegen generate
xcodebuild -project AirFlow.xcodeproj -scheme AirFlow -configuration Debug \
    -derivedDataPath build/DerivedData -jobs "${AIRFLOW_BUILD_JOBS:-4}" test 2>&1 \
    | grep -E '^/.*(error|warning):|: error:|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)|\] failed|BUILD FAILED' \
    | grep -vE 'appintentsmetadataprocessor|^[0-9]{4}-' | tail -40
