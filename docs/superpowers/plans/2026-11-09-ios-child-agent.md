# iOS Child Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iPhone app for the son. It counts his phone usage into the shared daily
budget and shields every app except Phone and Messages when the budget runs out or
downtime starts. It is paired and unlocked exactly like the Mac agent.

**Architecture:** All decisions live in a pure-Swift package, `NesTimerCore`. That covers
policy evaluation, remaining time, threshold and schedule planning, TOTP, setup parsing
and the sync engine. It is unit-tested with `swift test` on the Mac. A thin iOS layer
calls the engine from three processes: the app, a `DeviceActivityMonitor` extension and a
`ShieldConfiguration` extension. Each adapter maps engine calls onto one Apple API:
ManagedSettings, DeviceActivity, URLSession, Keychain, the App Group and notifications.
The project is generated with XcodeGen from `project.yml`, and the generated
`.xcodeproj` is committed so CI and Xcode don't need XcodeGen installed.

**Tech Stack:** Swift 6 / SwiftUI, FamilyControls, DeviceActivity, ManagedSettings,
ManagedSettingsUI, XCTest via SwiftPM, XcodeGen. FastAPI is unchanged; there are small
web-dashboard and ParentApp edits.

**Spec:** `docs/superpowers/specs/2026-11-09-ios-child-agent-design.md`

## Global Constraints

- iOS deployment target **17.4** (needs `includesPastActivity`).
- Bundle IDs: app `com.nestimer.child`, monitor `com.nestimer.child.monitor`,
  shield `com.nestimer.child.shield`. Team `CBBC6T33XY`.
- App Group `group.com.nestimer.child`. Keychain access group
  `CBBC6T33XY.com.nestimer.child`.
- Entitlement `com.apple.developer.family-controls` on all three targets.
- Authorization: `.child` in Release, `.individual` in Debug.
- Phone, Messages and NesTimer are **never shielded and never counted**.
- Counting chunk: **5 minutes**. Warnings at **15 / 10 / 5 / 1** minutes left (same as
  the Mac).
- TOTP: HMAC-SHA1, 300 s step, 6 digits, ±1 step. A code grants **5 minutes**, same as
  the Mac.
- Device token and TOTP secret live in the Keychain (shared group) only, never in
  UserDefaults or App Group files.
- When unsure, keep the shield (anti-goal: silent unlock).
- English only. Conventional commits. The NesTimer brand.
- `ios-agent/` is its own Xcode project; nothing from it goes into `ParentApp`.

## Review Focus

1. **Day rollover while shielded.** At 00:00 the daily schedule restarts and the local count
   must reset to 0 for the new date. Downtime that spans midnight must still hold. Test this
   in Task 5 (`testDateRolloverResetsCountButKeepsOvernightDowntime`).
2. **Server unreachable at a wake.** Policy is evaluated from the last snapshot plus the
   local count. With no snapshot, the shield stays on. Task 5
   (`testNoSnapshotOfflineShields`, `testStaleSnapshotUsesLocalCount`).
3. **Usage report fails, then the next one succeeds.** The total is absolute, so nothing
   is lost and nothing double-counts. Task 5 (`testFailedReportIsRetriedWithLatestTotal`).
4. **The parent lowers the limit below what the phone has already used.** The phone
   shields at the next wake and doesn't wait for a threshold that has already passed.
   Task 3 (`testRemainingZeroArmsNothingAndLocks`) and Task 5.
5. **Malformed setup string** (spaces, trailing slash, `http://` IP form, missing token).
   It is rejected or normalized the same way as the Mac, including the
   `134.209.8.62:8000` → `my.nestimer.com` migration. Task 1 (`SetupStringTests`).

---

### Task 0: Spike on Ruslan's iPhone (throwaway, decision gate)

Not TDD. Answers the six spike questions in the spec before any real code. The code is
deleted at the end of the task.

**Files:**
- Create (temporary): `spikes/ios-screentime/project.yml`, `App/SpikeApp.swift`,
  `Monitor/SpikeMonitor.swift`
- Modify: `docs/superpowers/specs/2026-11-09-ios-child-agent-design.md`. Add a
  `## Spike findings` section.

