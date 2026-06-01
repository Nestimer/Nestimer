# NesTimer Rename + Repo Move Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan phase-by-phase. Steps use checkbox (`- [ ]`) syntax for tracking. This is a refactor/migration, not a TDD feature — "verify" steps replace unit tests; build success is the test.

**Goal:** Rename the project from UsageTime* / `com.usagetime.*` to NesTimer / `com.nestimer.*` across code, identifiers, brand, infra, and move the repo to `github.com/Nestimer/Nestimer` at `/Users/ex/GitHub/Nestimer`.

**Architecture:** Three rename scopes executed in dependency order — (A) repo move, (B) brand/display, (C) identifiers (bundle IDs, Keychain services, Xcode target/folder names). Identifier changes ship with backward-compatible Keychain migration so the parent app keeps working; the agent's single installed device (son's Mac) is migrated by one-time manual reinstall.

**Tech Stack:** Xcode (Swift), FastAPI/PostgreSQL, React/Vite, GitHub Actions, Docker, nginx. Apple Developer team `CBBC6T33XY` (Global Tech Distribution s.r.o.).

**Naming map (authoritative):**
| Old | New |
|---|---|
| `com.usagetime.agent` | `com.nestimer.agent` |
| `com.usagetime.control` | `com.nestimer.control` |
| `com.usagetime.watchdog` | `com.nestimer.watchdog` |
| Keychain service `com.usagetime.agent` | `com.nestimer.agent` (+ fallback read of old) |
| Keychain service `com.usagetime.control` | `com.nestimer.control` (+ fallback read of old) |
| Xcode target/folder `UsageTimeAgent` | `NesTimerAgent` |
| Xcode target/folder `UsageTimeControl` | `NesTimer` |
| Display name `UsageTime` | `NesTimer` |
| Repo dir `UsageTimeController` | `Nestimer` |
| Remote `ruslan-splynx/UsageTimeController` | `Nestimer/Nestimer` |

**Known risk callouts:**
- pbxproj editing is the #1 sharp edge (CLAUDE.md). Target/folder renames (Phase 3) are highest-risk — done in Xcode GUI, not hand-edited.
- App Store Connect bundle ID is immutable → a NEW app record is required for `com.nestimer.control`; the old app `6775628165` is abandoned/archived.
- Changing the agent bundle ID + LaunchDaemon label means the OLD watchdog keeps the OLD agent alive on already-installed Macs → manual uninstall+reinstall required (Phase 6).

---

## Phase 0: Safety net

**Files:** none (git only)

- [ ] **Step 1: Confirm clean tree**

Run: `cd /Users/ex/GitHub/UsageTimeController && git status --short`
Expected: empty output.

- [ ] **Step 2: Tag the pre-rename state for rollback**

```bash
git tag pre-nestimer-rename
git rev-parse pre-nestimer-rename
```
Expected: prints the commit SHA (currently `6f053cf`).

- [ ] **Step 3: Create a working branch**

```bash
git switch -c rename/nestimer
git branch --show-current
```
Expected: `rename/nestimer`.

---

## Phase 1: Bundle IDs + Keychain migration (code keeps compiling)

**Files:**
- Modify: `macos-agent/UsageTimeAgent.xcodeproj/project.pbxproj` (2× `PRODUCT_BUNDLE_IDENTIFIER`)
- Modify: `ParentApp/UsageTimeControl.xcodeproj/project.pbxproj` (2× `PRODUCT_BUNDLE_IDENTIFIER`)
- Modify: `macos-agent/UsageTimeAgent/Services/KeychainStore.swift:7`
- Modify: `ParentApp/UsageTimeControl/Services/Keychain.swift:6`
- Modify: `macos-agent/UsageTimeAgent/Services/SystemInstaller.swift`, `macos-agent/UsageTimeAgent/Services/AgentConfig.swift` (any `com.usagetime.*` string refs)
- Modify: `macos-agent/Watchdog/com.usagetime.watchdog.plist`, `macos-agent/UsageTimeAgent/watchdog.plist`, `macos-agent/UsageTimeAgent/watchdog.sh`, `macos-agent/Watchdog/watchdog.sh`

- [ ] **Step 1: Swap bundle IDs in both pbxproj**

