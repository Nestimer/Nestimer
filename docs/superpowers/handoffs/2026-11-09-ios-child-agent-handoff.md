# Handoff: iOS child agent (2026-11-09 evening)

**Goal for tomorrow (2026-11-10):** NesTimer installed on the son's iPhone, paired to his
child record, counting into the shared budget and locking. Ruslan wants to hand the phone
over tomorrow.

Read first: `docs/superpowers/specs/2026-11-09-ios-child-agent-design.md` (incl. the
"Spike and first device-run findings" section) and the plan
`docs/superpowers/plans/2026-11-09-ios-child-agent.md`.

## Where things are

- **Branch:** `feat/ios-child-agent`, 21 commits ahead of `main`. **Draft PR #7.** CI was
  green as of the security-fix commit. Re-check before merging.
- **Production server:** at `9f7c2f4` (main, PR #6). **None of PR #7 is deployed.** That
  includes:
  - server hardening: plausible-date check on `/agent/config` and `/agent/usage`, one-time
    TOTP via the new `devices.last_totp_step` column (auto-migrated by `init_db`);
  - the web/ParentApp "iPhone" platform choice;
  - 24-hour staleness for iOS devices.
- **Code:**
  - `ios-agent/NesTimerCore` is a SwiftPM package with all the decision logic. 104 tests:
    `cd ios-agent/NesTimerCore && swift test`.
  - `ios-agent/project.yml` is the XcodeGen project (`xcodegen generate` in `ios-agent/`).
    It has three targets: app `com.nestimer.child`, monitor extension `.monitor`, shield
    extension `.shield`. The App Group is `group.com.nestimer.child`.
- **Ruslan's iPhone** (UDID `00008160-000469690230000A`, "iPhoneEx", iOS 27) runs a
  **Debug** build (`.individual` auth). It is paired to device "Ruslan iphone"
  (id `bbacccf5-…`), whose platform is still `macos` in the DB. Test limit 200, and today's
  usage was inflated by the Screen Time sharing below.
- **Install on a phone:**
  1. `cd ios-agent && xcodebuild -project NesTimerChild.xcodeproj -scheme NesTimerChild -configuration Debug -destination 'id=<UDID>' -derivedDataPath build -allowProvisioningUpdates build`
  2. `xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/NesTimerChild.app`

  Xcode is signed in to team CBBC6T33XY. The ASC API key does **not** work for
  provisioning in Xcode.

## Verified on device today

- Pairing with `server|token`, Screen Time authorization, picking "All Apps & Categories" and
  then Messages. **Phone can't be picked and is never shielded.**
- Counting: chunk/warning events reach the server about every 5 minutes of use.
- Notifications at 15, 10, 5 and 1 minutes, then the shield, while Phone and Messages
  keep working.
- Code unlock works (online).
- Bonus from the parent opens the phone.

## Hard-won iOS facts (all in the spec findings; don't relearn them)

1. `DeviceActivityCenter.startMonitoring` **blocks while any monitor callback is running**,
   including the caller's own.
   - The extension therefore arms **after** its callback returns (`DeferredScheduler`).
   - The app never calls iOS APIs while holding the state flock.
2. Restarting the `daily` activity makes iOS fire `intervalDidEnd`/`intervalDidStart` for it
   immediately. Those echoes are ignored away from midnight (`isEcho`); otherwise they loop.
3. **Thresholds are relative to arming** (`includesPastActivity: false`).
   - Event names carry the absolute minute (`lock-200`); `armThreshold` is the relative one.
   - Re-arming drops the partial minutes since the last event (up to 5), so the engine
     re-arms only when needed.
   - **Never re-arm on app open**: that was an exploit and was removed in `093e021`.
4. Events are one-shot. A fired event is removed from `armedEvents`. If it fired early
   (iOS bursts), it is re-armed from now.
5. Observed usage can't grow faster than the clock. **Screen Time "Share Across Devices"
   must be OFF**; it pulled the Mac's usage into the iPhone count (140 → 450 min).

## To do before handing the phone over (in order)

1. **Cap `debug.log`.** `ios-agent/Shared/AppGroup.swift` → `DebugLog` grows without bound.
   Trim to the last ~500 lines, or drop the per-wake lines. Keep "Copy debug log" in Debug only.
2. **Release-config build for the son's phone, signed for Development.**
   - `.child` authorization is compiled in `#if !DEBUG`, so build `-configuration Release`
     with automatic development signing.
   - App Store review can't happen by tomorrow. That's the agreed fallback: a dev build
     with developer mode on.
   - Register the son's iPhone (connect it by cable; `-allowProvisioningUpdates
     -allowProvisioningDeviceRegistration`).
3. **Son's iPhone setup.** Add these to the parent instructions:
   - His Apple ID is a child in Ruslan's Family Sharing.
   - Screen Time → Share Across Devices **off**.
   - Date & Time set to automatic. Check whether `.child` Screen Time locks it; if not, the
     clock-check shield covers it.
   - Developer Mode on.
   - Pair, then the parent approves the `.child` authorization on that phone.
4. **Server and web:**
   - Run a whole-branch review of PR #7 (the mandatory pre-PR review; a risk review of
     SyncEngine was already done and its findings fixed).
   - Merge, then deploy `docker compose up -d --build api web`.
   - Verify:
     - the Mac agent still syncs (it sends plausible dates);
     - `last_totp_step` exists;
     - creating an "iPhone" device in the dashboard works.
   - Create the son's iPhone device under his child record with platform iPhone.
5. **Checklist items not yet tested on device:**
   - downtime start and end;
   - activity window (counting paused);
   - bonus end window;
   - airplane mode (offline gets half of what's left; the code works offline only at
     trusted time);
   - midnight rollover;
   - the same code twice online (rejected after the deploy);
   - clock changed by hand (expect the "Date & time changed" shield).
6. **Nice to have:**
   - App icon. `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` is set but there is no asset
     catalog.
   - A heartbeat window, so stale armed state self-heals without a fired event.

## Open items outside the iOS work

- **Mac agent, DST (task):** after the 2026-10-25 switch to winter time, the Mac agent "ran
  on wrong time until the Mac rebooted".
  - No root cause yet. The agent uses `Calendar.current` / `TimeZone.current` per call, and
    tzdata for Kyiv is fine.
  - **Ruslan's answer:** downtime ended at **07:00 instead of 08:00**, so the Mac unlocked an
    hour early, until a reboot. That is exactly the EEST→EET shift (UTC+3 → UTC+2): the
    long-running agent kept evaluating local time with the old +3 offset.
  - Hypothesis to test first: the process holds a cached fixed-offset zone (via
    `TimeZone.current` / `Calendar.current` / a `DateFormatter`, or a `TZ`/`localtime`
    picked up at launch by the root watchdog), and nothing resets it on
    `NSSystemTimeZoneDidChange` / `NSSystemClockDidChange`.
  - Reproduce with a long-running Swift process across a simulated zone change before
    fixing. Candidate fix: `NSTimeZone.resetSystemTimeZone()` on those notifications, plus
    using `TimeZone.autoupdatingCurrent`.
  - Follow systematic debugging; no speculative fix.
- **Partial-minute loss per re-arm (≤5 min)** is accepted, and noted in the commit messages.

## Session context worth keeping

- Production also got two security fixes today: dependency upgrades and real-client-IP
  rate limiting (PR #5), then a Postgres-shared limiter (PR #6). Both are deployed and
  verified.
- Fresh DMGs (agent 3.0 and the parent app) are on nestimer.com.
- Two outside users exist (Emil, who signed up today; Eliana, inactive since June).
- Ruslan's working style: options → recommendation → wait for a confirm → ship end to end,
  including the deploy. Reply to him in Ukrainian.
