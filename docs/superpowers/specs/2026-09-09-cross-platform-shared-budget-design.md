# Cross-platform shared time budget (Mac + Android + iPhone)

**Date:** 2026-09-09
**Status:** Approved design, not yet implemented

## Problem

Screen time is currently tracked and enforced per *device*. The child uses a Mac and
an Android phone, and will move to an iPhone soon. Today he can spend the full daily
limit on the Mac and then the full limit again on the phone, and the parent has no
single place to see or set the rules.

There is no `Child` entity — `Device.child_name` is a free-text string, and `Policy`,
`Activity` and `bonus_until` all hang off `Device`.

## Goals

- One daily time budget per child, shared across all their devices.
- An optional per-device ceiling within that budget ("at most 1h of the 2h on the phone").
- One place for the parent to set rules and grant bonus time.
- Room for a third and fourth platform without redesigning the backend.

## Non-goals

- Tamper-proof enforcement on Android. Explicitly rejected: Device Owner enrolment
  requires a factory reset, and the parent chose not to do that.
- Blocking on Android at all in the first release (see "Android" below).
- Per-app rules or content filtering on any platform.
- Handling devices in different timezones (see "Accepted limitations").

## Approach

Two decisions, chosen over the alternatives in "Alternatives considered":

**The server owns the counter; the client owns the verdict.**
The server aggregates a single daily total per child. Each client still decides
locally whether to lock, exactly as `PolicyEnforcer` does today.

The reason is offline behaviour. If the server returned the lock/unlock verdict, a
client that loses network has no verdict and needs local logic as a fallback — so the
policy logic gets implemented locally *anyway*, and the server version is a second
implementation on top. Centralising the counter (which must be shared) while keeping
the verdict local (which must work offline) puts each piece where it has to live.

The cost is that policy evaluation exists once per platform. This is accepted: the
logic is small (a downtime window plus a remaining-minutes comparison), and the
project already carries three TOTP implementations for the same kind of reason.

**Android counts, it does not block.**
A soft overlay is bypassable by an adaptive child within a day, so building one is
weeks of work for a lock that does not hold. Time spent on the phone still drains the
shared budget, so the Mac locks sooner — the bypass costs him Mac time either way.

## Data model

### New: `Child`

| Column | Type | Notes |
|---|---|---|
| `id` | String PK | uuid |
| `owner_id` | FK → `users.id` | |
| `name` | String | |
| `bonus_until` | DateTime(tz) nullable | moved from `Device` |
| `created_at` | DateTime(tz) | |

### Changed: `Device`

- `child_id` — FK → `children.id`; nullable during the two-phase migration, `NOT NULL`
  once backfilled. Creating a device afterwards requires a child: the parent API
  creates one from the supplied name if no `child_id` is given, so the existing
  "add a device" flow keeps working unchanged.
- `platform` — `macos` | `android` | `ios`
- `daily_cap_minutes` — Integer nullable; null means no per-device ceiling
- `child_name` — retained until the parent UI migrates, then dropped
- `bonus_until` — moves to `Child`

### Moved to `Child`

- `Policy.device_id` → `Policy.child_id`, and the `unique=True` constraint moves with
  it — one policy per child, as there is today one policy per device.
- `Activity.device_id` → `Activity.child_id`

A scheduled activity (English class) applies to the child, not to a laptop. Same for
parent-granted bonus time.

### Unchanged: `Device.shared_secret` (TOTP)

The TOTP secret stays per-device. Each device keeps its own secret in its own Keychain,
the parent app already shows a code per device, and nothing about a shared budget
requires one child to have one secret. Moving it would be churn with no benefit and
would force every installed agent to re-fetch.

### Unchanged: `UsageLog`

`UsageLog` keeps `(device_id, date)` with an absolute `total_minutes`, and this is
load-bearing. `POST /agent/usage` already sends an absolute total for a date rather
than a delta, so:

- each device stays authoritative for its own counter and rewrites it idempotently
- the child's shared usage is `SUM(total_minutes)` over the child's devices for that date
- a device that was offline catches up by sending its absolute total on reconnect
- Mac and Android cannot race — they write different rows

No delta protocol, no double-counting, no reconciliation logic.

### Remaining-time formula (evaluated on the client)

```
remaining = min(shared_limit - child_used_today,
                device_cap    - device_used_today)   # second term only if a cap is set
```

## Migration

**Strictly 1:1.** Every existing `Device` gets its own `Child`, named from its
`child_name`; its policy and activities move to that child. Behaviour after migration
is byte-identical to before. Merging two Macs under one child is an explicit parent
action in the UI, never a guess by the migration.

Silently merging devices that share a `child_name` would halve the effective limit for
real users without warning.

**Two-phase column move.** This runs against a live production database with a real
external user. `Policy.device_id` → `child_id` is done by adding `child_id` as
nullable, backfilling it, and leaving `device_id` in place for one release before
dropping it. If the API has to be rolled back, a destroyed column would orphan every
policy and leave the child's Mac unrestricted. Dump the database before migrating.

## API

### `/agent/config`

`used_minutes_today` changes meaning: it becomes the child's total across all devices
rather than this device's total.

This is what makes already-installed agents work. Agent 2.9 in the field reads
`used_minutes_today` and compares it against `screen_time_limit_minutes`; once the
backend aggregates, it honours the shared budget **with no agent update pushed**.

Two additive optional fields:

