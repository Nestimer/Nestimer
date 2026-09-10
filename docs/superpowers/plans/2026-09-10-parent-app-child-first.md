# Child-first Parent App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the NesTimer Parent App child-centric on iPhone and Mac, so the shared daily budget is shown and edited where it actually lives, and fix the device-deletion bug that the device merge would otherwise expose.

**Architecture:** Eight additive endpoints on `/children` (usage, policy, bonus, activities) that reuse the existing resolvers in `devices.py`; `devices.py` routes are unchanged so older TestFlight builds and the macOS agent keep working. The app gains a `Child` model, a children list as its home screen, and a child detail screen that takes the policy, downtime, activities and bonus sections off the 889-line device screen.

**Tech Stack:** FastAPI, SQLAlchemy async, pytest/httpx (SQLite in-memory for tests, PostgreSQL 16 in prod); SwiftUI, iOS 17+ / macOS 14+.

**Spec:** `docs/superpowers/specs/2026-09-10-parent-app-child-first-design.md`

## Global Constraints

- All English. No Russian text anywhere.
- Conventional commits (`feat:`, `fix:`, `security:`, `docs:`, `chore:`).
- All datetime writes use `datetime.now(timezone.utc)` — never `utcnow()`.
- `PUT /children/{id}/policy` must **never** create a `Policy` row. Returns 404 when none exists. See "Never create a policy row for a childless child" in the spec: a `Policy` with `device_id` NULL means a device attaching later never gets `device_id` stamped, and an API rolled back to pre-child code then finds nothing.
- `devices.py` routes are not modified by Tasks 2–5. Task 1 modifies only `delete_device`.
- Run API tests with: `cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 .venv/bin/python -m pytest`
- Parent App deployment targets: iOS 17+, macOS 14+. Agent targets macOS 13+ (not touched here).
- The Parent App has **no test target** (zero `XCTest` references). Swift tasks are verified by compiling both destinations. Do not claim automated test coverage for Swift.

---

### Task 1: Device deletion must not destroy the child's shared settings

Pre-existing bug, reachable as soon as two devices share a child. `Device.policy` and `Device.activities` are `cascade="all, delete-orphan"`, and the shared policy row carries one device's `device_id`.

**Files:**
- Modify: `api/app/routers/devices.py:314-329` (`delete_device`)
- Test: `api/tests/test_shared_budget.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `delete_device` behaviour that later tasks and the app rely on — deleting one device of a shared child preserves the child's policy and activities.

- [ ] **Step 1: Write the failing tests**

Append to `api/tests/test_shared_budget.py`:

```python
async def test_deleting_one_shared_device_keeps_the_childs_policy(client):
    """Two Macs under one child; delete the one the policy row points at.

    Device.policy is cascade="all, delete-orphan" and the shared policy row carries a
    single device's id, so without the fix the parent's settings are silently replaced
    by defaults (90 -> 120) on the surviving Mac.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Alex2")

    resp = await client.patch(f"/api/v1/devices/{d2['id']}",
                              json={"child_id": d1["child_id"]}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.put(f"/api/v1/devices/{d1['id']}/policy",
                            json={"screen_time_enabled": True,
                                  "screen_time_limit_minutes": 90}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.delete(f"/api/v1/devices/{d1['id']}", headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.get(f"/api/v1/devices/{d2['id']}/policy", headers=h)
    assert resp.status_code == 200, resp.text
    assert resp.json()["screen_time_limit_minutes"] == 90


async def test_agent_keeps_the_configured_limit_after_sibling_deleted(client):
    """The agent never opens the policy screen, so it must see the real limit."""
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Alex2")
    await client.patch(f"/api/v1/devices/{d2['id']}",
                       json={"child_id": d1["child_id"]}, headers=h)
    await client.put(f"/api/v1/devices/{d1['id']}/policy",
                     json={"screen_time_enabled": True,
                           "screen_time_limit_minutes": 90}, headers=h)

    await client.delete(f"/api/v1/devices/{d1['id']}", headers=h)

    resp = await client.get("/api/v1/agent/config",
                            headers={"Authorization": f"Bearer {d2['api_token']}"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["screen_time_limit_minutes"] == 90


async def test_deleting_one_shared_device_keeps_the_childs_activities(client):
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Alex2")
    await client.patch(f"/api/v1/devices/{d2['id']}",
                       json={"child_id": d1["child_id"]}, headers=h)

    resp = await client.post(f"/api/v1/devices/{d1['id']}/activities",
                             json={"name": "Homework", "day_of_week": 1,
                                   "start_time": "16:00", "end_time": "17:00"},
                             headers=h)
    assert resp.status_code == 200, resp.text

    await client.delete(f"/api/v1/devices/{d1['id']}", headers=h)

    resp = await client.get(f"/api/v1/devices/{d2['id']}/activities", headers=h)
    assert resp.status_code == 200, resp.text
    assert [a["name"] for a in resp.json()] == ["Homework"]


async def test_deleting_the_only_device_still_removes_its_policy(client):
    """The 1:1 case must keep behaving as it always has -- no orphan rows."""
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="Only Mac", child_name="Alex")
    await client.put(f"/api/v1/devices/{d1['id']}/policy",
                     json={"screen_time_limit_minutes": 45}, headers=h)

    resp = await client.delete(f"/api/v1/devices/{d1['id']}", headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.get(f"/api/v1/devices/{d1['id']}/policy", headers=h)
    assert resp.status_code == 404
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest tests/test_shared_budget.py -k "sibling or shared_device or only_device" -v
```
Expected: the first three FAIL (`assert 120 == 90`, and an empty activities list); `test_deleting_the_only_device_still_removes_its_policy` PASSES already.

- [ ] **Step 3: Re-point shared rows before deleting**

In `api/app/routers/devices.py`, replace the body of `delete_device` (currently lines 314-329) between `_verify_device_owner` and `await db.delete(device)`:

```python
@router.delete("/{device_id}")
async def delete_device(
    device_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    device = await _verify_device_owner(db, device_id, user.id)

    # Device.policy and Device.activities are cascade="all, delete-orphan", and a child's
    # shared policy row carries exactly one device's id (stamped by create_device and by
    # the migration backfill). Deleting that device would take the whole child's policy
    # and activities with it, silently reverting the surviving Mac to default limits.
    # Hand those rows to a sibling before the cascade can reach them.
    if device.child_id:
        result = await db.execute(
            select(Device.id).where(
                Device.child_id == device.child_id, Device.id != device.id
            ).limit(1)
        )
        sibling_id = result.scalar_one_or_none()
        if sibling_id:
            await db.execute(
                update(Policy).where(Policy.device_id == device.id)
                .values(device_id=sibling_id)
            )
            await db.execute(
                update(Activity).where(Activity.device_id == device.id)
                .values(device_id=sibling_id)
            )
            # Expire the in-session copies so the ORM does not cascade-delete rows it
            # still believes belong to this device.
            await db.refresh(device)

    await db.delete(device)
    await db.commit()
    return {"ok": True}
```

Add `update` to the SQLAlchemy import at the top of the file if it is not already there:

```python
from sqlalchemy import select, update, or_, func
```

(Check the existing import line first and add only what is missing.)

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest tests/test_shared_budget.py -v
```
Expected: all PASS, including the pre-existing tests in that file.

- [ ] **Step 5: Run the whole API suite**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest -q
```
Expected: all PASS. `test_devices.py` covers device deletion; if anything there fails, the re-pointing changed 1:1 behaviour and must be fixed before continuing.

- [ ] **Step 6: Commit**

```bash
git add api/app/routers/devices.py api/tests/test_shared_budget.py
git commit -m "fix: deleting a shared device no longer wipes the child's policy"
```

---

### Task 2: `GET /children/{id}/usage`

**Files:**
- Modify: `api/app/routers/children.py`
- Test: `api/tests/test_children_api.py`

**Interfaces:**
- Consumes: `_verify_child_owner(db, child_id, user_id) -> Child` (exists in `children.py`).
- Produces: `GET /api/v1/children/{child_id}/usage?days=7` returning `List[UsageOut]`, i.e. `[{"date": "YYYY-MM-DD", "total_minutes": float}]`, newest first. Consumed by Task 9 (`APIClient.getChildUsage`).

- [ ] **Step 1: Write the failing test**

Append to `api/tests/test_children_api.py`:

```python
async def test_child_usage_sums_across_devices(client):
    """The child's usage must equal what /agent/config counts for the same child."""
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Alex2")
    await client.patch(f"/api/v1/devices/{d2['id']}",
                       json={"child_id": d1["child_id"]}, headers=h)

    today = date.today().isoformat()
    for dev, minutes in ((d1, 20.0), (d2, 12.5)):
        resp = await client.post(
            "/api/v1/agent/usage",
            json={"date": today, "total_minutes": minutes},
            headers={"Authorization": f"Bearer {dev['api_token']}"},
        )
        assert resp.status_code == 200, resp.text

    resp = await client.get(f"/api/v1/children/{d1['child_id']}/usage", headers=h)
    assert resp.status_code == 200, resp.text
    rows = resp.json()
    assert [r["date"] for r in rows] == [today]
    assert rows[0]["total_minutes"] == pytest.approx(32.5)


