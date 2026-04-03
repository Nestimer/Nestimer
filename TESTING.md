# Testing UsageTimeController

## Quick Start (safe to run on your own Mac)

### 1. Start the API server

```bash
cd api
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python -m uvicorn app.main:app --reload
```

Server starts at `http://localhost:8000`. Swagger UI: `http://localhost:8000/docs`.

### 2. Run API tests

```bash
cd api
source venv/bin/activate
python -m pytest tests/ -v
```

All 70+ tests should pass.

### 3. Run the macOS agent in DEV MODE

```bash
cd macos-agent
./dev-test.sh
```

The script automatically:
- Checks that the API server is running
- Creates a test user and device
- Sets a test policy (5 minutes of screen time)
- Builds the app in Debug
- Launches with DEV MODE

### 4. Run the web dashboard

```bash
cd web-dashboard
npm install
npm run dev
```

Opens at `http://localhost:5173`. Login: `dev-test@usagetime.local` / `devtest123`.

---

## Dev Mode — Self-Lock Protection

When the agent runs in dev mode (`UTC_DEV_MODE=1`), the following safeguards are active:

| Safeguard | Description |
|-----------|-------------|
| **Auto-unlock** | Lock screen auto-dismisses after 10 seconds |
| **Emergency hotkey** | `Ctrl+Opt+Cmd+U` — instantly dismisses lock screen |
| **Floating window** | Lock screen at `.floating` level, can switch away via `Cmd+Tab` |
| **Quit available** | Menu bar has "Quit (Dev Mode)" item, `Cmd+Q` works |
| **No self-protection** | Process can be freely killed via Activity Monitor or `pkill` |
| **No watchdog** | No LaunchDaemon installed, process won't respawn |
| **Fast timers** | Tick every 5s (instead of 30), sync every 10s (instead of 60) |
| **DEV badge** | "DEV MODE" label in menu bar and on lock screen |

### How to stop the agent in dev mode

Any method works:
```bash
# Via menu bar → "Quit (Dev Mode)"
# Cmd+Q
# From terminal:
pkill -f UsageTimeAgent
# Activity Monitor → UsageTimeAgent → Force Quit
```

### Dev mode configuration

Via environment variables:
```bash
export UTC_DEV_MODE=1              # enable dev mode
export UTC_DEV_AUTO_UNLOCK=10      # auto-unlock after N seconds
export UTC_SERVER_URL=http://localhost:8000
export UTC_API_TOKEN=your-token
export UTC_POLL_INTERVAL=10        # sync every N seconds
```

Or via plist (`/etc/usagetime/config.plist`):
```xml
<key>DevMode</key>
<true/>
<key>DevAutoUnlockSeconds</key>
<integer>10</integer>
```

Or via UserDefaults:
```bash
defaults write com.usagetime.agent DevMode -bool true
defaults write com.usagetime.agent DevAutoUnlockSeconds -int 10
```

---

## Test Scenarios

### Scenario 1: Screen Time
1. Launch the agent in dev mode
2. Set the limit to 1 minute in the web dashboard
3. Wait — the lock screen should appear after ~1 minute
4. Lock screen auto-dismisses after 10s (dev mode)
5. Menu bar should show remaining time

### Scenario 2: Downtime
1. Set downtime: current time → +2 minutes
2. Lock screen should appear immediately (next sync)
3. Verify it shows "Downtime"

### Scenario 3: Adding Time
1. Hit the limit (lock screen appears)
2. Increase the limit in the dashboard
3. On next sync (10s in dev mode) lock screen should dismiss
4. Warnings should reset

### Scenario 4: Weekday/Weekend
1. Set different limits for weekday/weekend
2. Verify the correct limit is applied

### Scenario 5: Offline Unlock Code
1. Hit the limit (lock screen appears)
2. In the parent app or web dashboard, find the 6-digit unlock code
3. Enter the code on the lock screen
4. Mac should unlock for 30 minutes

### Scenario 6: Parent App (iOS/macOS)
1. Open ParentApp in Xcode, run on simulator or device
2. Log in with test credentials
3. Verify devices and policies are visible
4. Change a policy — verify the agent picks it up

---

## Production Install (NOT for testing on your own Mac!)

```bash
cd macos-agent
sudo ./install.sh
```

This installs the agent with full protection:
- Lock screen at maximum window level (cannot switch away)
- Cmd+Q blocked
- Watchdog restarts the process every 15 seconds
- App owned by root (cannot delete without sudo)

**NEVER run a production install on your own work Mac without configured remote access!**

---

## Testing Architecture

```
┌─────────────────┐     HTTP      ┌──────────────┐
│  macOS Agent    │◄────────────►│  API Server  │
│  (dev mode)     │               │  (localhost)  │
└─────────────────┘               └──────┬───────┘
                                         │
┌─────────────────┐     HTTP      ┌──────┴───────┐
│  Parent App     │◄────────────►│   SQLite DB  │
│  (Xcode sim)    │               └──────────────┘
└─────────────────┘
         │
┌────────┴────────┐
│  Web Dashboard  │
│  (localhost)     │
└─────────────────┘
```

All components run locally, no external server needed.
