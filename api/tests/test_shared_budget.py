import uuid

import pytest
from sqlalchemy import text

from app.database import get_db
from app.main import app
from app.routers.agent import USAGE_REPORT_SLACK_MINUTES

from .conftest import register_user, create_device, simulate_elapsed_time

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
    """Run `fn(conn)` against the exact database the current test's `client` fixture wired
    into the app, committing afterwards. Reaches into `app.dependency_overrides[get_db]`,
    the session factory `client` registered, rather than opening a second, unrelated
    in-memory database. Drives the generator to completion explicitly (instead of
    returning while it is still suspended at `yield`), so its session is closed
    deterministically here rather than at garbage-collection time."""
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


async def _create_child(conn, owner_id: str, name: str = "Alex") -> str:
    child_id = str(uuid.uuid4())
    await conn.execute(
        text("INSERT INTO children (id, owner_id, name) VALUES (:id, :owner_id, :name)"),
        {"id": child_id, "owner_id": owner_id, "name": name},
    )
    return child_id


async def _put_devices_on_one_child(keep_device_id: str, move_device_id: str) -> str:
    """Point move_device at keep_device's child, as the UI merge action will later do."""
    async def _do(conn):
        owner_id, child_id = (await conn.execute(
            text("SELECT owner_id, child_id FROM devices WHERE id = :id"), {"id": keep_device_id}
        )).one()
        if child_id is None:
            child_id = await _create_child(conn, owner_id)
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


async def _point_device_at_a_fresh_childless_policy_child(device_id: str) -> str:
    """Set device.child_id to a brand-new Child that has NO Policy row of its own —
    simulating a sibling device after the device that owned the shared Policy row was
    deleted (Policy.device.policy cascades on delete)."""
    async def _do(conn):
        owner_id = (await conn.execute(
            text("SELECT owner_id FROM devices WHERE id = :id"), {"id": device_id}
        )).scalar_one()
        child_id = await _create_child(conn, owner_id)
        await conn.execute(
            text("UPDATE devices SET child_id = :child_id WHERE id = :id"),
            {"child_id": child_id, "id": device_id},
        )
        return child_id

    return await _run_on_app_db(_do)


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
    """Agent 2.9 in the field must keep decoding this response — both the field names
    AND their types, since a type change breaks a fixed decoder as hard as a removed
    field does."""
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

    assert isinstance(config["used_minutes_today"], (int, float)), "used_minutes_today must stay numeric"
    assert isinstance(config["screen_time_limit_minutes"], int), "screen_time_limit_minutes must stay an int"


