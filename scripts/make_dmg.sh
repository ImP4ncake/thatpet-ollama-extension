#!/bin/sh
# Builds the drag-and-drop installer build/ThatPet-Ollama-Extension.dmg from the built app:
# a window with the app, an arrow and the Applications folder, and a disk icon with the cat.
#
#   scripts/make_dmg.sh          (after scripts/build.sh; release.sh runs it too)
#
# Finder lays out the window, so macOS may ask once to let the Terminal control Finder.
set -e
cd "$(dirname "$0")/.."
NAME="ThatPet Ollama Extension"
APP="build/$NAME.app"
OUT="build/ThatPet-Ollama-Extension.dmg"
[ -d "$APP" ] || { echo "build the app first: scripts/build.sh"; exit 1; }
[ ! -d "/Volumes/$NAME" ] || { echo "eject the \"$NAME\" disk first"; exit 1; }

WORK=$(mktemp -d)
trap '[ -n "$DEVICE" ] && hdiutil detach -quiet -force "$DEVICE" 2>/dev/null; rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
swift scripts/artwork.swift dmg-background "$WORK" >/dev/null
swift scripts/artwork.swift disk-icon "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

SIZE=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE}m" "$WORK/rw.dmg"
ATTACHED=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg")
DEVICE=$(echo "$ATTACHED" | awk -F'\t' '/Apple_HFS/ {sub(/[ \t]+$/, "", $1); print $1}')
MOUNT=$(echo "$ATTACHED" | awk -F'\t' '/Apple_HFS/ {print $NF}')
[ "$MOUNT" = "/Volumes/$NAME" ] || { echo "unexpected mount point: $MOUNT"; exit 1; }

# Window 640x420 (plus the title bar), icons 112 pt where the background expects them.
if ! osascript <<EOF
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 568}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$NAME.app" of container window to {165, 185}
        set position of item "Applications" of container window to {475, 185}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
then
  echo "Finder could not lay out the window (allow the Terminal to control Finder in"
  echo "System Settings > Privacy & Security > Automation, then run this again)"
  exit 1
fi

[ -f "$MOUNT/.DS_Store" ] || { echo "Finder did not save the window layout"; exit 1; }
# The disk's icon, set after Finder's pass (Finder drops one copied in before it).
cp "$WORK/VolumeIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
rm -rf "$MOUNT/.fseventsd"
sync
hdiutil detach -quiet "$DEVICE"
DEVICE=""
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
echo "Built: $(pwd)/$OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
