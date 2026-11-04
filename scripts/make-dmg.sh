#!/bin/bash
# Builds a drag-to-Applications disk image: the app on the left, an Applications link on the right, the arrow
# background from assets/. Usage: make-dmg.sh <app bundle> <output dmg>
set -euo pipefail
app="${1:?app bundle}" out="${2:?output dmg}"
name=$(basename "$app" .app)
stage=$(mktemp -d "${TMPDIR:-/tmp}/dmg.XXXXXX")
rw="$stage/rw.dmg"
trap 'hdiutil detach "$mount" -quiet 2>/dev/null || true; rm -rf "$stage"' EXIT
mkdir -p "$stage/root/.background"
cp -R "$app" "$stage/root/"
ln -s /Applications "$stage/root/Applications"
cp assets/dmg-background.png "$stage/root/.background/background.png"
# A volume of the same name still mounted (an earlier image left open) would be the one Finder lays out.
for v in /Volumes/"$name"*; do [[ -d "$v" ]] && hdiutil detach "$v" -quiet 2>/dev/null || true; done
hdiutil create -quiet -srcfolder "$stage/root" -volname "$name" -fs HFS+ -format UDRW -ov "$rw"
mount=$(hdiutil attach -readwrite -noverify -nobrowse "$rw" | awk -F'\t' '/Apple_HFS/{print $NF}')
[[ -d "$mount" ]] || { echo "mount failed"; exit 1; }
# Finder lays the window out and writes .DS_Store; on a build machine without a Finder session this step is skipped
# and the image still works, just without the arranged window.
osascript <<APPLESCRIPT || echo "Finder layout skipped"
tell application "Finder"
  tell disk "$name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.png"
    set position of item "$name.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync
hdiutil detach "$mount" -quiet
mount=""
rm -f "$out"
hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$out"
echo "Built $out ($(stat -f %z "$out") bytes)"
