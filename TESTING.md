# Testing UsageTimeController

Guidance for running locally, testing safely, and the escape hatches that exist so you don't lock yourself out.

---

## Quick Start (safe on your own Mac)

### 1. Start the API server

```bash
cd api
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python -m uvicorn app.main:app --reload
```

Server at `http://localhost:8000`, Swagger at `/docs`.

### 2. Run API tests

```bash
cd api
source venv/bin/activate
python -m pytest tests/ -v
```

80+ tests should pass (auth, devices, policy, usage, TOTP, activities, e2e).

### 3. Run the macOS agent in DEV MODE

Open `macos-agent/UsageTimeAgent.xcodeproj` in Xcode → Cmd+R.

**Debug builds automatically enable Dev Mode** via `#if DEBUG`. No env vars needed. On first launch, paste the setup string from the dashboard into the dialog.

If you prefer env vars:
```bash
export UTC_DEV_MODE=1
export UTC_SERVER_URL=http://localhost:8000
export UTC_API_TOKEN=<token>
```

### 4. Run the web dashboard

```bash
cd web-dashboard
npm install && npm run dev
```

Opens at `http://localhost:5173`.

---

## Dev Mode safeguards

When the agent is a Debug build (or `UTC_DEV_MODE=1`), these protections are active so you don't lock yourself out:

| Safeguard | Description |
|-----------|-------------|
| **Auto-unlock** | Lock screen dismisses itself after 10 s |
| **Emergency hotkey** | `Ctrl+Opt+Cmd+U` — instant unlock (uses both local + global monitors) |
| **Floating window** | Lock at `.floating` level, Cmd+Tab still works |
| **Quit available** | "Quit (Dev Mode)" menu item + Cmd+Q works |
| **No self-protection** | Process can be killed via Activity Monitor / `pkill` |
| **No watchdog** | `SystemInstaller` skips the root LaunchDaemon install |
| **Fast timers** | Tick every 5 s, sync every 10 s (vs 30/20 in Release) |
| **DEV badge** | Visible in menu bar and on lock screen |

### Stop the agent
```bash
# Via menu bar → Quit (Dev Mode)
# or Cmd+Q
# or from terminal:
pkill -f UsageTimeAgent
```

### Configure
Plist (`/etc/usagetime/config.plist`), UserDefaults (`defaults write com.usagetime.agent …`), or env vars:
```bash
UTC_DEV_MODE=1
UTC_DEV_AUTO_UNLOCK=10
UTC_SERVER_URL=http://localhost:8000
UTC_API_TOKEN=<token>
UTC_POLL_INTERVAL=20
```

---

## Test Scenarios

### 1. Screen Time limit
- Set limit to 1 min in dashboard → wait
- Lock screen appears at remaining < 1 (menu shows "0m")
- In Dev Mode: dismisses after 10 s
- Menu bar shows `XXm` remaining

### 2. Downtime
- Set downtime: `now` → `now + 2 min`
- Lock screen appears on next sync
- Shows "Downtime — Computer available at HH:MM"

### 3. Adding time (override)
- Hit the limit → lock appears
- Increase limit in dashboard
- Next sync (5 s while locked) → unlock, warnings reset

### 4. Per-day limits
- Set Weekday 120 min, Mon 30 min
- On Monday the agent uses 30, other weekdays 120
- Weekend uses weekend limit or weekday default

### 5. Scheduled activity (whitelisting)
- Add activity: name "English", day = today, window = `now`–`now+10min`, buffer 5m
- On next sync → lock hides, menu bar shows "English until HH:MM"
- Screen time **is not counted** during the window

### 6. Offline unlock (TOTP)
- Let it lock (downtime or limit)
- Copy the 6-digit code from dashboard / parent app
- Type it on the lock screen
- Mac unlocks for 30 min; during that window, time is not counted

### 7. Parent App
- Open `ParentApp/UsageTimeControl.xcodeproj` → Cmd+R (macOS target)
- Login, edit policy, watch the agent pick up changes on next sync
- Clicking the TOTP code copies it to clipboard

---

## If you get locked out (Release build)

Release builds have **no dev safeguards**. Ways to recover:

1. **TOTP code** — always works offline. Read it from dashboard/parent app, type on lock screen.
2. **Change policy via dashboard** — move downtime window or raise limit; agent syncs every 5 s while locked.
3. **Safe Mode** (Shift at boot) — LaunchDaemons don't run. Delete the app and plist.
4. **Recovery Mode** (Cmd+R at boot for Intel, hold Power for Apple Silicon) → Terminal → `rm -rf` the paths.

**Uninstall (with admin password):**
```bash
sudo launchctl unload /Library/LaunchDaemons/com.usagetime.agent-watchdog.plist
sudo rm /Library/LaunchDaemons/com.usagetime.agent-watchdog.plist
sudo rm -rf /Applications/UsageTimeAgent.app
sudo rm -rf /usr/local/libexec/usagetime-watchdog.sh /var/log/usagetime
defaults delete com.usagetime.agent
```

---

## Production install (Release)

```bash
# Build once
xcodebuild -project macos-agent/UsageTimeAgent.xcodeproj \
  -scheme UsageTimeAgent -configuration Release build

# Or use the pre-built binary in dist/
open dist/UsageTimeAgent.app
```

On first launch the agent:
1. Asks for the setup string (`http://server:8000|TOKEN`) → saves in UserDefaults
2. Asks to install as a protected system service → admin password via `NSAppleScript`
3. Copies `.app` to `/Applications/` (root), installs watchdog `LaunchDaemon`
4. Relaunches from `/Applications`; future reboots auto-start via LaunchDaemon

The `SystemInstaller` flow is skipped in Debug builds.

**Never run a Release install on a Mac you need for work.** It's designed to resist removal.

---

## Architecture

```
┌─────────────────┐     HTTP     ┌──────────────┐
│  macOS Agent    │◀────────────▶│  API Server  │
│  (Release/Root) │               │  localhost   │
└─────────────────┘               └──────┬───────┘
                                         │
┌─────────────────┐     HTTP     ┌──────┴───────┐
│  Parent App     │◀────────────▶│  SQLite DB   │
│  (Xcode sim/Mac)│               └──────────────┘
└─────────────────┘
         │
┌────────┴────────┐
│  Web Dashboard  │
│  http://:5173   │
└─────────────────┘
```

Everything runs locally — no external services required.