async def test_child_usage_is_scoped_to_its_owner(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    d = await create_device(client, token_a, name="Mac", child_name="Alex")

    resp = await client.get(f"/api/v1/children/{d['child_id']}/usage",
                            headers={"Authorization": f"Bearer {token_b}"})
    assert resp.status_code == 404
```

Add to that file's imports if missing:

```python
from datetime import date
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest tests/test_children_api.py -k child_usage -v
```
Expected: FAIL with 404 (the route does not exist).

- [ ] **Step 3: Implement the endpoint**

In `api/app/routers/children.py`, extend the imports:

```python
from sqlalchemy import select, update, func
from ..models.models import Child, Device, User, UsageLog
from ..schemas import ChildCreate, ChildOut, ChildUpdate, UsageOut
```

Then append:

```python
@router.get("/{child_id}/usage", response_model=List[UsageOut])
async def get_child_usage(
    child_id: str,
    days: int = 7,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Per-day totals across every device this child owns.

    Mirrors the aggregation `/agent/config` uses for the shared counter, so the number a
    parent sees and the number the agent enforces against cannot disagree.
    """
    child = await _verify_child_owner(db, child_id, user.id)

    result = await db.execute(
        select(UsageLog.date, func.sum(UsageLog.total_minutes))
        .select_from(UsageLog)
        .join(Device, Device.id == UsageLog.device_id)
        .where(Device.child_id == child.id)
        .group_by(UsageLog.date)
        .order_by(UsageLog.date.desc())
        .limit(days)
    )
    return [UsageOut(date=row[0], total_minutes=float(row[1])) for row in result.all()]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest tests/test_children_api.py -v
```
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add api/app/routers/children.py api/tests/test_children_api.py
git commit -m "feat: GET /children/{id}/usage"
```

---

### Task 3: `GET` and `PUT /children/{id}/policy`

**Files:**
- Modify: `api/app/routers/children.py`
- Test: `api/tests/test_children_api.py`

**Interfaces:**
- Consumes: `_resolve_policy(db, child_id, device_id) -> Policy | None` and `policy_to_out(policy) -> PolicyOut` from `devices.py`; `parse_time` from wherever `devices.py` imports it.
- Produces: `GET/PUT /api/v1/children/{child_id}/policy` returning `PolicyOut`. 404 when the child has no policy. Consumed by Task 9 (`APIClient.getChildPolicy` / `updateChildPolicy`).

- [ ] **Step 1: Write the failing tests**

Append to `api/tests/test_children_api.py`:

```python
async def test_child_policy_round_trip(client):
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d = await create_device(client, token, name="Mac", child_name="Alex")

    resp = await client.put(f"/api/v1/children/{d['child_id']}/policy",
                            json={"screen_time_enabled": True,
                                  "screen_time_limit_minutes": 75,
                                  "downtime_start": "21:30"}, headers=h)
    assert resp.status_code == 200, resp.text
    assert resp.json()["screen_time_limit_minutes"] == 75
    assert resp.json()["downtime_start"] == "21:30"

    resp = await client.get(f"/api/v1/children/{d['child_id']}/policy", headers=h)
    assert resp.status_code == 200
    assert resp.json()["screen_time_limit_minutes"] == 75


async def test_child_and_device_policy_routes_are_the_same_row(client):
    """Two URLs, one policy -- they must never diverge."""
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d = await create_device(client, token, name="Mac", child_name="Alex")

    await client.put(f"/api/v1/children/{d['child_id']}/policy",
                     json={"screen_time_limit_minutes": 55}, headers=h)

    resp = await client.get(f"/api/v1/devices/{d['id']}/policy", headers=h)
    assert resp.json()["screen_time_limit_minutes"] == 55


async def test_childless_child_policy_is_404_and_creates_nothing(client):
    """A Policy with device_id NULL breaks the rollback path -- never create one.

    See create_child's comment: POST /devices skips policy creation when the child
    already has one, so a device attaching later would never get device_id stamped.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    resp = await client.post("/api/v1/children", json={"name": "Bea"}, headers=h)
    child_id = resp.json()["id"]

    assert (await client.get(f"/api/v1/children/{child_id}/policy", headers=h)).status_code == 404
    resp = await client.put(f"/api/v1/children/{child_id}/policy",
                            json={"screen_time_limit_minutes": 60}, headers=h)
    assert resp.status_code == 404

    # A device attaching afterwards must still get a policy WITH device_id stamped.
    resp = await client.post("/api/v1/devices",
                             json={"name": "Later Mac", "child_name": "Bea",
                                   "child_id": child_id}, headers=h)
    assert resp.status_code == 200, resp.text
    device = resp.json()

    resp = await client.get(f"/api/v1/devices/{device['id']}/policy", headers=h)
    assert resp.status_code == 200, resp.text
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest tests/test_children_api.py -k child_policy -v
```
Expected: FAIL with 404 on the PUT in the first test (route missing).

- [ ] **Step 3: Implement both routes**

In `api/app/routers/children.py`, add imports:

```python
from ..models.models import Child, Device, Policy, User, UsageLog
from ..schemas import ChildCreate, ChildOut, ChildUpdate, PolicyOut, PolicyUpdate, UsageOut
from .devices import _resolve_policy, policy_to_out, parse_time
```

Then append:

```python
async def _child_policy(db: AsyncSession, child: Child) -> Policy | None:
    """The child's policy, reusing the device route's resolver so the two URLs cannot
    diverge. Tries each of the child's devices in turn so a legacy device-keyed row is
    still found and adopted, exactly as `/devices/{id}/policy` would.
    """
    result = await db.execute(select(Device.id).where(Device.child_id == child.id))
    for device_id in result.scalars().all():
        policy = await _resolve_policy(db, child.id, device_id)
        if policy is not None:
            return policy
    return None


@router.get("/{child_id}/policy", response_model=PolicyOut)
async def get_child_policy(
    child_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    policy = await _child_policy(db, child)
    if policy is None:
        raise HTTPException(status_code=404, detail="This child has no devices yet")
    await db.commit()  # _resolve_policy may have adopted a legacy row under the child
    return policy_to_out(policy)


@router.put("/{child_id}/policy", response_model=PolicyOut)
async def update_child_policy(
    child_id: str,
    data: PolicyUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Never creates a Policy row. A child with no devices has no policy, and a row with
    `device_id` NULL would leave a later-attaching device without one -- see the long
    comment in `create_child`.
    """
    child = await _verify_child_owner(db, child_id, user.id)
    policy = await _child_policy(db, child)
    if policy is None:
        raise HTTPException(status_code=404, detail="This child has no devices yet")

    time_fields = {
        "downtime_start", "downtime_end",
        "downtime_weekday_start", "downtime_weekday_end",
        "downtime_weekend_start", "downtime_weekend_end",
    }
    for field_name in data.model_fields_set:
        value = getattr(data, field_name)
        if field_name in time_fields:
            value = parse_time(value) if value is not None else None
        setattr(policy, field_name, value)

    await db.commit()
    await db.refresh(policy)
    return policy_to_out(policy)
```

If `parse_time` is not importable from `devices.py`, import it from the module `devices.py` itself imports it from — check `devices.py`'s import block and match it.

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest tests/test_children_api.py -v
```
Expected: all PASS.

- [ ] **Step 5: Check for a circular import**

`children.py` now imports from `devices.py`. Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -c "from app.main import app; print('imports fine')"
```
Expected: `imports fine`. If it fails with a circular import, move `_resolve_policy`, `policy_to_out` and `_child_id_for_device` into a new `api/app/routers/_policy_shared.py` and import from there in both routers.

- [ ] **Step 6: Commit**

```bash
git add api/app/routers/children.py api/tests/test_children_api.py
git commit -m "feat: GET and PUT /children/{id}/policy"
```

---

### Task 4: `POST /children/{id}/grant-bonus`

**Files:**
- Modify: `api/app/routers/children.py`
- Test: `api/tests/test_children_api.py`

**Interfaces:**
- Consumes: `_verify_child_owner`.
- Produces: `POST /api/v1/children/{child_id}/grant-bonus` taking `{"minutes": int}` (1–120) and returning `{"bonus_until": "<iso8601>"}`. Consumed by Task 9 (`APIClient.grantChildBonus`).

- [ ] **Step 1: Write the failing test**

Append to `api/tests/test_children_api.py`:

```python
async def test_child_grant_bonus_applies_to_every_device(client):
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Alex2")
    await client.patch(f"/api/v1/devices/{d2['id']}",
                       json={"child_id": d1["child_id"]}, headers=h)

    resp = await client.post(f"/api/v1/children/{d1['child_id']}/grant-bonus",
                             json={"minutes": 15}, headers=h)
    assert resp.status_code == 200, resp.text
    assert resp.json()["bonus_until"] is not None

    for dev in (d1, d2):
        resp = await client.get("/api/v1/agent/config",
                                headers={"Authorization": f"Bearer {dev['api_token']}"})
        assert resp.json()["bonus_until"] is not None, f"{dev['name']} did not see the bonus"


async def test_child_grant_bonus_rejects_out_of_range(client):
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d = await create_device(client, token, name="Mac", child_name="Alex")

    resp = await client.post(f"/api/v1/children/{d['child_id']}/grant-bonus",
                             json={"minutes": 999}, headers=h)
    assert resp.status_code == 422
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest tests/test_children_api.py -k grant_bonus -v
```
Expected: FAIL with 404.

- [ ] **Step 3: Implement the endpoint**

Add imports to `api/app/routers/children.py`:

```python
from datetime import datetime, timedelta, timezone
from ..schemas import GrantBonusRequest, GrantBonusResponse
```

Then append:

```python
@router.post("/{child_id}/grant-bonus", response_model=GrantBonusResponse)
async def grant_child_bonus(
    child_id: str,
    data: GrantBonusRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Bonus is inherently shared: `bonus_until` lives on the child, so the window
    applies to every device that child owns. Calling again replaces the window rather
    than extending it, matching `/devices/{id}/grant-bonus`.
    """
    child = await _verify_child_owner(db, child_id, user.id)
    child.bonus_until = datetime.now(timezone.utc) + timedelta(minutes=data.minutes)
    await db.commit()
    return GrantBonusResponse(bonus_until=child.bonus_until)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest tests/test_children_api.py -v
```
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add api/app/routers/children.py api/tests/test_children_api.py
git commit -m "feat: POST /children/{id}/grant-bonus"
```

---

### Task 5: Child activity CRUD

**Files:**
- Modify: `api/app/routers/children.py`
- Test: `api/tests/test_children_api.py`

**Interfaces:**
- Consumes: `_verify_child_owner`; `activity_to_out(activity) -> ActivityOut` and `parse_time` from `devices.py`.
- Produces: `GET`/`POST /api/v1/children/{child_id}/activities` and `PUT`/`DELETE /api/v1/children/{child_id}/activities/{activity_id}`. Consumed by Task 9.

Activities created here stamp `device_id` to one of the child's devices, for the same rollback reason policy rows do: a pre-child API reads activities by `device_id` only, and a row with `device_id` NULL would be invisible to it, so a scheduled activity would stop suppressing the lock.

- [ ] **Step 1: Write the failing tests**

Append to `api/tests/test_children_api.py`:

```python
async def test_child_activities_crud(client):
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d = await create_device(client, token, name="Mac", child_name="Alex")
    child_id = d["child_id"]

    resp = await client.post(f"/api/v1/children/{child_id}/activities",
                             json={"name": "Homework", "day_of_week": 1,
                                   "start_time": "16:00", "end_time": "17:00"}, headers=h)
    assert resp.status_code == 200, resp.text
    activity_id = resp.json()["id"]

    resp = await client.get(f"/api/v1/children/{child_id}/activities", headers=h)
    assert [a["name"] for a in resp.json()] == ["Homework"]

    resp = await client.put(f"/api/v1/children/{child_id}/activities/{activity_id}",
                            json={"name": "Piano"}, headers=h)
    assert resp.status_code == 200, resp.text
    assert resp.json()["name"] == "Piano"

    resp = await client.delete(f"/api/v1/children/{child_id}/activities/{activity_id}",
                               headers=h)
    assert resp.status_code == 200, resp.text
    assert (await client.get(f"/api/v1/children/{child_id}/activities", headers=h)).json() == []


async def test_child_activity_is_visible_on_every_device(client):
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Alex2")
    await client.patch(f"/api/v1/devices/{d2['id']}",
                       json={"child_id": d1["child_id"]}, headers=h)

    await client.post(f"/api/v1/children/{d1['child_id']}/activities",
                      json={"name": "Homework", "day_of_week": 1,
                            "start_time": "16:00", "end_time": "17:00"}, headers=h)

    for dev in (d1, d2):
        resp = await client.get(f"/api/v1/devices/{dev['id']}/activities", headers=h)
        assert [a["name"] for a in resp.json()] == ["Homework"], f"missing on {dev['name']}"


async def test_child_activity_stamps_a_device_id(client):
    """device_id NULL would be invisible to a rolled-back, device-keyed API."""
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d = await create_device(client, token, name="Mac", child_name="Alex")

    resp = await client.post(f"/api/v1/children/{d['child_id']}/activities",
                             json={"name": "Homework", "day_of_week": 1,
                                   "start_time": "16:00", "end_time": "17:00"}, headers=h)
    activity_id = resp.json()["id"]

    async def _check(conn):
        row = await conn.execute(
            text("SELECT device_id FROM activities WHERE id = :aid"), {"aid": activity_id}
        )
        return row.scalar_one()

    assert await _run_on_app_db(_check) == d["id"]


async def test_child_activities_are_scoped_to_their_owner(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    d = await create_device(client, token_a, name="Mac", child_name="Alex")

    resp = await client.get(f"/api/v1/children/{d['child_id']}/activities",
                            headers={"Authorization": f"Bearer {token_b}"})
    assert resp.status_code == 404
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest tests/test_children_api.py -k child_activit -v
```
Expected: FAIL with 404.

- [ ] **Step 3: Implement the four routes**

Add imports to `api/app/routers/children.py`:

```python
from ..models.models import Activity, Child, Device, Policy, User, UsageLog
from ..schemas import ActivityCreate, ActivityOut, ActivityUpdate
from .devices import activity_to_out
```

Then append:

```python
@router.get("/{child_id}/activities", response_model=List[ActivityOut])
async def list_child_activities(
    child_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    result = await db.execute(
        select(Activity)
        .where(Activity.child_id == child.id)
        .order_by(Activity.day_of_week, Activity.start_time)
    )
    return [activity_to_out(a) for a in result.scalars().all()]


@router.post("/{child_id}/activities", response_model=ActivityOut)
async def create_child_activity(
    child_id: str,
    data: ActivityCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)

    # Stamp a device id as well as the child id. An API rolled back to pre-child code
    # reads activities by device_id alone; a row with device_id NULL would be invisible
    # to it and the scheduled activity would silently stop suppressing the lock.
    result = await db.execute(select(Device.id).where(Device.child_id == child.id).limit(1))
    device_id = result.scalar_one_or_none()

    activity = Activity(
        device_id=device_id,
        child_id=child.id,
        name=data.name,
        day_of_week=data.day_of_week,
        start_time=parse_time(data.start_time),
        end_time=parse_time(data.end_time),
        buffer_before_minutes=data.buffer_before_minutes,
        buffer_after_minutes=data.buffer_after_minutes,
        enabled=data.enabled,
    )
    db.add(activity)
    await db.commit()
    await db.refresh(activity)
    return activity_to_out(activity)


async def _child_activity(db: AsyncSession, child: Child, activity_id: str) -> Activity:
    result = await db.execute(
        select(Activity).where(Activity.id == activity_id, Activity.child_id == child.id)
    )
    activity = result.scalar_one_or_none()
    if not activity:
        raise HTTPException(status_code=404, detail="Activity not found")
    return activity


@router.put("/{child_id}/activities/{activity_id}", response_model=ActivityOut)
async def update_child_activity(
    child_id: str,
    activity_id: str,
    data: ActivityUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    activity = await _child_activity(db, child, activity_id)

    for field_name in data.model_fields_set:
        value = getattr(data, field_name)
        if field_name in ("start_time", "end_time"):
            value = parse_time(value) if value is not None else None
        setattr(activity, field_name, value)

    await db.commit()
    await db.refresh(activity)
    return activity_to_out(activity)


@router.delete("/{child_id}/activities/{activity_id}")
async def delete_child_activity(
    child_id: str,
    activity_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    activity = await _child_activity(db, child, activity_id)
    await db.delete(activity)
    await db.commit()
    return {"ok": True}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
cd api && DATABASE_URL="sqlite+aiosqlite:///:memory:" SECRET_KEY="test-key-0123456789" TESTING=1 \
  .venv/bin/python -m pytest -q
```
Expected: the whole suite PASSES.

- [ ] **Step 5: Commit**

```bash
git add api/app/routers/children.py api/tests/test_children_api.py
git commit -m "feat: child activity CRUD"
```

---

### Task 6: Deploy the API

The endpoints are additive and `devices.py` is unchanged apart from Task 1's deletion fix, so nothing needs updating in lockstep.

**Files:** none modified.

**Interfaces:**
- Consumes: Tasks 1–5 merged to `main`.
- Produces: the eight routes live on `https://my.nestimer.com`, which Tasks 7–12 develop against.

- [ ] **Step 1: Confirm CI is green**

```bash
gh pr checks   # or: gh run list --branch main --limit 1
```
Expected: all 5 jobs pass. Do not deploy on red.

- [ ] **Step 2: Back up production**

```bash
ssh root@134.209.8.62 "cd /root/Nestimer && docker compose exec -T db pg_dump -U nestimer nestimer" \
  > ~/nestimer-backup-before-child-routes.sql
ls -lh ~/nestimer-backup-before-child-routes.sql
```
Expected: a non-empty file. This release adds no migration, but the backup costs seconds.

- [ ] **Step 3: Deploy**

```bash
ssh root@134.209.8.62 "cd /root/Nestimer && git fetch origin -q && git reset --hard origin/main && docker compose up -d --build"
```

- [ ] **Step 4: Verify the new routes answer**

```bash
curl -s -o /dev/null -w "children/x/policy -> %{http_code}\n" https://my.nestimer.com/api/v1/children/x/policy
```
Expected: `403` (route exists, auth required). `404` means the deploy did not take.

- [ ] **Step 5: Verify the old routes still answer**

```bash
ssh root@134.209.8.62 "docker logs --since 5m nestimer-api-1 2>&1 | grep -c 'agent/config'"
```
Expected: a non-zero count — the agents are still syncing.

---

### Task 7: `Child` model and `Device` fields

**Files:**
- Modify: `ParentApp/NesTimer/Models/Models.swift`

**Interfaces:**
- Consumes: the JSON shapes from Tasks 2–5.
- Produces: `Child` (`id`, `name`, `bonusUntil`, `createdAt`, `deviceIds`) and `Device.childId` / `Device.platform` / `Device.dailyCapMinutes`. Consumed by Tasks 8–12.

`JSONDecoder` here uses **no** `keyDecodingStrategy`, so every snake_case field needs an explicit `CodingKeys` entry. Follow the existing `Device` struct exactly.

- [ ] **Step 1: Add the `Child` struct**

Append to `ParentApp/NesTimer/Models/Models.swift`:

```swift
// MARK: - Child

struct Child: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let bonusUntil: String?
    let createdAt: String?
    let deviceIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, name
        case bonusUntil = "bonus_until"
        case createdAt = "created_at"
        case deviceIds = "device_ids"
    }

    var deviceCountText: String {
        deviceIds.count == 1 ? "1 device" : "\(deviceIds.count) devices"
    }
}

struct ChildCreateRequest: Encodable {
    let name: String
}

struct ChildUpdateRequest: Encodable {
    var name: String?
}

struct DeviceCapUpdateRequest: Encodable {
    var dailyCapMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case dailyCapMinutes = "daily_cap_minutes"
    }
}
```

- [ ] **Step 2: Add the three missing `Device` fields**

In the `Device` struct, add the stored properties after `bonusUntil`:

```swift
    let childId: String?
    let platform: String?
    let dailyCapMinutes: Int?
```

and the matching `CodingKeys` cases after `case bonusUntil = "bonus_until"`:

```swift
        case childId = "child_id"
        case platform
        case dailyCapMinutes = "daily_cap_minutes"
```

- [ ] **Step 3: Extend `DeviceUpdateRequest` so a device can be moved between children**

Replace the existing `DeviceUpdateRequest` struct with:

```swift
struct DeviceUpdateRequest: Encodable {
    var name: String?
    var childName: String?
    var childId: String?
    var dailyCapMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case childName = "child_name"
        case childId = "child_id"
        case dailyCapMinutes = "daily_cap_minutes"
    }
}
```

Check the file for an existing `CodingKeys` on `DeviceUpdateRequest` and replace it rather than adding a second one.

- [ ] **Step 4: Build both platforms**

```bash
xcodebuild -project ParentApp/NesTimer.xcodeproj -scheme NesTimer -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES build 2>&1 | tail -3
xcodebuild -project ParentApp/NesTimer.xcodeproj -scheme NesTimer -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 5: Commit**

```bash
git add ParentApp/NesTimer/Models/Models.swift
git commit -m "feat: Child model and child fields on Device"
```

---

### Task 8: `APIClient` child methods

**Files:**
- Modify: `ParentApp/NesTimer/Services/APIClient.swift`

**Interfaces:**
- Consumes: `Child`, `ChildCreateRequest`, `ChildUpdateRequest`, `DeviceUpdateRequest` (Task 7); `Policy`, `PolicyUpdate`, `UsageEntry`, `Activity`, `ActivityCreate`, `ActivityUpdate`, `GrantBonusResponse` (existing).
- Produces, all `async throws` on the `APIClient` actor:
  - `listChildren() -> [Child]`
  - `createChild(name: String) -> Child`
  - `renameChild(_ id: String, name: String) -> Child`
  - `deleteChild(_ id: String)`
  - `getChildUsage(childId: String, days: Int = 7) -> [UsageEntry]`
  - `getChildPolicy(childId: String) -> Policy`
  - `updateChildPolicy(childId: String, update: PolicyUpdate) -> Policy`
  - `grantChildBonus(childId: String, minutes: Int) -> GrantBonusResponse`
  - `listChildActivities(childId: String) -> [Activity]`
  - `createChildActivity(childId: String, activity: ActivityCreate) -> Activity`
  - `updateChildActivity(childId: String, activityId: String, update: ActivityUpdate) -> Activity`
  - `deleteChildActivity(childId: String, activityId: String)`

- [ ] **Step 1: Add the methods**

Insert into `ParentApp/NesTimer/Services/APIClient.swift` after the `// MARK: - Devices` block:

```swift
    // MARK: - Children

    func listChildren() async throws -> [Child] {
        try await get("/api/v1/children")
    }

    func createChild(name: String) async throws -> Child {
        try await post("/api/v1/children", body: ChildCreateRequest(name: name))
    }

    @discardableResult
    func renameChild(_ id: String, name: String) async throws -> Child {
        try await request("PATCH", path: "/api/v1/children/\(id)",
                          body: ChildUpdateRequest(name: name))
    }

    func deleteChild(_ id: String) async throws {
        let _: [String: Bool] = try await request("DELETE", path: "/api/v1/children/\(id)")
    }

    func getChildUsage(childId: String, days: Int = 7) async throws -> [UsageEntry] {
        try await get("/api/v1/children/\(childId)/usage?days=\(days)")
    }

    func getChildPolicy(childId: String) async throws -> Policy {
        try await get("/api/v1/children/\(childId)/policy")
    }

    func updateChildPolicy(childId: String, update: PolicyUpdate) async throws -> Policy {
        try await request("PUT", path: "/api/v1/children/\(childId)/policy", body: update)
    }

    @discardableResult
    func grantChildBonus(childId: String, minutes: Int) async throws -> GrantBonusResponse {
        try await post("/api/v1/children/\(childId)/grant-bonus",
                       body: GrantBonusRequest(minutes: minutes))
    }

    func listChildActivities(childId: String) async throws -> [Activity] {
        try await get("/api/v1/children/\(childId)/activities")
    }

    func createChildActivity(childId: String, activity: ActivityCreate) async throws -> Activity {
        try await post("/api/v1/children/\(childId)/activities", body: activity)
    }

    func updateChildActivity(childId: String, activityId: String,
                             update: ActivityUpdate) async throws -> Activity {
        try await request("PUT", path: "/api/v1/children/\(childId)/activities/\(activityId)",
                          body: update)
    }

    func deleteChildActivity(childId: String, activityId: String) async throws {
        let _: [String: Bool] = try await request(
            "DELETE", path: "/api/v1/children/\(childId)/activities/\(activityId)")
    }
```

- [ ] **Step 2: Add a "not found" case to `APIError` handling**

Child detail must distinguish "this child has no policy yet" (404) from a real failure. In the `request` method, before the generic `guard (200...299)` check, add:

```swift
        if http.statusCode == 404 {
            throw APIError.notFound
        }
```

and add the case to the `APIError` enum plus its `errorDescription` — both are at the bottom of `APIClient.swift` (lines 173-189), not in `Models.swift`:

```swift
    case notFound
```
```swift
        case .notFound: return "Not found"
```

Read the existing `APIError` enum and its `errorDescription` switch first, and match their formatting.

- [ ] **Step 3: Build both platforms**

Run the two `xcodebuild` commands from Task 7 Step 4.
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 4: Commit**

```bash
git add ParentApp/NesTimer/Services/APIClient.swift
git commit -m "feat: APIClient child endpoints"
```

---

### Task 9: `ChildrenViewModel`

**Files:**
- Create: `ParentApp/NesTimer/ViewModels/ChildrenViewModel.swift`
- Modify: `ParentApp/NesTimer.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `APIClient.listChildren/createChild/renameChild/deleteChild/getChildUsage`, `APIClient.listDevices`.
- Produces: `@MainActor final class ChildrenViewModel: ObservableObject` with `@Published var children: [Child]`, `@Published var devices: [Device]`, `@Published var todayMinutes: [String: Double]`, `@Published var isLoading: Bool`, `@Published var errorMessage: String?`; methods `load() async`, `createChild(name:) async`, `renameChild(_:name:) async`, `deleteChild(_:) async`, and `devices(for:) -> [Device]`.

**Adding a Swift file to the Xcode project is the sharpest edge in this repo.** `CLAUDE.md`: adding a file requires a `PBXBuildFile` entry, a `PBXFileReference` entry, a group membership entry, and a `PBXSourcesBuildPhase` entry. Missing one produces `cannot find 'X' in scope`. Do all four for every new file.

- [ ] **Step 1: Write the view model**

Create `ParentApp/NesTimer/ViewModels/ChildrenViewModel.swift`:

```swift
import Foundation

@MainActor
final class ChildrenViewModel: ObservableObject {
    @Published var children: [Child] = []
    @Published var devices: [Device] = []
    /// Today's shared minutes per child id. Populated per child after `load()`.
    @Published var todayMinutes: [String: Double] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func devices(for child: Child) -> [Device] {
        devices.filter { $0.childId == child.id }
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        // Loaded independently and on purpose. This is the screen a parent opens to check
        // on their child's machines, so a failing /children request must not leave it
        // stuck on "Loading..." -- the same reasoning as DevicesPage.jsx on the web.
        do {
            children = try await api.listChildren()
        } catch {
            errorMessage = "Could not load children."
        }
        do {
            devices = try await api.listDevices()
        } catch {
            errorMessage = "Could not load devices."
        }

        isLoading = false
        await loadTodayMinutes()
    }

    /// One request per child. Failures here are deliberately silent: the list is still
    /// usable without today's figure, and this is the screen a parent opens to check on
    /// their child's machines.
    private func loadTodayMinutes() async {
        let today = Self.todayString()
        for child in children {
            guard let rows = try? await api.getChildUsage(childId: child.id, days: 1) else {
                continue
            }
            todayMinutes[child.id] = rows.first(where: { $0.date == today })?.totalMinutes ?? 0
        }
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func createChild(name: String) async {
        do {
            _ = try await api.createChild(name: name)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameChild(_ id: String, name: String) async {
        do {
            try await api.renameChild(id, name: name)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteChild(_ id: String) async {
        do {
            try await api.deleteChild(id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Register the file in the Xcode project**

Open `ParentApp/NesTimer.xcodeproj/project.pbxproj` and copy the four entries that `DevicesViewModel.swift` has, changing the name and generating fresh 24-hex-character ids:

1. `PBXBuildFile` section: `<NEWID1> /* ChildrenViewModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = <NEWID2> /* ChildrenViewModel.swift */; };`
2. `PBXFileReference` section: `<NEWID2> /* ChildrenViewModel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ChildrenViewModel.swift; sourceTree = "<group>"; };`
3. The `ViewModels` group's `children` array: add `<NEWID2> /* ChildrenViewModel.swift */,`
4. The `PBXSourcesBuildPhase` `files` array: add `<NEWID1> /* ChildrenViewModel.swift in Sources */,`

Find the existing entries with:
```bash
grep -n "DevicesViewModel.swift" ParentApp/NesTimer.xcodeproj/project.pbxproj
```
Expected: 4 matching lines. Your new file must also produce 4.

- [ ] **Step 3: Verify the file is in the build**

```bash
grep -c "ChildrenViewModel.swift" ParentApp/NesTimer.xcodeproj/project.pbxproj
```
Expected: `4`.

- [ ] **Step 4: Build both platforms**

Run the two `xcodebuild` commands from Task 7 Step 4.
Expected: `** BUILD SUCCEEDED **` twice. `cannot find 'ChildrenViewModel' in scope` means Step 2 missed an entry.

- [ ] **Step 5: Commit**

```bash
git add ParentApp/NesTimer/ViewModels/ChildrenViewModel.swift ParentApp/NesTimer.xcodeproj/project.pbxproj
git commit -m "feat: ChildrenViewModel"
```

---

### Task 10: `ChildrenListView` as the app's home screen

**Files:**
- Create: `ParentApp/NesTimer/Views/ChildrenListView.swift`
- Modify: `ParentApp/NesTimer/ContentView.swift`
- Modify: `ParentApp/NesTimer.xcodeproj/project.pbxproj`
- Modify: `ParentApp/NesTimer/NesTimerApp.swift` (Mac default window size)

**Interfaces:**
- Consumes: `ChildrenViewModel` (Task 9), `AuthViewModel` (existing, injected as `@EnvironmentObject`).
- Produces: `ChildrenListView`, navigating to `ChildDetailView(childId:)` (Task 11) via `.navigationDestination(for: Child.self)`.

- [ ] **Step 1: Write the view**

Create `ParentApp/NesTimer/Views/ChildrenListView.swift`:

```swift
import SwiftUI

struct ChildrenListView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var vm = ChildrenViewModel()
    @State private var showAddChild = false
    @State private var newChildName = ""
    @State private var renameTarget: Child?
    @State private var renameText = ""

    var body: some View {
        List {
            if vm.children.isEmpty && !vm.isLoading {
                ContentUnavailableView {
                    Label("No Children", systemImage: "person.2")
                } description: {
                    Text("Add a child, then attach their Macs")
                } actions: {
                    Button("Add Child") { showAddChild = true }
                        .buttonStyle(.borderedProminent)
                }
            }

            ForEach(vm.children) { child in
                NavigationLink(value: child) {
                    ChildRow(child: child,
                             devices: vm.devices(for: child),
                             usedMinutes: vm.todayMinutes[child.id])
                }
                .swipeActions(edge: .trailing) {
                    // DELETE /children/{id} returns 400 while the child still has
                    // devices. Offering a button that can only fail is worse than not
                    // offering it, so it appears only once the child is empty.
                    if vm.devices(for: child).isEmpty {
                        Button("Delete", role: .destructive) {
                            Task { await vm.deleteChild(child.id) }
                        }
                    }
                    Button("Rename") {
                        renameTarget = child
                        renameText = child.name
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Children")
        .navigationDestination(for: Child.self) { child in
            ChildDetailView(childId: child.id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddChild = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .cancellationAction) {
                Menu {
                    if let user = authVM.user {
                        Text(user.name)
                        Text(user.email)
                        Divider()
                    }
                    Button("Sign Out", role: .destructive) { authVM.logout() }
                } label: {
                    Image(systemName: "person.circle")
                }
            }
        }
        .refreshable { await vm.load() }
        .task { await vm.load() }
        .alert("New Child", isPresented: $showAddChild) {
            TextField("Name", text: $newChildName)
            Button("Cancel", role: .cancel) { newChildName = "" }
            Button("Add") {
                let name = newChildName.trimmingCharacters(in: .whitespaces)
                newChildName = ""
                guard !name.isEmpty else { return }
                Task { await vm.createChild(name: name) }
            }
        }
        .alert("Rename Child", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                let target = renameTarget
                renameTarget = nil
                guard !name.isEmpty, let target else { return }
                Task { await vm.renameChild(target.id, name: name) }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}

struct ChildRow: View {
    let child: Child
    let devices: [Device]
    let usedMinutes: Double?

    private var onlineCount: Int {
        devices.filter(\.isOnline).count
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(child.name)
                    .font(.headline)
                Text(child.deviceCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let usedMinutes {
                    Text(durationText(usedMinutes))
                        .font(.headline)
                        .monospacedDigit()
                }
                if onlineCount > 0 {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("\(onlineCount) online")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Register the file in the Xcode project**

Same four `project.pbxproj` entries as Task 9 Step 2, copying the pattern from `DevicesListView.swift` (which lives in the `Views` group).

```bash
grep -c "ChildrenListView.swift" ParentApp/NesTimer.xcodeproj/project.pbxproj
```
Expected: `4`.

- [ ] **Step 3: Make it the home screen, with a Mac sidebar**

Replace the body of `ParentApp/NesTimer/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authVM: AuthViewModel

    var body: some View {
        Group {
            if authVM.isAuthenticated {
                #if os(macOS)
                NavigationSplitView {
                    ChildrenListView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                } detail: {
                    Text("Select a child")
                        .foregroundStyle(.secondary)
                }
                #else
                NavigationStack {
                    ChildrenListView()
                }
                #endif
            } else {
                LoginView()
            }
        }
        .animation(.default, value: authVM.isAuthenticated)
    }
}
```

- [ ] **Step 4: Widen the Mac window for the sidebar**

In `ParentApp/NesTimer/NesTimerApp.swift`, change:

```swift
        .defaultSize(width: 500, height: 700)
```
to:
```swift
        .defaultSize(width: 900, height: 650)
```

- [ ] **Step 5: Build both platforms**

Run the two `xcodebuild` commands from Task 7 Step 4.
Expected: `** BUILD SUCCEEDED **` twice. `ChildDetailView` and `durationText` already exist — Task 11 runs before this task (see the execution-order note at the top of Task 11).

- [ ] **Step 6: Commit**

```bash
git add ParentApp/NesTimer/Views/ChildrenListView.swift ParentApp/NesTimer/ContentView.swift \
        ParentApp/NesTimer/NesTimerApp.swift ParentApp/NesTimer.xcodeproj/project.pbxproj
git commit -m "feat: children list as the app's home screen"
```

---

### Task 11: `ChildDetailViewModel` and `ChildDetailView`

> **Runs before Task 10.** `ChildrenListView` navigates to `ChildDetailView` and uses
> `durationText`, both created here, so building Task 10 first would commit a tree that
> does not compile. Execution order is 1-9, then 11, then 10, then 12-14.

This is the largest task. It moves the shared sections off `DeviceDetailView` and gives them a home.

**Files:**
- Create: `ParentApp/NesTimer/ViewModels/ChildDetailViewModel.swift`
- Create: `ParentApp/NesTimer/Views/ChildDetailView.swift`
- Create: `ParentApp/NesTimer/Views/FormRows.swift`
- Modify: `ParentApp/NesTimer/Views/DeviceDetailView.swift`
- Modify: `ParentApp/NesTimer.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: every `APIClient` child method from Task 8; `Policy`, `PolicyUpdate`, `Activity`, `ActivityCreate`, `ActivityUpdate`.
- Produces: `ChildDetailView(childId: String)`; `ChildDetailViewModel` with `@Published var child: Child?`, `policy: Policy?`, `activities: [Activity]`, `devices: [Device]`, `usage: [UsageEntry]`, `hasNoDevices: Bool`, `errorMessage: String?`; and `FormRows.swift` holding the row helpers both detail screens use.

- [ ] **Step 1: Extract the shared row helpers first**

`toggleRow`, `timePickerRow`, `minutesPickerRow`, `infoRow` and `TimePickerCompact` currently live as private members of `DeviceDetailView` (around lines 627–759) and are needed by both screens. Move them into a new `ParentApp/NesTimer/Views/FormRows.swift` as internal free functions / types:

```swift
import SwiftUI

// Row helpers shared by ChildDetailView and DeviceDetailView. These were private members
// of DeviceDetailView until the child-level sections moved out; both screens need them.

func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn)
}

/// "2h 04m" / "45m". Lives here rather than on a view so ChildrenListView and
/// ChildDetailView can both use it without depending on each other.
func durationText(_ minutes: Double) -> String {
    let total = Int(minutes.rounded())
    return total < 60 ? "\(total)m" : "\(total / 60)h \(total % 60)m"
}
```

Copy the **existing bodies verbatim** from `DeviceDetailView.swift` rather than rewriting them — read lines 627–759 and move them as they are, changing only `private func` to `func` and dropping `self.` references. Delete the originals from `DeviceDetailView.swift`.

Register `FormRows.swift` in `project.pbxproj` (four entries, as in Task 9 Step 2), then build both platforms to confirm the move alone compiles before going further.

```bash
grep -c "FormRows.swift" ParentApp/NesTimer.xcodeproj/project.pbxproj
```
Expected: `4`.

- [ ] **Step 2: Commit the extraction on its own**

```bash
git add ParentApp/NesTimer/Views/FormRows.swift ParentApp/NesTimer/Views/DeviceDetailView.swift \
        ParentApp/NesTimer.xcodeproj/project.pbxproj
git commit -m "refactor: extract shared form rows from DeviceDetailView"
```

- [ ] **Step 3: Write `ChildDetailViewModel`**

Create `ParentApp/NesTimer/ViewModels/ChildDetailViewModel.swift`:

```swift
import Foundation

@MainActor
final class ChildDetailViewModel: ObservableObject {
    @Published var child: Child?
    @Published var policy: Policy?
    @Published var activities: [Activity] = []
    @Published var devices: [Device] = []
    @Published var usage: [UsageEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// True when the child has no devices, so no policy row exists. The API returns 404
    /// rather than creating one -- a Policy with device_id NULL would leave a device that
    /// attaches later without one. The view shows guidance instead of an editor.
    @Published var hasNoDevices = false

    let childId: String
    private let api = APIClient.shared

    init(childId: String) {
        self.childId = childId
    }

    var todayMinutes: Double {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        return usage.first(where: { $0.date == today })?.totalMinutes ?? 0
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let children = try await api.listChildren()
            child = children.first(where: { $0.id == childId })

            let allDevices = try await api.listDevices()
            devices = allDevices.filter { $0.childId == childId }
            hasNoDevices = devices.isEmpty

            usage = (try? await api.getChildUsage(childId: childId)) ?? []
            activities = (try? await api.listChildActivities(childId: childId)) ?? []

            do {
                policy = try await api.getChildPolicy(childId: childId)
            } catch APIError.notFound {
                policy = nil          // expected for a child with no devices
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func updatePolicy(_ update: PolicyUpdate) async {
        do {
            policy = try await api.updateChildPolicy(childId: childId, update: update)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func grantBonus(minutes: Int) async {
        do {
            try await api.grantChildBonus(childId: childId, minutes: minutes)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addActivity(_ activity: ActivityCreate) async {
        do {
            _ = try await api.createChildActivity(childId: childId, activity: activity)
            activities = (try? await api.listChildActivities(childId: childId)) ?? activities
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteActivity(_ activityId: String) async {
        do {
            try await api.deleteChildActivity(childId: childId, activityId: activityId)
            activities.removeAll { $0.id == activityId }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Write `ChildDetailView`**

Create `ParentApp/NesTimer/Views/ChildDetailView.swift`. Sections 1 and 2 are new, so their code is given in full; sections 3–5 are moved verbatim from `DeviceDetailView.swift`.

```swift
import SwiftUI

struct ChildDetailView: View {
    let childId: String
    @StateObject private var vm: ChildDetailViewModel

    init(childId: String) {
        self.childId = childId
        _vm = StateObject(wrappedValue: ChildDetailViewModel(childId: childId))
    }

    var body: some View {
        Form {
            sharedBudgetSection
            devicesSection

            if vm.hasNoDevices {
                Section {
                    ContentUnavailableView {
                        Label("No Devices", systemImage: "desktopcomputer")
                    } description: {
                        Text("Add a device to this child to set limits")
                    }
                }
            } else if vm.policy != nil {
                // Sections 3-5, moved from DeviceDetailView (see Steps below)
                downtimeSection
                screenTimeSection
                activitiesSection
                bonusSection
            }
        }
        .navigationTitle(vm.child?.name ?? "Child")
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }

    // MARK: - Shared budget

    private var sharedBudgetSection: some View {
        Section("Today") {
            let limit = vm.policy?.screenTimeLimitMinutes
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(durationText(vm.todayMinutes))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if let limit {
                        Text("of \(durationText(Double(limit)))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let limit, limit > 0 {
                    ProgressView(value: min(vm.todayMinutes / Double(limit), 1.0))
                }
                Text("Shared across every device below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        Section("Devices") {
            ForEach(vm.devices) { device in
                NavigationLink {
                    DeviceDetailView(deviceId: device.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(device.dailyCapMinutes.map { "cap: \(durationText(Double($0)))" }
                                 ?? "cap: none")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(device.isOnline ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
    }
}
```

Then add the moved sections:
- **`downtimeSection`, `screenTimeSection`, `perDayPickerRows`** — move from `DeviceDetailView.swift` lines 237–472 verbatim; change their save calls from `vm.updatePolicy(deviceId:…)` to `vm.updatePolicy(_:)`.
- **`activitiesSection`, `activityRow`, `AddActivityView`** — move from lines 475–536 and 762–839; change their calls to `vm.addActivity` / `vm.deleteActivity`.
- **`bonusSection`** — move from lines 190–234; call `vm.grantBonus(minutes:)`.

The `hasNoDevices` and `policy != nil` guards in `body` above are what keep the editor
off screen for a childless child, whose policy is a 404 by design.

- [ ] **Step 5: Strip the moved sections from `DeviceDetailView`**

Delete `bonusSection`, `downtimeSection`, `screenTimeSection`, `perDayPickerRows`, `activitiesSection`, `activityRow` and `AddActivityView` from `DeviceDetailView.swift`, and remove their call sites from its `body`. What remains: today's usage card, unlock code (TOTP), usage history, device info, and `EditDeviceNameView`.

Add a per-device cap row to the device info section:

```swift
Picker("Daily cap", selection: $capMinutes) {
    Text("None").tag(Optional<Int>.none)
    ForEach([30, 60, 90, 120, 180, 240], id: \.self) { m in
        Text("\(m / 60)h \(m % 60)m").tag(Optional(m))
    }
}
.onChange(of: capMinutes) { _, newValue in
    Task { await vm.updateCap(newValue) }
}
```

Add the matching `updateCap` to `DeviceDetailViewModel`:

```swift
    func updateCap(_ minutes: Int?) async {
        do {
            var update = DeviceUpdateRequest()
            update.dailyCapMinutes = minutes
            device = try await APIClient.shared.updateDevice(deviceId, update: update)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
```

- [ ] **Step 6: Register both new files and build**

Four `project.pbxproj` entries each for `ChildDetailViewModel.swift` and `ChildDetailView.swift`.

```bash
grep -c "ChildDetailView.swift" ParentApp/NesTimer.xcodeproj/project.pbxproj      # expect 4
grep -c "ChildDetailViewModel.swift" ParentApp/NesTimer.xcodeproj/project.pbxproj # expect 4
```

Run the two `xcodebuild` commands from Task 7 Step 4.
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Commit**

```bash
git add ParentApp/NesTimer/Views/ChildDetailView.swift \
        ParentApp/NesTimer/ViewModels/ChildDetailViewModel.swift \
        ParentApp/NesTimer/Views/DeviceDetailView.swift \
        ParentApp/NesTimer/ViewModels/DeviceDetailViewModel.swift \
        ParentApp/NesTimer.xcodeproj/project.pbxproj
git commit -m "feat: child detail screen owns the shared budget"
```

---

### Task 12: Move a device between children

The step that makes the merge possible from the app.

**Files:**
- Modify: `ParentApp/NesTimer/Views/DeviceDetailView.swift`
- Modify: `ParentApp/NesTimer/ViewModels/DeviceDetailViewModel.swift`

**Interfaces:**
- Consumes: `APIClient.listChildren`, `APIClient.updateDevice` with `DeviceUpdateRequest.childId`.
- Produces: a child picker on the device screen.

- [ ] **Step 1: Load the children list in `DeviceDetailViewModel`**

Add:

```swift
    @Published var allChildren: [Child] = []

    func loadChildren() async {
        // A failing /children request must not block the rest of the device screen --
        // the picker is unavailable, everything else still works.
        allChildren = (try? await APIClient.shared.listChildren()) ?? []
    }

    func moveToChild(_ childId: String) async {
        do {
            var update = DeviceUpdateRequest()
            update.childId = childId
            device = try await APIClient.shared.updateDevice(deviceId, update: update)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
```

Call `await loadChildren()` from the existing `load()`.

- [ ] **Step 2: Add the picker to the device info section**

```swift
if !vm.allChildren.isEmpty {
    Picker("Child", selection: Binding(
        get: { vm.device?.childId ?? "" },
        set: { newId in Task { await vm.moveToChild(newId) } }
    )) {
        ForEach(vm.allChildren) { child in
            Text(child.name).tag(child.id)
        }
    }
}
```

- [ ] **Step 3: Build both platforms**

Run the two `xcodebuild` commands from Task 7 Step 4.
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 4: Commit**

```bash
git add ParentApp/NesTimer/Views/DeviceDetailView.swift \
        ParentApp/NesTimer/ViewModels/DeviceDetailViewModel.swift
git commit -m "feat: move a device between children from the app"
```

---

### Task 13: Manual verification on both platforms

No test target exists, so this is the only functional verification the app gets. Do not skip it and do not report the app as working without it.

**Files:** none modified.

- [ ] **Step 1: Run the Mac app**

```bash
xcodebuild -project ParentApp/NesTimer.xcodeproj -scheme NesTimer -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES build
open ~/Library/Developer/Xcode/DerivedData/NesTimer-*/Build/Products/Debug/NesTimer.app
```

- [ ] **Step 2: Walk the checklist on Mac**

- [ ] Sidebar lists all three children with device counts
- [ ] Each child shows today's shared minutes
- [ ] Child detail shows the shared limit and today's usage
- [ ] Changing the limit persists across a relaunch
- [ ] Adding and deleting a scheduled activity works
- [ ] Granting a bonus updates `bonus_until`
- [ ] A child with no devices shows guidance, not an error or a blank editor
- [ ] Device detail shows the cap picker and the child picker
- [ ] Moving a device to another child updates both child rows

- [ ] **Step 3: Walk the same checklist on iPhone**

Run in the simulator, confirming the split view collapses to push navigation and every item above still holds.

- [ ] **Step 4: Confirm the limit reaches the agent**

Change a child's limit in the app, then:

```bash
ssh root@134.209.8.62 "cd /root/Nestimer && docker compose exec -T db psql -U nestimer -d nestimer -c \
  \"SELECT c.name, p.screen_time_limit_minutes FROM policies p JOIN children c ON c.id=p.child_id ORDER BY c.name;\""
```
Expected: the new value against that child.

- [ ] **Step 5: Commit any fixes**

```bash
git commit -am "fix: <what manual testing found>"
```

---

### Task 14: Ship to TestFlight

**Files:**
- Modify: `ParentApp/NesTimer.xcodeproj/project.pbxproj` (build number, bumped by the script)

- [ ] **Step 1: Confirm CI is green on `main`**

```bash
gh run list --branch main --limit 1
```

- [ ] **Step 2: Upload**

```bash
./push-ios-testflight.sh
```
Expected: `UPLOAD SUCCEEDED`, then `Uploaded 1.0 (6) to TestFlight.`

If it fails with `No Keychain password item found for profile: nestimer-notary`, the keychain item must be recreated interactively by the user — a background process cannot write to the login keychain. See `reference_signing_distribution.md`.

- [ ] **Step 3: Commit the build number**

```bash
git add ParentApp/NesTimer.xcodeproj/project.pbxproj
git commit -m "chore: iOS build 6 (TestFlight upload)"
git push origin main
```

- [ ] **Step 4: Hand back to the user**

Report that the merge (putting both Macs under one child) is now safe to do, and that it is theirs to perform — it is the step that actually changes their son's day.