- [ ] **Step 1:** `brew install xcodegen`. Check with `xcodegen --version`.
- [ ] **Step 2:** Ask Ruslan to create a test device "Spike iPhone" (platform doesn't
  matter yet) in his own account in the dashboard and paste its setup string. Write it
  to the spike's `Secrets.xcconfig` (gitignored). Never commit it.
- [ ] **Step 3:** Write the spike: an app target and a monitor extension, both with the
  Family Controls entitlement and the App Group.
  - **App:** `.individual` auth, a `FamilyActivityPicker` for "everything" and for Phone +
    Messages, and a button that starts a daily activity with events at 5…60 min. It
    applies `shield.applicationCategories = .all(except:)` with the picked exemptions.
  - **Monitor:** on every callback, append `{callback, event, timestamp}` to an App Group
    log file and `POST /agent/usage` with the event minutes.
  - **App screen:** shows the log.
- [ ] **Step 4:** Run it on Ruslan's iPhone from Xcode. Ruslan uses the phone normally
  for ~1 hour, with the app killed and the screen locking between sessions.
- [ ] **Step 5:** Answer in `## Spike findings`, one line each with evidence (log lines,
  dashboard numbers):
  - Q1 events fire every 5 min of use;
  - Q2 extension HTTPS works;
  - Q3 "all apps" can be counted without picking each app, and whether Phone/Messages can
    be excluded from the event;
  - Q4 Phone and Messages stay usable under `.all(except:)`;
  - Q5 the event and activity limits;
  - Q6 callback lag.
- [ ] **Step 6: Gate.**
  - **Q2 = no** → stop and redesign with Ruslan.
  - **Q3: Phone/Messages can't be excluded from counting** → tell Ruslan and ask whether to
    count them or drop counting precision. Don't continue until he answers.
  - **Q5 limits below 20 activities / 20 events** → adjust the constants in Tasks 3–4
    before starting them.
- [ ] **Step 7:** `git rm -r spikes/` and commit the findings:
  `docs: iOS Screen Time spike findings`.

---

### Task 1: `NesTimerCore` package — models, remaining time, TOTP, setup string

**Files:**
- Create: `ios-agent/NesTimerCore/Package.swift` (library `NesTimerCore`, platforms
  `.iOS("17.4"), .macOS(.v14)`)
- Create: `Sources/NesTimerCore/ServerPolicy.swift`. Copy `ServerPolicy` +
  `ScheduledActivity` + `UsageReport` from `macos-agent/NesTimerAgent/Services/APIClient.swift:1-143`
  verbatim, and make them `public`, `Sendable`, `Equatable`.
- Create: `Sources/NesTimerCore/RemainingTime.swift`. Copy from
  `macos-agent/NesTimerAgent/Services/RemainingTime.swift` and make it public.
- Create: `Sources/NesTimerCore/TOTP.swift`. Port `TOTPGenerator`, but
  `verifyCode(secretHex:code:window:now:)` takes `now: Date` and uses CryptoKit
  `Insecure.SHA1`/`HMAC` instead of CommonCrypto.
- Create: `Sources/NesTimerCore/SetupString.swift`
- Test: `Tests/NesTimerCoreTests/{RemainingTimeTests,TOTPTests,SetupStringTests,ServerPolicyDecodingTests}.swift`

**Interfaces:**
- Produces:
  - `public struct ServerPolicy` (same fields and computed properties as the Mac),
    `public struct ScheduledActivity`.
  - `public enum RemainingTime { static func minutes(limitMinutes:childUsedMinutes:deviceCapMinutes:deviceUsedMinutes:) -> Double; static func binding(...) -> LimitSource }`
  - `public enum TOTP { static func code(secretHex: String, counter: UInt64) -> String?; static func verify(secretHex: String, code: String, now: Date, window: Int = 1) -> Bool }`
  - `public struct SetupString { let serverURL: URL; let token: String; static func parse(_ raw: String) -> SetupString? }`

