#!/bin/zsh
# This step signs the executables inside Sparkle.framework after Xcode leaves them with Sparkle's
# own signature. It signs them from the inside out, then signs the framework, and then signs the
# app again so that its signature covers the framework. Thus, notarization sees one identity on
# every Mach-O in the bundle. Run it before you verify the app's own signature.
#
# The helper is not signed here. scripts/embed-helper.sh signs it during the build, under its own
# identifier, and this script checks that it carries the same identity.
#
#   CODESIGN_FLAGS='--timestamp --keychain path' scripts/sign-nested.sh <AirFlow.app> <identity>
set -euo pipefail

APP="${1:?usage: sign-nested.sh <AirFlow.app> <identity>}"
IDENTITY="${2:?missing identity}"
FLAGS=(${=CODESIGN_FLAGS:-})
HERE="${0:A:h}"

sign() {
    codesign --force --sign "$IDENTITY" --options runtime "${FLAGS[@]}" "$@"
}

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "no Sparkle.framework in $APP" >&2; exit 1; }
VERSION="$SPARKLE/Versions/B"

for xpc in "$VERSION"/XPCServices/*.xpc; do
    [[ -d "$xpc" ]] || continue
    sign "$xpc/Contents/MacOS/$(basename "$xpc" .xpc)"
    sign "$xpc"
done
sign "$VERSION/Autoupdate"
sign "$VERSION/Updater.app/Contents/MacOS/Updater"
sign "$VERSION/Updater.app"
sign "$SPARKLE"

# The helper trusts only an app that its own team signed, so both must carry one team.
HELPER="$APP/Contents/MacOS/AirFlowHelper"
[[ -f "$HELPER" ]] || { echo "no helper in $APP" >&2; exit 1; }
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
helper_team="$(team "$HELPER")"
if [[ -z "$helper_team" || "$helper_team" == "not set" ]]; then
    echo "the helper has no team's signature" >&2
    exit 1
fi

# The app is signed last, so its signature covers the framework. Signing again drops the
# entitlements unless they are named.
sign --entitlements "$HERE/../AirFlow/AirFlow.entitlements" "$APP"
if [[ "$(team "$APP")" != "$helper_team" ]]; then
    echo "the app and the helper carry different teams" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"
