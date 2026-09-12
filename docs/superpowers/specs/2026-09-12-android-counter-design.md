# Android usage counter

**Date:** 2026-09-12
**Status:** Design. Not implemented.
**Implements:** step 4 of the rollout in `2026-09-09-cross-platform-shared-budget-design.md`.

## Problem

The child's Android phone contributes nothing to the shared daily budget. Time spent
on it is invisible to the server, so the Mac's `remaining` is computed as if the phone
did not exist. The budget is shared in the data model and on the Mac; the phone is the
hole in it.

The backend is already finished for this. `Device.platform` accepts `android`,
`/agent/config` aggregates across a child's devices, and `/agent/usage` clamps a
report to what wall-clock time allows. **This design adds no API endpoints and no
migrations.** It is a client.

## Goals

- Foreground time on the phone drains the child's shared budget, so the Mac locks sooner.
- The parent can see that the phone is reporting, and see when it stops.

## Non-goals

- **Blocking on Android.** Carried over from the September design: a soft overlay is
  removed by an adaptive child within a day. Not built, not planned.
- Per-app rules, content filtering, location.
- Device Owner enrolment (needs a factory reset; rejected by the parent).
- A parent-side Android app. The web dashboard already serves that; this is the
  child-side counter only.

## Approach

### The counter is stateless

The single most important decision, and it departs from how the Mac agent works.

The Mac agent accumulates its own tally in memory and persists it. The Android app
does **not**. On every tick it recomputes the day's total from scratch:

```
UsageStatsManager.queryEvents(startOfLocalDay, now)
  → pair ACTIVITY_RESUMED / ACTIVITY_PAUSED per package
  → sum the intervals
```

Android keeps this event history itself, in the system, outside the app's process. So:

- **Force-stop costs the child almost nothing.** When the service comes back — on
  reboot, or when the parent reopens the app — it re-derives the true total including
  the time the app was dead. The child does not "bank" free minutes by killing it.
- No local database, no persisted counter, no reconciliation with the server's number,
  and therefore **none of the class of bug that agent 2.9 had**. The app cannot echo
  the server's total back at it, because it never reads a total into its own tally.
- A reboot or a crash loses nothing.

This also means the server's existing clamp can never fire spuriously. Reported growth
between two reports is foreground time within that interval, which is by definition
≤ wall-clock elapsed, which is exactly the ceiling
`_clamp_reported_minutes` enforces (`api/app/routers/agent.py`). Offline catch-up fits
under the clamp for the same reason.

### Foreground time, not screen-on time

Counting screen-on time would be dishonest — the phone can sit unlocked on a table.
`ACTIVITY_RESUMED`/`ACTIVITY_PAUSED` is the honest measure and matches what the Mac
agent counts.

### The client owns nothing else

No verdict, no lock, no TOTP, no Keychain equivalent, no self-protection. The app is a
sensor plus a notification.

## Module layout

New top-level `android-agent/`, sibling to `macos-agent/`. Gradle wrapper committed.

```
android-agent/
  settings.gradle.kts
  gradle/wrapper/              # committed, so CI and a fresh Mac need no Gradle install
  app/
    build.gradle.kts
    src/main/kotlin/com/nestimer/agent/
      counting/UsageCounter.kt     # pure Kotlin — no android.* imports
      net/AgentClient.kt           # pure Kotlin — no android.* imports
      net/Dto.kt
      service/CountingService.kt   # the only Android-aware layer
      service/BootReceiver.kt
      ui/SetupActivity.kt
    src/test/kotlin/...            # JVM unit tests, no device, no emulator
```

- `applicationId = "com.nestimer.agent"` — consistent with the `com.nestimer.*` scheme.
- `minSdk = 29` (Android 10). The `ACTIVITY_RESUMED`/`ACTIVITY_PAUSED` event constants
  are stable from 29; below that they carry different names and semantics.
- `targetSdk = 35`.

### Why the three-layer split

The phone is the parent's, not Claude's. Everything that can be verified without a
device is pushed into layers that a JVM test can reach:

| Layer | Android types? | Verified by |
|---|---|---|
| `UsageCounter` | no | JVM unit tests in CI |
| `AgentClient` | no | JVM unit tests against a mock server |
| `CountingService` | yes | by hand, on the phone |

`UsageCounter` takes `List<UsageEventRecord>` — a plain data class of
`(packageName, type, timestampMillis)` — and returns minutes. The Android-specific job
of turning `UsageEvents` into that list is three lines inside the service.

This mirrors `macos-agent/NesTimerAgentTests/run-logic-tests.sh`, which exists for the
same reason and guards the same kind of contract.

### Counting edge cases `UsageCounter` must handle

These are the unit tests, and they are the reason the layer exists:

- A `RESUMED` with no matching `PAUSED` — the app is in the foreground right now.
  Count to `now`, not to zero.
