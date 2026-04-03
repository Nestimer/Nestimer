#!/bin/bash
# UsageTimeAgent Watchdog
# Runs as a LaunchDaemon (root) and ensures the agent app is always running.
# If the agent is killed, this script restarts it within 15 seconds.

APP_PATH="/Applications/UsageTimeAgent.app"
BUNDLE_ID="com.usagetime.agent"
LOG_TAG="[UsageTimeWatchdog]"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG $1"
}

# Check if the app is running
if ! pgrep -f "UsageTimeAgent" > /dev/null 2>&1; then
    log "Agent not running. Starting..."

    # Get the console user (the logged-in GUI user)
    CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null)

    if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
        CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)

        if [ -n "$CONSOLE_UID" ] && [ -d "$APP_PATH" ]; then
            # Launch as the console user (needed for GUI apps)
            launchctl asuser "$CONSOLE_UID" open "$APP_PATH"
            log "Agent started as user $CONSOLE_USER (UID: $CONSOLE_UID)"
        else
            log "App not found at $APP_PATH or invalid UID"
        fi
    else
        log "No console user logged in, skipping"
    fi
else
    # Agent is running, nothing to do
    :
fi
