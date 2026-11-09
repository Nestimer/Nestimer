# Handoff: iOS child agent (2026-11-09 late evening → 2026-11-10)

**Goal for 2026-11-10:** NesTimer on the son's (Alex's) iPhone, paired to his child record,
counting into the budget he shares with his Mac, and locking.

This handoff replaces the to-do list in `2026-11-09-ios-child-agent-handoff.md`. Keep using
that file for the "hard-won iOS facts". The spec and plan are in
`docs/superpowers/specs/2026-11-09-ios-child-agent-design.md` and
`docs/superpowers/plans/2026-11-09-ios-child-agent.md`.

## Where things are

- **Everything is on `main`.**
  - PR #7: the iOS agent, server hardening, iPhone platform. Squash-merged as `59620cf` and
    **deployed** 2026-11-09 ~19:25.
  - PR #8: edge timing, heartbeat, bonus pause, warning rounding. Squash-merged as
    `e8d4280`. It is iOS only, so there's nothing to deploy.
- **Production checks after the PR #7 deploy:**
  - the Mac agents (3.0) sync with 200;
  - `devices.last_totp_step` exists;
  - the dashboard offers "iPhone";
  - a one-time code is accepted once and rejected the second time (tested against the live
    API).
- **Ruslan's test iPhone** ("iPhoneEx", UDID `00008160-000469690230000A`):
  - runs a Debug build from `main` (with `.individual` auth);
  - device `bbacccf5…` "Ruslan iphone", platform now `ios`;
  - child "Ruslan" `bcc7d7ee…`, policy `765ad7f0…`. There are two children called "Ruslan".
    The other one (`d4395e0e…`) holds a stale device-level policy. It's harmless clutter.
- **Alex** (the son): child `8594f7c6-6d6a-4301-8194-040a7c201989`. His Mac is "Real Alex
  Macbook". The iPhone device for him is **not created yet**.
- Tests: `cd ios-agent/NesTimerCore && swift test` (121 pass). API: 377 pass.

## Done on 2026-11-09

- `debug.log` is capped: past 64 KB it keeps the last 500 lines (`LogTrim`).
- The app icon (agent variant, from `gen_icons.py`) and a cleaner status and setup UI.
  Release builds have no Debug section.
- Server, from the review findings:
  - `/agent/usage` accepts yesterday's date (a morning report in the Americas);
  - the one-time TOTP check is an atomic conditional UPDATE.
- Edge timing:
  - a wake within 60 s before a real policy edge evaluates the policy at that edge;
  - the bonus window ends on the minute after the bonus. iOS arms windows to the minute;
    the "8 s early" wake was truncation.
- Heartbeat:
  - a window ends every quarter hour (epoch-aligned, armed first; at most 16 schedule
    windows), so the monitor wakes even with no usage;
  - a monitor wake that times out (25 s) still arms the heartbeat.
- **Bonus pauses counting**, as on the Mac (`AppDelegate.performTick`).
- **The 1-minute warning was lost** when the remaining time was fractional. Warnings are now
  armed rounded down, and the engine compares whole minutes left.
- The app refreshes once on open instead of 3–5 times.

## Verified on Ruslan's iPhone

- The limit, with warnings at 15, 10, 5 and 1. The lock fires.
- Downtime start and end, including an end with nobody touching the phone.
- Bonus:
  - picked up by the heartbeat without opening the app;
  - minutes during the bonus are not counted (8.5 left before → 7.07 after; the first chunk
    is split by wall time);
  - the bonus end fires on time.
- The heartbeat every 15 min, and it survives a reinstall.
- Airplane mode.
- Manual clock change.
- A raised limit reaches the locked phone on the next heartbeat (up to 15 min) or at once
  when the app is opened. **Ruslan accepted the 15 min. Don't add a 7.5-min heartbeat or
  APNs unless he asks.**

## Not verified on a device yet

- **Midnight rollover.** Check the morning debug log from Ruslan's phone:
  - a new day starts from 0;
  - yesterday's leftover is reported (`flushYesterday`);
  - no echo loop on the `daily` activity.
- **Activity window** (counting paused). It's the same pause mechanism as the bonus, so the
  risk is low. Test it if there's time: add an activity for 15–20 min in the dashboard.

## To do on 2026-11-10 (in order)

1. **Morning: read Ruslan's debug log** for the midnight rollover (see above).
2. **Dashboard:** under child Alex, add a device with platform **iPhone** and copy its setup
   string.
3. **Son's iPhone by cable.** Then build Release (`.child` auth is `#if !DEBUG`) with
   automatic Development signing, register the phone and install:
   ```bash
   cd ios-agent && xcodegen generate
   xcrun devicectl list devices            # get the UDID
   xcodebuild -project NesTimerChild.xcodeproj -scheme NesTimerChild \
     -configuration Release -destination 'id=<UDID>' -derivedDataPath build \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   xcrun devicectl device install app --device <UDID> \
     build/Build/Products/Release-iphoneos/NesTimerChild.app
   ```
   Xcode is signed in to team CBBC6T33XY. The ASC API key does not work for provisioning.
4. **Phone setup:** follow `docs/ios-child-setup.md`.
   - Family Sharing child.
   - **Share Across Devices OFF.**
   - Date & Time automatic.
   - Developer Mode ON (it appears only after the first Xcode install; the phone restarts).
   - Pair.
   - Ruslan enters **his** Apple ID password for the `.child` authorization.
   - "All Apps & Categories" counted; Messages always allowed.
   - Notifications on.
5. **After setup:**
   - the dashboard shows the iPhone online;
   - usage grows after ~5 min of use;
   - a parent code unlocks for 5 min;
   - the shield shows when time is up.
   - Things that only `.child` changes, so check them on his phone:
     - Can he delete the app? It should need the parent.
     - Can he turn off Screen Time access for NesTimer?
     - Is Date & Time locked?
6. Release builds have **no Debug section**, so his debug log can't be copied. Debug on
   Ruslan's phone, or temporarily install a Debug build on the son's phone (that switches it
   to `.individual` auth, so not for real use).

## New facts learned on 2026-11-09 (don't relearn)

- `devicectl device copy from --domain-type appGroupDataContainer` is **refused** ("outside
  the directories the container access policy allows"). The App Group log can only be
  read through "Copy debug log" in a Debug build.
- DeviceActivity windows are armed with **minute** precision (`DateComponents` without
  seconds). Round the end of a non-minute edge up.
- A window whose start is in the past fires `intervalDidStart` at once when armed. The
  heartbeat relies on this, and it doesn't loop because the name is stable within a slot.
- Right after `restart daily`, iOS can fire a burst of events at once (lock and warn
  events while 11 min were left). The cap "usage can't grow faster than the clock" absorbs
  them. Keep it.
- In auto mode, writes to the production DB (`policies`) are blocked. Ask Ruslan to change
  rules in the dashboard for tests.
- Ruslan is at UTC+1. Debug-log timestamps are UTC.

## Open items outside the iOS work

- **Mac agent DST bug** (from the previous handoff, not started): after the 2026-10-25
  switch, downtime ended an hour early until a reboot. Hypothesis: the zone offset is
  cached at launch. Reproduce first (systematic debugging), then try
  `NSTimeZone.resetSystemTimeZone()` on `NSSystemTimeZoneDidChange` plus
  `TimeZone.autoupdatingCurrent`.
- Optional UI: during a bonus, show "Bonus until HH:MM" instead of the regular minutes
  left.
- Clean up the duplicate "Ruslan" child (`d4395e0e…`). Only with Ruslan's OK; it's a prod
  data change.
