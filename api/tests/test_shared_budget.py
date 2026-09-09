import uuid

import pytest
from sqlalchemy import text

from app.database import get_db
from app.main import app

from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


# NOTE: The brief's version of these helpers reads `child_id` off `GET /devices/{id}`
# and moves a device with `PATCH /devices/{id}`. Neither capability exists yet — both
# are built in Task 6. Per controller ruling, we instead write the database directly
# through the exact session the running app uses for this test, so /agent/config below
# actually observes the change through the API (not through a separate `db_session`
# fixture: `client` and `db_session` in conftest.py each build their own independent
# in-memory SQLite engine — verified empirically — so a write through `db_session`
# would be invisible to `client`'s requests here).
#
# A further gap the brief couldn't know about: `POST /devices` does not create a Child
# or set `Device.child_id` yet (that wiring is also Task 6), so a freshly created device
# has `child_id = NULL`. Reading `child_id` off an existing device therefore yields NULL
# rather than a real id to share. `_put_devices_on_one_child` below creates the Child
# (standing in for the one Task 6's device-creation flow will auto-create) and also syncs
# the owning Policy row's `child_id`, since `get_config`'s policy lookup is child-aware.


async def _run_on_app_db(fn):
    """Run `fn(conn)` against the same database the `client` fixture wired into the app,
    committing afterwards. Reaches into `app.dependency_overrides[get_db]`, which is the
    session factory the current test's `client` fixture registered, rather than opening
    a second, unrelated in-memory database."""
    override = app.dependency_overrides[get_db]
    async for session in override():
        conn = await session.connection()
        result = await fn(conn)
        await session.commit()
        return result


async def _put_devices_on_one_child(keep_device_id: str, move_device_id: str) -> str:
    """Point move_device at keep_device's child, as the UI merge action will later do."""
    async def _do(conn):
        owner_id, child_id = (await conn.execute(
            text("SELECT owner_id, child_id FROM devices WHERE id = :id"), {"id": keep_device_id}
        )).one()
        if child_id is None:
            child_id = str(uuid.uuid4())
            await conn.execute(
                text("INSERT INTO children (id, owner_id, name) VALUES (:id, :owner_id, 'Alex')"),
                {"id": child_id, "owner_id": owner_id},
            )
            await conn.execute(
                text("UPDATE devices SET child_id = :child_id WHERE id = :id"),
                {"child_id": child_id, "id": keep_device_id},
            )
        # get_config's policy lookup is child-aware; keep the policy row in sync too
        # (Task 6 will maintain this invariant going forward — we establish it here).
        await conn.execute(
            text("UPDATE policies SET child_id = :child_id WHERE device_id = :id"),
            {"child_id": child_id, "id": keep_device_id},
        )
        await conn.execute(
            text("UPDATE devices SET child_id = :child_id WHERE id = :id"),
            {"child_id": child_id, "id": move_device_id},
        )
        return child_id

    return await _run_on_app_db(_do)


async def _set_daily_cap_minutes(device_id: str, minutes: int) -> None:
    async def _do(conn):
        await conn.execute(
            text("UPDATE devices SET daily_cap_minutes = :m WHERE id = :id"),
            {"m": minutes, "id": device_id},
        )

    await _run_on_app_db(_do)


async def test_usage_is_summed_across_the_childs_devices(client):
    """The Mac sees time spent on the phone: one budget, one counter."""
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")
    await _put_devices_on_one_child(mac["id"], phone["id"])

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
    await _set_daily_cap_minutes(mac["id"], 60)

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
