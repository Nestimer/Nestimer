# iOS child agent (son's iPhone)

**Date:** 2026-11-09
**Implements:** step 5 of the rollout in `2026-09-09-cross-platform-shared-budget-design.md`.
**Precondition met:** Family Controls (Distribution) entitlement approved for the team
(request `V9BYW3K8YD`, filed 2026-09-09, seen approved 2026-11-09).

## Why

The son is moving to an iPhone. Right now the phone is a free, uncounted screen. Every
minute he spends on it should count against the same daily budget as his Macs. When the
budget runs out or downtime starts, the phone should lock everything except calls and
messages, the same way the Mac agent locks the Mac.

What Ruslan asked for: duplicate the macOS agent's functionality as far as iOS allows,
against the same API, paired with the same `server|token` string.

## Goals

1. **Pairing like the Mac.** The son enters `https://my.nestimer.com|TOKEN` in the app,
   and the phone joins his child account as one more device (`platform = ios`).
2. **Counting.** iPhone usage is reported to `POST /agent/usage` and feeds the shared
   daily budget (`used_minutes_today`), together with the Macs.
3. **Locking.** When the budget is exhausted or downtime is active, every app is shielded
   **except Phone, Messages and NesTimer itself**. YouTube and everything else are blocked.
4. **The rest of the Mac policy carries over:** downtime with weekday/weekend variants,
   scheduled activities (unlocked, counting paused), parent-granted bonus window,
   per-device ceiling, TOTP unlock with the parent's 6-digit code, and "N minutes left"
   warnings.
5. **Tamper resistance through Family Sharing.** On the son's phone the app uses
   `.child` authorization. He has his own Apple ID as a child in Ruslan's family, so he
   cannot delete the app or revoke Screen Time access without parent approval.

## Non-goals

- Watchdog, self-update, media-key control and the AppleScript notification hack. These
  are macOS-only mechanisms. Updates go through TestFlight / App Store.
- A custom full-screen lock UI. iOS doesn't allow one; the Apple shield with our text is the
  lock screen.
