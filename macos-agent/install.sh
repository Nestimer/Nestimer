#!/bin/bash
set -euo pipefail

# UsageTimeAgent installer for macOS
# Must be run as root (sudo)

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== UsageTimeAgent Installer ==="
echo ""

# 1. Build the agent
echo "[1/5] Building UsageTimeAgent..."
cd "$SCRIPT_DIR/UsageTimeAgent"
swift build -c release
BINARY=$(swift build -c release --show-bin-path)/UsageTimeAgent

# 2. Install binary
echo "[2/5] Installing binary to /usr/local/bin/..."
cp "$BINARY" /usr/local/bin/UsageTimeAgent
chmod 755 /usr/local/bin/UsageTimeAgent

# 3. Create directories
echo "[3/5] Creating directories..."
mkdir -p /etc/usagetime
mkdir -p /var/lib/usagetime
mkdir -p /var/log/usagetime

# 4. Config file (if not exists)
CONFIG_FILE="/etc/usagetime/config.plist"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[4/5] Creating config file..."

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
    echo "[4/5] Config already exists at $CONFIG_FILE, skipping."
fi

# 5. Install and load LaunchDaemon
echo "[5/5] Installing LaunchDaemon..."
PLIST_SRC="$SCRIPT_DIR/LaunchDaemon/com.usagetime.agent.plist"
PLIST_DST="/Library/LaunchDaemons/com.usagetime.agent.plist"

# Stop if already running
launchctl unload "$PLIST_DST" 2>/dev/null || true

cp "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"
launchctl load "$PLIST_DST"

echo ""
echo "=== Installation complete! ==="
echo "The agent is now running. Check logs at /var/log/usagetime/agent.log"
echo ""
echo "To uninstall:"
echo "  sudo launchctl unload /Library/LaunchDaemons/com.usagetime.agent.plist"
echo "  sudo rm /usr/local/bin/UsageTimeAgent"
echo "  sudo rm /Library/LaunchDaemons/com.usagetime.agent.plist"
echo "  sudo rm -rf /etc/usagetime /var/lib/usagetime /var/log/usagetime"