```bash
sed -i '' 's/com\.usagetime\.agent/com.nestimer.agent/g'   macos-agent/UsageTimeAgent.xcodeproj/project.pbxproj
sed -i '' 's/com\.usagetime\.control/com.nestimer.control/g' ParentApp/UsageTimeControl.xcodeproj/project.pbxproj
grep -n "PRODUCT_BUNDLE_IDENTIFIER" macos-agent/UsageTimeAgent.xcodeproj/project.pbxproj ParentApp/UsageTimeControl.xcodeproj/project.pbxproj
```
Expected: all show `com.nestimer.*`.

- [ ] **Step 2: Keychain service — add backward-compat fallback (agent)**

In `macos-agent/UsageTimeAgent/Services/KeychainStore.swift`, change:
```swift
    private static let service = "com.usagetime.agent"
```
to:
```swift
    private static let service = "com.nestimer.agent"
    private static let legacyService = "com.usagetime.agent"
```
Then in the read/`load` query path, after a miss on `service`, retry the same `SecItemCopyMatching` query with `kSecAttrService` = `legacyService`; if found, write it back under `service` and return it. (One-time migration so existing TOTP secret survives the rename.)

- [ ] **Step 3: Keychain service — same fallback (parent)**

Apply the identical change in `ParentApp/UsageTimeControl/Services/Keychain.swift:6` (`service` → `com.nestimer.control`, add `legacyService = "com.usagetime.control"`, fallback-read-then-rewrite).

- [ ] **Step 4: Watchdog label + plist bundle refs**

```bash
sed -i '' 's/com\.usagetime\.watchdog/com.nestimer.watchdog/g' \
  macos-agent/Watchdog/com.usagetime.watchdog.plist \
  macos-agent/UsageTimeAgent/watchdog.plist
git mv macos-agent/Watchdog/com.usagetime.watchdog.plist macos-agent/Watchdog/com.nestimer.watchdog.plist
sed -i '' 's/com\.usagetime\.agent/com.nestimer.agent/g; s/com\.usagetime\.watchdog/com.nestimer.watchdog/g' \
  macos-agent/Watchdog/watchdog.sh macos-agent/UsageTimeAgent/watchdog.sh
```
Then grep both `watchdog.sh` and `SystemInstaller.swift` for any remaining `com.usagetime` and the renamed plist filename; fix references (the installer copies the plist by name and `launchctl load`s `com.nestimer.watchdog`).

- [ ] **Step 5: Sweep for any remaining `com.usagetime` in code/scripts**

```bash
grep -rn "com\.usagetime" --include='*.swift' --include='*.sh' --include='*.plist' --include='*.entitlements' macos-agent ParentApp
```
Expected: empty (README/CLAUDE.md handled in Phase 2).

- [ ] **Step 6: Verify agent builds (Debug)**

