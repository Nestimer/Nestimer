#!/bin/bash
# Install pre-built Release agent + watchdog for auto-start.
# Uses the .app already built in dist/ (no rebuild needed).
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./install-release.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="UsageTimeAgent"
APP_SRC="$REPO_DIR/dist/${APP_NAME}.app"
APP_DST="/Applications/${APP_NAME}.app"

echo "=== UsageTimeAgent Installer (Release) ==="

if [ ! -d "$APP_SRC" ]; then
    echo "ERROR: Release app not found at $APP_SRC"
    echo "Build it first with: xcodebuild ... -configuration Release"
    exit 1
fi

# Console user (to run the app under)
CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    echo "ERROR: No GUI user detected"
    exit 1
fi
CONSOLE_UID=$(id -u "$CONSOLE_USER")
CONSOLE_HOME=$(dscl . -read /Users/"$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')

# 1. Install app
echo "[1/3] Installing $APP_NAME.app to /Applications..."
if pgrep -f "$APP_NAME" > /dev/null; then
    launchctl asuser "$CONSOLE_UID" killall "$APP_NAME" 2>/dev/null || true
    sleep 1
fi
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
chown -R root:wheel "$APP_DST"
chmod -R 755 "$APP_DST"

# 2. Copy setup string from user defaults if already configured
echo "[2/3] Checking agent config..."
USER_DEFAULTS=$(launchctl asuser "$CONSOLE_UID" defaults read com.usagetime.agent 2>/dev/null || echo "")
if [ -z "$USER_DEFAULTS" ] || ! echo "$USER_DEFAULTS" | grep -q "APIToken"; then
    echo ""
    echo "    No config found in UserDefaults. The agent will show a setup dialog"
    echo "    on first launch — paste the string from the parent dashboard there."
    echo "    Format: http://server:8000|token"
else
    echo "    Config already set in UserDefaults ✓"
fi

# 3. Install watchdog
echo "[3/3] Installing watchdog daemon..."
mkdir -p /usr/local/lib/usagetime /var/log/usagetime
cp "$SCRIPT_DIR/Watchdog/watchdog.sh" /usr/local/lib/usagetime/watchdog.sh
chmod 755 /usr/local/lib/usagetime/watchdog.sh

WATCHDOG_PLIST_DST="/Library/LaunchDaemons/com.usagetime.watchdog.plist"
launchctl unload "$WATCHDOG_PLIST_DST" 2>/dev/null || true
cp "$SCRIPT_DIR/Watchdog/com.usagetime.watchdog.plist" "$WATCHDOG_PLIST_DST"
chown root:wheel "$WATCHDOG_PLIST_DST"
chmod 644 "$WATCHDOG_PLIST_DST"
launchctl load "$WATCHDOG_PLIST_DST"

# Launch app immediately
launchctl asuser "$CONSOLE_UID" open "$APP_DST"

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Agent installed at:  $APP_DST"
echo "Watchdog installed:  $WATCHDOG_PLIST_DST"
echo "Watchdog logs:       /var/log/usagetime/"
echo ""
echo "The agent starts automatically on boot and restarts within 15s if killed."
echo ""
echo "To UNINSTALL:"
echo "  sudo launchctl unload /Library/LaunchDaemons/com.usagetime.watchdog.plist"
echo "  sudo rm /Library/LaunchDaemons/com.usagetime.watchdog.plist"
echo "  sudo rm -rf /Applications/UsageTimeAgent.app"
echo "  sudo rm -rf /usr/local/lib/usagetime /var/log/usagetime"
echo "  defaults delete com.usagetime.agent"