- [ ] **Step 1: Write failing tests**
  - `TOTPTests.testRFC4226Vectors`: secret `"3132333435363738393031323334353637383930"`,
    counter 0 → `"755224"`, counter 1 → `"287082"`, counter 9 → `"520489"`.
  - `TOTPTests.testVerifyAcceptsPlusMinusOneStep`: `now = Date(timeIntervalSince1970: 3000)`
    (counter 10). The codes for counters 9, 10 and 11 verify; the code for 12 doesn't.
  - `SetupStringTests`:
    - `"https://my.nestimer.com|abc"` → url `https://my.nestimer.com`, token `abc`;
    - `"  https://my.nestimer.com/|abc \n"` → trimmed, trailing slash dropped;
    - `"http://134.209.8.62:8000|abc"` → url `https://my.nestimer.com` (migration);
    - `"https://my.nestimer.com|"`, `"|abc"`, `"abc"` and `"a|b|c"` → nil.
  - `RemainingTimeTests`: port every `check(...)` case from
    `macos-agent/NesTimerAgentTests/run-logic-tests.sh` that targets `RemainingTime`.
  - `ServerPolicyDecodingTests`: decode a JSON without `device_used_minutes` /
    `device_cap_minutes`. It doesn't throw, and `reportsDeviceUsage == false`.
- [ ] **Step 2:** `cd ios-agent/NesTimerCore && swift test`. Expected: compile failure
  (types missing).
- [ ] **Step 3:** Implement. `SetupString.parse`:
  1. trims whitespace;
  2. splits on `|` and needs exactly 2 non-empty parts;
  3. applies the same URL migration as `AgentConfig.migrateServerURL`;
  4. drops a trailing `/`;
  5. needs an `http`/`https` scheme.
- [ ] **Step 4:** `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(ios): NesTimerCore package with policy models, TOTP and setup parsing`.

---

### Task 2: `PolicyEvaluator` — the Mac evaluation order as a pure function

**Files:**
- Create: `ios-agent/NesTimerCore/Sources/NesTimerCore/PolicyEvaluator.swift`
- Test: `Tests/NesTimerCoreTests/PolicyEvaluatorTests.swift`

**Interfaces:**
- Consumes: `ServerPolicy`, `ScheduledActivity`, `RemainingTime` (Task 1).
- Produces:
  ```swift
  public enum ShieldReason: Equatable, Sendable { case downtime(until: String), timeExpired, deviceCapReached }
  public enum Decision: Equatable, Sendable {
      case open(remainingMinutes: Double?, why: OpenReason)   // nil remaining = no limit
      case shield(ShieldReason)
  }
  public enum OpenReason: Equatable, Sendable { case activity(endsAt: String), temporaryUnlock, bonus, withinLimit, noLimit }
  public enum PolicyEvaluator {
      static func evaluate(policy: ServerPolicy, deviceUsedMinutes: Double, unlockUntil: Date?,
                           now: Date, calendar: Calendar) -> Decision
  }
  ```

The order matches `PolicyEnforcer.evaluate` (`macos-agent/.../PolicyEnforcer.swift:94-188`):
activity → TOTP unlock → bonus → downtime → remaining < 1 → open. Port
`isInDowntime`, `parseTimeToMinutes` and `findActiveActivity` with `now`/`calendar`
injected.

The child total for `RemainingTime` comes from the server snapshot plus local growth:
`childUsed = policy.otherDevicesUsed + deviceUsedMinutes`.

