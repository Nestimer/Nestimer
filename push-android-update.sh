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

# Both values get interpolated into sed replacements and remote ssh/scp commands
# below, so reject anything that isn't plainly a version or a host/IP before
# touching either. A typo here must not be able to run arbitrary commands as
# root on the production server.
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "ERROR: version '$VERSION' doesn't look like a version (expected e.g. 1.1, 1.2.3)."
    exit 1
fi
if ! [[ "$SERVER" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "ERROR: server '$SERVER' doesn't look like a hostname or IP."
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
GRADLE_FILE="$ROOT/android-agent/app/build.gradle.kts"
APK="$ROOT/android-agent/app/build/outputs/apk/release/app-release.apk"
REMOTE_DIR="/var/www/nestimer/download"

# If the version bump from a previous run was never committed, the versionCode
# in this file is already in doubt: it may have been built and uploaded once
# already, or discarded and about to be recomputed into a duplicate. Either
# way, don't guess — make the operator sort it out first.
if [ -n "$(cd "$ROOT" && git status --porcelain -- "$GRADLE_FILE")" ]; then
    echo "ERROR: $GRADLE_FILE has uncommitted changes."
    echo "       A previous run's version bump was never committed, so the next"
    echo "       versionCode this script derives can't be trusted. Commit or"
    echo "       discard those changes first."
    exit 1
fi

export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# Resolve the newest installed build-tools rather than hardcoding a patch
# version — otherwise a version mismatch fails with "No such file or
# directory" and gets misread as a signing/local.properties problem.
# `|| true` is load-bearing: under `set -e` with `pipefail` a failing `ls` would
# abort the script here, before the empty-check below could print its explanation.
BUILD_TOOLS_DIR=$(ls -d "$ANDROID_HOME"/build-tools/*/ 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$BUILD_TOOLS_DIR" ]; then
    echo "ERROR: no build-tools found under $ANDROID_HOME/build-tools/"
    exit 1
fi
APKSIGNER="${BUILD_TOOLS_DIR}apksigner"

# versionCode must increase monotonically and can never be reused once the app is
# on Play, so derive it from the existing value rather than from the version name.
CURRENT_CODE=$(grep -E '^\s*versionCode = ' "$GRADLE_FILE" | head -1 | grep -oE '[0-9]+')
NEXT_CODE=$((CURRENT_CODE + 1))
echo "versionCode $CURRENT_CODE -> $NEXT_CODE, versionName -> $VERSION"

# The bump has to happen BEFORE the build — the APK must carry the new versionCode —
# so it cannot simply be moved after it. Instead it is undone on any failure: the
# guard above already proved the file was clean, so restoring it is safe, and it keeps
# a failed run from leaving the tree dirty and self-blocking on that same guard next
# time. Cleared once the bump is committed, at which point there is nothing to revert.
BUMP_APPLIED=0
revert_bump_on_failure() {
    local status=$?
    if [ "$status" -ne 0 ] && [ "$BUMP_APPLIED" -eq 1 ]; then
        echo ""
        echo "Run failed — reverting the uncommitted version bump in $GRADLE_FILE"
        (cd "$ROOT" && git checkout -- "$GRADLE_FILE") || true
    fi
}
trap revert_bump_on_failure EXIT

sed -i '' "s/versionCode = $CURRENT_CODE/versionCode = $NEXT_CODE/" "$GRADLE_FILE"
sed -i '' "s/versionName = \"[^\"]*\"/versionName = \"$VERSION\"/" "$GRADLE_FILE"
BUMP_APPLIED=1

echo "Building signed release..."
(cd "$ROOT/android-agent" && ./gradlew --quiet assembleRelease)

if [ ! -f "$APK" ]; then
    echo "ERROR: $APK not found after build."
    exit 1
fi

# Fail before uploading an unsigned APK — an unsigned one installs nowhere.
echo "Verifying signature..."
if ! "$APKSIGNER" verify --print-certs "$APK"; then
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

# Commit the version bump now that it's actually built and uploaded, so the
# versionCode this run consumed can never be silently discarded and reused.
# Commit with an explicit pathspec rather than `git add` + `git commit`: the latter
# would sweep in whatever else the operator happened to have staged.
(cd "$ROOT" && git commit -m "chore: Android agent $VERSION (versionCode $NEXT_CODE)" -- "$GRADLE_FILE")
BUMP_APPLIED=0

echo ""
echo "=== Done ==="
echo "Version $VERSION (code $NEXT_CODE) uploaded."
echo "Download: https://nestimer.com/download/NesTimerAgent.apk"
echo ""
echo "This does NOT reach any phone by itself — install it by hand."
