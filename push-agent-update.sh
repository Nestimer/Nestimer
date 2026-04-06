#!/bin/bash
# Push a new agent version to the server for auto-update.
# Usage: ./push-agent-update.sh <server-host> [version]
# Example: ./push-agent-update.sh 134.209.8.62 1.2
set -euo pipefail

SERVER="${1:-}"
VERSION="${2:-}"

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

    # Rebuild with new version
    echo "Building v$VERSION..."
    xcodebuild -project "$(dirname "$0")/macos-agent/UsageTimeAgent.xcodeproj" \
        -scheme UsageTimeAgent -configuration Release \
        CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
        CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | tail -1

    # Copy fresh build to dist
    DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -path "*UsageTimeAgent*/Build/Products/Release/UsageTimeAgent.app" -maxdepth 5 2>/dev/null | head -1)
    if [ -n "$DERIVED" ]; then
        rm -rf "$APP_PATH"
        cp -R "$DERIVED" "$APP_PATH"
    fi
fi

# Strip quarantine so the app works on other Macs without Gatekeeper issues
xattr -cr "$APP_PATH" 2>/dev/null

echo "=== Push Agent Update ==="
echo "App:     $APP_PATH"
echo "Version: $VERSION"
echo "Server:  $SERVER"
echo ""

# Create zip
TMPDIR=$(mktemp -d)
ZIPFILE="$TMPDIR/UsageTimeAgent.zip"
cd "$(dirname "$APP_PATH")"
zip -qr "$ZIPFILE" "UsageTimeAgent.app"
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
