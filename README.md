# UsageTimeController

Parental controls for macOS — a Family Link alternative. Remotely manage screen time and downtime schedules on your child's Mac.

## Features (v1)

- **Downtime** — set a schedule when the computer is fully locked (e.g., 10 PM – 8 AM)
- **Screen Time** — daily limit of minutes the child can use the computer outside of downtime
- **Separate settings for weekdays and weekends**
- **Remote management** via a native iOS/macOS app or web dashboard
- **Smart tracking** — only counts real usage (not lock screen, not idle)
- **Usage stats** — how much time the child spent on the computer each day
- **Offline unlock codes** — TOTP-based 6-digit codes for unlocking without internet

## Architecture

```
┌───────────────────┐
│  Native App       │     ┌──────────────┐      ┌─────────────────┐
│  (SwiftUI,        │────▶│   API Server │◀─────│  macOS Agent    │
│  iOS + macOS)     │     │  (FastAPI)   │      │  (Swift daemon) │
│  Parent           │     └──────────────┘      │  Child's Mac    │
├───────────────────┤            ▲              └─────────────────┘
│  Web Dashboard    │────▶       │
│  (React, browser) │            │
└───────────────────┘            │
```

## Quick Start

### 1. Start the server (API + Web Dashboard)

```bash
# Set SECRET_KEY for production
export SECRET_KEY=$(openssl rand -hex 32)

docker-compose up -d
```

Dashboard at `http://localhost:3000`, API at `http://localhost:8000`.

### 2. Set up an account

1. Open `http://localhost:3000`
2. Register a parent account
3. Click "Add Device" — enter the Mac name and child's name
4. Copy the API token

### 3. Install the agent on the child's Mac

```bash
# Clone the repo on the child's Mac
git clone <repo-url>
cd UsageTimeController/macos-agent

# Run the installer (requires sudo)
sudo ./install.sh
# You'll be prompted for the server URL and API token
```

### 4. Configure rules

Go back to the dashboard and set:
- **Downtime**: when the computer is locked (default 10 PM – 8 AM)
- **Screen Time**: how many minutes per day are allowed (default 120 min)
- Separate limits for weekdays and weekends

## Development

### API Server

```bash
cd api
pip install -r requirements.txt
uvicorn app.main:app --reload
```

### Web Dashboard

```bash
cd web-dashboard
npm install
npm run dev
```

### Native Parent App (iOS + macOS)

Open `ParentApp/UsageTimeControl.xcodeproj` in Xcode and run on iPhone, iPad, or Mac.
Supports iOS 16+ and macOS 13+.

### macOS Agent

Open `macos-agent/UsageTimeAgent.xcodeproj` in Xcode → Build & Run.
Or install via script:
```bash
cd macos-agent
sudo ./install.sh
```

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/api/v1/auth/register` | POST | Register |
| `/api/v1/auth/login` | POST | Login |
| `/api/v1/devices` | GET/POST | List/create devices |
| `/api/v1/devices/{id}/policy` | GET/PUT | Control settings |
| `/api/v1/devices/{id}/usage` | GET | Usage statistics |
| `/api/v1/devices/{id}/regenerate-secret` | POST | Regenerate TOTP secret |
| `/api/v1/agent/config` | GET | Agent config |
| `/api/v1/agent/usage` | POST | Agent usage report |
| `/api/v1/agent/verify-totp` | POST | Verify TOTP code |

## How the Agent Works

The agent is a full **macOS app** (menu bar app), not a script:

1. **Menu bar icon** — shows remaining time, downtime, status
2. Every 30 seconds checks activity, counts time **only when**:
   - Screen is on (not sleeping) — IOKit `DevicePowerState`
   - Screen is **not locked** — `CGSessionCopyCurrentDictionary`
   - User is **not idle >5 min** (mouse/keyboard) — IOKit `HIDIdleTime`
3. Syncs with the server every 60 seconds
4. When locked — **full-screen overlay** (`NSWindow` at `maximumWindow` level):
   - Covers all screens including full-screen apps
   - Dark background with animated icon and clock
   - Cannot minimize, close, or switch away
   - **Code input field** for offline TOTP unlock
5. **Native notifications** (UserNotifications) at 15, 10, 5, 1 minutes before time expires

## Offline Unlock Codes

When the parent needs to unlock the child's Mac without internet:

1. Open the parent app or web dashboard — a 6-digit code is displayed
2. Tell the code to the child (verbally, by phone, etc.)
3. The child enters the code on the lock screen
4. The Mac unlocks for 30 minutes

Codes are TOTP-based (HMAC-SHA1, 5-minute step) and work completely offline — both the parent app and the agent compute codes independently from a shared secret.

## Tamper Protection

- **Watchdog daemon** (LaunchDaemon running as root) — checks every 15 sec, restarts agent if killed
- **Self-protection**: blocks Cmd+Q, disables sudden termination
- App is owned by root (`/Applications/UsageTimeAgent.app`) — child cannot delete without admin password
- Config in `/etc/usagetime/` with 600 permissions — only root can modify
- Data cached locally for offline operation

## Security

- JWT tokens for device authentication
- Keychain for token storage (in Parent App)
- TOTP shared secrets for offline unlock
- CORS on API server (configure for production)
