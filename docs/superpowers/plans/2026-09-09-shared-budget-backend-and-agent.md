# Shared Time Budget — Backend, Web & macOS Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each child one daily time budget shared across all their devices, with an optional per-device ceiling, without changing behaviour for anything already deployed.

**Architecture:** A new `Child` entity owns the policy, activities and bonus window; devices hang off it. The server aggregates `SUM(usage_logs.total_minutes)` across a child's devices into `used_minutes_today`, so already-installed agents honour the shared budget with no update. Each client still decides locally whether to lock, so offline enforcement keeps working.

**Tech Stack:** FastAPI, SQLAlchemy 2 async, PostgreSQL 16 (SQLite in tests), pytest + httpx AsyncClient, React + Vite, Swift 5 / XCTest.

**Spec:** `docs/superpowers/specs/2026-09-09-cross-platform-shared-budget-design.md`

**Scope:** Rollout steps 1–3 of the spec. The Android counter (step 4) and the iOS child client (step 5) get their own plans. The SwiftUI parent app is deliberately excluded — the web dashboard is enough to perform the merge, and the parent app keeps working through the alias endpoints; it gets a follow-up plan.

## Global Constraints

- All datetime writes use `datetime.now(timezone.utc)`, never `utcnow()`. DB columns are `DateTime(timezone=True)`.
- Migrations live in `api/app/database.py::init_db()` and must be dialect-agnostic (they run on SQLite in tests and PostgreSQL in production) and idempotent (they run on every boot).
- No Russian text anywhere. All code, comments, commits and UI copy in English.
- Conventional commits: `feat:`, `fix:`, `perf:`, `security:`, `ci:`, `chore:`, `docs:`, `refactor:`.
- Run the API test suite with: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest`
- `Policy.device_id` and `Activity.device_id` are retained for one full release. Do not drop them in this plan.
- Every existing endpoint under `/api/v1/devices/{id}/...` must keep working unchanged — the TestFlight parent app cannot be updated in lockstep.
- macOS agent deployment target is 13+; avoid macOS 14-only APIs without an availability check.

---

### Task 1: `Child` model and additive schema migration

Adds the table and columns with no behaviour change at all. Nothing reads them yet.

**Files:**
- Modify: `api/app/models/models.py`
- Modify: `api/app/database.py:35-48` (the migrations block in `init_db`)
- Test: `api/tests/test_children.py` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `Child` model with fields `id: str`, `owner_id: str`, `name: str`, `bonus_until: datetime | None`, `created_at: datetime`; `Device.child_id: str | None`, `Device.platform: str`, `Device.daily_cap_minutes: int | None`; `Policy.child_id: str | None`; `Activity.child_id: str | None`.

- [ ] **Step 1: Write the failing test**

Create `api/tests/test_children.py`:

```python
import pytest
from sqlalchemy import inspect

from app.models.models import Child, Device

pytestmark = pytest.mark.anyio


async def test_child_table_and_device_columns_exist(db_session):
    """The Child entity and the new Device columns are part of the schema."""
    def _tables(sync_conn):
        return set(inspect(sync_conn).get_table_names())

    def _device_columns(sync_conn):
        return {c["name"] for c in inspect(sync_conn).get_columns("devices")}

    conn = await db_session.connection()
    assert "children" in await conn.run_sync(_tables)
    cols = await conn.run_sync(_device_columns)
    assert {"child_id", "platform", "daily_cap_minutes"} <= cols


async def test_child_defaults(db_session):
    """A Child can be created with just an owner and a name."""
    child = Child(owner_id="owner-1", name="Alex")
    db_session.add(child)
    await db_session.flush()

    assert child.id
    assert child.bonus_until is None
    assert child.created_at is not None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest tests/test_children.py -v`
Expected: FAIL — `ImportError: cannot import name 'Child' from 'app.models.models'`

- [ ] **Step 3: Add the model**

In `api/app/models/models.py`, add after the `User` class:

```python
class Child(Base):
    """A child. Owns the policy, activities and bonus window shared by all their devices."""
    __tablename__ = "children"

    id = Column(String, primary_key=True, default=gen_uuid)
    owner_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    name = Column(String, nullable=False)
    bonus_until = Column(DateTime(timezone=True), nullable=True)  # parent-granted temporary unlock
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    devices = relationship("Device", back_populates="child")
```

In the `Device` class, add these columns after `owner_id`:

```python
    child_id = Column(String, ForeignKey("children.id"), nullable=True, index=True)
    platform = Column(String, nullable=False, default="macos")  # macos | android | ios
    daily_cap_minutes = Column(Integer, nullable=True)  # per-device ceiling; null = no ceiling
```

and this relationship next to the existing `owner`:

```python
    child = relationship("Child", back_populates="devices")
```

In `Policy`, make `device_id` nullable and add `child_id`:

```python
    device_id = Column(String, ForeignKey("devices.id"), unique=True, nullable=True)
    child_id = Column(String, ForeignKey("children.id"), unique=True, nullable=True)
```

In `Activity`, the same shape:

```python
    device_id = Column(String, ForeignKey("devices.id"), nullable=True, index=True)
    child_id = Column(String, ForeignKey("children.id"), nullable=True, index=True)
```

- [ ] **Step 4: Add the migration for existing databases**

In `api/app/database.py`, inside `init_db()`, append to the migrations block:

```python
        # children / shared-budget migration (see specs/2026-09-09-cross-platform-shared-budget-design.md)
        await _add_column_if_missing(conn, "devices", "child_id", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "platform", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "daily_cap_minutes", "INTEGER", dev_cols)
        await _add_column_if_missing(conn, "policies", "child_id", "TEXT", pol_cols)

        act_cols = await _get_columns(conn, "activities")
        await _add_column_if_missing(conn, "activities", "child_id", "TEXT", act_cols)

        # Existing rows predate `platform`; they are all Macs.
        await conn.execute(text("UPDATE devices SET platform = 'macos' WHERE platform IS NULL"))

        # Policies and activities may now belong to a child instead of a device.
        # SQLite cannot drop NOT NULL, but its test databases are created fresh
        # from the models, where these columns are already nullable.
        if conn.dialect.name == "postgresql":
            await conn.execute(text("ALTER TABLE policies ALTER COLUMN device_id DROP NOT NULL"))
            await conn.execute(text("ALTER TABLE activities ALTER COLUMN device_id DROP NOT NULL"))
```

- [ ] **Step 5: Run the new test and the full suite**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest`
Expected: PASS — the two new tests pass and every existing test still passes. Nothing reads the new columns yet, so no existing behaviour can have changed.

- [ ] **Step 6: Commit**

```bash
git add api/app/models/models.py api/app/database.py api/tests/test_children.py
git commit -m "feat: add Child model and additive shared-budget columns"
```

---

### Task 2: 1:1 backfill migration

Every existing device gets its own child. This is the task the whole rollout rests on, so its test is a golden comparison.

**Files:**
- Modify: `api/app/database.py` (add `_backfill_children`, call it from `init_db`)
- Test: `api/tests/test_children.py` (append)

**Interfaces:**
- Consumes: the `Child` model and columns from Task 1.
- Produces: `async def _backfill_children(conn) -> None` — idempotent; gives every `devices` row with `child_id IS NULL` a fresh child and repoints that device's policy and activities at it.

- [ ] **Step 1: Write the failing test**

Append to `api/tests/test_children.py`:

