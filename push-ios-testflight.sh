#!/bin/bash
# Build the iOS parent app, export an .ipa, and upload it to TestFlight.
# Usage: ./push-ios-testflight.sh [build-number]
#   build-number  optional. If omitted, auto-bumps CURRENT_PROJECT_VERSION by 1.
#
# Auth: App Store Connect API key (.p8). One-time setup:
#   1. App Store Connect -> Users and Access -> Integrations ->
#      App Store Connect API -> generate a key with "App Manager" access.
#   2. Save the downloaded AuthKey_<KEYID>.p8 to:
#        ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
#   3. Export the two IDs (add to your shell profile so they persist):
#        export ASC_KEY_ID=XXXXXXXXXX
#        export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   The .p8 and the IDs are secrets and are NEVER committed to this repo.
set -euo pipefail

cd "$(dirname "$0")"

# --- Config (override via env if your setup differs) ---
PROJECT="ParentApp/NesTimer.xcodeproj"
SCHEME="NesTimer"
PBXPROJ="ParentApp/NesTimer.xcodeproj/project.pbxproj"
DEV_TEAM="${DEV_TEAM:-CBBC6T33XY}"
BUILD_DIR="ios-build"
ARCHIVE_PATH="$BUILD_DIR/NesTimer.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# --- Auth: App Store Connect API key ---
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ]; then
    echo "ERROR: ASC_KEY_ID / ASC_ISSUER_ID not set."
    echo "See the setup steps at the top of this script."
    exit 1
fi
if [ ! -f "$KEY_FILE" ]; then
    echo "ERROR: API key not found at $KEY_FILE"
    echo "Save your AuthKey_${ASC_KEY_ID}.p8 there (see header)."
    exit 1
fi

# --- Bump build number (TestFlight requires a unique, increasing build) ---
CURRENT_BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION" "$PBXPROJ" | sed 's/[^0-9]//g')
BUILD_NUMBER="${1:-$((CURRENT_BUILD + 1))}"
echo "==> Build number: $CURRENT_BUILD -> $BUILD_NUMBER"
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" "$PBXPROJ"

MARKETING_VERSION=$(grep -m1 "MARKETING_VERSION" "$PBXPROJ" | sed 's/[^0-9.]//g')
echo "==> Uploading version $MARKETING_VERSION ($BUILD_NUMBER) to TestFlight"

# --- Clean previous build ---
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Archive ---
echo "==> Archiving..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_FILE" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    archive

# --- ExportOptions.plist (generated; not committed) ---
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$DEV_TEAM</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
PLIST

# --- Export .ipa ---
echo "==> Exporting .ipa..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_FILE" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"

IPA_PATH=$(ls "$EXPORT_PATH"/*.ipa | head -1)
if [ ! -f "$IPA_PATH" ]; then
    echo "ERROR: no .ipa produced in $EXPORT_PATH"
    exit 1
fi
echo "==> Built $IPA_PATH"

# --- Validate then upload ---
echo "==> Validating..."
xcrun altool --validate-app -f "$IPA_PATH" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Uploading to TestFlight..."
xcrun altool --upload-app -f "$IPA_PATH" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo ""
echo "✅ Uploaded $MARKETING_VERSION ($BUILD_NUMBER) to TestFlight."
echo "   It takes ~5-15 min to finish processing before it appears in TestFlight."
echo "   Remember to commit the bumped build number:"
echo "     git add $PBXPROJ && git commit -m \"chore: iOS build $BUILD_NUMBER\""