```bash
xcodebuild -project macos-agent/UsageTimeAgent.xcodeproj -scheme UsageTimeAgent \
  -configuration Debug CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Verify parent builds (macOS Debug)**

```bash
xcodebuild -project ParentApp/UsageTimeControl.xcodeproj -scheme UsageTimeControl \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: rename bundle IDs and Keychain services to com.nestimer.*"
```

---

## Phase 2: Brand / display names

**Files:**
- Modify: `macos-agent/UsageTimeAgent.xcodeproj/project.pbxproj` (`INFOPLIST_KEY_CFBundleDisplayName = "UsageTime"` → `"NesTimer"`)
- Modify: `ParentApp/UsageTimeControl.xcodeproj/project.pbxproj` (add/confirm `INFOPLIST_KEY_CFBundleDisplayName = "NesTimer"`)
- Modify: `README.md`, `TESTING.md`, `CLAUDE.md`
- Modify: `website/index.html`, `website/style.css` (any "UsageTime" copy), `web-dashboard/index.html` (`<title>`), `web-dashboard/src/**` brand strings

- [ ] **Step 1: Agent display name**

```bash
sed -i '' 's/INFOPLIST_KEY_CFBundleDisplayName = "UsageTime"/INFOPLIST_KEY_CFBundleDisplayName = "NesTimer"/' macos-agent/UsageTimeAgent.xcodeproj/project.pbxproj
```

- [ ] **Step 2: Parent display name** — add `INFOPLIST_KEY_CFBundleDisplayName = "NesTimer";` to both build configs of the parent pbxproj (next to `PRODUCT_NAME`).

- [ ] **Step 3: Docs + web user-facing copy**

```bash
grep -rln "UsageTime" README.md TESTING.md website web-dashboard/src web-dashboard/index.html
```
For each hit, replace user-visible "UsageTime"/"UsageTimeController" with "NesTimer" (leave code identifiers alone — those are Phase 3). CLAUDE.md: update the rename note to reflect `com.nestimer.*` is now the identifier.

- [ ] **Step 4: Verify web builds**

```bash
cd web-dashboard && npm ci && npm run build 2>&1 | tail -3; cd ..
```
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: rebrand display names and docs to NesTimer"
```

---

## Phase 3: Xcode target / folder / project renames (GUI — highest risk)

> Do these in Xcode GUI, NOT by hand-editing pbxproj. Xcode rewrites all internal references atomically. After each rename, immediately build to catch breakage early.

**macos-agent: `UsageTimeAgent` → `NesTimerAgent`**

- [ ] **Step 1:** Open `macos-agent/UsageTimeAgent.xcodeproj`. In Project navigator click the target → slow-double-click the name → rename `UsageTimeAgent` → `NesTimerAgent`. Accept the "Rename project content items?" dialog. Repeat for the scheme (Product → Scheme → Manage Schemes) if not auto-renamed.
- [ ] **Step 2:** Quit Xcode. Rename on disk + fix the `.entitlements`/App file names:
```bash
cd macos-agent
git mv UsageTimeAgent NesTimerAgent
git mv NesTimerAgent/UsageTimeAgent.entitlements NesTimerAgent/NesTimerAgent.entitlements
git mv NesTimerAgent/UsageTimeAgentApp.swift NesTimerAgent/NesTimerAgentApp.swift
git mv UsageTimeAgentTests NesTimerAgentTests 2>/dev/null || true
git mv UsageTimeAgent.xcodeproj NesTimerAgent.xcodeproj
cd ..
```
- [ ] **Step 3:** Reopen `macos-agent/NesTimerAgent.xcodeproj`, fix any red (missing) file refs + `CODE_SIGN_ENTITLEMENTS` path → `NesTimerAgent/NesTimerAgent.entitlements`. Build Debug. Expected: `** BUILD SUCCEEDED **`.

**ParentApp: `UsageTimeControl` → `NesTimer`**

- [ ] **Step 4:** Open `ParentApp/UsageTimeControl.xcodeproj`, rename target `UsageTimeControl` → `NesTimer` (accept rename dialog), rename scheme.
- [ ] **Step 5:** Quit Xcode, rename on disk:
```bash
cd ParentApp
git mv UsageTimeControl/UsageTimeControlApp.swift UsageTimeControl/NesTimerApp.swift
git mv UsageTimeControl NesTimer
git mv UsageTimeControl.xcodeproj NesTimer.xcodeproj
cd ..
```
- [ ] **Step 6:** Reopen `ParentApp/NesTimer.xcodeproj`, fix file refs + `INFOPLIST_FILE` path (`NesTimer/Info.plist`). Build macOS + iOS-device. Expected: both succeed.

- [ ] **Step 7:** Update every script/CI/doc that hardcodes the old project/scheme/path names:
```bash
grep -rln "UsageTimeAgent\|UsageTimeControl" . | grep -v '.git/'
```
Fix `push-agent-update.sh` (`-project`, `-scheme`, `dist/UsageTimeAgent.app`, DerivedData glob), `.github/workflows/ci.yml`, `macos-agent/install*.sh`, CLAUDE.md build commands.

- [ ] **Step 8: Commit**
```bash
git add -A && git commit -m "refactor: rename Xcode targets and folders to NesTimer(Agent)"
```

---

## Phase 4: Apple Developer portal + App Store Connect (manual)

- [ ] **Step 1:** developer.apple.com → Identifiers → "+" → register **`com.nestimer.agent`** (macOS App) and **`com.nestimer.control`** (iOS App), team `CBBC6T33XY`.
- [ ] **Step 2:** appstoreconnect.apple.com → My Apps → "+" → New App, bundle ID `com.nestimer.control`, name "NesTimer", SKU `nestimer-parent-002`. (Old app `6775628165` on `com.usagetime.control` is now orphaned — leave it or remove later.)
- [ ] **Step 3:** In Xcode, archive the parent (`NesTimer` scheme, Any iOS Device) → Distribute → App Store Connect → Upload (`-allowProvisioningUpdates` auto-creates the new App Store profile under Apple Distribution). Verify the new build appears under the new app's TestFlight.
- [ ] **Step 4:** Re-add yourself to the new app's Internal Testing group; install via TestFlight to confirm the renamed app runs.

---

## Phase 5: Verify signed agent release end-to-end

- [ ] **Step 1:** Build signed agent Release with the new identifiers:
```bash
xcodebuild -project macos-agent/NesTimerAgent.xcodeproj -scheme NesTimerAgent \
  -configuration Release -derivedDataPath /tmp/nesagent \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM=CBBC6T33XY PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.
- [ ] **Step 2:** Verify signature + identifier:
```bash
codesign -dvv /tmp/nesagent/Build/Products/Release/NesTimerAgent.app 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Developer ID"
```
Expected: `Identifier=com.nestimer.agent`, `TeamIdentifier=CBBC6T33XY`, Developer ID authority.

---

## Phase 6: Agent installed-base migration (son's Mac — manual, one-time)

> The old agent persists under the old LaunchDaemon. Renaming breaks auto-update for it; migrate by hand once.

- [ ] **Step 1:** On the target Mac (as admin): unload + remove old daemon and app:
```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.usagetime.watchdog.plist 2>/dev/null || \
  sudo launchctl unload /Library/LaunchDaemons/com.usagetime.watchdog.plist
sudo rm -f /Library/LaunchDaemons/com.usagetime.watchdog.plist /usr/local/libexec/watchdog.sh
sudo rm -rf /Applications/UsageTimeAgent.app
```
- [ ] **Step 2:** Install the new signed/notarized `NesTimerAgent.app` (double-click → SystemInstaller installs `com.nestimer.watchdog` daemon). Confirm `sudo launchctl list | grep com.nestimer.watchdog` shows it running, and the TOTP unlock still works (Keychain fallback migrated the secret).

---

## Phase 7: Repo move to github.com/Nestimer/Nestimer

**Files:** none (git only). Target empty repo already exists at `/Users/ex/GitHub/Nestimer` with remote `https://github.com/Nestimer/Nestimer.git`.

- [ ] **Step 1:** Merge the rename branch back to main in the current repo:
```bash
cd /Users/ex/GitHub/UsageTimeController
git switch main && git merge --no-ff rename/nestimer -m "refactor: rename project to NesTimer"
```
- [ ] **Step 2:** Push full history (incl. tag) to the new remote:
```bash
git remote add nestimer https://github.com/Nestimer/Nestimer.git
git push nestimer main
git push nestimer pre-nestimer-rename
```
- [ ] **Step 3:** Make `/Users/ex/GitHub/Nestimer` the canonical clone:
```bash
rm -rf /Users/ex/GitHub/Nestimer
git clone https://github.com/Nestimer/Nestimer.git /Users/ex/GitHub/Nestimer
cd /Users/ex/GitHub/Nestimer && git log --oneline -8
```
Expected: full history present at the new path.
- [ ] **Step 4:** Archive the old working copy (don't delete until everything verified):
```bash
mv /Users/ex/GitHub/UsageTimeController /Users/ex/GitHub/UsageTimeController.archived
```

---

## Phase 8: Server-side rename (manual, on deploy host)

- [ ] **Step 1:** SSH to the server, re-point the deployed repo and nginx:
```bash
ssh root@134.209.8.62
cd ~ && git clone https://github.com/Nestimer/Nestimer.git Nestimer
# migrate data dir (DB volume, agent-update) from ~/UsageTimeController/data
cp -R ~/UsageTimeController/data ~/Nestimer/data
cd ~/Nestimer && docker compose up -d --build
```
- [ ] **Step 2:** Update `push-agent-update.sh` server-dir probe if needed (it already tries `~/UsageTimeController` and `/root/UsageTimeController` — add `~/Nestimer`).
- [ ] **Step 3:** Confirm API health + agent update endpoint, then retire the old server dir.

---

## Self-Review notes

- **Spec coverage:** A (Phase 7), B (Phase 2), C (Phases 1+3). Apple/infra/installed-base consequences of C covered in Phases 4–6, 8.
- **Domains touched:** macOS agent, parent app (iOS+macOS), web, docs, CI, Docker/nginx, Apple portal, two git remotes.
- **Ordering rationale:** identifiers + keychain first (keeps builds green with least churn), brand next (cosmetic), target/folder renames last among code (riskiest), then external/manual (portal, devices, remotes, server).
- **Rollback:** `git reset --hard pre-nestimer-rename` (code) + the old app `6775628165` and old agent install remain until Phase 4/6 confirmed.