- Per-app limits or an app picker for the parent. Everything except the exemptions is blocked.
- iPad support (it may work, but it isn't tested or promised).
- Server-side changes beyond what the iOS client needs. The API is already
  platform-agnostic (see below).

## Anti-goals (failure even if it "works")

- **Silent unlock.** Any path where the phone ends up unshielded during downtime or after
  the budget is spent, without a parent action, is the worst outcome. The son actively
  probes bypasses (see the threat-model memory). When the agent is unsure, it keeps the
  phone shielded.
- **Locking calls or messages.** He must always be able to call and text.
- **Secrets readable by the child.** The TOTP secret and device token go in the Keychain
  (shared access group), never in UserDefaults or the App Group plist.

## Constraints

- **iOS 17.4+** *(Claude's call)*. Earlier versions reset the threshold count whenever
  monitoring restarts mid-interval, because they lack `includesPastActivity`. This design
  re-arms thresholds during the day, so a reset would break the cumulative daily total. If
  the son's phone can't run 17.4, the counting design has to change: fixed daily events
  that are never restarted.
- **No custom process runs in the background.** Code only runs when:
  - the app is in the foreground;
  - the `DeviceActivityMonitor` extension is woken by a schedule boundary
    (`intervalDidStart`/`intervalDidEnd`) or a usage threshold (`eventDidReachThreshold`);
  - the `ShieldConfiguration` extension renders a shield.

  Everything below is designed around these wake points.
- **`DeviceActivityReport` has no network access.** Real minute counts can't leave that
  sandbox. Counting is built on threshold events instead (5-minute chunks).
- **Minimum schedule interval is 15 minutes**, and the number of monitored activities per
  app is limited (~20). Downtime and activity schedules have to fit those limits.
- **Distribution: public App Store release** (Ruslan's decision). A build that expires is
  a silent unlock (the anti-goal), so TestFlight's 90-day builds aren't the long-term
  channel. App Store review needs:
  - a privacy policy page on nestimer.com;
  - App Review notes explaining the Family Controls use;
  - a demo pairing string for the reviewer.

  **Fallback if review fails:** install a Development build straight onto the son's phone
  with developer mode on, and re-sign it before the profile expires. The parent app warns
  ahead of the expiry date.
- **pbxproj editing is manual** (see CLAUDE.md sharp edge #1).

## The API needs (almost) nothing new

- `GET /agent/config?date=YYYY-MM-DD&version=…` returns the policy, `used_minutes_today`
  (shared), `device_used_minutes`, `device_cap_minutes`, activities and `bonus_until`.
  That is everything the iOS client needs.
- `POST /agent/usage` takes an absolute per-device total for the date, clamped by elapsed
  time. 5-minute chunks fit this shape.
- `GET /agent/totp-secret` and `POST /agent/verify-totp` work as on the Mac.
- `Device.platform` already accepts `ios`.

**Silence detection for iOS** *(Claude's call)*. The dashboard's 15-minute
"Not reporting" rule (`STALE_AFTER_MS` in `DevicesPage.jsx`) would fire all day: an idle or
shielded iPhone only talks to the server when it's used or opened. For `platform = ios`, the
rule is "no contact for 24 hours". Under `.child` authorization the real bypasses (delete
app, revoke access) already need the parent, so this is just a safety net. Apply the same
rule in the parent app if it shows staleness.

**One gap:** neither the parent app (`AddDeviceView.swift`) nor the web dashboard lets you
pick a platform when adding a device. Everything is created as `macos`. The add-device
flow needs a platform choice (macOS / iPhone) so the device card shows the right icon,
and so silence detection treats it as a platform that can be bypassed.

## How it works

### Parts

| Part | Bundle ID (proposed) | Job |
|------|----------------------|-----|
| App `NesTimerChild` | `com.nestimer.child` | pairing, authorization, TOTP entry, status, foreground sync |
| `DeviceActivityMonitor` extension | `com.nestimer.child.monitor` | counting, reporting, applying/removing shields, warnings |
| `ShieldConfiguration` extension | `com.nestimer.child.shield` | the text on the shield ("Time's up — open NesTimer to enter a code") |

Shared through **App Group** `group.com.nestimer.child` (policy snapshot, today's count,
unlock state) and a **shared Keychain access group** (device token, TOTP secret).

A separate Xcode project `ios-agent/NesTimerChild.xcodeproj`, not a new target in
`ParentApp`. The parent app and the child app must never be the same binary.

**Shared logic** lives in a small Swift package or shared folder, written as pure
functions with unit tests:
- policy evaluation, ported from `PolicyEnforcer.evaluate`, same order:
  activity → temporary unlock (TOTP or bonus) → downtime → remaining < 1 min → warn → unlock;
- remaining time (shared budget and per-device ceiling, same as `RemainingTime.swift`);
- TOTP, a copy of `TOTPGenerator.swift` that stays in sync with Python and JS.

### Counting

- One daily `DeviceActivitySchedule` (00:00–23:59, repeating) with events at 5, 10,
  15 … minutes of device usage.
- **Phone, Messages and NesTimer do not count** (Ruslan's decision). The counting events
  exclude the same tokens the shield exempts. As a result, a shielded phone goes quiet: no
  usage, so no wakes. A parent bonus or a policy change is picked up when the son opens
  NesTimer, and the shield text tells him to do that.
- On `eventDidReachThreshold(N)`, the monitor extension:
  1. stores today's total N in the App Group;
  2. `POST /agent/usage {date, total_minutes: N}`. On failure it retries at the next wake;
  3. fetches `/agent/config`, evaluates policy, then applies or removes the shield and
     re-arms the next events.
- **Shared budget across devices:** the Macs can spend the budget while the phone sits
  idle. That's fine. The next threshold event (≤5 min of phone use) fetches fresh config
  and shields. So the phone overshoots the shared budget by at most one chunk, and the
  thresholds are re-armed so one lands exactly where the remaining budget runs out.
- The event count per activity and "all apps without a picker" are **spike questions**
  (below). If the event count is capped, the builder re-arms a rolling window of upcoming
  thresholds at each wake.

### Locking

- `ManagedSettingsStore().shield.applicationCategories = .all(except: exemptions)`, and
  the same for web domains.
- **Exemptions:** Phone, Messages and NesTimer. Getting their `ApplicationToken`s may
  require a one-time `FamilyActivityPicker` step during setup (the parent ticks Phone +
  Messages). Whether Phone is shielded at all is a spike question.
- **Downtime:** registered as its own `DeviceActivitySchedule`(s). `intervalDidStart`
  shields and `intervalDidEnd` re-evaluates. Weekday and weekend variants need separate
  schedules.
- **Scheduled activities:** registered as schedules too (unshield on start, re-evaluate on
  end). Re-registered on every sync to stay under the activity limit: the next ~24h only.
- **Default when unsure:** if config can't be fetched and the last known snapshot is
  stale or missing, follow the last known policy using the local count. If there's no
  snapshot at all, keep the shield.

### Unlocking

- **TOTP:** the son opens NesTimer (exempt from the shield) and enters the parent's code.
  The app verifies it with `POST /agent/verify-totp`, or offline against the Keychain
  secret, and lifts the shield. The Mac grants **5 minutes**. iOS can't schedule a
  5-minute interval, so the unlock ends with a dedicated usage threshold (5 more minutes of
  use) and a timed fallback, whichever comes first. Builder's call on the exact mechanism.
- **Bonus from the parent:** a shielded phone has no usage events, so nothing wakes up to
  notice the bonus. The shield text tells him to open NesTimer, which syncs and lifts the
  shield. Silent push (APNs) is out of scope for v1.
- **Policy changes** (limit raised, downtime moved) apply at the next wake: a threshold,
  a schedule boundary or the app opening.

### Warnings

Local `UNUserNotification`s at the same thresholds as the Mac (e.g. 15 / 5 / 1 min left),
fired from the monitor extension when a threshold crosses them.

### Pairing and authorization

1. First launch: paste or type `server|token`, the same parser and validation as the Mac
   setup (#3 fixed which strings are accepted; reuse that logic).
2. Fetch the TOTP secret once and store it in the Keychain.
3. `AuthorizationCenter.shared.requestAuthorization(for: .child)` on the son's phone, or
   `.individual` in **test mode** (Debug builds and the spike on Ruslan's phone).
4. Ask for the exemption tokens if the spike says they're needed, then register the
   schedules.

## Phase 0 — spike on Ruslan's iPhone (throwaway)

A bare app + monitor extension, `.individual` authorization, Development signing via
Xcode. It answers, by hand:

1. Do threshold events fire reliably every 5 minutes of real use, including with the app
   killed and the phone locked between sessions?
2. Can the monitor extension make the HTTPS call to `my.nestimer.com`? (Expected yes.
   Check it.)
3. Can "all usage" be counted without the user picking apps (`.all` categories), or is a
   picker step needed?
4. Does `shield.applicationCategories = .all(except:)` leave Phone and Messages usable, and
   how do we get their tokens?
5. How many events per activity are accepted, and how many activities?
6. How late are the events (lag between real usage and the callback)?

The answers go into this doc. If a hard "no" comes up (e.g. the extension can't reach the
network), we stop and redesign before the real build.

## Testing

- **Shared logic:** unit tests (XCTest), TDD, failing first. Policy order (mirrors the
  Mac's), remaining-time maths with shared budget + ceiling, TOTP vectors (same as the
  Python/JS suites), `server|token` parsing.
- **API:** add tests only if the platform choice touches the API. Existing suite stays green.
- **Device:** manual checklist on a real iPhone (Screen Time APIs don't work in the
  simulator): count → report → shield → TOTP unlock → re-shield, downtime start/end,
  activity window, parent bonus + app open, airplane mode.
- **CI:** add an iOS simulator *build* of `NesTimerChild` (build only, no device tests).

## Rollout

1. Spike on Ruslan's iPhone → findings into this doc.
2. Real app, `.individual` test mode, on Ruslan's iPhone, paired to a test device in
   his account.
3. Add-device platform choice in the parent app + web.
4. App Store submission: privacy policy, review notes, demo pairing. TestFlight is only
   for our own pre-release testing.
5. Son's iPhone: `.child` authorization under Family Sharing, App Store install (or a
   Development install if review fails), paired to the son's child record → joins the
   shared budget.

## Left to the builder

- Exact threshold/re-arm mechanics and the TOTP-unlock end mechanism within the iOS limits.
- Shield copy and visuals (English only, NesTimer brand).
- App UI layout: setup screen, status screen (remaining time, locked/unlocked, code entry).
- Shared-code packaging (local Swift package vs. a shared folder in both projects).
- Version string scheme for `?version=`.

## Spike and first device-run findings (2026-11-09, Ruslan's iPhone, iOS 27)

- **Q2 extension network:** yes — `DeviceActivityMonitor` extension POSTs to
  `my.nestimer.com` fine (dozens of 200s).
- **Q4 shield:** `shield.applicationCategories = .all(except:)` blocks everything; Phone and
  Messages keep working. **Phone can't even be picked in `FamilyActivityPicker`** — iOS never
  shields it — so setup only asks for Messages.
- **Q5 limits:** 120 events on one activity were accepted.
- **Past activity:** with `includesPastActivity: true`, every (re)start of monitoring
  immediately delivers all thresholds already passed today, as a burst.
- **`DeviceActivityCenter.startMonitoring` blocks while any monitor callback is running**,
  including the caller's own. Arming inside the extension's callback stalled every wake to
  its timeout (25–75 s) and the app queued behind it. The extension now arms after its
  callback returns.
- **Screen Time "Share Across Devices"** makes the "All Apps & Categories" usage include
  other devices on the same Apple ID (the Mac). Turning it on mid-day pushed the counted
  usage from ~140 to ~450 minutes in ten minutes. Countermeasures: observed usage can't grow
  faster than the clock; **the child's devices must have Share Across Devices off** (the Mac
  agent already counts Mac time — sharing would count it twice). Added to the device
  checklist and pairing instructions.
- Q1/Q6 (cadence and lag of 5-minute events) — being measured in the device run.
