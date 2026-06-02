#!/bin/bash
# Build a pretty, signed + notarized DMG installer for the macOS agent.
#
# Expects dist/NesTimerAgent.app to already be a Developer ID-signed, hardened,
# notarized + stapled build (produce it with ./push-agent-update.sh first, or a
# Release build with the same signing flags). This script wraps it in a branded
# DMG, signs the DMG, notarizes and staples it.
#
# Usage: ./build-dmg.sh            -> dist/NesTimer.dmg
# Deps:  create-dmg, python3+Pillow, Xcode CLT (iconutil/notarytool/stapler).
set -euo pipefail

cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nestimer-notary}"
APP="dist/NesTimerAgent.app"
OUT="dist/NesTimer.dmg"
VOLNAME="NesTimer"
ICONSET_SRC="macos-agent/NesTimerAgent/Assets.xcassets/AppIcon.appiconset"

[ -d "$APP" ] || { echo "ERROR: $APP not found. Build/notarize the agent first (./push-agent-update.sh)."; exit 1; }
command -v create-dmg >/dev/null || { echo "ERROR: create-dmg missing. brew install create-dmg"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "[1/5] Volume icon (.icns)..."
ISET="$TMP/vol.iconset"; mkdir -p "$ISET"
cp "$ICONSET_SRC/icon_16.png"   "$ISET/icon_16x16.png"
cp "$ICONSET_SRC/icon_32.png"   "$ISET/icon_16x16@2x.png"
cp "$ICONSET_SRC/icon_32.png"   "$ISET/icon_32x32.png"
cp "$ICONSET_SRC/icon_64.png"   "$ISET/icon_32x32@2x.png"
cp "$ICONSET_SRC/icon_128.png"  "$ISET/icon_128x128.png"
cp "$ICONSET_SRC/icon_256.png"  "$ISET/icon_128x128@2x.png"
cp "$ICONSET_SRC/icon_256.png"  "$ISET/icon_256x256.png"
cp "$ICONSET_SRC/icon_512.png"  "$ISET/icon_256x256@2x.png"
cp "$ICONSET_SRC/icon_512.png"  "$ISET/icon_512x512.png"
cp "$ICONSET_SRC/icon_1024.png" "$ISET/icon_512x512@2x.png"
iconutil -c icns "$ISET" -o "$TMP/vol.icns"

echo "[2/5] Branded background..."
python3 - "$TMP/dmg-bg.png" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
W, H = 600, 420
BG_START, BG_END = (88, 101, 242), (168, 85, 247)
img = Image.new("RGB", (W, H)); px = img.load()
for y in range(H):
    t = y / H
    row = (int(BG_START[0]*(1-t)+BG_END[0]*t), int(BG_START[1]*(1-t)+BG_END[1]*t), int(BG_START[2]*(1-t)+BG_END[2]*t))
    for x in range(W): px[x, y] = row
d = ImageDraw.Draw(img, "RGBA")
def font(sz):
    for p in ["/System/Library/Fonts/SFNSRounded.ttf", "/System/Library/Fonts/SFNS.ttf", "/Library/Fonts/Arial.ttf"]:
        try: return ImageFont.truetype(p, sz)
        except Exception: pass
    return ImageFont.load_default()
def ctext(y, txt, f, fill):
    w = d.textlength(txt, font=f); d.text(((W - w) / 2, y), txt, font=f, fill=fill)
ctext(34, "NesTimer", font(40), (255, 255, 255, 255))
ctext(86, "Drag the app onto the Applications folder", font(20), (255, 255, 255, 210))
ay = 200
d.line([(232, ay), (372, ay)], fill=(255, 255, 255, 230), width=6)
d.polygon([(372, ay-14), (372, ay+14), (398, ay)], fill=(255, 255, 255, 230))
img.save(sys.argv[1])
PY

echo "[3/5] Building DMG..."
STAGE="$TMP/src"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"
rm -f "$OUT"
create-dmg \
  --volname "$VOLNAME" \
  --volicon "$TMP/vol.icns" \
  --background "$TMP/dmg-bg.png" \
  --window-pos 200 120 \
  --window-size 600 420 \
  --icon-size 120 \
  --icon "NesTimerAgent.app" 150 200 \
  --app-drop-link 450 200 \
  --hide-extension "NesTimerAgent.app" \
  --no-internet-enable \
  --codesign "$SIGN_IDENTITY" \
  "$OUT" "$STAGE"

echo "[4/5] Notarizing DMG via '$NOTARY_PROFILE'..."
if ! xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$TMP/notary.log"; then
    echo "ERROR: notarytool submit failed."; exit 1
fi
grep -q "status: Accepted" "$TMP/notary.log" || { echo "ERROR: DMG notarization not Accepted."; exit 1; }

echo "[5/5] Stapling + verifying..."
xcrun stapler staple "$OUT"
spctl --assess --type open --context context:primary-signature -v "$OUT"

echo ""
echo "=== Done: $OUT ==="
echo "SHA256: $(shasum -a 256 "$OUT" | awk '{print $1}')"
echo "Size:   $(du -h "$OUT" | awk '{print $1}')"
