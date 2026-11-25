#!/bin/zsh
# Creates the drag-to-Applications disk image from a built AirFlow.app.
#
#   scripts/make-dmg.sh <path to AirFlow.app> <version> [output.dmg]
#
# The window opens at a fixed size with the app on the left and an alias to /Applications on the
# right. Drag the app onto the alias to install it. The window has no picture, so Finder's own
# surface and labels follow the appearance.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <AirFlow.app> <version> [out.dmg]}"
VERSION="${2:?missing version}"
OUT="${3:-AirFlow-${VERSION}.dmg}"

STAGE="$(mktemp -d)/AirFlow"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# The mounted volume shows the app's own icon.
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
    SetFile -a C "$STAGE" 2>/dev/null || true
fi

RW="$(mktemp -u).dmg"
hdiutil create -srcfolder "$STAGE" -volname "AirFlow $VERSION" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -quiet "$RW"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -Eo '/Volumes/.*$' | head -1)"

# This step sets the icon positions and the window bounds. Finder counts the title bar in the window
# bounds. Finder scripting needs an Automation grant for the terminal that runs this script. Without
# the grant, the script still builds the image with Finder's default layout, and the message says
# why.
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$(basename "$MOUNT")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 100, 800, 448}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 13
    set position of item "AirFlow.app" of container window to {150, 150}
    set position of item "Applications" of container window to {450, 150}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT
then
    echo "make-dmg.sh: Finder would not take the window layout (allow this terminal under System Settings > Privacy & Security > Automation). Built with the default layout." >&2
fi

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$MOUNT" -quiet

rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
rm -f "$RW"
echo "$OUT"
