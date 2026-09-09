"""Task 5: /devices/{id}/policy, /activities and /grant-bonus now resolve through the
child, but every existing URL must behave exactly as before for the iOS app and web
dashboard already in the field.

NOTE on fixtures: `client` and `db_session` in conftest.py each build a SEPARATE
in-memory SQLite engine, so a write through `db_session` is invisible to `client`'s
requests. To point two devices at one child (a capability the parent-facing API does
not expose until Task 6's `PATCH /devices/{id}` with `child_id`), we write directly
through the exact session `client`'s app is using — the same `_run_on_app_db` pattern
already used in test_shared_budget.py and test_children_api.py.
"""
import uuid

import pytest
from sqlalchemy import text

from app.database import get_db, _backfill_children
from app.main import app

from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


async def _run_on_app_db(fn):
    """Run `fn(conn)` against the exact database the current test's `client` fixture
    wired into the app, committing afterwards."""
    override = app.dependency_overrides[get_db]
    gen = override()
    session = await gen.__anext__()
    try:
        conn = await session.connection()
        result = await fn(conn)
        await session.commit()
        return result
    finally:
        await gen.aclose()


async def _put_devices_on_one_child(keep_device_id: str, move_device_id: str) -> str:
    """Point both devices at the same child, syncing the keeper's policy row too —
    standing in for the move-device UI action that Task 6 wires up for real."""

    async def _do(conn):
        owner_id, child_id = (
            await conn.execute(
                text("SELECT owner_id, child_id FROM devices WHERE id = :id"),
                {"id": keep_device_id},
            )
        ).one()
        if child_id is None:
            child_id = str(uuid.uuid4())
            await conn.execute(
                text("INSERT INTO children (id, owner_id, name) VALUES (:id, :owner_id, :name)"),
                {"id": child_id, "owner_id": owner_id, "name": "Alex"},
            )
            await conn.execute(
                text("UPDATE devices SET child_id = :child_id WHERE id = :id"),
                {"child_id": child_id, "id": keep_device_id},
            )
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


async def test_policy_set_on_one_device_applies_to_the_whole_child(client):
    """Two devices, one child: the limit is the child's, not the laptop's."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")
    await _put_devices_on_one_child(mac["id"], phone["id"])

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
    await _put_devices_on_one_child(mac["id"], phone["id"])

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
    await _put_devices_on_one_child(mac["id"], phone["id"])

    await client.post(
        f"/api/v1/devices/{mac['id']}/activities",
        json={"name": "English", "day_of_week": 1, "start_time": "17:00", "end_time": "18:00"},
        headers=headers,
    )

    resp = await client.get(f"/api/v1/devices/{phone['id']}/activities", headers=headers)
    assert [a["name"] for a in resp.json()] == ["English"]


async def test_config_is_byte_identical_across_the_migration(client):
    """The migration must be invisible to an agent already in the field.

    Rewinds a device to its pre-migration shape (child_id NULL everywhere), confirms
    the device-keyed fallback reproduces the exact same /agent/config response, then
    runs `_backfill_children` and confirms migrating forward again changes nothing
    either. If this fails, fix the code — never adjust the test to pass.
    """
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

    # Rewind this device to its pre-migration shape, through the exact DB the app reads.
    async def _rewind(conn):
        await conn.execute(text("UPDATE devices SET child_id = NULL"))
        await conn.execute(text("UPDATE policies SET child_id = NULL"))
        await conn.execute(text("UPDATE activities SET child_id = NULL"))

    await _run_on_app_db(_rewind)

    legacy = (await client.get("/api/v1/agent/config?date=2026-09-09", headers=headers)).json()

    await _run_on_app_db(_backfill_children)

    after = (await client.get("/api/v1/agent/config?date=2026-09-09", headers=headers)).json()

    # last_seen is written on every request and is not part of the response,
    # so these three payloads must match exactly.
    assert legacy == before, "the device-level fallback must match the child-level result"
    assert after == before, "migrating must not change what the agent sees"