- [ ] **Step 1: Write failing tests.** All use a fixed `calendar` (Europe/Kyiv) and dates
  built from components.
  - `testActivityBeatsDowntime`: downtime 21:00–07:00, an activity Mon 22:00–23:00 with
    buffers 0, now Mon 22:30 → `.open(_, .activity(endsAt: "23:00"))`.
  - `testTemporaryUnlockBeatsLimit`: limit 60, used 90, `unlockUntil` = now + 3 min →
    `.open(_, .temporaryUnlock)`.
  - `testExpiredUnlockIgnored`: `unlockUntil` = now − 1 s → `.shield(.timeExpired)`.
  - `testBonusBeatsDowntime`: `bonus_until` = now + 10 min during downtime → `.open(_, .bonus)`.
  - `testOvernightDowntime`: 22:00–08:00. 23:00 and 07:59 → shield. 08:00 → open.
  - `testDowntimeStartEqualsEndIsNoDowntime`: 08:00–08:00 → open.
  - `testRemainingBelowOneShields`: limit 60, other devices 30, device used 29.5 →
    `.shield(.timeExpired)`.
  - `testDeviceCapBinds`: limit 120, other devices 0, cap 30, device used 30 →
    `.shield(.deviceCapReached)`.
  - `testScreenTimeDisabledOpensWithNilRemaining` → `.open(nil, .noLimit)`.
  - `testOvernightActivityFromYesterday`: Sun 23:00–01:00, now Mon 00:30 → open (activity).
