#!/bin/bash
set -euo pipefail

# UsageTimeAgent installer for macOS
# Installs the app + watchdog daemon
# Must be run as root (sudo)

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="UsageTimeAgent"
APP_SRC="$SCRIPT_DIR/build/${APP_NAME}.app"
APP_DST="/Applications/${APP_NAME}.app"

echo "=== UsageTimeAgent Installer ==="
echo ""

# 1. Build the app
echo "[1/6] Building ${APP_NAME}.app..."
cd "$SCRIPT_DIR"
xcodebuild -project "${APP_NAME}.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$SCRIPT_DIR/build/derived" \
    -archivePath "$SCRIPT_DIR/build/${APP_NAME}.xcarchive" \
    archive ONLY_ACTIVE_ARCH=NO 2>&1 | tail -5

# Extract the .app from the archive
APP_SRC="$SCRIPT_DIR/build/${APP_NAME}.xcarchive/Products/Applications/${APP_NAME}.app"

if [ ! -d "$APP_SRC" ]; then
    echo "ERROR: Build failed. App not found at $APP_SRC"
    echo "You can also build manually in Xcode and copy to /Applications"
    exit 1
fi

# 2. Install the app
echo "[2/6] Installing app to /Applications..."
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
chown -R root:wheel "$APP_DST"
chmod -R 755 "$APP_DST"

# 3. Create directories
echo "[3/6] Creating directories..."
mkdir -p /etc/nestimer
mkdir -p /var/log/nestimer
mkdir -p /usr/local/lib/nestimer

# 4. Config file
CONFIG_FILE="/etc/nestimer/config.plist"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[4/6] Creating config file..."

    read -p "Enter server URL (e.g., https://your-server.com): " SERVER_URL
    read -p "Enter device API token (from web dashboard): " API_TOKEN

    cat > "$CONFIG_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ServerURL</key>
    <string>${SERVER_URL}</string>
    <key>APIToken</key>
    <string>${API_TOKEN}</string>
    <key>PollInterval</key>
    <integer>60</integer>
</dict>
</plist>
EOF
    chmod 600 "$CONFIG_FILE"
    echo "    Config saved to $CONFIG_FILE"
else
    echo "[4/6] Config already exists at $CONFIG_FILE, skipping."
fi

# 5. Install watchdog
echo "[5/6] Installing watchdog daemon..."

# Copy watchdog script
cp "$SCRIPT_DIR/Watchdog/watchdog.sh" /usr/local/lib/nestimer/watchdog.sh
chmod 755 /usr/local/lib/nestimer/watchdog.sh

# Install LaunchDaemon
WATCHDOG_PLIST_DST="/Library/LaunchDaemons/com.nestimer.watchdog.plist"
launchctl unload "$WATCHDOG_PLIST_DST" 2>/dev/null || true

cp "$SCRIPT_DIR/Watchdog/com.nestimer.watchdog.plist" "$WATCHDOG_PLIST_DST"
chown root:wheel "$WATCHDOG_PLIST_DST"
chmod 644 "$WATCHDOG_PLIST_DST"
launchctl load "$WATCHDOG_PLIST_DST"

# 6. Start the app
echo "[6/6] Starting UsageTimeAgent..."
CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    CONSOLE_UID=$(id -u "$CONSOLE_USER")
    launchctl asuser "$CONSOLE_UID" open "$APP_DST"
    echo "    Started as user $CONSOLE_USER"
else
    echo "    No console user. App will start on next login."
fi

echo ""
echo "=== Installation complete! ==="
echo ""
echo "The agent is running as a menu bar app (clock icon in menu bar)."
echo "The watchdog daemon ensures it restarts if killed."
echo ""
echo "Logs: /var/log/nestimer/"
echo "Config: /etc/nestimer/config.plist"
echo ""
echo "To uninstall:"
echo "  sudo launchctl unload /Library/LaunchDaemons/com.nestimer.watchdog.plist"
echo "  sudo rm -rf /Applications/UsageTimeAgent.app"
echo "  sudo rm /Library/LaunchDaemons/com.nestimer.watchdog.plist"
echo "  sudo rm -rf /etc/nestimer /usr/local/lib/nestimer /var/log/nestimer"
