#!/bin/zsh
# Takes the README's screenshots of the Debug build into docs/images. Build first with
# scripts/build.sh. The app opens behind the other windows and never takes the keyboard.
#
#   scripts/make-screenshots.sh
#
# The screenshots show this Mac's own readings and whatever presets and rules the Debug copy holds.
# An ad hoc build shows the Monitoring Only banner, so the pictures of fans under control (the
# Adaptive page, the fan curve, and the setup sheet) are taken by hand from a signed copy with the
# helper approved. The terminal needs Screen Recording permission for screencapture.
#
# The grid of apps shows the apps on this Mac. To leave some out of the picture, list words that
# their names or identifiers hold, with commas between:
#
#   AIRFLOW_HIDE_APPS="word,another" scripts/make-screenshots.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Debug/AirFlow.app"
OUT="$ROOT/docs/images"
DOMAIN="com.kevster.airflow.debug"
# The whole path, so a copy of AirFlow in /Applications keeps running.
BINARY="$APP/Contents/MacOS/AirFlow"
ADAPTIVE_ID="A1F10000-0000-4000-8000-000000000003"

[[ -d "$APP" ]] || { echo "No Debug build at $APP. Run scripts/build.sh first." >&2; exit 1; }
mkdir -p "$OUT"

WORK="$(mktemp -d -t airflow-shots)"
FINDER="$WORK/window.swift"
SCRATCH="$WORK/shot.png"
cat > "$FINDER" <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list where (window[kCGWindowOwnerName as String] as? String) == "AirFlow Debug"
    && (window[kCGWindowLayer as String] as? Int) == 0 {
    print(window[kCGWindowNumber as String] ?? 0)
    break
}
SWIFT

quit_app() {
    pkill -f "$BINARY" 2>/dev/null || true
    for _ in {1..20}; do
        pgrep -f "$BINARY" >/dev/null || return 0
        sleep 0.5
    done
    pkill -9 -f "$BINARY" 2>/dev/null || true
    sleep 1
}

# shot <page> <appearance> <file> <seconds to wait>
shot() {
    quit_app
    defaults write "$DOMAIN" "NSWindow Frame main" "264 194 1240 800 0 0 1728 1084 "
    defaults delete "$DOMAIN" "NSSplitView Subview Frames main, SidebarNavigationSplitView" 2>/dev/null || true
    open -g --env "AIRFLOW_SHOW=$1" --env "AIRFLOW_APPEARANCE=$2" --env "AIRFLOW_HIDE_APPS=${AIRFLOW_HIDE_APPS:-}" "$APP"
    sleep "$4"
    local id
    id="$(swift "$FINDER" 2>/dev/null)"
    [[ -n "$id" ]] || { echo "AirFlow's window did not open for $1." >&2; exit 1; }
    # The picture goes to a scratch file first, so a failed capture leaves the old picture alone.
    screencapture -x -o -l "$id" "$SCRATCH" || { echo "No picture of $1. Is the screen awake and unlocked?" >&2; exit 1; }
    sips -Z 1600 "$SCRATCH" --out "$OUT/$3" >/dev/null
    echo "wrote docs/images/$3"
}

# Adaptive is the active preset in every screenshot. The earlier choice comes back afterward.
before_active="$(defaults read "$DOMAIN" activePresetID 2>/dev/null || true)"
before_user="$(defaults read "$DOMAIN" userPresetID 2>/dev/null || true)"
finish() {
    quit_app
    [[ -n "$before_active" ]] && defaults write "$DOMAIN" activePresetID "$before_active"
    [[ -n "$before_user" ]] && defaults write "$DOMAIN" userPresetID "$before_user"
    rm -rf "$WORK"
}
trap finish EXIT
quit_app
defaults write "$DOMAIN" activePresetID "$ADAPTIVE_ID"
defaults write "$DOMAIN" userPresetID "$ADAPTIVE_ID"
# The readings panel shows in every picture.
defaults write "$DOMAIN" showsInspector -bool true

shot rules dark rules.png 8
shot sensors dark sensors.png 8
shot apps dark apps.png 9