```python
from sqlalchemy import text

from app.database import _backfill_children


async def test_backfill_creates_one_child_per_device(db_session):
    """Migration is strictly 1:1 — two devices never get merged, even with the same child_name."""
    conn = await db_session.connection()
    await conn.execute(text(
        "INSERT INTO users (id, email, hashed_password, name) "
        "VALUES ('u1', 'p@test.com', 'x', 'Parent')"
    ))
    for dev in ("d1", "d2"):
        await conn.execute(text(
            "INSERT INTO devices (id, owner_id, name, child_name, api_token, platform) "
            f"VALUES ('{dev}', 'u1', '{dev}', 'Alex', 'tok-{dev}', 'macos')"
        ))
        await conn.execute(text(
            f"INSERT INTO policies (id, device_id, screen_time_limit_minutes) VALUES ('p-{dev}', '{dev}', 120)"
        ))

    await _backfill_children(conn)

    rows = (await conn.execute(text("SELECT id, child_id FROM devices ORDER BY id"))).fetchall()
    child_ids = {r[1] for r in rows}
    assert len(child_ids) == 2, "each device must get its own child, not a merged one"
    assert None not in child_ids

    # Each policy follows its device's child, and device_id is left in place.
    for dev_id, child_id in rows:
        pol = (await conn.execute(text(
            "SELECT child_id, device_id FROM policies WHERE device_id = :d"
        ), {"d": dev_id})).fetchone()
        assert pol[0] == child_id
        assert pol[1] == dev_id


async def test_backfill_is_idempotent(db_session):
    """init_db runs on every boot, so a second pass must be a no-op."""
    conn = await db_session.connection()
    await conn.execute(text(
        "INSERT INTO users (id, email, hashed_password, name) VALUES ('u1', 'p@test.com', 'x', 'Parent')"
    ))
    await conn.execute(text(
        "INSERT INTO devices (id, owner_id, name, child_name, api_token, platform) "
        "VALUES ('d1', 'u1', 'Mac', 'Alex', 'tok-1', 'macos')"
    ))

    await _backfill_children(conn)
    first = (await conn.execute(text("SELECT child_id FROM devices WHERE id = 'd1'"))).scalar_one()
    await _backfill_children(conn)
    second = (await conn.execute(text("SELECT child_id FROM devices WHERE id = 'd1'"))).scalar_one()

    assert first == second
    count = (await conn.execute(text("SELECT COUNT(*) FROM children"))).scalar_one()
    assert count == 1


async def test_backfill_carries_bonus_window_to_child(db_session):
    """bonus_until belongs to the child now; the device's existing window must not be lost."""
    conn = await db_session.connection()
    await conn.execute(text(
        "INSERT INTO users (id, email, hashed_password, name) VALUES ('u1', 'p@test.com', 'x', 'Parent')"
    ))
    await conn.execute(text(
        "INSERT INTO devices (id, owner_id, name, child_name, api_token, platform, bonus_until) "
        "VALUES ('d1', 'u1', 'Mac', 'Alex', 'tok-1', 'macos', '2026-09-09 18:00:00+00')"
    ))

    await _backfill_children(conn)

    bonus = (await conn.execute(text(
        "SELECT c.bonus_until FROM children c JOIN devices d ON d.child_id = c.id WHERE d.id = 'd1'"
    ))).scalar_one()
    assert bonus is not None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest tests/test_children.py -v`
Expected: FAIL — `ImportError: cannot import name '_backfill_children' from 'app.database'`

- [ ] **Step 3: Implement the backfill**

In `api/app/database.py`, add these imports at the top:

```python
import uuid
from datetime import datetime, timezone
```

and this function above `init_db`:

```python
async def _backfill_children(conn):
    """Give every device without a child its own child (strictly 1:1).

    Merging devices under one child is an explicit parent action in the UI —
    guessing it here from a matching child_name would silently halve the
    effective daily limit for real users. Idempotent: init_db runs on every boot.
    """
    rows = (await conn.execute(text(
        "SELECT id, owner_id, child_name, bonus_until FROM devices WHERE child_id IS NULL"
    ))).fetchall()

    for dev_id, owner_id, child_name, bonus_until in rows:
        child_id = str(uuid.uuid4())
        await conn.execute(
            text(
                "INSERT INTO children (id, owner_id, name, bonus_until, created_at) "
                "VALUES (:id, :owner_id, :name, :bonus_until, :created_at)"
            ),
            {
                "id": child_id,
                "owner_id": owner_id,
                "name": child_name or "Child",
                "bonus_until": bonus_until,
                "created_at": datetime.now(timezone.utc),
            },
        )
        for stmt in (
            "UPDATE devices SET child_id = :child_id WHERE id = :dev_id",
            "UPDATE policies SET child_id = :child_id WHERE device_id = :dev_id",
            "UPDATE activities SET child_id = :child_id WHERE device_id = :dev_id",
        ):
            await conn.execute(text(stmt), {"child_id": child_id, "dev_id": dev_id})
```

Call it at the end of the migrations block in `init_db()`:

```python
        await _backfill_children(conn)
```

- [ ] **Step 4: Run the tests**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest`
Expected: PASS, all tests.

- [ ] **Step 5: Commit**

```bash
git add api/app/database.py api/tests/test_children.py
git commit -m "feat: backfill one child per existing device (1:1, idempotent)"
```

---

### Task 3: `/agent/config` returns the child's shared usage

The behavioural core. After this task an unmodified agent 2.9 starts honouring the shared budget.

**Files:**
- Modify: `api/app/routers/agent.py:56-145` (`get_config`)
- Modify: `api/app/schemas.py:172-186` (`AgentConfig`)
- Test: `api/tests/test_shared_budget.py` (create)

**Interfaces:**
- Consumes: `Device.child_id`, `Device.daily_cap_minutes`, `Policy.child_id` from Tasks 1–2.
- Produces: `AgentConfig` gains `device_used_minutes: float` and `device_cap_minutes: int | None`; `used_minutes_today` now means the child's total across devices.

- [ ] **Step 1: Write the failing test**

Create `api/tests/test_shared_budget.py`:

```python
import pytest
from sqlalchemy import text

from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