async def test_policy_falls_back_to_device_when_childs_policy_is_missing(client):
    """A device whose child_id is set but whose child has no Policy row (e.g. because the
    sibling device that owned the shared policy was deleted, cascading it away) must still
    be governed by its own device-keyed policy — NEVER fail open into 'no restrictions'.
    This is the failure mode the exclusive if/else in the child-aware policy lookup used
    to allow: a device with a real policy would silently get zero restrictions forever."""
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")

    # Give the device-keyed policy a distinctive, unmistakably-non-default limit.
    resp = await client.put(
        f"/api/v1/devices/{mac['id']}/policy",
        json={"screen_time_limit_minutes": 45},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200

    await _point_device_at_a_fresh_childless_policy_child(mac["id"])

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    config = resp.json()
    assert config["screen_time_enabled"] is True, "must not fail open just because the child has no policy row"
    assert config["screen_time_limit_minutes"] == 45, "must fall back to the device's own policy, not the 999 default"


async def test_aggregation_excludes_other_childs_usage(client):
    """A second child's usage on the same date must never bleed into this child's total —
    the mirror failure to under-counting: a child's computer locking when it shouldn't."""
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")
    await _put_devices_on_one_child(mac["id"], phone["id"])

    other_token = await register_user(client, email="other-parent@test.com")
    other_device = await create_device(client, other_token, name="OtherKid-Tablet")
    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-09-09", "total_minutes": 999.0},
        headers={"Authorization": f"Bearer {other_device['api_token']}"},
    )
    assert resp.status_code == 200

    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-09-09", "total_minutes": 30.0},
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    assert resp.status_code == 200

    resp = await client.get(
        "/api/v1/agent/config?date=2026-09-09",
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    assert resp.json()["used_minutes_today"] == 30.0, "another child's 999 minutes must not be summed in"


async def test_sibling_device_sees_combined_total(client):
    """After linking, the sibling device's own /agent/config poll must also see the
    combined total — not just its own usage — even when it has never reported usage
    itself (exercises the coalesce() path with a partial usage_logs set: one linked
    device has a row for the day, the other has none at all)."""
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")
    await _put_devices_on_one_child(mac["id"], phone["id"])

    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-09-09", "total_minutes": 50.0},
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    assert resp.status_code == 200
    # phone deliberately never reports usage — no UsageLog row for it exists at all.

    resp = await client.get(
        "/api/v1/agent/config?date=2026-09-09",
        headers={"Authorization": f"Bearer {phone['api_token']}"},
    )
    config = resp.json()
    assert config["used_minutes_today"] == 50.0, "sibling must see the combined total, not just its own zero"
    assert config["device_used_minutes"] == 0.0, "the phone's own counter is separately zero"


async def test_echoing_the_shared_total_back_does_not_inflate_the_counters(client):
    """The runaway loop, reproduced end to end.

    Agent 2.9 ratchets its local counter up to `used_minutes_today` — which is now the
    CHILD's combined total across every device — and then posts that value back as this
    device's own total. Two Macs on one child therefore echo each other's sums: 30 + 20
    becomes 50, then 70, then 120, then 190, and both machines lock permanently within a
    handful of sync rounds (locked → 5s syncs → faster).

    We cannot ship an agent fix to a Mac whose auto-update failed, so the server has to
    refuse the impossible growth: `report_usage` clamps each report to what could have
    been accumulated since that device's previous report. Growth is then bounded by real
    elapsed time plus USAGE_REPORT_SLACK_MINUTES per report, instead of compounding.
    """
    token = await register_user(client)
    mac_a = await create_device(client, token, name="Mac A")
    mac_b = await create_device(client, token, name="Mac B")
    await _put_devices_on_one_child(mac_a["id"], mac_b["id"])

    date = "2026-09-09"

    async def _post(device, minutes):
        resp = await client.post(
            "/api/v1/agent/usage",
            json={"date": date, "total_minutes": minutes},
            headers={"Authorization": f"Bearer {device['api_token']}"},
        )
        assert resp.status_code == 200

    async def _child_total(device):
        resp = await client.get(
            f"/api/v1/agent/config?date={date}",
            headers={"Authorization": f"Bearer {device['api_token']}"},
        )
        assert resp.status_code == 200
        return resp.json()["used_minutes_today"]

    # Honest starting point: 30 minutes on one Mac, 20 on the other.
    await _post(mac_a, 30.0)
    await _post(mac_b, 20.0)
    assert await _child_total(mac_a) == 50.0

    # Now both Macs behave exactly like agent 2.9: read the shared total, post it back.
    rounds = 6
    for _ in range(rounds):
        for device in (mac_a, mac_b):
            await _post(device, await _child_total(device))

    total = await _child_total(mac_a)

    # Each of the 2 * rounds reports may add at most the slack, plus the real elapsed time
    # of the test itself. That elapsed time is charged to BOTH devices' ceilings, so the
    # +1.0 buys only about 30 seconds of actual wall clock — still a wide margin for a
    # loop that runs in milliseconds. Unclamped, this reaches 14530 minutes by round 6.
    ceiling = 50.0 + rounds * 2 * USAGE_REPORT_SLACK_MINUTES + 1.0
    assert total <= ceiling, (
        f"child total ran away to {total}m after {rounds} echo rounds "
        f"(honest total was 50m, ceiling {ceiling}m)"
    )


async def test_a_device_that_was_offline_can_report_its_catch_up_total(client):
    """The clamp must not punish a Mac that could not reach the server for a while.

    `last_updated` only advances when the device actually reports, so three hours of
    silence buys three hours of headroom: the agent kept counting locally and posts the
    whole catch-up total on its first successful sync.
    """
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")

    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-09-09", "total_minutes": 10.0},
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    assert resp.status_code == 200

    await simulate_elapsed_time(180)

    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-09-09", "total_minutes": 185.0},
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    assert resp.status_code == 200

    resp = await client.get(
        "/api/v1/agent/config?date=2026-09-09",
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    assert resp.json()["used_minutes_today"] == 185.0, "offline catch-up must not be clamped"


async def test_a_lower_total_is_still_accepted(client):
    """A report BELOW the stored value is a parent-initiated reset, never an attack —
    the clamp only ever caps growth."""
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")

    for minutes in (60.0, 0.0):
        resp = await client.post(
            "/api/v1/agent/usage",
            json={"date": "2026-09-09", "total_minutes": minutes},
            headers={"Authorization": f"Bearer {mac['api_token']}"},
        )
        assert resp.status_code == 200

    resp = await client.get(
        "/api/v1/agent/config?date=2026-09-09",
        headers={"Authorization": f"Bearer {mac['api_token']}"},
    )
    assert resp.json()["used_minutes_today"] == 0.0


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


async def test_deleting_the_only_device_orphans_its_policy_row_without_deleting_it(client):
    """The 1:1 case: no sibling exists to hand the policy to.

    `GET /devices/{id}/policy` 404s once the device itself is gone regardless of
    whether its Policy row survived underneath -- that 404 comes from
    `_verify_device_owner` ("Device not found"), not from the policy lookup, so it
    cannot tell us anything about the row. Query the `policies` table directly instead.

    delete_device must never DELETE a Policy row (that is how a still-live policy for
    some other child got destroyed in earlier attempts at this fix). With no other
    device on this child to hand the row to, the correct outcome is that the row
    survives, detached (device_id set to NULL), rather than being removed.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="Only Mac", child_name="Alex")
    resp = await client.put(f"/api/v1/devices/{d1['id']}/policy",
                            json={"screen_time_limit_minutes": 45}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.delete(f"/api/v1/devices/{d1['id']}", headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.get(f"/api/v1/devices/{d1['id']}/policy", headers=h)
    assert resp.status_code == 404

    async def _read_policy(conn):
        return (await conn.execute(
            text("SELECT device_id, screen_time_limit_minutes FROM policies WHERE child_id = :cid"),
            {"cid": d1["child_id"]},
        )).one_or_none()

    row = await _run_on_app_db(_read_policy)
    assert row is not None, "the policy row must survive the only device that ever owned it"
    assert row.device_id is None, "with no sibling to hand it to, the row is detached, not deleted"
    assert row.screen_time_limit_minutes == 45, "the configured value must not revert to the default"


async def test_deleting_the_non_policy_holding_sibling_keeps_the_live_policy(client):
    """Mirror of the policy-holder-deleted case: delete the sibling that does NOT carry
    the child's live policy row.

    d1 and d2 are each created independently (own child, own default policy). d1 is then
    merged ONTO d2's child, so the shared child's live policy is the row d2 has always
    owned (device_id=d2) -- d1 keeps its own now-orphaned policy row (still keyed to its
    original child) untouched, exactly as update_device's re-keying comment describes.
    Deleting d1 must not disturb d2's live policy: it is not the row that carries this
    child's id, so it must never be deleted or re-pointed.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Bea")

    resp = await client.patch(f"/api/v1/devices/{d1['id']}",
                              json={"child_id": d2["child_id"]}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.put(f"/api/v1/devices/{d2['id']}/policy",
                            json={"screen_time_enabled": True,
                                  "screen_time_limit_minutes": 90}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.delete(f"/api/v1/devices/{d1['id']}", headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.get("/api/v1/agent/config",
                            headers={"Authorization": f"Bearer {d2['api_token']}"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["screen_time_limit_minutes"] == 90


async def test_deleting_a_device_never_touches_another_childs_policy(client):
    """A device's own Policy row and its own child_id can diverge: update_device
    deliberately never re-keys a device's pre-existing Policy row when that device is
    merged onto a different child. Deleting some OTHER device must never let that
    divergence destroy a third child's still-live policy.

    d3 owns its own Policy row (P3) from creation, so merging d3 onto d2's child does
    not touch P3 -- Bea's live policy stays P2, owned by d2. Merging d2 onto d1's child
    likewise leaves P2 (child_id=Bea) in place, owned by d2, even though d2 itself now
    sits on Alex. Setting the limit through d3 (child-first resolution) lands on P2.
    Deleting d1 must not reach P2 at all -- d1 never owned it and never shared a child
    with it directly.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="D1", child_name="Alex")
    d2 = await create_device(client, token, name="D2", child_name="Bea")
    d3 = await create_device(client, token, name="D3", child_name="Cara")

    resp = await client.patch(f"/api/v1/devices/{d3['id']}",
                              json={"child_id": d2["child_id"]}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.patch(f"/api/v1/devices/{d2['id']}",
                              json={"child_id": d1["child_id"]}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.put(f"/api/v1/devices/{d3['id']}/policy",
                            json={"screen_time_enabled": True,
                                  "screen_time_limit_minutes": 90}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.delete(f"/api/v1/devices/{d1['id']}", headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.get("/api/v1/agent/config",
                            headers={"Authorization": f"Bearer {d3['api_token']}"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["screen_time_limit_minutes"] == 90


async def test_deleting_a_device_that_holds_another_childs_policy_keeps_it(client):
    """Same divergence as above, but this time the device being deleted is the one that
    literally owns (device_id=) the still-live policy for a DIFFERENT child than the one
    it currently sits on. Deleting it must re-point that row within ITS OWN child
    (Bea, via d3), never destroy it just because the owning device is going away.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="D1", child_name="Alex")
    d2 = await create_device(client, token, name="D2", child_name="Bea")
    d3 = await create_device(client, token, name="D3", child_name="Cara")

    resp = await client.patch(f"/api/v1/devices/{d3['id']}",
                              json={"child_id": d2["child_id"]}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.patch(f"/api/v1/devices/{d2['id']}",
                              json={"child_id": d1["child_id"]}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.put(f"/api/v1/devices/{d3['id']}/policy",
                            json={"screen_time_enabled": True,
                                  "screen_time_limit_minutes": 90}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.delete(f"/api/v1/devices/{d2['id']}", headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.get("/api/v1/agent/config",
                            headers={"Authorization": f"Bearer {d3['api_token']}"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["screen_time_limit_minutes"] == 90


async def test_deleting_a_device_in_a_policy_cycle_succeeds(client):
    """Two devices, each still owning its own pre-merge Policy row, patched onto each
    OTHER's child: P_A's only same-child candidate is B, and P_B's only same-child
    candidate is A, so each would need the other freed first. Deleting either device
    must not raise (the unique constraint on Policy.device_id) and must not delete
    either policy row -- both must survive, still carrying their original child_id.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    a = await create_device(client, token, name="A", child_name="C2")
    b = await create_device(client, token, name="B", child_name="C1")
    a_child_id = a["child_id"]
    b_child_id = b["child_id"]

    resp = await client.patch(f"/api/v1/devices/{a['id']}",
                              json={"child_id": b_child_id}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.patch(f"/api/v1/devices/{b['id']}",
                              json={"child_id": a_child_id}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.delete(f"/api/v1/devices/{a['id']}", headers=h)
    assert resp.status_code == 200, resp.text

    async def _read_policies(conn):
        return (await conn.execute(
            text("SELECT child_id FROM policies WHERE child_id IN (:c1, :c2)"),
            {"c1": a_child_id, "c2": b_child_id},
        )).all()

    rows = await _run_on_app_db(_read_policies)
    assert {r.child_id for r in rows} == {a_child_id, b_child_id}, (
        "both policy rows must survive the cycle, each still carrying its own child_id"
    )


async def test_deleting_a_device_in_a_three_way_policy_cycle_succeeds(client):
    """Same shape as the two-device cycle, but three devices deep: A->B->C->A, each
    still owning its own pre-merge Policy row after being patched onto the next one's
    child. Deleting A must not raise and must not delete any of the three policy rows.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    a = await create_device(client, token, name="A", child_name="CA")
    b = await create_device(client, token, name="B", child_name="CB")
    c = await create_device(client, token, name="C", child_name="CC")
    a_child_id = a["child_id"]
    b_child_id = b["child_id"]
    c_child_id = c["child_id"]

    resp = await client.patch(f"/api/v1/devices/{a['id']}",
                              json={"child_id": b_child_id}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.patch(f"/api/v1/devices/{b['id']}",
                              json={"child_id": c_child_id}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.patch(f"/api/v1/devices/{c['id']}",
                              json={"child_id": a_child_id}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.delete(f"/api/v1/devices/{a['id']}", headers=h)
    assert resp.status_code == 200, resp.text

    async def _read_policies(conn):
        return (await conn.execute(
            text("SELECT child_id FROM policies WHERE child_id IN (:c1, :c2, :c3)"),
            {"c1": a_child_id, "c2": b_child_id, "c3": c_child_id},
        )).all()

    rows = await _run_on_app_db(_read_policies)
    assert {r.child_id for r in rows} == {a_child_id, b_child_id, c_child_id}, (
        "all three policy rows must survive the cycle, each still carrying its own child_id"
    )