- A `PAUSED` with no preceding `RESUMED` — the session began before the window (i.e.
  before midnight). Count from `startOfDay`.
- Overlapping packages: A resumes, B resumes, A pauses. Treat foreground as a single
  timeline, not a sum per package, or a handoff double-counts.
- Events out of order (the API does not guarantee ordering).
- An empty event list → 0.0, not a crash.
- The launcher and the system UI resuming between apps — counted, because the screen
  is in use. Documented rather than filtered; filtering would need a package allowlist
  that drifts.

## Runtime behaviour

### Permissions

- `PACKAGE_USAGE_STATS` — **special access.** Cannot be requested programmatically;
  the user grants it by hand in Settings. `SetupActivity` detects the missing grant via
  `AppOpsManager.unsafeCheckOpNoThrow` and deep-links to
  `Settings.ACTION_USAGE_ACCESS_SETTINGS`.
- `POST_NOTIFICATIONS` (API 33+) — normal runtime request; the foreground notification
  is otherwise invisible.
- `RECEIVE_BOOT_COMPLETED` — normal.
- `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` (API 34+), with
  `foregroundServiceType="dataSync"` in the manifest.
- Battery optimisation exemption via `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
  Without it the service dies silently after a few hours. This is a prompt, not a
  guarantee — the user can decline, and then the app is unreliable. `SetupActivity`
  shows the state of all four and refuses to report "ready" until they are granted.

### The service loop

`CountingService` ticks every 60s:

1. Recompute today's total (stateless, as above).
2. `POST /agent/usage` with `{date: localDate, total_minutes: total}`.
3. `GET /agent/config?date=<localDate>&version=<versionName>` — this is what advances
   `last_seen` and `agent_version` server-side, and therefore what makes silence
   detection work.
4. Update the persistent notification.

No adaptive interval. The Mac's adaptive schedule exists because the Mac must react
fast enough to lock; this client never locks, so 60s flat is right and cheaper.

Failures are logged and skipped. The next tick re-sends an absolute total, so a missed
report needs no retry queue — this is the same property that makes the Mac agent's
offline catch-up work.

### The notification

Mandatory (foreground service), so it should earn its place: it shows the child's
remaining shared minutes, from `used_minutes_today` and `screen_time_limit_minutes` in
the config response. Tapping it opens `SetupActivity`.

The child seeing the remaining budget is a feature, not a leak — the same number is on
the Mac's menu bar today.

### Pairing

`SetupActivity` takes the same `server|token` string the Mac agent's setup dialog
parses (`ParentApp/NesTimer/Views/AddDeviceView.swift:36`), split on the single `|`.
Stored in `EncryptedSharedPreferences`.

No QR in v1. QR would need a generator in ParentApp and the web dashboard, neither of
which has one today (`grep -ril qr` finds nothing in the repo). It is a real
improvement and a separate, small piece of work.

## Distribution

Sideload now, Play Store later — so the decisions that are expensive to reverse are
made correctly on day one:

- Release signing keystore generated now, kept out of git, recorded alongside the
  other signing material.
- `versionCode` is a monotonic integer, `versionName` tracks it. Play will reject a
  re-used `versionCode` forever after, so it must be right from the first build.
- `applicationId` is final from the first install; changing it later is a new app.

The APK is hosted next to the Mac DMG on `my.nestimer.com` and installed by hand.

**The app cannot update itself.** Silent reinstall requires Device Owner, which was
rejected. This is the same failure mode that left `Juliana's Macbook` on agent 2.9 for
three months, and on Android there is no watchdog to fix it. Mitigation is visibility
only: the app reports `version` on every config poll, the parent UI shows it. Moving to
Play Store later removes this properly, which is why v1 is built Play-ready.

## Silence detection (parent-side)

Without this, the counter is defeated by force-stop or by revoking usage access, and
the parent never finds out. The server already stores `last_seen`; the work is
surfacing it.

**Amended after reading the code: the web dashboard already does this.**
`web-dashboard/src/pages/DevicesPage.jsx` has `STALE_AFTER_MS = 15 * 60 * 1000`,
`isStale()` and `staleLabel()`, rendering an orange "Not reporting since HH:MM" on the
device card — with a comment naming it the compensating control for platforms the agent
cannot forcibly lock. So the threshold this design would have proposed is already the
one shipped, and the web half is done.

What is left is the parent app, which has no equivalent:

- `DeviceOut` (`api/app/schemas.py:62`) and `DeviceListOut` (`api/app/schemas.py:83`)
  already carry `last_seen` and `agent_version`, both serialized as UTC ISO strings.
  No API change.
- `Device` in `ParentApp/NesTimer/Models/Models.swift:80` already parses `lastSeen` into
  `lastSeenDate` and exposes `isOnline` (3 min) and `lastSeenText`. It needs `isStale`
  and `staleLabel` on the same model, matching the web's 15-minute threshold and wording
  so the two surfaces cannot disagree.