async def _link_devices_to_one_child(client, token, dev_a, dev_b):
    """Point dev_b at dev_a's child, the way the merge action in the UI will."""
    resp = await client.get(f"/api/v1/devices/{dev_a['id']}", headers={"Authorization": f"Bearer {token}"})
    child_id = resp.json()["child_id"]
    resp = await client.patch(
        f"/api/v1/devices/{dev_b['id']}",
        json={"child_id": child_id},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    return child_id


async def test_usage_is_summed_across_the_childs_devices(client):
    """The Mac sees time spent on the phone: one budget, one counter."""
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")
    await _link_devices_to_one_child(client, token, mac, phone)

    for device, minutes in ((mac, 30.0), (phone, 45.0)):
        resp = await client.post(
            "/api/v1/agent/usage",
            json={"date": "2026-09-09", "total_minutes": minutes},
            headers={"Authorization": f"Bearer {device['api_token']}"},
        )
        assert resp.status_code == 200

    resp = await client.get(
        "/api/v1/agent/config?date=2026-09-09",
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    config = resp.json()
    assert config["used_minutes_today"] == 75.0, "shared budget must include the phone's time"
    assert config["device_used_minutes"] == 30.0, "this device's own counter stays separate"


async def test_repeated_absolute_total_does_not_double_count(client):
    """Agents send an absolute total, not a delta — re-sending must be a no-op."""
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")

    for _ in range(3):
        await client.post(
            "/api/v1/agent/usage",
            json={"date": "2026-09-09", "total_minutes": 40.0},
            headers={"Authorization": f"Bearer {mac['api_token']}"},
        )

    resp = await client.get(
        "/api/v1/agent/config?date=2026-09-09",
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    assert resp.json()["used_minutes_today"] == 40.0


async def test_device_cap_is_reported(client):
    """The per-device ceiling reaches the agent; the agent applies it."""
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")
    await client.patch(
        f"/api/v1/devices/{mac['id']}",
        json={"daily_cap_minutes": 60},
        headers={"Authorization": f"Bearer {token}"},
    )

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    assert resp.json()["device_cap_minutes"] == 60


async def test_config_shape_is_unchanged_for_old_agents(client):
    """Agent 2.9 in the field must keep decoding this response."""
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    config = resp.json()
    for key in (
        "downtime_enabled", "downtime_start", "downtime_end",
        "screen_time_enabled", "screen_time_limit_minutes",
        "used_minutes_today", "activities", "bonus_until",
    ):
        assert key in config, f"removing {key} would break installed agents"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest tests/test_shared_budget.py -v`
Expected: FAIL — `KeyError: 'child_id'` in the helper and `KeyError: 'device_used_minutes'`.

- [ ] **Step 3: Extend the schema**

In `api/app/schemas.py`, add two fields to `AgentConfig`, after `used_minutes_today`:

```python
    device_used_minutes: float = 0.0       # this device's own total for the day
    device_cap_minutes: Optional[int] = None  # per-device ceiling; null = no ceiling
```

- [ ] **Step 4: Aggregate in `get_config`**

In `api/app/routers/agent.py`, add `func` to the SQLAlchemy import:

```python
from sqlalchemy import select, func
```

Replace the policy lookup (currently `select(Policy).where(Policy.device_id == device.id)`) with a child-aware lookup:

```python
    # Policy lives on the child; fall back to the device for rows not yet backfilled.
    if device.child_id:
        result = await db.execute(select(Policy).where(Policy.child_id == device.child_id))
    else:
        result = await db.execute(select(Policy).where(Policy.device_id == device.id))
    policy = result.scalar_one_or_none()
```

Replace the usage lookup with the per-child sum plus this device's own row:

```python
    # This device's own counter (used for the per-device ceiling).
    result = await db.execute(
        select(UsageLog).where(UsageLog.device_id == device.id, UsageLog.date == today)
    )
    own = result.scalar_one_or_none()
    device_used = own.total_minutes if own else 0.0

    # The child's shared counter: the sum over every device they own.
    if device.child_id:
        result = await db.execute(
            select(func.coalesce(func.sum(UsageLog.total_minutes), 0.0))
            .select_from(UsageLog)
            .join(Device, Device.id == UsageLog.device_id)
            .where(Device.child_id == device.child_id, UsageLog.date == today)
        )
        used_today = float(result.scalar_one())
    else:
        used_today = device_used
```

Add the two new fields to both `AgentConfig(...)` returns in the function — the early "no policy" return uses zeroes:

```python
            device_used_minutes=0.0,
            device_cap_minutes=device.daily_cap_minutes,
```

and the main return:

```python
        device_used_minutes=device_used,
        device_cap_minutes=device.daily_cap_minutes,
```

- [ ] **Step 5: Run the tests**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest`
Expected: the four new tests still fail on `child_id` / `daily_cap_minutes` in the PATCH body (Task 6 adds those); `test_repeated_absolute_total_does_not_double_count` and `test_config_shape_is_unchanged_for_old_agents` PASS. Every pre-existing test passes.

Note for the implementer: this is expected. Tasks 3 and 6 are split because the aggregation is worth reviewing on its own, but two of these tests only go green after Task 6. Do not weaken the tests to make them pass here.

- [ ] **Step 6: Commit**

```bash
git add api/app/routers/agent.py api/app/schemas.py api/tests/test_shared_budget.py
git commit -m "feat: aggregate usage per child in /agent/config"
```

---

### Task 4: `/children` parent API

**Files:**
- Create: `api/app/routers/children.py`
- Modify: `api/app/main.py` (register the router)
- Modify: `api/app/schemas.py` (add child schemas)
- Test: `api/tests/test_children_api.py` (create)

**Interfaces:**
- Consumes: the `Child` model from Task 1.
- Produces: `GET /api/v1/children`, `POST /api/v1/children`, `PATCH /api/v1/children/{child_id}`, `DELETE /api/v1/children/{child_id}`. Schemas `ChildCreate {name: str}`, `ChildUpdate {name: str | None}`, `ChildOut {id, name, bonus_until, created_at, device_ids: list[str]}`.

- [ ] **Step 1: Write the failing test**

Create `api/tests/test_children_api.py`:

```python
import pytest

from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


async def test_create_and_list_children(client):
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}

    resp = await client.post("/api/v1/children", json={"name": "Alex"}, headers=headers)
    assert resp.status_code == 200
    child = resp.json()
    assert child["name"] == "Alex"
    assert child["device_ids"] == []

    resp = await client.get("/api/v1/children", headers=headers)
    assert [c["id"] for c in resp.json()] == [child["id"]]


async def test_creating_a_device_creates_a_child(client):
    """The existing 'add a device' flow must keep working without a child_id."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    device = await create_device(client, token, child_name="Alex")

    resp = await client.get("/api/v1/children", headers=headers)
    children = resp.json()
    assert len(children) == 1
    assert children[0]["name"] == "Alex"
    assert children[0]["device_ids"] == [device["id"]]


async def test_children_are_scoped_to_their_owner(client):
    """One parent must never see another parent's children."""
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    await client.post("/api/v1/children", json={"name": "Alex"},
                      headers={"Authorization": f"Bearer {token_a}"})

    resp = await client.get("/api/v1/children", headers={"Authorization": f"Bearer {token_b}"})
    assert resp.json() == []


async def test_rename_child(client):
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    child = (await client.post("/api/v1/children", json={"name": "Alex"}, headers=headers)).json()

    resp = await client.patch(f"/api/v1/children/{child['id']}", json={"name": "Alexander"}, headers=headers)
    assert resp.status_code == 200
    assert resp.json()["name"] == "Alexander"


async def test_cannot_delete_a_child_that_still_has_devices(client):
    """Deleting would orphan the devices and leave them unmanaged."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    await create_device(client, token, child_name="Alex")
    child_id = (await client.get("/api/v1/children", headers=headers)).json()[0]["id"]

    resp = await client.delete(f"/api/v1/children/{child_id}", headers=headers)
    assert resp.status_code == 400
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest tests/test_children_api.py -v`
Expected: FAIL — all requests return 404, the router does not exist.

- [ ] **Step 3: Add the schemas**

In `api/app/schemas.py`:

```python
class ChildCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)


class ChildUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=100)


class ChildOut(BaseModel):
    id: str
    name: str
    bonus_until: Optional[datetime] = None
    created_at: Optional[datetime] = None
    device_ids: list[str] = Field(default_factory=list)

    @field_serializer("bonus_until", "created_at")
    def _serialize_dt(self, v: Optional[datetime]) -> Optional[str]:
        v = _ensure_utc(v)
        return v.isoformat() if v else None
```

- [ ] **Step 4: Add the router**

Create `api/app/routers/children.py`:

```python
"""Parent-facing endpoints for managing children."""
from typing import List

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_current_user
from ..database import get_db
from ..models.models import Child, Device, Policy, User
from ..schemas import ChildCreate, ChildOut, ChildUpdate

router = APIRouter(prefix="/children", tags=["children"])


async def _verify_child_owner(db: AsyncSession, child_id: str, user_id: str) -> Child:
    result = await db.execute(
        select(Child).where(Child.id == child_id, Child.owner_id == user_id)
    )
    child = result.scalar_one_or_none()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")
    return child


async def _to_out(db: AsyncSession, child: Child) -> ChildOut:
    result = await db.execute(select(Device.id).where(Device.child_id == child.id))
    return ChildOut(
        id=child.id,
        name=child.name,
        bonus_until=child.bonus_until,
        created_at=child.created_at,
        device_ids=list(result.scalars().all()),
    )


@router.post("", response_model=ChildOut)
async def create_child(
    data: ChildCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = Child(owner_id=user.id, name=data.name)
    db.add(child)
    await db.flush()
    db.add(Policy(child_id=child.id))  # default policy, same defaults as a new device
    await db.commit()
    await db.refresh(child)
    return await _to_out(db, child)


@router.get("", response_model=List[ChildOut])
async def list_children(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(Child).where(Child.owner_id == user.id))
    return [await _to_out(db, c) for c in result.scalars().all()]


@router.patch("/{child_id}", response_model=ChildOut)
async def update_child(
    child_id: str,
    data: ChildUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    if data.name is not None:
        child.name = data.name
    await db.commit()
    await db.refresh(child)
    return await _to_out(db, child)


@router.delete("/{child_id}")
async def delete_child(
    child_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    result = await db.execute(select(Device.id).where(Device.child_id == child.id))
    if result.scalars().first():
        raise HTTPException(
            status_code=400,
            detail="Move or delete this child's devices first",
        )
    await db.delete(child)
    await db.commit()
    return {"ok": True}
```

Register it in `api/app/main.py` next to the existing routers:

```python
from .routers import children
app.include_router(children.router, prefix="/api/v1")
```

Match the exact `include_router` style already used in that file for `devices` and `agent`.

- [ ] **Step 5: Run the tests**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest tests/test_children_api.py -v`
Expected: PASS except `test_creating_a_device_creates_a_child`, which Task 6 completes.

- [ ] **Step 6: Commit**

```bash
git add api/app/routers/children.py api/app/main.py api/app/schemas.py api/tests/test_children_api.py
git commit -m "feat: /children CRUD for parents"
```

---

### Task 5: Device endpoints resolve through the child

Policy, activities and bonus now live on the child, but every existing `/devices/{id}/...` route must behave exactly as before.

**Files:**
- Modify: `api/app/routers/devices.py:197-257` (policy get/put), `:282-301` (grant bonus), `:347-355` (`_verify_device_owner`), `:357-445` (activities)
- Test: `api/tests/test_device_aliases.py` (create)

**Interfaces:**
- Consumes: `Device.child_id` (Task 1), `Policy.child_id`, `Activity.child_id`.
- Produces: `async def _child_id_for_device(db: AsyncSession, device: Device) -> str` — returns the device's `child_id`, creating a child on the fly for any device that somehow still lacks one.

- [ ] **Step 1: Write the failing test**

Create `api/tests/test_device_aliases.py`:

```python
import pytest

from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


async def test_policy_set_on_one_device_applies_to_the_whole_child(client):
    """Two devices, one child: the limit is the child's, not the laptop's."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")

    child_id = (await client.get(f"/api/v1/devices/{mac['id']}", headers=headers)).json()["child_id"]
    await client.patch(f"/api/v1/devices/{phone['id']}", json={"child_id": child_id}, headers=headers)

    await client.put(
        f"/api/v1/devices/{mac['id']}/policy",
        json={"screen_time_limit_minutes": 45},
        headers=headers,
    )

    resp = await client.get(f"/api/v1/devices/{phone['id']}/policy", headers=headers)
    assert resp.json()["screen_time_limit_minutes"] == 45


async def test_bonus_granted_on_one_device_reaches_the_other(client):
    """Bonus time is granted to the child, so every device unlocks."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")

    child_id = (await client.get(f"/api/v1/devices/{mac['id']}", headers=headers)).json()["child_id"]
    await client.patch(f"/api/v1/devices/{phone['id']}", json={"child_id": child_id}, headers=headers)

    resp = await client.post(
        f"/api/v1/devices/{mac['id']}/grant-bonus", json={"minutes": 30}, headers=headers
    )
    assert resp.status_code == 200

    resp = await client.get(
        "/api/v1/agent/config", headers={"Authorization": f"Bearer {phone['api_token']}"}
    )
    assert resp.json()["bonus_until"] is not None


async def test_activity_created_on_one_device_is_visible_from_the_other(client):
    """An English class belongs to the child, not to a laptop."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")

    child_id = (await client.get(f"/api/v1/devices/{mac['id']}", headers=headers)).json()["child_id"]
    await client.patch(f"/api/v1/devices/{phone['id']}", json={"child_id": child_id}, headers=headers)

    await client.post(
        f"/api/v1/devices/{mac['id']}/activities",
        json={"name": "English", "day_of_week": 1, "start_time": "17:00", "end_time": "18:00"},
        headers=headers,
    )

    resp = await client.get(f"/api/v1/devices/{phone['id']}/activities", headers=headers)
    assert [a["name"] for a in resp.json()] == ["English"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest tests/test_device_aliases.py -v`
Expected: FAIL — the policy set on the Mac is invisible from the phone (each still has its own row).

- [ ] **Step 3: Add the resolver**

In `api/app/routers/devices.py`, next to `_verify_device_owner`:

```python
async def _child_id_for_device(db: AsyncSession, device: Device) -> str:
    """Resolve a device to its child, creating one if the row predates the migration."""
    if device.child_id:
        return device.child_id
    child = Child(owner_id=device.owner_id, name=device.child_name or "Child")
    db.add(child)
    await db.flush()
    device.child_id = child.id
    return child.id
```

Import `Child` in that module's model import.

- [ ] **Step 4: Point policy, activities and bonus at the child**

In every policy, activity and bonus handler, replace the `Policy.device_id == device_id` / `Activity.device_id == device_id` filters with the child equivalent. For example, `get_policy` becomes:

```python
    device = await _verify_device_owner(db, device_id, user.id)
    child_id = await _child_id_for_device(db, device)
    result = await db.execute(select(Policy).where(Policy.child_id == child_id))
    policy = result.scalar_one_or_none()
    if not policy:
        policy = Policy(child_id=child_id)
        db.add(policy)
        await db.commit()
        await db.refresh(policy)
    return policy_to_out(policy)
```

`grant_bonus` writes to the child instead of the device:

```python
    device = await _verify_device_owner(db, device_id, user.id)
    child_id = await _child_id_for_device(db, device)
    result = await db.execute(select(Child).where(Child.id == child_id))
    child = result.scalar_one()
    child.bonus_until = datetime.now(timezone.utc) + timedelta(minutes=data.minutes)
    await db.commit()
    return GrantBonusResponse(bonus_until=child.bonus_until)
```

Apply the same substitution to `update_policy`, `list_activities`, `create_activity`, `update_activity` and `delete_activity`: resolve the child first, then filter on `child_id`.

- [ ] **Step 5: Read the bonus window from the child in `/agent/config`**

In `api/app/routers/agent.py`, replace the `device.bonus_until` lookup with the child's:

```python
    bu = None
    if device.child_id:
        result = await db.execute(select(Child.bonus_until).where(Child.id == device.child_id))
        bu = result.scalar_one_or_none()
    if bu is None:
        bu = device.bonus_until  # pre-migration fallback
    # SQLite returns naive datetimes even for tz-aware columns — coerce to UTC.
    if bu is not None and bu.tzinfo is None:
        bu = bu.replace(tzinfo=timezone.utc)
    bonus_until = bu if bu and bu > now else None
```

Add `Child` to that module's model import.

- [ ] **Step 6: Write the golden migration test**

This is the spec's primary test: a device that predates the migration must get a
byte-identical `/agent/config` response after it. Append to `api/tests/test_device_aliases.py`:

```python
from sqlalchemy import text

from app.database import _backfill_children


async def test_config_is_byte_identical_across_the_migration(client, db_session):
    """The migration must be invisible to an agent already in the field."""
    token = await register_user(client)
    device = await create_device(client, token, name="Mac", child_name="Alex")
    headers = {"Authorization": f"Bearer {device['api_token']}"}

    await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={"screen_time_limit_minutes": 90, "downtime_start": "21:30"},
        headers={"Authorization": f"Bearer {token}"},
    )
    await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-09-09", "total_minutes": 25.0},
        headers=headers,
    )

    before = (await client.get("/api/v1/agent/config?date=2026-09-09", headers=headers)).json()

    # Rewind this device to its pre-migration shape, then migrate it forward again.
    conn = await db_session.connection()
    await conn.execute(text("UPDATE devices SET child_id = NULL"))
    await conn.execute(text("UPDATE policies SET child_id = NULL"))
    await conn.execute(text("UPDATE activities SET child_id = NULL"))
    await conn.commit()

    legacy = (await client.get("/api/v1/agent/config?date=2026-09-09", headers=headers)).json()

    conn = await db_session.connection()
    await _backfill_children(conn)
    await conn.commit()

    after = (await client.get("/api/v1/agent/config?date=2026-09-09", headers=headers)).json()

    # last_seen is written on every request and is not part of the response,
    # so these three payloads must match exactly.
    assert legacy == before, "the device-level fallback must match the child-level result"
    assert after == before, "migrating must not change what the agent sees"
```

Note for the implementer: if this test fails, do not adjust it to pass. A difference
here means the migration changes behaviour for a device already in the field, which is
the one thing this rollout promises it will not do. Fix the code.

- [ ] **Step 7: Run the full suite**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest`
Expected: PASS. Existing `test_policy.py`, `test_activities.py` and `test_devices.py` must pass untouched — they exercise the alias routes, which is exactly the guarantee this task makes.

- [ ] **Step 8: Commit**

```bash
git add api/app/routers/devices.py api/app/routers/agent.py api/tests/test_device_aliases.py
git commit -m "feat: resolve device policy, activities and bonus through the child"
```

---

### Task 6: Device create and update accept child, platform and cap

Closes the tests left red by Tasks 3 and 4.

**Files:**
- Modify: `api/app/routers/devices.py:65-101` (`create_device`), `:145-178` (`update_device`)
- Modify: `api/app/schemas.py` (`DeviceCreate`, `DeviceUpdate`, `DeviceOut`, `DeviceListOut`)
- Test: `api/tests/test_devices.py` (append)

**Interfaces:**
- Consumes: `_child_id_for_device` (Task 5), `Child` (Task 1).
- Produces: `DeviceCreate` gains `child_id: str | None`, `platform: str = "macos"`; `DeviceUpdate` gains `child_id: str | None`, `daily_cap_minutes: int | None`; `DeviceOut`/`DeviceListOut` gain `child_id`, `platform`, `daily_cap_minutes`.

- [ ] **Step 1: Write the failing test**

Append to `api/tests/test_devices.py`:

```python
async def test_device_can_be_moved_to_another_child(client):
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")

    child_id = (await client.get(f"/api/v1/devices/{mac['id']}", headers=headers)).json()["child_id"]
    resp = await client.patch(
        f"/api/v1/devices/{phone['id']}", json={"child_id": child_id}, headers=headers
    )
    assert resp.status_code == 200
    assert resp.json()["child_id"] == child_id


async def test_cannot_move_a_device_to_another_parents_child(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    device_a = await create_device(client, token_a, name="Mac A")
    device_b = await create_device(client, token_b, name="Mac B")

    child_a = (await client.get(
        f"/api/v1/devices/{device_a['id']}", headers={"Authorization": f"Bearer {token_a}"}
    )).json()["child_id"]

    resp = await client.patch(
        f"/api/v1/devices/{device_b['id']}",
        json={"child_id": child_a},
        headers={"Authorization": f"Bearer {token_b}"},
    )
    assert resp.status_code == 404


async def test_daily_cap_can_be_set_and_cleared(client):
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac")

    resp = await client.patch(
        f"/api/v1/devices/{mac['id']}", json={"daily_cap_minutes": 60}, headers=headers
    )
    assert resp.json()["daily_cap_minutes"] == 60

    resp = await client.patch(
        f"/api/v1/devices/{mac['id']}", json={"daily_cap_minutes": None}, headers=headers
    )
    assert resp.json()["daily_cap_minutes"] is None


async def test_device_defaults_to_macos_platform(client):
    token = await register_user(client)
    device = await create_device(client, token, name="Mac")
    assert device["platform"] == "macos"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest tests/test_devices.py -v`
Expected: FAIL — `KeyError: 'child_id'`.

- [ ] **Step 3: Extend the schemas**

In `api/app/schemas.py`, add to `DeviceCreate`:

```python
    child_id: Optional[str] = None            # attach to an existing child; a new one is created if omitted
    platform: str = Field(default="macos", pattern="^(macos|android|ios)$")
```

to `DeviceUpdate`:

```python
    child_id: Optional[str] = None
    daily_cap_minutes: Optional[int] = Field(default=None, ge=0, le=1440)
```

and to both `DeviceOut` and `DeviceListOut`:

```python
    child_id: Optional[str] = None
    platform: str = "macos"
    daily_cap_minutes: Optional[int] = None
```

Note for the implementer: `DeviceUpdate` needs to distinguish "clear the cap" from "leave it alone". Use `data.model_fields_set` to tell them apart, as shown in Step 5.

- [ ] **Step 4: Create the child alongside the device**

In `create_device`, before constructing the `Device`:

```python
    if data.child_id:
        result = await db.execute(
            select(Child).where(Child.id == data.child_id, Child.owner_id == user.id)
        )
        child = result.scalar_one_or_none()
        if not child:
            raise HTTPException(status_code=404, detail="Child not found")
    else:
        child = Child(owner_id=user.id, name=data.child_name)
        db.add(child)
        await db.flush()
```

Pass `child_id=child.id` and `platform=data.platform` to the `Device(...)` constructor, and create the default policy on the child rather than the device — but only when that child has none yet, so attaching a second device does not overwrite the first one's rules:

```python
    result = await db.execute(select(Policy).where(Policy.child_id == child.id))
    if result.scalar_one_or_none() is None:
        db.add(Policy(child_id=child.id))
```

Add `child_id`, `platform` and `daily_cap_minutes` to the `DeviceOut(...)` return.

- [ ] **Step 5: Handle reassignment and the cap in `update_device`**

```python
    if data.child_id is not None:
        result = await db.execute(
            select(Child).where(Child.id == data.child_id, Child.owner_id == user.id)
        )
        if result.scalar_one_or_none() is None:
            raise HTTPException(status_code=404, detail="Child not found")
        device.child_id = data.child_id

    if "daily_cap_minutes" in data.model_fields_set:
        device.daily_cap_minutes = data.daily_cap_minutes
```

Add the three new fields to this handler's `DeviceOut(...)` return, and to `list_devices`' `DeviceListOut(...)`.

- [ ] **Step 6: Run the full suite**

Run: `cd api && DATABASE_URL=sqlite+aiosqlite:///:memory: SECRET_KEY=test-secret-key TESTING=1 .venv/bin/pytest`
Expected: PASS — every test, including the ones Tasks 3 and 4 left red.

- [ ] **Step 7: Commit**

```bash
git add api/app/routers/devices.py api/app/schemas.py api/tests/test_devices.py
git commit -m "feat: assign devices to children, set platform and per-device cap"
```

---

### Task 7: Web dashboard — children, cap and silence indicator

**Files:**
- Modify: `web-dashboard/src/services/api.js` (add child calls)
- Modify: `web-dashboard/src/pages/DevicesPage.jsx` (group by child, show stale devices)
- Modify: `web-dashboard/src/pages/DeviceDetailPage.jsx` (cap field, move-to-child control)

**Interfaces:**
- Consumes: `GET/POST/PATCH /api/v1/children` (Task 4), `PATCH /api/v1/devices/{id}` with `child_id` / `daily_cap_minutes` (Task 6), `DeviceListOut.child_id`, `.platform`, `.daily_cap_minutes`, `.last_seen`.
- Produces: no interface other tasks depend on.

- [ ] **Step 1: Add the API calls**

In `web-dashboard/src/services/api.js`, following the existing export style in that file:

```javascript
export const listChildren = () => request('/children')
export const createChild = (name) => request('/children', { method: 'POST', body: { name } })
export const renameChild = (id, name) => request(`/children/${id}`, { method: 'PATCH', body: { name } })
export const moveDeviceToChild = (deviceId, childId) =>
  request(`/devices/${deviceId}`, { method: 'PATCH', body: { child_id: childId } })
export const setDeviceCap = (deviceId, minutes) =>
  request(`/devices/${deviceId}`, { method: 'PATCH', body: { daily_cap_minutes: minutes } })
```

Match the existing helper's argument shape — read the top of the file first and adapt `request` to however it is actually named and called there.

- [ ] **Step 2: Group devices by child on `DevicesPage`**

Read the file first and keep its existing device-card markup — only the grouping around it is new.

```javascript
const groupByChild = (devices, children) => {
  const byId = new Map(children.map((c) => [c.id, { child: c, devices: [] }]))
  const orphans = []
  for (const device of devices) {
    const group = byId.get(device.child_id)
    if (group) group.devices.push(device)
    else orphans.push(device)
  }
  const groups = [...byId.values()].filter((g) => g.devices.length > 0)
  if (orphans.length) groups.push({ child: { id: null, name: 'Unassigned' }, devices: orphans })
  return groups
}
```

Render it, reusing whatever card component the page already has for a device:

```jsx
{groupByChild(devices, children).map(({ child, devices: childDevices }) => (
  <section key={child.id ?? 'unassigned'} className="child-group">
    <h2>{child.name}</h2>
    {childDevices.map((device) => (
      <DeviceCard key={device.id} device={device} stale={isStale(device)} />
    ))}
  </section>
))}
```

- [ ] **Step 3: Add the silence indicator**

A device is stale when it has not reported for more than 15 minutes. Add next to the device row:

```javascript
const STALE_AFTER_MS = 15 * 60 * 1000

const isStale = (device) =>
  !device.last_seen || (Date.now() - new Date(device.last_seen).getTime()) > STALE_AFTER_MS
```

Render a warning badge for stale devices reading `Not reporting since HH:MM` (formatted from `last_seen`), or `Never reported` when `last_seen` is null. This is the compensating control for platforms that cannot enforce: a bypass stops being invisible.

- [ ] **Step 4: Add the cap and move controls to `DeviceDetailPage`**

```jsx
<label className="field">
  Daily cap on this device
  <input
    type="number"
    min="0"
    max="1440"
    value={device.daily_cap_minutes ?? ''}
    placeholder="No cap"
    onChange={(e) => {
      const raw = e.target.value
      setDeviceCap(device.id, raw === '' ? null : Number(raw)).then(reload)
    }}
  />
  <small>Minutes of the shared daily budget that may be spent here. It cannot add time.</small>
</label>

<label className="field">
  Child
  <select
    value={device.child_id ?? ''}
    onChange={(e) => moveDeviceToChild(device.id, e.target.value).then(reload)}
  >
    {children.map((c) => (
      <option key={c.id} value={c.id}>{c.name}</option>
    ))}
  </select>
</label>
```

The `<small>` copy matters: the cap is a ceiling *within* the shared budget, never an extra allowance. Use whatever `reload` / refetch function the page already defines.

- [ ] **Step 5: Build**

Run: `cd web-dashboard && npm run build`
Expected: build succeeds with no errors.

- [ ] **Step 6: Commit**

```bash
git add web-dashboard/src
git commit -m "feat: group devices by child, per-device cap and stale-device badge"
```

---

### Task 8: Extract a testable remaining-minutes function in the agent

Pure refactor, no behaviour change. It exists because `PolicyEnforcerTests.swift:121` currently re-implements `remainingMinutes` inside the test file, so the production calculation in `PolicyEnforcer.evaluate` is not actually covered. Task 9 changes exactly that calculation, so it needs a real seam first.

**Files:**
- Create: `macos-agent/NesTimerAgent/Services/RemainingTime.swift`
- Modify: `macos-agent/NesTimerAgent/Services/PolicyEnforcer.swift:126-128`
- Modify: `macos-agent/NesTimerAgentTests/PolicyEnforcerTests.swift:121-124`
- Modify: `macos-agent/NesTimerAgent.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `ServerPolicy` from `APIClient.swift`.
- Produces: `enum RemainingTime { static func minutes(limitMinutes: Int, childUsedMinutes: Double, deviceCapMinutes: Int?, deviceUsedMinutes: Double) -> Double }` and `enum LimitSource { case sharedBudget, deviceCap }` with `static func binding(...) -> LimitSource`.

- [ ] **Step 1: Write the failing test**

Replace the private `remainingMinutes` helper in `macos-agent/NesTimerAgentTests/PolicyEnforcerTests.swift` (lines 121-124) with tests against the production function:

```swift
    // MARK: - Remaining time (production logic, not a mirror)

    func testRemainingUsesSharedBudgetWhenNoCap() {
        let remaining = RemainingTime.minutes(
            limitMinutes: 120, childUsedMinutes: 45,
            deviceCapMinutes: nil, deviceUsedMinutes: 45
        )
        XCTAssertEqual(remaining, 75.0)
    }

    func testRemainingCountsTimeSpentOnOtherDevices() {
        // 120 min budget, 30 used here and 50 on the phone.
        let remaining = RemainingTime.minutes(
            limitMinutes: 120, childUsedMinutes: 80,
            deviceCapMinutes: nil, deviceUsedMinutes: 30
        )
        XCTAssertEqual(remaining, 40.0)
    }

    func testRemainingIsClampedToZero() {
        let remaining = RemainingTime.minutes(
            limitMinutes: 120, childUsedMinutes: 150,
            deviceCapMinutes: nil, deviceUsedMinutes: 150
        )
        XCTAssertEqual(remaining, 0.0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project macos-agent/NesTimerAgent.xcodeproj -scheme NesTimerAgent \
  -destination 'platform=macOS' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES test
```
Expected: FAIL — `cannot find 'RemainingTime' in scope`.

- [ ] **Step 3: Create the function**

Create `macos-agent/NesTimerAgent/Services/RemainingTime.swift`:

```swift
import Foundation

/// Which limit is currently binding — decides what the lock screen tells the child.
enum LimitSource: Equatable {
    case sharedBudget
    case deviceCap
}

/// Remaining screen time, in minutes.
///
/// Two limits apply at once: the child's shared daily budget across all their
/// devices, and an optional ceiling on this device. The tighter one wins.
enum RemainingTime {

    static func minutes(
        limitMinutes: Int,
        childUsedMinutes: Double,
        deviceCapMinutes: Int?,
        deviceUsedMinutes: Double
    ) -> Double {
        let fromBudget = Double(limitMinutes) - childUsedMinutes
        guard let cap = deviceCapMinutes else {
            return max(0, fromBudget)
        }
        let fromCap = Double(cap) - deviceUsedMinutes
        return max(0, min(fromBudget, fromCap))
    }

    static func binding(
        limitMinutes: Int,
        childUsedMinutes: Double,
        deviceCapMinutes: Int?,
        deviceUsedMinutes: Double
    ) -> LimitSource {
        guard let cap = deviceCapMinutes else { return .sharedBudget }
        let fromBudget = Double(limitMinutes) - childUsedMinutes
        let fromCap = Double(cap) - deviceUsedMinutes
        return fromCap < fromBudget ? .deviceCap : .sharedBudget
    }
}
```

- [ ] **Step 4: Add the file to the Xcode project**

Edit `macos-agent/NesTimerAgent.xcodeproj/project.pbxproj` by hand and add all four entries for `RemainingTime.swift`: a `PBXBuildFile`, a `PBXFileReference`, membership in the `Services` group, and an entry in the target's `PBXSourcesBuildPhase`. Missing any one of them produces `cannot find 'RemainingTime' in scope` at build time.

- [ ] **Step 5: Use it from `PolicyEnforcer`**

In `PolicyEnforcer.swift`, replace `let remaining = limitMinutes - usedMinutesToday` (line 128) with:

```swift
            let remaining = RemainingTime.minutes(
                limitMinutes: policy.screenTimeLimitMinutes,
                childUsedMinutes: usedMinutesToday,
                deviceCapMinutes: nil,
                deviceUsedMinutes: usedMinutesToday
            )
```

`deviceCapMinutes` stays `nil` here — Task 9 wires the real value. Passing nil keeps this task a pure refactor, so a reviewer can confirm nothing changed. Delete the now-unused `let limitMinutes = Double(policy.screenTimeLimitMinutes)` line above it.

- [ ] **Step 6: Run the tests**

Run:
```bash
xcodebuild -project macos-agent/NesTimerAgent.xcodeproj -scheme NesTimerAgent \
  -destination 'platform=macOS' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES test
```
Expected: PASS, all tests including the pre-existing downtime and activity ones.

- [ ] **Step 7: Commit**

```bash
git add macos-agent/NesTimerAgent/Services/RemainingTime.swift \
        macos-agent/NesTimerAgent/Services/PolicyEnforcer.swift \
        macos-agent/NesTimerAgentTests/PolicyEnforcerTests.swift \
        macos-agent/NesTimerAgent.xcodeproj/project.pbxproj
git commit -m "refactor: extract RemainingTime so the real calculation is under test"
```

---

### Task 9: Agent decodes and applies the per-device cap

**Files:**
- Modify: `macos-agent/NesTimerAgent/Services/APIClient.swift:24-64` (`ServerPolicy`)
- Modify: `macos-agent/NesTimerAgent/Services/PolicyEnforcer.swift`
- Test: `macos-agent/NesTimerAgentTests/PolicyEnforcerTests.swift`

**Interfaces:**
- Consumes: `RemainingTime.minutes` (Task 8), the `device_used_minutes` / `device_cap_minutes` fields (Task 3).
- Produces: `ServerPolicy.deviceUsedMinutes: Double` (defaults to 0) and `ServerPolicy.deviceCapMinutes: Int?`.

- [ ] **Step 1: Write the failing test**

Extend the `makePolicy` helper in `PolicyEnforcerTests.swift` with the two new parameters, and add:

```swift
    func testDeviceCapBindsBeforeSharedBudget() {
        // 120 min budget with 20 used overall, but only 60 allowed here and 55 already spent.
        let remaining = RemainingTime.minutes(
            limitMinutes: 120, childUsedMinutes: 20,
            deviceCapMinutes: 60, deviceUsedMinutes: 55
        )
        XCTAssertEqual(remaining, 5.0)
    }

    func testSharedBudgetBindsWhenCapIsLooser() {
        let remaining = RemainingTime.minutes(
            limitMinutes: 120, childUsedMinutes: 115,
            deviceCapMinutes: 60, deviceUsedMinutes: 10
        )
        XCTAssertEqual(remaining, 5.0)
    }

    func testBindingLimitIsReportedForTheLockScreen() {
        XCTAssertEqual(
            RemainingTime.binding(limitMinutes: 120, childUsedMinutes: 20,
                                  deviceCapMinutes: 60, deviceUsedMinutes: 55),
            .deviceCap
        )
        XCTAssertEqual(
            RemainingTime.binding(limitMinutes: 120, childUsedMinutes: 115,
                                  deviceCapMinutes: 60, deviceUsedMinutes: 10),
            .sharedBudget
        )
    }

    func testMissingFieldsDecodeToSafeDefaults() throws {
        // A server that has not been upgraded yet omits both fields.
        let json = """
        {"downtime_enabled": true, "downtime_start": "22:00", "downtime_end": "08:00",
         "screen_time_enabled": true, "screen_time_limit_minutes": 120,
         "used_minutes_today": 10.0}
        """.data(using: .utf8)!

        let policy = try JSONDecoder().decode(ServerPolicy.self, from: json)
        XCTAssertEqual(policy.deviceUsedMinutes, 0)
        XCTAssertNil(policy.deviceCapMinutes)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project macos-agent/NesTimerAgent.xcodeproj -scheme NesTimerAgent \
  -destination 'platform=macOS' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES test
```
Expected: FAIL — `value of type 'ServerPolicy' has no member 'deviceUsedMinutes'`.

- [ ] **Step 3: Add the fields to `ServerPolicy`**

In `APIClient.swift`, add the properties after `bonusUntil`:

```swift
    /// This device's own usage today. Absent on servers older than the shared-budget release.
    let deviceUsedMinutes: Double
    /// Per-device ceiling within the shared budget. Nil means no ceiling.
    let deviceCapMinutes: Int?
```

Add them to `init` with defaults so existing call sites and tests keep compiling:

```swift
        deviceUsedMinutes: Double = 0,
        deviceCapMinutes: Int? = nil
```
```swift
        self.deviceUsedMinutes = deviceUsedMinutes
        self.deviceCapMinutes = deviceCapMinutes
```

Add the coding keys:

```swift
        case deviceUsedMinutes = "device_used_minutes"
        case deviceCapMinutes = "device_cap_minutes"
```

Add a custom decoder so that a server response without the fields still decodes:

```swift
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downtimeEnabled = try c.decode(Bool.self, forKey: .downtimeEnabled)
        downtimeStart = try c.decode(String.self, forKey: .downtimeStart)
        downtimeEnd = try c.decode(String.self, forKey: .downtimeEnd)
        screenTimeEnabled = try c.decode(Bool.self, forKey: .screenTimeEnabled)
        screenTimeLimitMinutes = try c.decode(Int.self, forKey: .screenTimeLimitMinutes)
        usedMinutesToday = try c.decode(Double.self, forKey: .usedMinutesToday)
        activities = try c.decodeIfPresent([ScheduledActivity].self, forKey: .activities)
        bonusUntil = try c.decodeIfPresent(String.self, forKey: .bonusUntil)
        deviceUsedMinutes = try c.decodeIfPresent(Double.self, forKey: .deviceUsedMinutes) ?? 0
        deviceCapMinutes = try c.decodeIfPresent(Int.self, forKey: .deviceCapMinutes)
    }
```

- [ ] **Step 4: Pass the real values in `PolicyEnforcer`**

Replace the `deviceCapMinutes: nil` / `deviceUsedMinutes: usedMinutesToday` arguments added in Task 8 with:

```swift
                deviceCapMinutes: policy.deviceCapMinutes,
                deviceUsedMinutes: policy.deviceUsedMinutes
```

- [ ] **Step 5: Run the tests**

Run:
```bash
xcodebuild -project macos-agent/NesTimerAgent.xcodeproj -scheme NesTimerAgent \
  -destination 'platform=macOS' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES test
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add macos-agent/NesTimerAgent/Services/APIClient.swift \
        macos-agent/NesTimerAgent/Services/PolicyEnforcer.swift \
        macos-agent/NesTimerAgentTests/PolicyEnforcerTests.swift
git commit -m "feat: agent applies the per-device daily cap"
```

---

### Task 10: Lock screen tells the child which limit was hit

**Files:**
- Modify: `macos-agent/NesTimerAgent/Views/LockScreenWindow.swift:19-46` (`LockReason`)
- Modify: `macos-agent/NesTimerAgent/Services/PolicyEnforcer.swift:107-133`
- Test: `macos-agent/NesTimerAgentTests/PolicyEnforcerTests.swift`

**Interfaces:**
- Consumes: `LimitSource` (Task 8), `ServerPolicy.deviceCapMinutes` (Task 9).
- Produces: `LockScreenWindow.LockReason.deviceCapReached`.

- [ ] **Step 1: Write the failing test**

```swift
    func testDeviceCapLockHasItsOwnMessage() {
        let capped = LockScreenWindow.LockReason.deviceCapReached
        let expired = LockScreenWindow.LockReason.timeExpired
        XCTAssertNotEqual(capped.message, expired.message)
        XCTAssertNotEqual(capped.title, expired.title)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project macos-agent/NesTimerAgent.xcodeproj -scheme NesTimerAgent \
  -destination 'platform=macOS' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES test
```
Expected: FAIL — `type 'LockScreenWindow.LockReason' has no member 'deviceCapReached'`.

- [ ] **Step 3: Add the case**

In `LockScreenWindow.swift`, add to `LockReason`:

```swift
        case deviceCapReached
```

and a branch to each of the three computed properties:

```swift
            case .deviceCapReached: return "Done On This Mac"
```
```swift
            case .deviceCapReached: return "Today's time for this Mac is used up. Other devices may still have time left."
```
```swift
            case .deviceCapReached: return "desktopcomputer.trianglebadge.exclamationmark"
```

The message says explicitly that other devices may still have time. Without it the child sees minutes left in the menu bar while the screen is locked and reasonably reads it as a bug.

- [ ] **Step 4: Choose the reason in `PolicyEnforcer`**

In the `remaining < 1` branch:

```swift
            if remaining < 1 {
                let source = RemainingTime.binding(
                    limitMinutes: policy.screenTimeLimitMinutes,
                    childUsedMinutes: usedMinutesToday,
                    deviceCapMinutes: policy.deviceCapMinutes,
                    deviceUsedMinutes: policy.deviceUsedMinutes
                )
                notifications.showTimeExpired()
                lockScreen.show(reason: source == .deviceCap ? .deviceCapReached : .timeExpired)
                previousRemaining = remaining
                transitionToLocked()
                return
            }
```

- [ ] **Step 5: Reset warning thresholds when the cap changes**

The reset currently keys only off the policy limit. Add a stored property next to `lastPolicyLimitMinutes`:

```swift
    private var lastDeviceCapMinutes: Int??
```

and extend the reset check:

```swift
        let capChanged = lastDeviceCapMinutes.map { $0 != policy.deviceCapMinutes } ?? false
        if let lastLimit = lastPolicyLimitMinutes,
           lastLimit != policy.screenTimeLimitMinutes || capChanged {
            warningThresholdsCrossed.removeAll()
            previousRemaining = nil
        }
        lastPolicyLimitMinutes = policy.screenTimeLimitMinutes
        lastDeviceCapMinutes = policy.deviceCapMinutes
```

The double optional is deliberate: it distinguishes "no cap has been seen yet" from "the cap is nil", so raising a cap from nil still clears stale warnings.

- [ ] **Step 6: Run the tests**

Run:
```bash
xcodebuild -project macos-agent/NesTimerAgent.xcodeproj -scheme NesTimerAgent \
  -destination 'platform=macOS' CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES test
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add macos-agent/NesTimerAgent/Views/LockScreenWindow.swift \
        macos-agent/NesTimerAgent/Services/PolicyEnforcer.swift \
        macos-agent/NesTimerAgentTests/PolicyEnforcerTests.swift
git commit -m "feat: distinct lock screen when the per-device cap is what binds"
```

---

## Deployment

Do not deploy until every task above is committed and the full API suite plus the agent test suite pass.

1. **Back up the production database first.** The backfill writes to `devices`, `policies` and `activities`:
   ```bash
   ssh root@134.209.8.62 "cd /root/Nestimer && docker compose exec -T db pg_dump -U nestimer nestimer" \
     > ~/nestimer-backup-before-children.sql
   ```
2. Deploy the API. `init_db()` runs the migration and backfill on boot:
   ```bash
   ssh root@134.209.8.62 "cd /root/Nestimer && git fetch origin && git reset --hard origin/main && docker compose up -d --build && docker logs --tail 30 nestimer-api-1"
   ```
3. Verify the backfill produced exactly one child per device and changed nothing:
   ```bash
   ssh root@134.209.8.62 "cd /root/Nestimer && docker compose exec -T db psql -U nestimer -d nestimer -c \
     'SELECT d.name, c.name AS child, p.screen_time_limit_minutes FROM devices d JOIN children c ON c.id = d.child_id LEFT JOIN policies p ON p.child_id = c.id ORDER BY d.name;'"
   ```
   Expect three rows, each with the limit that device had before.
4. Deploy the web dashboard (same `docker compose up -d --build` covers it), then merge the two Macs under one child in the UI. The shared budget takes effect on the installed 2.9 agents immediately, with no agent update.
5. Watch one full day before touching the agents. Only then run `./push-agent-update.sh 134.209.8.62 3.0` to ship the per-device cap.

## Follow-up plans

- **Android counter** — spec section "Android counter". Depends on nothing in this plan beyond `platform=android` device creation, which Task 6 delivers.
- **iOS child client** — blocked on the Family Controls distribution entitlement, and needs a spike on `DeviceActivityMonitor` threshold granularity first.
- **SwiftUI parent app** — child grouping and the cap field, mirroring Task 7. It keeps working through the alias endpoints until then.