- `device_used_minutes` — this device's own total
- `device_cap_minutes` — the per-device ceiling, nullable

Swift's `JSONDecoder` ignores unknown keys, so old agents are unaffected. The
per-device ceiling therefore takes effect only after the agent is updated; the shared
budget takes effect immediately.

### `/agent/usage`

Unchanged.

### Android needs no new endpoints

Auth is already by device token and the contract is identical. The Android client is
another consumer of the existing `/agent/config` + `/agent/usage` with
`platform=android`. This is the payoff for keeping the verdict on the client.

### Parent API

Adds `/children` (CRUD, device assignment, merge). Policy and activities move to
`/children/{id}/...`.

`/devices/{id}/policy`, `/devices/{id}/activities` and `/devices/{id}/bonus` remain as
aliases that resolve a device to its child. The parent iOS app ships through
TestFlight and cannot be updated in lockstep with the backend, and the web dashboard
deploys separately. Breaking them on a backend deploy is the fastest way to lose
control of the child's Mac on a weeknight.

## Clients

### macOS agent

`evaluate()` already takes `usedMinutesToday`, and the remaining calculation is one
line (`PolicyEnforcer.swift:128`). Changes:

1. `ServerPolicy` decodes the two new optional fields.
2. Remaining becomes the `min(...)` above.
3. New `LockReason` case so the lock screen says "time used up on this Mac" rather
   than "time used up" when the per-device ceiling is what binds. Otherwise the child
   sees budget left in the menu bar and correctly reads it as a bug.
4. Warning-threshold reset currently keys off `lastPolicyLimitMinutes`; it must also
   reset when the cap changes.

### Android counter

Kotlin, foreground service with a persistent notification (Android kills the process
otherwise):

- **Counting** — `UsageStatsManager` over `ACTIVITY_RESUMED`/`PAUSED` events, i.e.
  foreground time. Counting screen-on time would be dishonest: the phone can sit
  unlocked on a table.
- **Permission** — `PACKAGE_USAGE_STATS` is special access, granted by hand in
  Settings; it cannot be requested programmatically.
- **Pairing** — the same `URL|TOKEN` string the Mac agent uses, delivered by QR from
  the parent app instead of typed.
- **Survival** — `BOOT_COMPLETED` receiver plus a battery-optimisation exemption.
  Without the exemption the service dies silently after a few hours.
- **No blocking.**

### Silence detection

The child can force-stop the app or revoke usage access, and this cannot be prevented
in the chosen model. It can be made visible: the server already records `last_seen`,
so the parent app surfaces "phone hasn't reported since 16:20" when a device goes
quiet during allowed hours. The bypass stops being free and invisible, which suits an
adaptive child better than an overlay he will simply remove.

### iOS (later)

Requires the Family Controls distribution entitlement, requested separately from this
work (~3 weeks, Account Holder only).

**Known constraint:** the `DeviceActivityReport` extension runs in a privacy sandbox
with no network access, so real screen-time minutes cannot be exfiltrated to the
server the way the Mac agent reports them. The workaround is threshold events —
`DeviceActivityMonitor.eventDidReachThreshold` — which lets the iPhone contribute to
the shared budget in discrete chunks (roughly 5–15 min) rather than continuously.

This needs a spike before iOS implementation starts; the constraint is well
established, but the real-world behaviour of threshold events should be verified by
hand rather than assumed.

## Testing

Existing suite runs on in-memory SQLite with `TESTING=1`. Added, TDD, failing first:

- **Migration changes nothing** — golden test: the `/agent/config` response for an
  existing device is identical before and after migration. This is the primary test of
  the whole change.
- **Shared budget** — two devices under one child, usage on each, `used_minutes_today`
  equals the sum.
- **Idempotency** — re-POSTing the same absolute total does not double-count.
- **Ceiling** — when the per-device cap is tighter than the shared limit, the cap binds.
- **Aliases live** — `/devices/{id}/policy` and `/devices/{id}/bonus` still work after
  policy moves to the child.

## Rollout

Ordered so every step can be halted:

1. Backend + 1:1 migration → **nothing changes in production**; verified against the
   three existing devices.
2. Child management in the parent UI → merge the two Macs under one child → shared
   budget activates **on already-installed 2.9 agents, with no update**.
3. Agent update → the per-device ceiling starts applying.
4. Android counter.
5. iOS, once both the phone and the entitlement exist.

Step 3 deliberately follows step 2: confirm aggregation is correct on agents that
already work before touching code on the child's machines.

## Alternatives considered

**Server computes the verdict; clients are dumb.** Rejected: an offline client still
needs local policy logic as a fallback, so this adds a second implementation rather
than removing one.

**Per-device limits with a shared control panel only.** Rejected: cheap, but the child
can still spend 2h + 2h instead of 2h, which is the actual problem.

**Android Device Owner enrolment.** Rejected by the parent: requires a factory reset.

**Google Family Link for Android.** Rejected: no API, so a shared budget with the Mac
is impossible; it would leave two disconnected systems.

## Accepted limitations

- **Timezones.** The local date comes from the device, as it does today. If the Mac and
  the phone are in different timezones, daily totals diverge at the day boundary. Not
  designed for — one child, one household.
- **Android is bypassable.** By choice. Mitigated by silence detection and by the fact
  that phone time drains the shared budget.
- **iOS granularity is coarse.** A platform constraint, not a design choice.