- Rendered in `DevicesListView.swift:96` and on `DeviceDetailView.swift:379`, where the
  parent already looks.

Deliberately not an alert or a push: no notification infrastructure exists, and adding
one is its own project.

## Hard precondition — do not skip

Attaching the phone to the same `Child` as the Mac **is** the "second device under one
child" operation, and the precondition from the September design applies in full:

> do not attach a second device to any child until every one of that child's Macs is
> confirmed on the new agent — check `agent_version` and a recent `last_seen`, not
> merely that `push-agent-update.sh` exited successfully.

Agent 2.9 ratchets its local counter up to `used_minutes_today` — which, once the child
has two devices, is the child's combined total — and posts it back as its own. The
server clamp keeps this linear instead of exponential, but on a merged child a 2.9
agent still inflates the counter several times faster than wall clock: a 120-minute
budget disappears in roughly 15–20 real minutes, and the child is locked out.

So the implementation plan gates the attach step on reading `agent_version` and
`last_seen` for every Mac belonging to the target child, from the API, and confirming
3.0 with a recent heartbeat. If a Mac is on 2.9 and cannot be updated, the phone gets
its own `Child` instead — no shared budget, but a correct counter and no lockout.

## Testing

JVM unit tests, TDD, failing first. No emulator; `UsageStatsManager` returns nothing
meaningful in one, so an emulator would buy false confidence.

- **`UsageCounter`** — every edge case listed above, each as its own test.
- **`AgentClient`** — builds the right request; parses a config response that omits
  every optional field (the Mac agent's equivalent test exists because a decoder that
  throws leaves the child unmanaged); survives a 500 and a timeout without crashing.
- **Day boundary** — events spanning local midnight are attributed to the right day.

A new `android-build` job in `.github/workflows/ci.yml` on `ubuntu-latest`
(`actions/setup-java@v4` + `android-actions/setup-android@v3`), running
`./gradlew test assembleDebug`. Ubuntu, not macOS — the runner is cheaper and nothing
here needs a Mac.

On-device verification is the parent's, and is listed explicitly in the plan: grant the
four permissions, confirm the notification appears, use a couple of apps, confirm the
minutes land on the device in the dashboard, reboot, confirm it comes back, force-stop
it and confirm the next start recovers the missed time.

## Alternatives considered

**Accumulate the counter in-app, like the Mac agent.** Rejected. It reintroduces
persistence, reconciliation and the 2.9 echo bug, and it loses time on every
force-stop — for no benefit, since Android hands us the history for free.

**`UsageStatsManager.queryUsageStats` (the aggregated API) instead of events.**
Rejected: its buckets are coarse and their boundaries are not aligned to local
midnight, so the day total would be wrong at exactly the moment it matters.

**`AccessibilityService` to observe foreground apps.** Rejected: far more invasive
permission, a Play Store policy minefield, and it gives nothing `queryEvents` does not.

**WorkManager instead of a foreground service.** Rejected: minimum periodic interval is
15 minutes and it is subject to Doze deferral, so the notification — which the design
relies on for both survival and the remaining-time display — could not exist.

> **Amended 2026-09-12 — the premise was wrong.** This rejection assumed a foreground
> service runs all day. On the child's phone (Android 15) it does not. An app targeting
> API 35 gets roughly **6 hours of `dataSync` foreground service per 24 hours**, after
> which the system calls `Service.onTimeout()` and ANRs a service that does not stop —
> so the counter would have gone quiet every afternoon, silently. Separately, **Android
> 14 forbids a `BOOT_COMPLETED` receiver from starting a `dataSync` foreground
> service**, which breaks reboot recovery, an explicit item on the verification
> checklist below.
>
> Resolved by switching the service to `foregroundServiceType="specialUse"` with a
> `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` declaration, which is exempt from both. The
> approved design is otherwise unchanged: 60-second ticks, a non-dismissible
> notification.
>
> **This has a cost at the Play Store**, and it lands on the "sideload now, Play later"
> decision above. Google reviews `specialUse` strictly and rejects weak justifications.
> If Play becomes the distribution route, the fallback is the one rejected here —
> `AlarmManager` (or WorkManager) ticks with an ordinary notification. That fallback is
> cheap *because* the counter is stateless: it reconstructs the whole day from the
> system's event history on any tick, so a coarser schedule loses notification
> freshness and nothing else. What it costs is a dismissible notification and a
> `last_seen` that updates slower than the 15-minute silence threshold, which would
> then need raising.

## Accepted limitations

- **Bypassable.** By choice. Mitigated by stateless recovery (killing it forfeits only
  the dead window) and by silence detection.
- **No auto-update.** Until Play Store. Mitigated by version visibility.
- **Battery exemption is a prompt.** If declined, the service dies after hours and the
  device simply goes quiet — which silence detection then surfaces.
- **Timezones.** Local date comes from the device, as on the Mac. One household.
