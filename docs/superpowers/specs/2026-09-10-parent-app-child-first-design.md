# Child-first Parent App (iPhone + Mac)

Status: designed, not implemented
Supersedes part of `2026-09-09-cross-platform-shared-budget-design.md` — see [Spec reversal](#spec-reversal).

## Problem

The shared-budget work shipped to the API, the web dashboard and the macOS agent, but
never touched `ParentApp/`. The Parent App calls only `/v1/auth/*` and `/v1/devices`;
it has no `Child` model and no `children` string anywhere in its Swift sources.

Today that is merely invisible: the backfill gave every device its own child 1:1, so
"two computers" and "two children" describe the same thing. It becomes actively
misleading the moment two devices are merged under one child — the app shows two
devices, each with what looks like its own screen-time limit, while both edit a single
shared policy row. Changing the limit on one silently changes the other, with nothing
on screen explaining why.

The app is also not usable for the merge itself: assigning a device to a child requires
`PATCH /devices/{id}` with `child_id`, which the app cannot send.

## Goals

- Children are the top-level object; the shared budget is displayed where it lives.
- The parent can perform the whole merge from the app: create a child, move both Macs
  under it, set the shared limit and per-device caps.
- The Mac app behaves like a Mac app, not a phone app in a small window.
- Older TestFlight builds keep working against the same backend.

## Non-goals

- iPhone as a *monitored* device (Family Controls, `DeviceActivityMonitor` threshold
  events). That is a separate, entitlement-gated effort — see `iOS (later)` in the
  2026-09-09 spec. This document concerns only the *parent-facing* app.
- Any change to the macOS agent or to `/agent/*`.
- A test target for the Parent App (see [Testing](#testing)).

## Approach

Child-first navigation. `ChildrenListView` becomes the home screen; a child's detail
screen owns the shared budget, schedule, bonus and the list of that child's devices.
The device screen keeps only what is genuinely per-device.

Rejected: grouping the device list under child headings (what the web dashboard does).
It is the smaller change and would keep the three clients identical, but it preserves
exactly the confusion this work exists to remove — a shared limit that still looks like
a per-device setting.

## API

Four additive endpoints in `api/app/routers/children.py`. **`devices.py` is not
modified.**

| Endpoint | Behaviour |
|---|---|
| `GET /children/{id}/usage?days=7` | Per-day totals summed across the child's devices |
| `GET /children/{id}/policy` | The child's policy; 404 when none exists |
| `PUT /children/{id}/policy` | Edits it; 404 when none exists — never creates a row |
| `POST /children/{id}/grant-bonus` | Sets `child.bonus_until` |
| `GET /children/{id}/activities` | The child's scheduled activities |
| `POST /children/{id}/activities` | Creates one under the child |
| `PUT /children/{id}/activities/{aid}` | Edits one |
| `DELETE /children/{id}/activities/{aid}` | Removes one |

Activities are child-scoped in the data model exactly as policy is (`Activity.child_id`,
resolved child-first by `/agent/config`), so they carry the same "looks per-device but is
shared" problem and move to the child screen alongside downtime and screen time.

`GET /children/{id}/usage` must reproduce the aggregation already in `/agent/config`:

```sql
SELECT SUM(usage_logs.total_minutes)
  FROM usage_logs JOIN devices ON devices.id = usage_logs.device_id
 WHERE devices.child_id = :child_id AND usage_logs.date = :date
```

Both policy routes delegate to the existing `_resolve_policy` rather than reimplementing
the lookup, so the device-keyed and child-keyed paths cannot diverge.

### Never create a policy row for a childless child

`create_child` deliberately creates no `Policy`, and its comment explains why at length:
a `Policy` with `child_id` set and `device_id` NULL means `POST /devices` skips policy
creation for the device that attaches later, so no row ever gets `device_id` stamped. An
API rolled back to pre-child code then finds nothing via the device-keyed lookup, takes
its "no policy" branch (`screen_time_enabled=False`, `downtime_enabled=False`) and **the
child's Mac stops locking altogether.**

`PUT /children/{id}/policy` therefore returns 404 for a child with no devices. It must
never `db.add(Policy(...))`. This is the single most important constraint in this
document.

### Prerequisite bug: device deletion destroys the child's settings

`Device.policy` and `Device.activities` are declared `cascade="all, delete-orphan"`, and
the child's single shared policy row carries one device's `device_id` (stamped by
`create_device` and by the migration backfill). Deleting that device therefore deletes
**the child's shared policy** and any activities stamped with that device's id.

Verified against the test suite on 2026-09-10. Two Macs under one child, limit set to 90:

| | Before deleting the sibling | After |
|---|---|---|
| `screen_time_limit_minutes` | 90 | 120 |
| `screen_time_enabled` | True | True |

Enforcement is not lost — `/agent/config` and `GET /devices/{id}/policy` both auto-create
a policy when none exists — so the failure is silent rather than total: every customised
value reverts to defaults and the child gains time, with nothing reported anywhere.

This is pre-existing, deployed, and unreachable while every device has its own child
1:1. Merging two devices under one child makes it reachable. It is therefore Task 1 of
the plan and ships before the merge.

The fix is to detach rather than cascade: before deleting a device, re-point a shared
policy or activity at a surviving sibling device, and only delete rows that belong to no
other device.

### Spec reversal

The 2026-09-09 spec states: "No `/children/{id}/policy` endpoint is added", because "the
parent iOS app ships through TestFlight and cannot be updated in lockstep with the
backend".

That constraint was about **not moving** policy into the child URL space — keeping
`/devices/{id}/policy` as a working path for clients that cannot be redeployed together
with the backend. It does not bind an **additive** route: the device endpoints are
unchanged, so existing TestFlight builds continue to work untouched. The client the
constraint was protecting is the one this work updates.

The real cost is two write paths to one policy row, mitigated by sharing
`_resolve_policy`.

## App structure

### Models (`Models.swift`)

New `Child`: `id`, `name`, `bonusUntil`, `createdAt`, `deviceIds`.
`Device` gains the three fields it is missing today: `childId`, `platform`,
`dailyCapMinutes`.

### Views

```
Views/ChildrenListView.swift    new   home; create / rename / delete
Views/ChildDetailView.swift     new   budget, downtime, activities, bonus, devices
Views/DeviceDetailView.swift    edit  strip child-level sections
ViewModels/ChildrenViewModel.swift    new
ViewModels/ChildDetailViewModel.swift new
```

`DeviceDetailView.swift` is 889 lines — 2.7× the next largest file in the app and
the clearest "doing too much" signal in the codebase. Moving the policy, schedule and
bonus sections to `ChildDetailView` is a structural improvement, not incidental churn.
What remains is per-device: daily cap, TOTP, rename, delete, per-device usage.

### Navigation

An explicit platform branch, consistent with the four files that already use
`#if os(macOS)`:

```swift
#if os(macOS)
    NavigationSplitView { ChildrenListView() } detail: { … }
#else
    NavigationStack { ChildrenListView() }
#endif
```

Two navigation code paths is the accepted cost; every new screen must be wired into
both. The Mac window grows from 500×700 to ~900×650.

## Edge cases

| Case | Behaviour |
|---|---|
| Child with no devices | No policy exists. Show "Add a device to set limits" — do not render an editor over a 404. |
| Delete a child that has devices | API returns 400 `"Move or delete this child's devices first"`. Disable the action and explain, rather than surfacing the error. |
| Rename a child | `PATCH /children/{id}` cascades `child_name` to devices server-side; the app refetches. |
| Moving the last device off a child | Allowed; leaves an empty child. Matches the web dashboard. |
| `/children` fails but `/devices` succeeds | Degrade to an ungrouped device list rather than blocking on an error, as `DevicesPage.jsx` does. |

## Testing

API: pytest, test-first, alongside `test_children_api.py` and `test_shared_budget.py`.
Coverage must include the 404-not-create behaviour of `PUT /children/{id}/policy` for a
childless child, and agreement between `/children/{id}/usage` and the `/agent/config`
total for the same child and date.

**The Parent App has no test target** — zero `XCTest` references in the pbxproj. The
Swift side is verified by compilation for both destinations plus manual testing. No
automated-coverage claim should be made for it.

## Rollout

1. API endpoints, test-first; deploy. Additive, so nothing needs updating in lockstep.
2. Parent App; build for macOS and iOS Simulator.
3. Manual pass on both platforms.
4. TestFlight build 6.
5. Only then merge the two Macs under one child.

Step 5 last: the merge is the point at which a device-centric app becomes actively
wrong, so the app should understand children before it happens.

## Accepted limitations

- Two navigation code paths (chosen deliberately over a single `NavigationSplitView`).
- Two URL paths to one policy row.
- No automated tests for the Parent App.
- `/children/{id}/usage` is one request per child; the children list shows per-child
  totals only after those requests resolve.
