#!/bin/bash
# Build and publish the Android counter APK for sideloading.
# Usage: ./push-android-update.sh <server-host> <version>
# Example: ./push-android-update.sh 134.209.8.62 1.1
#
# Unlike push-agent-update.sh there is nothing to restart and nothing to notify:
# Android cannot update itself without Device Owner, so this only puts a file
# where a human can download it.
set -euo pipefail

SERVER="${1:-}"
VERSION="${2:-}"

if [ -z "$SERVER" ] || [ -z "$VERSION" ]; then
    echo "Usage: $0 <server-host-or-ip> <version>"
    echo "Example: $0 134.209.8.62 1.1"
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
GRADLE_FILE="$ROOT/android-agent/app/build.gradle.kts"
APK="$ROOT/android-agent/app/build/outputs/apk/release/app-release.apk"
REMOTE_DIR="/var/www/nestimer/download"

export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# versionCode must increase monotonically and can never be reused once the app is
# on Play, so derive it from the existing value rather than from the version name.
CURRENT_CODE=$(grep -E '^\s*versionCode = ' "$GRADLE_FILE" | head -1 | grep -oE '[0-9]+')
NEXT_CODE=$((CURRENT_CODE + 1))
echo "versionCode $CURRENT_CODE -> $NEXT_CODE, versionName -> $VERSION"

sed -i '' "s/versionCode = $CURRENT_CODE/versionCode = $NEXT_CODE/" "$GRADLE_FILE"
sed -i '' "s/versionName = \"[^\"]*\"/versionName = \"$VERSION\"/" "$GRADLE_FILE"

echo "Building signed release..."
(cd "$ROOT/android-agent" && ./gradlew --quiet assembleRelease)

if [ ! -f "$APK" ]; then
    echo "ERROR: $APK not found after build."
    exit 1
fi

# Fail before uploading an unsigned APK — an unsigned one installs nowhere.
echo "Verifying signature..."
if ! "$ANDROID_HOME/build-tools/35.0.0/apksigner" verify --print-certs "$APK"; then
    echo "ERROR: apksigner rejected the APK. Is local.properties configured?"
    exit 1
fi

# The path is asserted, not guessed: fail loudly if the download dir moved.
if ! ssh "root@$SERVER" "[ -d '$REMOTE_DIR' ]"; then
    echo "ERROR: $REMOTE_DIR does not exist on $SERVER."
    echo "       Find where the DMGs are served from and update REMOTE_DIR."
    exit 1
fi

scp "$APK" "root@$SERVER:$REMOTE_DIR/NesTimerAgent.apk"
ssh "root@$SERVER" "echo '$VERSION' > $REMOTE_DIR/NesTimerAgent.apk.version"

echo ""
echo "=== Done ==="
echo "Version $VERSION (code $NEXT_CODE) uploaded."
echo "Download: https://nestimer.com/download/NesTimerAgent.apk"
echo ""
echo "This does NOT reach any phone by itself — install it by hand."