- [ ] **Step 2:** `swift test --filter PolicyEvaluatorTests`. Expected: FAIL (type missing).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(ios): pure PolicyEvaluator mirroring the Mac evaluation order`.

---

### Task 3: `ThresholdPlanner` — which usage events to arm

**Files:**
- Create: `ios-agent/NesTimerCore/Sources/NesTimerCore/ThresholdPlanner.swift`
- Test: `Tests/NesTimerCoreTests/ThresholdPlannerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct PlannedEvent: Equatable, Sendable { public let name: String; public let deviceMinutes: Int; public let kind: Kind
      public enum Kind: Equatable, Sendable { case chunk, warning(minutesLeft: Int), lock, unlockEnd } }
  public enum ThresholdPlanner {
      static let chunk = 5
      static let maxEvents = 20   // adjust from spike Q5
      static func plan(deviceUsedMinutes: Double, remainingMinutes: Double?, unlockEndsAfterMinutes: Int?) -> [PlannedEvent]
  }
  ```
  `deviceMinutes` is the cumulative device-usage value for today at which the event fires.
  Names are stable and unique (`"chunk-35"`, `"warn-5"`, `"lock"`, `"unlock-end"`).

Rules:
- Chunk events go at the next multiples of 5 above `deviceUsedMinutes`.
- With a finite `remainingMinutes`:
  - `lock` at `ceil(deviceUsed + remaining)`;
  - `warning(n)` at `ceil(deviceUsed + remaining − n)` for each n in [15, 10, 5, 1] that is
    still ahead of `deviceUsed`;
  - chunks only up to the lock point.
- `unlock-end` at `ceil(deviceUsed) + unlockEndsAfterMinutes` when it is given.
- Never more than `maxEvents`. Drop the furthest chunks first. `lock`, warnings and
  `unlock-end` are never dropped.

- [ ] **Step 1: Write failing tests**
  - `testChunksFromZeroNoLimit`: used 0, remaining nil → chunks 5,10,…,100 (20 events).
  - `testLockAndWarnings`: used 12, remaining 20 → lock at 32; warnings at 17 (15 left),
    22 (10 left), 27 (5 left), 31 (1 left); chunks 15, 20, 25, 30; nothing > 32.
  - `testRemainingZeroArmsNothingAndLocks`: used 50, remaining 0 → `[]` (the caller has
    already shielded via the PolicyEvaluator).
  - `testUnlockEnd`: used 40.2, remaining 0, unlockEndsAfter 5 → exactly
    `[unlock-end @ 46]`.
  - `testCapAtMaxEventsKeepsLockAndWarnings`: used 0, remaining 300 → count == 20, and
    contains `lock` and all 4 warnings.
- [ ] **Step 2:** `swift test --filter ThresholdPlannerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(ios): ThresholdPlanner for usage events`.

---

### Task 4: `SchedulePlanner` — downtime and activity windows for the next 24 h

**Files:**
- Create: `ios-agent/NesTimerCore/Sources/NesTimerCore/SchedulePlanner.swift`
- Test: `Tests/NesTimerCoreTests/SchedulePlannerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct PlannedWindow: Equatable, Sendable { public let name: String; public let start: Date; public let end: Date; public let kind: Kind
      public enum Kind: Equatable, Sendable { case downtime, activity } }
  public enum SchedulePlanner {
      static let minimumLength: TimeInterval = 15 * 60
      static let maxWindows = 18   // 20 activities − daily counter − 1 spare; adjust from spike Q5
      static func plan(policy: ServerPolicy, now: Date, calendar: Calendar, horizon: TimeInterval = 24 * 3600) -> [PlannedWindow]
  }
  ```

Rules:
- Windows are the policy's downtime (today's, as resolved by the server) and the enabled
  activities with buffers, clipped to `[now, now + horizon]`. A window that is already in
  progress starts at `now`.
- Windows shorter than 15 min are extended at the **end** to 15 min.
- Sorted by start and truncated to `maxWindows`.
- Names are `"downtime-<yyyyMMddHHmm>"` / `"activity-<id>-<yyyyMMddHHmm>"`.

Weekday/weekend downtime needs no extra logic here: the server already returns the
downtime for the `?date=` it was asked about, and the planner is re-run at every wake,
including the 00:00 daily boundary.

- [ ] **Step 1: Write failing tests**
  - `testOvernightDowntimeFromEvening`: downtime 22:00–07:00, now 20:00 → one window
    22:00 → next day 07:00.
  - `testInProgressDowntimeStartsNow`: now 23:30 → a window starting 23:30.
  - `testShortActivityPaddedTo15`: activity 10:00–10:05 with 0 buffers → 10:00–10:15.
  - `testActivityBuffersApplied`: 16:00–17:00, buffers 5/5 → 15:55–17:05.
  - `testDisabledActivitySkipped`.
  - `testTruncatedToMax`: 30 activities in 24 h → 18 windows, the earliest kept.
- [ ] **Step 2:** `swift test --filter SchedulePlannerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(ios): SchedulePlanner for downtime and activity windows`.

---

### Task 5: `SyncEngine` — what every wake does (risk point: fail-closed logic)

**Files:**
- Create: `ios-agent/NesTimerCore/Sources/NesTimerCore/SyncEngine.swift`,
  `Sources/NesTimerCore/Ports.swift`
- Test: `Tests/NesTimerCoreTests/SyncEngineTests.swift` (with in-memory fakes for every port)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces (`Ports.swift`):
  ```swift
  public protocol AgentAPI: Sendable { func fetchConfig(localDate: String) async throws -> ServerPolicy
      func reportUsage(date: String, totalMinutes: Double) async throws
      func verifyTOTP(code: String) async throws -> Bool }
  public protocol StateStore: Sendable { func load() -> AgentState; func save(_ s: AgentState) }
  public protocol Shield: Sendable { func apply(_ reason: ShieldReason); func remove() }
  public protocol MonitorScheduler: Sendable { func arm(events: [PlannedEvent], windows: [PlannedWindow]) throws }
  public protocol Notifier: Sendable { func warn(minutesLeft: Int); func expired() }
  public protocol SecretStore: Sendable { func totpSecret() -> String? }
  public struct AgentState: Codable, Equatable, Sendable {
      public var date: String               // yyyy-MM-dd local
      public var deviceUsedMinutes: Double  // monotonic within `date`
      public var reportedMinutes: Double    // last total the server acknowledged
      public var snapshot: ServerPolicy?
      public var snapshotAt: Date?
      public var unlockUntil: Date?
      public var unlockEndsAtDeviceMinutes: Int?
      public var warned: Set<Int> }
  ```
  `SyncEngine(api:store:shield:scheduler:notifier:secrets:calendar:now:)` with:
  - `func onThreshold(eventName: String, deviceMinutes: Int) async -> Decision`
  - `func onIntervalBoundary() async -> Decision`
  - `func onForeground() async -> Decision`
  - `func submitCode(_ code: String) async -> Bool`

Every `on*` call follows the same sequence:
1. Roll the date over if needed.
2. Raise `deviceUsedMinutes` to max(current, reported).
3. If the total isn't reported yet, report it. On failure, keep the gap; it is resent
   next time.
4. Fetch config. On success, store the snapshot.
5. Evaluate with `snapshot` (fresh or last known). With **no snapshot at all**, shield as
   `.timeExpired`.
6. Apply or remove the shield.
7. Fire warnings that were crossed and not yet sent, plus `expired()` on the transition
   to shield.
8. Re-arm the planners.

`submitCode`:
1. Try server verify first. On a network error, fall back to `TOTP.verify` with the
   Keychain secret.
2. On success, set `unlockUntil` = now + 5 min and `unlockEndsAtDeviceMinutes` = 5.
3. Remove the shield and re-arm.

An `unlock-end` event clears both fields and re-evaluates.

- [ ] **Step 1: Write failing tests**
  - `testNoSnapshotOfflineShields`: the API throws, the store is empty →
    `.shield(.timeExpired)` and `shield.applied == [.timeExpired]`.
  - `testStaleSnapshotUsesLocalCount`: snapshot limit 60, other devices 0, then the API
    throws on `onThreshold(deviceMinutes: 60)` → shield.
  - `testFailedReportIsRetriedWithLatestTotal`: the report throws at 10, succeeds at 15 →
    the API received `[10 (failed), 15]` and `reportedMinutes == 15`.
  - `testDateRolloverResetsCountButKeepsOvernightDowntime`: state date "2026-11-09",
    used 80. Now 2026-11-10 00:00 with downtime 22:00–07:00 → used 0, and the decision is
    `.shield(.downtime)`.
  - `testDeviceMinutesNeverDecrease`: `onThreshold(deviceMinutes: 20)` after state 25 →
    state stays 25.
  - `testLimitLoweredBelowUsedShieldsImmediately`: used 40, new snapshot limit 30 →
    shield on that wake, and the scheduler is armed with no `lock` event.
  - `testCodeOnlineGrantsFiveMinutes`, `testCodeOfflineFallsBackToKeychainSecret`
    (verify throws; a valid code for the fake secret at `now` → true),
    `testWrongCodeKeepsShield`.
  - `testWarningsFireOnceEach`: two wakes at 5 min left → `notifier.warnings == [15,10,5]`
    once. A raised limit (remaining > 15) resets `warned`.
- [ ] **Step 2:** `swift test --filter SyncEngineTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test`. Expected: all pass.
- [ ] **Step 5:** **Risk-point review.** Dispatch an independent reviewer on
  `SyncEngine.swift` + tests. Brief: "find any path where the phone ends up unshielded
  during downtime or after the budget is spent without a parent action". Fix the findings
  and re-run `swift test`.
- [ ] **Step 6:** Commit `feat(ios): SyncEngine with fail-closed wake handling`.

---

### Task 6: Xcode project + iOS adapters

**Files:**
- Create: `ios-agent/project.yml`, defining:
  - targets `NesTimerChild` (app), `NesTimerMonitor` (`com.apple.deviceactivity.monitor-extension`)
    and `NesTimerShield` (`com.apple.ManagedSettingsUI.shield-configuration-service`);
  - the local package dependency `NesTimerCore`;
  - entitlements per Global Constraints;
  - `DEVELOPMENT_TEAM = CBBC6T33XY`, `MARKETING_VERSION = 1.0.0`;
  - `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`.
- Create: `ios-agent/Shared/` (compiled into all three targets):
  - `KeychainSecretStore.swift`: access group, keys `apiToken`, `totpSecret`, `serverURL`.
  - `AppGroupStateStore.swift`: JSON file `state.json` in the group container.
  - `URLSessionAgentAPI.swift`: same paths, headers and `?date=&version=` as
    `macos-agent/.../APIClient.swift`; the version is `CFBundleShortVersionString`.
  - `ManagedSettingsShield.swift`:
    - applies `shield.applicationCategories = .all(except:)` and
      `shield.webDomainCategories = .all()`;
    - reads the exemption tokens from the App Group (written by Task 7);
    - writes the `ShieldReason` to the App Group for the shield extension.
  - `DeviceActivityMonitorScheduler.swift`:
    - stops all activities;
    - starts the `daily` activity (00:00–23:59, repeats) with `DeviceActivityEvent`s from
      the planned events, threshold in minutes, `includesPastActivity: true`, counting all
      categories except the exemptions, per the spike;
    - starts one non-repeating activity per `PlannedWindow`.
  - `LocalNotifier.swift`: `UNUserNotificationCenter`. Copy text: "N minutes of screen
    time left" / "Screen time is up".
- Create: `ios-agent/NesTimerMonitor/MonitorExtension.swift`
  - It builds a `SyncEngine` from the Shared adapters and routes callbacks:
    - `eventDidReachThreshold` → `onThreshold`;
    - `intervalDidStart` / `intervalDidEnd` → `onIntervalBoundary`.
- Create: `ios-agent/NesTimerShield/ShieldExtension.swift`
  - Title "NesTimer", subtitle per reason:
    - "Downtime until HH:MM"
    - "Today's screen time is used up"
    - "This iPhone's daily limit is reached"
  - Footer for every reason: "Open NesTimer to enter a code".
- Generated and committed: `ios-agent/NesTimerChild.xcodeproj`.

- [ ] **Step 1:** `cd ios-agent && xcodegen generate`.
- [ ] **Step 2:** Build:
  ```bash
  xcodebuild -project ios-agent/NesTimerChild.xcodeproj -scheme NesTimerChild \
    -destination 'generic/platform=iOS Simulator' build
  ```
  Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 3:** `cd ios-agent/NesTimerCore && swift test`. Expected: still green.
- [ ] **Step 4:** Commit `feat(ios): NesTimerChild project with monitor and shield extensions`.

---

### Task 7: App UI — setup, status, code entry

**Files:**
- Create: `ios-agent/NesTimerChild/NesTimerChildApp.swift`, `Views/SetupView.swift`,
  `Views/StatusView.swift`, `Views/CodeEntryView.swift`

**Interfaces:**
- Consumes: `SetupString.parse`, `SyncEngine`, the Shared adapters.

Behaviour:
- **Setup**, shown until the Keychain has a token:
  1. A text field for the setup string, with "Paste" and "Connect" buttons. An invalid
     string shows "That doesn't look like a NesTimer setup string."
  2. Connect stores the URL and token in the Keychain and fetches `/agent/totp-secret`
     into the Keychain.
  3. Calls `requestAuthorization(for: .child)` (Debug: `.individual`).
  4. Shows a `FamilyActivityPicker` with the text "Tick Phone and Messages — they'll
     always stay available". It stores the selection tokens in the App Group, unless the
     spike showed this isn't needed.
  5. Calls `engine.onForeground()`.
- **Status:**
  - remaining time ("1 h 12 m left today" / "No limit today");
  - state ("Open" / the lock reason);
  - the last sync time;
  - a "Have a code from your parent?" field. It auto-submits at 6 digits, the same as the
    Mac lock screen, and calls `engine.submitCode`.
  - On `scenePhase == .active` it calls `onForeground()`.
- Debug builds only: a "Reset pairing" button.

- [ ] **Step 1:** Implement, regenerate the project and build (same command as Task 6).
  Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 2:** Commit `feat(ios): setup, status and code entry screens`.

---

### Task 8: Parent side — platform choice and iOS staleness

**Files:**
- Modify: `web-dashboard/src/pages/DevicesPage.jsx`
  - Add a platform `<select>` (macOS / iPhone) to the add form (around line 168) and pass
    `platform` to `api.createDevice` (line 98).
  - `isStale(device)` uses `24 * 60 * 60 * 1000` when `device.platform === 'ios'`,
    otherwise `STALE_AFTER_MS`.
  - Show the platform icon/label on the device card.
- Modify: `ParentApp/NesTimer/Views/AddDeviceView.swift` and `APIClient.createDevice`:
  a Mac / iPhone segmented picker, passing `platform`.
- Test: `api/tests/test_devices.py`

- [ ] **Step 1: Write a failing test** (if not already covered):
  `test_create_ios_device_roundtrips_platform`. POST `/api/v1/devices` with
  `platform: "ios"`; GET list → `platform == "ios"`; `/agent/config` with its token → 200.
- [ ] **Step 2:** Run it with the env from the local-API-tests memory:
  ```bash
  DATABASE_URL=… SECRET_KEY=… TESTING=1 api/.venv/bin/pytest api/tests/test_devices.py -k ios -v
  ```
  If it already passes, keep it as a regression test.
- [ ] **Step 3:** Implement the web and ParentApp changes.
- [ ] **Step 4:** Check:
  - `cd web-dashboard && npm run build` succeeds;
  - the ParentApp macOS build from CLAUDE.md succeeds;
  - the full API suite is green.
- [ ] **Step 5:** Commit `feat: choose iPhone as a device platform; iPhones go stale after 24 h`.

---

### Task 9: CI

**Files:**
- Modify: `.github/workflows/ci.yml`. Add a job `ios-child` on `macos-latest`:
  - `swift test --package-path ios-agent/NesTimerCore`;
  - the Task 6 simulator build with `CODE_SIGNING_ALLOWED=NO`.

- [ ] **Step 1:** Edit, push the branch, and confirm the new job is green with `gh run watch`.
- [ ] **Step 2:** Commit `ci: build and test the iOS child agent`.

---

### Task 10: Device run on Ruslan's iPhone (rollout step 2)

Manual. Debug build (`.individual`), paired to a test device in Ruslan's account.

- [ ] **Step 1:** Install from Xcode. Pair. Set the test device's limit to 15 min in the
  dashboard.
- [ ] **Step 2:** Run the checklist below and record each result as a comment in the PR:
  1. Usage appears on the dashboard in 5-min steps.
  2. A notification comes at 10 min left. The shield appears at 15 min.
  3. Phone and Messages still open.
  4. A parent code in NesTimer opens the phone. It re-shields after 5 more minutes of use.
  5. Downtime starting in 20 min → the shield at the start.
  6. An activity window opens a shielded phone.
  7. A parent bonus + opening NesTimer → the shield is gone.
  8. Airplane mode + use past the limit → shield. The code works offline.
  9. After midnight, the count resets.
- [ ] **Step 3:** Fix any failures through Tasks 2–7 (with a test first where the logic
  is in Core).

---

### Task 11: App Store submission prep

**Files:**
- Create: `website/privacy.html`.
  - Plain English, styled with `website/style.css`.
  - What the child app sends: usage minutes per day, app version, last seen. What it
    doesn't: which apps, content, location.
  - No third parties; data on the NesTimer server.
  - Contact email: Ruslan to confirm.
  - Link it from the `index.html` footer.
- Create: `ios-agent/AppStore/review-notes.md`: what Family Controls is used for, how to
  pair (a demo setup string for a reviewer test device), and why Phone/Messages are exempt.
- Create: `push-ios-child.sh`. Model it on `push-ios-testflight.sh`: archive
  `NesTimerChild`, export, upload, auto-bump the build number.

- [ ] **Step 1:** Write the files. Ask Ruslan for the contact email and to create the
  "App Review" test device.
- [ ] **Step 2:** Deploy the privacy page (marketing-site command in CLAUDE.md). Check
  `curl -sI https://nestimer.com/privacy.html` → `200`.
- [ ] **Step 3:** Run `./push-ios-child.sh`. The build appears in App Store Connect.
- [ ] **Step 4:** **Stop.** Hand Ruslan the review notes. He creates the App Store record
  (screenshots, age rating, category) and submits for review himself. The submission is
  his action.
- [ ] **Step 5:** Commit `chore(ios): privacy policy, review notes, upload script`.

---

### Task 12: Son's iPhone (rollout step 5) — after review

- [ ] **Step 1:** Approved → install from the App Store on the son's phone. Rejected →
  a Development build via Xcode with developer mode on; record the profile expiry date in
  the project memory, and open a follow-up for the spec's "parent app warns before the
  expiry date" (the app reports `version`; the build's expiry date goes in a new
  `?expires=` query parameter — designed then, not now).
- [ ] **Step 2:** Pair with a new `ios` device under the son's child record. The parent
  approves `.child` authorization on the son's phone.
- [ ] **Step 3:** Re-run the Task 10 checklist items 1–4. Confirm that his phone's minutes
  add into the shared budget alongside his Macs on the dashboard.
