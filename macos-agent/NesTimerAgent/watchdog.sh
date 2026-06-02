#!/bin/bash
# NesTimerAgent Watchdog
# Runs as LaunchDaemon (root) every 15s. Two jobs:
#   1. Ensure the agent app is running (restart if killed)
#   2. Check for updates every ~5 min (download, replace, restart)

APP_PATH="/Applications/NesTimerAgent.app"
APP_BINARY="$APP_PATH/Contents/MacOS/NesTimerAgent"
VERSION_FILE="/usr/local/libexec/nestimer-agent-version.txt"
UPDATE_CHECK_MARKER="/tmp/nestimer-last-update-check"
UPDATE_CHECK_INTERVAL=300  # seconds between update checks

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [Watchdog] $1"
}

# --- 1. Ensure agent is running ---
if ! pgrep -f "NesTimerAgent" > /dev/null 2>&1; then
    CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null)
    if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
        CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
        if [ -n "$CONSOLE_UID" ] && [ -d "$APP_PATH" ]; then
            launchctl asuser "$CONSOLE_UID" open "$APP_PATH"
            log "Agent started as $CONSOLE_USER"
        fi
    fi
fi

# --- 2. Auto-update (every ~5 min) ---
# Read server URL from the agent's UserDefaults (set by setup dialog)
CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null)
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    exit 0
fi

# Throttle: only check every UPDATE_CHECK_INTERVAL seconds
if [ -f "$UPDATE_CHECK_MARKER" ]; then
    LAST_CHECK=$(stat -f '%m' "$UPDATE_CHECK_MARKER" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    ELAPSED=$((NOW - LAST_CHECK))
    if [ "$ELAPSED" -lt "$UPDATE_CHECK_INTERVAL" ]; then
        exit 0
    fi
fi
touch "$UPDATE_CHECK_MARKER"

# Get server URL from agent's UserDefaults
SERVER_URL=$(sudo -u "$CONSOLE_USER" defaults read com.nestimer.agent ServerURL 2>/dev/null)
if [ -z "$SERVER_URL" ]; then
    exit 0
fi

# Check for update
UPDATE_INFO=$(curl -s --connect-timeout 5 --max-time 10 "$SERVER_URL/api/v1/agent/update/check" 2>/dev/null)
if [ -z "$UPDATE_INFO" ]; then
    exit 0
fi

REMOTE_VERSION=$(echo "$UPDATE_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('version') or '')" 2>/dev/null)
REMOTE_SHA256=$(echo "$UPDATE_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sha256') or '')" 2>/dev/null)

if [ -z "$REMOTE_VERSION" ] || [ "$REMOTE_VERSION" = "None" ]; then
    exit 0
fi

# Compare with installed version
LOCAL_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    LOCAL_VERSION=$(cat "$VERSION_FILE")
fi

if [ "$REMOTE_VERSION" = "$LOCAL_VERSION" ]; then
    exit 0
fi

log "Update available: $LOCAL_VERSION -> $REMOTE_VERSION"

# Retry limit: don't attempt same version more than 3 times
FAIL_COUNT_FILE="/tmp/nestimer-update-fails-$REMOTE_VERSION"
FAIL_COUNT=0
if [ -f "$FAIL_COUNT_FILE" ]; then
    FAIL_COUNT=$(cat "$FAIL_COUNT_FILE")
fi
if [ "$FAIL_COUNT" -ge 3 ]; then
    log "Skipping update — failed $FAIL_COUNT times for version $REMOTE_VERSION"
    exit 0
fi

# Download
TMPDIR=$(mktemp -d)
ZIPFILE="$TMPDIR/NesTimerAgent.zip"
curl -s --connect-timeout 10 --max-time 120 -o "$ZIPFILE" "$SERVER_URL/api/v1/agent/update/download"

if [ ! -f "$ZIPFILE" ] || [ ! -s "$ZIPFILE" ]; then
    log "Download failed"
    echo $((FAIL_COUNT + 1)) > "$FAIL_COUNT_FILE"
    rm -rf "$TMPDIR"
    exit 1
fi

# Verify SHA256
ACTUAL_SHA256=$(shasum -a 256 "$ZIPFILE" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$REMOTE_SHA256" ]; then
    log "SHA256 mismatch! Expected $REMOTE_SHA256, got $ACTUAL_SHA256"
    echo $((FAIL_COUNT + 1)) > "$FAIL_COUNT_FILE"
    rm -rf "$TMPDIR"
    exit 1
fi

# Unzip
cd "$TMPDIR"
unzip -qo "$ZIPFILE" -d "$TMPDIR"

if [ ! -d "$TMPDIR/NesTimerAgent.app" ]; then
    log "Invalid zip — no NesTimerAgent.app found"
    echo $((FAIL_COUNT + 1)) > "$FAIL_COUNT_FILE"
    rm -rf "$TMPDIR"
    exit 1
fi

# Kill running agent
pkill -f '/Applications/NesTimerAgent.app' 2>/dev/null || true
sleep 1
pkill -9 -f '/Applications/NesTimerAgent.app' 2>/dev/null || true
sleep 0.5

# Replace
rm -rf "$APP_PATH"
mv "$TMPDIR/NesTimerAgent.app" "$APP_PATH"
chown -R root:wheel "$APP_PATH"

# Save version + clear fail counter
echo "$REMOTE_VERSION" > "$VERSION_FILE"
rm -f "$FAIL_COUNT_FILE"

# Cleanup
rm -rf "$TMPDIR"

log "Updated to $REMOTE_VERSION — restarting agent"

# Launch new version
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
if [ -n "$CONSOLE_UID" ]; then
    launchctl asuser "$CONSOLE_UID" open "$APP_PATH"
fi
