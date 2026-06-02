#!/bin/bash
set -euo pipefail

# =============================================================================
# NesTimerAgent — Dev/Test Runner
# Safely runs the agent on YOUR computer without risk of being locked out.
#
# What dev mode does:
#   - Lock screen auto-dismisses after 10 seconds
#   - Ctrl+Opt+Cmd+U hotkey to instantly unlock
#   - Lock window is "floating" level (you can Cmd+Tab away)
#   - Self-protection disabled (Cmd+Q works, can kill process)
#   - Faster timers (5s tick, 10s sync) for quick testing
#   - Quit option in menu bar
#   - "DEV MODE" label in menu bar and lock screen
#
# No sudo, no root, no LaunchDaemons, no watchdog.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== NesTimerAgent Dev Test Runner ===${NC}"
echo ""

# --- 1. Check/start API server ---
API_URL="${UTC_SERVER_URL:-http://localhost:8000}"
echo -e "${YELLOW}[1/4] Checking API server at ${API_URL}...${NC}"

if curl -s --connect-timeout 2 "${API_URL}/docs" > /dev/null 2>&1; then
    echo -e "${GREEN}  API server is running.${NC}"
else
    echo -e "${RED}  API server is NOT running at ${API_URL}.${NC}"
    echo ""
    echo "  Start it first:"
    echo "    cd $(dirname "$SCRIPT_DIR")/api"
    echo "    python -m uvicorn app.main:app --reload"
    echo ""
    echo "  Or set UTC_SERVER_URL to point to your server."
    exit 1
fi

# --- 2. Register test user & device (if no token provided) ---
API_TOKEN="${UTC_API_TOKEN:-}"

if [ -z "$API_TOKEN" ]; then
    echo -e "${YELLOW}[2/4] Setting up test user and device...${NC}"

    TEST_EMAIL="dev-test@nestimer.local"
    TEST_PASS="devtest123"

    # Register (ignore 400 = already exists)
    REG_RESP=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"${TEST_EMAIL}\", \"password\": \"${TEST_PASS}\"}")
    REG_CODE=$(echo "$REG_RESP" | tail -1)

    if [ "$REG_CODE" = "200" ] || [ "$REG_CODE" = "201" ]; then
        echo -e "  ${GREEN}Test user registered.${NC}"
    elif [ "$REG_CODE" = "400" ]; then
        echo -e "  Test user already exists, logging in..."
    else
        echo -e "  ${RED}Registration failed (HTTP $REG_CODE). Check API server.${NC}"
        exit 1
    fi

    # Login
    LOGIN_RESP=$(curl -s -X POST "${API_URL}/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"${TEST_EMAIL}\", \"password\": \"${TEST_PASS}\"}")
    AUTH_TOKEN=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

    if [ -z "$AUTH_TOKEN" ]; then
        echo -e "  ${RED}Login failed. Response: $LOGIN_RESP${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}Logged in.${NC}"

    # Create device
    DEV_RESP=$(curl -s -X POST "${API_URL}/devices" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"Dev Mac $(hostname -s)\"}")
    API_TOKEN=$(echo "$DEV_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_token',''))" 2>/dev/null || echo "")

    if [ -z "$API_TOKEN" ]; then
        echo -e "  ${RED}Device creation failed. Response: $DEV_RESP${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}Device created. Token: ${API_TOKEN:0:12}...${NC}"

    # Set a test policy: 5 minute limit, downtime in 2 minutes
    DEVICE_ID=$(echo "$DEV_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [ -n "$DEVICE_ID" ]; then
        curl -s -X PUT "${API_URL}/devices/${DEVICE_ID}/policy" \
            -H "Authorization: Bearer ${AUTH_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"screen_time_enabled": true, "screen_time_limit_minutes": 5}' > /dev/null
        echo -e "  ${GREEN}Test policy set: 5 minute screen time limit.${NC}"
    fi
else
    echo -e "${YELLOW}[2/4] Using provided UTC_API_TOKEN.${NC}"
fi

# --- 3. Build the app ---
echo -e "${YELLOW}[3/4] Building NesTimerAgent (Debug)...${NC}"

BUILD_DIR="$PROJECT_DIR/build/dev"
mkdir -p "$BUILD_DIR"

if [ -d "$PROJECT_DIR/NesTimerAgent.xcodeproj" ]; then
    xcodebuild -project "$PROJECT_DIR/NesTimerAgent.xcodeproj" \
        -scheme "NesTimerAgent" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        build 2>&1 | tail -3

    APP_PATH=$(find "$BUILD_DIR" -name "NesTimerAgent.app" -type d | head -1)
    if [ -z "$APP_PATH" ]; then
        echo -e "  ${RED}Build failed — .app not found.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}Built: $APP_PATH${NC}"
else
    echo -e "  ${RED}Xcode project not found at $PROJECT_DIR/NesTimerAgent.xcodeproj${NC}"
    echo "  If running from a non-Mac environment, the build step won't work."
    echo "  On Mac, run this script from the macos-agent/ directory."
    exit 1
fi

# --- 4. Launch in dev mode ---
echo -e "${YELLOW}[4/4] Launching in DEV MODE...${NC}"
echo ""
echo -e "${GREEN}  Safety features active:${NC}"
echo "    - Lock screen auto-unlocks after 10 seconds"
echo "    - Ctrl+Opt+Cmd+U = emergency unlock"
echo "    - Cmd+Tab works (window is floating, not maximum)"
echo "    - Quit via menu bar or Cmd+Q"
echo "    - Fast timers: 5s tick, 10s sync"
echo ""
echo -e "${YELLOW}  To stop: Cmd+Q, menu Quit, or kill from Terminal:${NC}"
echo "    pkill -f NesTimerAgent"
echo ""

export UTC_SERVER_URL="$API_URL"
export UTC_API_TOKEN="$API_TOKEN"
export UTC_DEV_MODE="1"
export UTC_DEV_AUTO_UNLOCK="10"
export UTC_POLL_INTERVAL="10"

# Launch the app (foreground so you see logs)
exec "$APP_PATH/Contents/MacOS/NesTimerAgent"
