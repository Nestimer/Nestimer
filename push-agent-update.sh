#!/bin/bash
# Push a new agent version to the server for auto-update.
# Usage: ./push-agent-update.sh <server-host> [version]
# Example: ./push-agent-update.sh 134.209.8.62 1.2
set -euo pipefail

SERVER="${1:-}"
VERSION="${2:-}"

# --- Signing / notarization config (override via env if your team differs) ---
# Team ID is NOT secret (it's embedded in every distributed binary), so it's
# safe to commit. The app-specific password lives only in the keychain profile
# created via `xcrun notarytool store-credentials`, never in this repo.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
DEV_TEAM="${DEV_TEAM:-CBBC6T33XY}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nestimer-notary}"

if [ -z "$SERVER" ]; then
    echo "Usage: $0 <server-host-or-ip> [version]"
    echo "Example: $0 134.209.8.62 1.2"
    exit 1
fi

APP_PATH="$(dirname "$0")/dist/UsageTimeAgent.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_PATH not found. Build Release first."
    exit 1
fi

# Auto-increment version from Info.plist if not provided
if [ -z "$VERSION" ]; then
    CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")
    # Simple bump: 1.0 → 1.1, 1.5 → 1.6
    MAJOR=$(echo "$CURRENT" | cut -d. -f1)
    MINOR=$(echo "$CURRENT" | cut -d. -f2)
    VERSION="$MAJOR.$((MINOR + 1))"
fi

# Update MARKETING_VERSION in Xcode project to match push version
PBXPROJ="$(dirname "$0")/macos-agent/UsageTimeAgent.xcodeproj/project.pbxproj"
if [ -f "$PBXPROJ" ]; then
    sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $VERSION/" "$PBXPROJ"

    # Rebuild with new version — signed with Developer ID + hardened runtime
    # (required for notarization). No more ad-hoc "-" signing.
    echo "Building v$VERSION (Developer ID, hardened runtime)..."
    xcodebuild -project "$(dirname "$0")/macos-agent/UsageTimeAgent.xcodeproj" \
        -scheme UsageTimeAgent -configuration Release \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        DEVELOPMENT_TEAM="$DEV_TEAM" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        ENABLE_HARDENED_RUNTIME=YES \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        build 2>&1 | tail -1

    # Copy fresh build to dist — pick the most-recently-modified DerivedData result,
    # not the alphabetically first one (stale DerivedData folders would otherwise win).
    DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -path "*UsageTimeAgent*/Build/Products/Release/UsageTimeAgent.app" -maxdepth 6 -prune 2>/dev/null \
        | while read -r p; do echo "$(stat -f '%m' "$p") $p"; done \
        | sort -rn | head -1 | cut -d' ' -f2-)
    if [ -n "$DERIVED" ]; then
        # Verify version in the picked build matches what we want to ship
        BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DERIVED/Contents/Info.plist" 2>/dev/null || echo "?")
        if [ "$BUILT_VERSION" != "$VERSION" ]; then
            echo "ERROR: DerivedData build reports version $BUILT_VERSION, expected $VERSION"
            echo "       Path: $DERIVED"
            echo "       Try: rm -rf ~/Library/Developer/Xcode/DerivedData/UsageTimeAgent-*"
            exit 1
        fi
        rm -rf "$APP_PATH"
        cp -R "$DERIVED" "$APP_PATH"
    fi
fi

# Verify the signature is intact before doing anything else (fail-fast)
echo "Verifying signature..."
if ! codesign --verify --deep --strict --verbose=1 "$APP_PATH" 2>&1; then
    echo "ERROR: codesign verification failed — refusing to ship an unsigned build."
    exit 1
fi
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier" || true

echo "=== Push Agent Update ==="
echo "App:     $APP_PATH"
echo "Version: $VERSION"
echo "Server:  $SERVER"
echo ""

TMPDIR=$(mktemp -d)

# --- Notarize ---
# notarytool needs a zip of the app; staple is then applied to the .app itself.
NOTARIZE_ZIP="$TMPDIR/notarize.zip"
echo "Notarizing via profile '$NOTARY_PROFILE' (uploads to Apple, may take 1-3 min)..."
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
if ! xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$TMPDIR/notary.log"; then
    echo "ERROR: notarytool submit failed. See log above."
    rm -rf "$TMPDIR"; exit 1
fi
if ! grep -q "status: Accepted" "$TMPDIR/notary.log"; then
    SUBMIT_ID=$(grep -m1 "id:" "$TMPDIR/notary.log" | awk '{print $2}')
    echo "ERROR: notarization not Accepted. Inspect with:"
    echo "       xcrun notarytool log $SUBMIT_ID --keychain-profile $NOTARY_PROFILE"
    rm -rf "$TMPDIR"; exit 1
fi

# Staple the ticket into the .app so it validates offline
echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

# Final Gatekeeper gate — must be 'accepted' now
echo "Gatekeeper assessment:"
if ! spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1; then
    echo "ERROR: spctl rejected the stapled app — aborting upload."
    rm -rf "$TMPDIR"; exit 1
fi

# Create the upload zip from the stapled app
ZIPFILE="$TMPDIR/UsageTimeAgent.zip"
cd "$(dirname "$APP_PATH")"
ditto -c -k --keepParent "UsageTimeAgent.app" "$ZIPFILE"
SHA256=$(shasum -a 256 "$ZIPFILE" | awk '{print $1}')

echo "Zip:     $(du -h "$ZIPFILE" | awk '{print $1}')"
echo "SHA256:  $SHA256"
echo ""

# Upload to server
echo "Uploading to $SERVER..."
# Find the repo dir on server — try common locations
REMOTE_CMD="
  for d in /root/UsageTimeController ~/UsageTimeController; do
    [ -f \"\$d/docker-compose.yml\" ] && echo \"\$d\" && exit 0
  done
  echo ''
"
REMOTE_DIR=$(ssh "root@$SERVER" "$REMOTE_CMD" 2>/dev/null | tail -1)
if [ -z "$REMOTE_DIR" ]; then
    echo "ERROR: Could not find UsageTimeController on server"
    exit 1
fi

ssh "root@$SERVER" "mkdir -p $REMOTE_DIR/data/agent-update"
scp "$ZIPFILE" "root@$SERVER:$REMOTE_DIR/data/agent-update/UsageTimeAgent.zip"
ssh "root@$SERVER" "echo '$VERSION' > $REMOTE_DIR/data/agent-update/version.txt"

rm -rf "$TMPDIR"

echo ""
echo "=== Done ==="
echo "Version $VERSION uploaded. Agents will auto-update within 5 minutes."
echo ""
echo "Verify: curl http://$SERVER:8000/api/v1/agent/update/check"
