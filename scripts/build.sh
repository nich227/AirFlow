#!/bin/zsh
# Generates the Xcode project and builds the app into build/DerivedData.
#
#   scripts/build.sh [Debug|Release] [--sign]
#
# A plain build is signed ad hoc and can only monitor. With --sign, the build is signed with a
# developer identity from the keychain, which the fan control helper needs. AIRFLOW_SIGN_IDENTITY
# names the identity. Without it, the script takes the first Developer ID Application identity (the
# one a release is signed with) and then the first Apple Development identity.
set -euo pipefail
cd "${0:A:h}/.."
export PATH="/opt/homebrew/bin:$PATH"

configuration=Debug
sign=false
for argument in "$@"; do
    case "$argument" in
        --sign) sign=true ;;
        *) configuration="$argument" ;;
    esac
done

settings=()
if $sign; then
    identity="${AIRFLOW_SIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        identities=$(security find-identity -v -p codesigning)
        identity=$(print -r -- "$identities" | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
        [[ -n "$identity" ]] || identity=$(print -r -- "$identities" | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)
    fi
    if [[ -z "$identity" ]]; then
        print -u2 "No signing identity in the keychain. Set AIRFLOW_SIGN_IDENTITY, or build without --sign."
        exit 1
    fi
    # The team is the certificate's organizational unit, which is not always the text in parentheses.
    team=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt multiline | sed -nE 's/^ *organizationalUnitName *= *//p' | head -1)
    print "Signing as $identity (team $team)"
    settings=(AIRFLOW_SIGN_IDENTITY="$identity" AIRFLOW_TEAM="$team")
fi

xcodegen generate
# A build sizes its worker pool to the Mac's cores. AIRFLOW_BUILD_JOBS keeps it smaller.
xcodebuild -project AirFlow.xcodeproj -scheme AirFlow -configuration "$configuration" \
    -derivedDataPath build/DerivedData -jobs "${AIRFLOW_BUILD_JOBS:-4}" "${settings[@]}" build 2>&1 \
    | grep -E '^/.*(error|warning):|: error:|^error:|\*\* BUILD|Signing as' | grep -v appintentsmetadataprocessor
