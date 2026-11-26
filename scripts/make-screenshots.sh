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
# The last picture, palettes.png, shows the readings panel in several color palettes side by side.
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
AUTOMATIC_ID="A1F10000-0000-4000-8000-000000000001"
# The palettes in palettes.png, by their names in ColorPalette.
PALETTES=(aqua cyberpunk matrix girlypop darcula)

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

# strip.swift <out> <x> <y> <width> <height> <in>...: cuts the same rectangle out of each picture and
# puts the pieces side by side.
STRIP="$WORK/strip.swift"
cat > "$STRIP" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 6, let x = Int(arguments[2]), let y = Int(arguments[3]), let width = Int(arguments[4]), let height = Int(arguments[5]) else { exit(2) }
let pieces: [CGImage] = arguments[6...].compactMap { path in
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
}
guard pieces.count == arguments.count - 6,
      let context = CGContext(data: nil, width: width * pieces.count, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
for (index, piece) in pieces.enumerated() {
    context.draw(piece, in: CGRect(x: index * width, y: 0, width: width, height: height))
}
guard let joined = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, joined, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
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

# shot <page> <appearance> <file> <seconds to wait>: a file with no folder goes into docs/images.
shot() {
    local target="$3"
    [[ "$target" == */* ]] || target="$OUT/$3"
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
    sips -Z 1600 "$SCRATCH" --out "$target" >/dev/null
    [[ "$target" == "$OUT/$3" ]] && echo "wrote docs/images/$3"
    return 0
}

# Adaptive is the active preset in every screenshot. The earlier choice comes back afterward.
before_active="$(defaults read "$DOMAIN" activePresetID 2>/dev/null || true)"
before_user="$(defaults read "$DOMAIN" userPresetID 2>/dev/null || true)"
before_palette="$(defaults read "$DOMAIN" colorPalette 2>/dev/null || true)"
finish() {
    quit_app
    [[ -n "$before_active" ]] && defaults write "$DOMAIN" activePresetID "$before_active"
    [[ -n "$before_user" ]] && defaults write "$DOMAIN" userPresetID "$before_user"
    if [[ -n "$before_palette" ]]; then
        defaults write "$DOMAIN" colorPalette "$before_palette"
    else
        defaults delete "$DOMAIN" colorPalette 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap finish EXIT
quit_app
defaults write "$DOMAIN" activePresetID "$ADAPTIVE_ID"
defaults write "$DOMAIN" userPresetID "$ADAPTIVE_ID"
# The readings panel shows in every picture, and every page is in the palette a new copy starts with.
defaults write "$DOMAIN" showsInspector -bool true
defaults delete "$DOMAIN" colorPalette 2>/dev/null || true

shot rules dark rules.png 8
shot sensors dark sensors.png 8
shot apps dark apps.png 9


# The readings panel in each palette. Automatic is the active preset here, because Adaptive puts
# its rainbow behind the panel.
defaults write "$DOMAIN" activePresetID "$AUTOMATIC_ID"
defaults write "$DOMAIN" userPresetID "$AUTOMATIC_ID"
pieces=()
for palette in "${PALETTES[@]}"; do
    defaults write "$DOMAIN" colorPalette "$palette"
    shot Quiet dark "$WORK/$palette.png" 8
    pieces+=("$WORK/$palette.png")
done
# The panel's place in a picture 1,600 pixels wide.
swift "$STRIP" "$OUT/palettes.png" 1236 80 360 895 "${pieces[@]}" || { echo "No picture of the palettes." >&2; exit 1; }
echo "wrote docs/images/palettes.png"
