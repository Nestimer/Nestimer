from datetime import date, datetime, timedelta, timezone

import pytest
from sqlalchemy import delete, text

from .conftest import register_user, create_device
from app.main import app
from app.database import get_db
from app.models.models import Policy

pytestmark = pytest.mark.anyio


async def _run_on_app_db(fn):
    """Run `fn(conn)` against the exact database the current test's `client` fixture wired
    into the app, committing afterwards."""
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


async def _run_on_app_session(fn):
    """Like `_run_on_app_db`, but hands `fn` the ORM Session itself rather than a raw
    connection -- for tests that need to insert model instances directly (so column
    Python-level defaults apply) rather than composing raw SQL.
    """
    override = app.dependency_overrides[get_db]
    gen = override()
    session = await gen.__anext__()
    try:
        result = await fn(session)
        await session.commit()
        return result
    finally:
        await gen.aclose()


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

    # Create child via API
    child_resp = await client.post("/api/v1/children", json={"name": "Alex"}, headers=headers)
    child_id = child_resp.json()["id"]

    # Create device via API
    device = await create_device(client, token, child_name="Test Device")
    device_id = device["id"]

    # Get user_id to associate device with child in database
    async def _associate_device(conn):
        # Get user_id from token (we'll query devices to get it)
        result = await conn.execute(
            text("SELECT owner_id FROM devices WHERE id = :id"),
            {"id": device_id}
        )
        owner_id = result.scalar()

        # Update device to point to child
        await conn.execute(
            text("UPDATE devices SET child_id = :child_id WHERE id = :id"),
            {"child_id": child_id, "id": device_id}
        )
        return owner_id

    await _run_on_app_db(_associate_device)

    # Now try to delete child and expect 400
    resp = await client.delete(f"/api/v1/children/{child_id}", headers=headers)
    assert resp.status_code == 400


async def test_cannot_rename_another_parents_child(client):
    """Parent B cannot rename Parent A's child."""
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")

    # Parent A creates a child
    child_resp = await client.post(
        "/api/v1/children",
        json={"name": "Alex"},
        headers={"Authorization": f"Bearer {token_a}"}
    )
    child_id = child_resp.json()["id"]

    # Parent B tries to rename it
    resp = await client.patch(
        f"/api/v1/children/{child_id}",
        json={"name": "Alexander"},
        headers={"Authorization": f"Bearer {token_b}"}
    )
    assert resp.status_code == 404


async def test_cannot_delete_another_parents_child(client):
    """Parent B cannot delete Parent A's child."""
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")

    # Parent A creates a child
    child_resp = await client.post(
        "/api/v1/children",
        json={"name": "Alex"},
        headers={"Authorization": f"Bearer {token_a}"}
    )
    child_id = child_resp.json()["id"]

    # Parent B tries to delete it
    resp = await client.delete(
        f"/api/v1/children/{child_id}",
        headers={"Authorization": f"Bearer {token_b}"}
    )
    assert resp.status_code == 404


async def test_renaming_a_child_renames_them_on_every_device(client):
    """`Device.child_name` is a denormalised copy — the web device cards and the iOS
    parent app read it. A rename that only touches `Child.name` leaves the group heading
    saying "Alexander" while every card under it still says "Alex"."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}

    mac = await create_device(client, token, name="Mac", child_name="Alex")
    child_id = (await client.get(f"/api/v1/devices/{mac['id']}", headers=headers)).json()["child_id"]
    # A second device on the same child — every one of them must follow the rename.
    phone_resp = await client.post(
        "/api/v1/devices",
        json={"name": "Phone", "child_name": "Alex", "child_id": child_id},
        headers=headers,
    )
    assert phone_resp.status_code == 200
    phone = phone_resp.json()

    resp = await client.patch(
        f"/api/v1/children/{child_id}", json={"name": "Alexander"}, headers=headers
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "Alexander"

    for device_id in (mac["id"], phone["id"]):
        device = (await client.get(f"/api/v1/devices/{device_id}", headers=headers)).json()
        assert device["child_name"] == "Alexander", f"device {device_id} still shows the old name"


async def test_a_device_added_to_an_api_created_child_gets_a_device_keyed_policy(client):
    """"Add Child", then add a device to that child: the resulting policy row must be
    reachable by `device_id`, not only by `child_id`.

    An API rolled back to pre-child code against a still-migrated database looks policies
    up by `device_id` alone. A row it cannot find means its no-policy branch —
    screen_time_enabled=False, downtime_enabled=False — and the child's Mac stops locking
    entirely. `POST /children` therefore creates no policy row at all; `POST /devices`
    creates it, with both ids stamped, when the first device attaches.
    """
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}

    child = (await client.post("/api/v1/children", json={"name": "Alex"}, headers=headers)).json()

    async def _policies(conn):
        return (await conn.execute(text("SELECT child_id, device_id FROM policies"))).all()

    rows = await _run_on_app_db(_policies)
    assert rows == [], "a child with no devices must not own an unreachable policy row"

    resp = await client.post(
        "/api/v1/devices",
        json={"name": "Mac", "child_name": "Alex", "child_id": child["id"]},
        headers=headers,
    )
    assert resp.status_code == 200
    device_id = resp.json()["id"]

    rows = await _run_on_app_db(_policies)
    assert rows == [(child["id"], device_id)], (
        "the device's policy must carry BOTH ids — device_id is the only route back "
        "for a rolled-back API"
    )


async def test_auto_created_policy_is_device_keyed_too(client):
    """`GET /devices/{id}/policy` can create the policy row itself (a device whose child
    has none and which has no legacy device-keyed row either). That row needs `device_id`
    for exactly the same rollback reason."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    device = await create_device(client, token, name="Mac")

    async def _drop_policies(conn):
        await conn.execute(text("DELETE FROM policies"))

    await _run_on_app_db(_drop_policies)

    resp = await client.get(f"/api/v1/devices/{device['id']}/policy", headers=headers)
    assert resp.status_code == 200

    async def _policy_device_ids(conn):
        return (await conn.execute(text("SELECT device_id FROM policies"))).scalars().all()

    assert list(await _run_on_app_db(_policy_device_ids)) == [device["id"]]


async def test_moving_a_sibling_device_to_a_new_child_keeps_it_policed(client):
    """The exact UI path: child X has devices A and B (the policy row is keyed to A),
    parent uses "Add Child" to create Y, then moves B to Y from the device detail page.

    B never owned a policy row and Y has none, so without create-or-adopt in
    `update_device` the agent finds nothing by child_id and nothing by device_id, takes
    /agent/config's no-policy branch (screen_time_enabled=False, downtime_enabled=False)
    and B's Mac stops locking. It would self-heal only if the parent happened to open that
    device's policy page afterwards — which the move flow does not do.
    """
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}

    device_a = await create_device(client, token, name="Mac A", child_name="Alex")
    child_x = (await client.get(f"/api/v1/devices/{device_a['id']}", headers=headers)).json()["child_id"]
    device_b = (await client.post(
        "/api/v1/devices",
        json={"name": "Mac B", "child_name": "Alex", "child_id": child_x},
        headers=headers,
    )).json()

    # The policy row belongs to A; B has none of its own.
    async def _policy_device_ids(conn):
        return (await conn.execute(text("SELECT device_id FROM policies"))).scalars().all()

    assert list(await _run_on_app_db(_policy_device_ids)) == [device_a["id"]]

    child_y = (await client.post("/api/v1/children", json={"name": "Sam"}, headers=headers)).json()
    resp = await client.patch(
        f"/api/v1/devices/{device_b['id']}", json={"child_id": child_y["id"]}, headers=headers
    )
    assert resp.status_code == 200

    # The agent must still be policed — and by real rules, not the fail-open branch.
    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {device_b['api_token']}"},
    )
    assert resp.status_code == 200
    config = resp.json()
    assert config["screen_time_enabled"] is True, "moved device fell through to the no-policy branch"
    assert config["downtime_enabled"] is True
    assert config["screen_time_limit_minutes"] != 999, "999 is the no-policy sentinel"

    # And the new row carries device_id, the only route back for a rolled-back API.
    async def _policy_for_child_y(conn):
        return (await conn.execute(
            text("SELECT device_id FROM policies WHERE child_id = :cid"), {"cid": child_y["id"]}
        )).scalars().all()

    assert list(await _run_on_app_db(_policy_for_child_y)) == [device_b["id"]]


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

    resp = await client.put(f"/api/v1/children/{d['child_id']}/policy",
                            json={"screen_time_limit_minutes": 55}, headers=h)
    assert resp.status_code == 200, resp.text

    resp = await client.get(f"/api/v1/devices/{d['id']}/policy", headers=h)
    assert resp.status_code == 200, resp.text
    assert resp.json()["screen_time_limit_minutes"] == 55


async def test_child_and_device_policy_routes_agree_with_multiple_devices(client):
    """The single-device case above is the one case the device loop cannot get wrong --
    exercise it with a sibling device too."""
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Alex2")
    await client.patch(f"/api/v1/devices/{d2['id']}",
                       json={"child_id": d1["child_id"]}, headers=h)

    resp = await client.put(f"/api/v1/children/{d1['child_id']}/policy",
                            json={"screen_time_limit_minutes": 42}, headers=h)
    assert resp.status_code == 200, resp.text

    for dev in (d1, d2):
        resp = await client.get(f"/api/v1/devices/{dev['id']}/policy", headers=h)
        assert resp.status_code == 200, resp.text
        assert resp.json()["screen_time_limit_minutes"] == 42, f"{dev['name']} disagreed"

    resp = await client.get(f"/api/v1/children/{d1['child_id']}/policy", headers=h)
    assert resp.status_code == 200
    assert resp.json()["screen_time_limit_minutes"] == 42


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

    async def _policy_device_ids(conn):
        return (await conn.execute(
            text("SELECT device_id FROM policies WHERE child_id = :cid"), {"cid": child_id}
        )).scalars().all()

    assert await _run_on_app_db(_policy_device_ids) == [], (
        "no Policy row must exist for a device-less child"
    )

    # A device attaching afterwards must still get a policy WITH device_id stamped.
    resp = await client.post("/api/v1/devices",
                             json={"name": "Later Mac", "child_name": "Bea",
                                   "child_id": child_id}, headers=h)
    assert resp.status_code == 200, resp.text
    device = resp.json()

    resp = await client.get(f"/api/v1/devices/{device['id']}/policy", headers=h)
    assert resp.status_code == 200, resp.text

    assert await _run_on_app_db(_policy_device_ids) == [device["id"]], (
        "the child's policy must now exist and carry the attached device's id"
    )


async def test_child_policy_update_rejects_null_on_non_nullable_fields(client):
    """These back non-nullable columns/response fields. Writing an explicit null must
    422, never corrupt the row or brick the next read (see policy_to_out / PolicyOut)."""
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d = await create_device(client, token, name="Mac", child_name="Alex")
    child_id = d["child_id"]

    for field in (
        "screen_time_enabled", "screen_time_limit_minutes",
        "downtime_enabled", "downtime_start", "downtime_end",
    ):
        resp = await client.put(f"/api/v1/children/{child_id}/policy",
                                json={field: None}, headers=h)
        assert resp.status_code == 422, f"{field}=None should be rejected, got {resp.status_code}"

    # The genuinely optional overrides must still be clearable with an explicit null.
    resp = await client.put(f"/api/v1/children/{child_id}/policy",
                            json={"downtime_weekday_start": "20:00"}, headers=h)
    assert resp.status_code == 200, resp.text
    resp = await client.put(f"/api/v1/children/{child_id}/policy",
                            json={"downtime_weekday_start": None}, headers=h)
    assert resp.status_code == 200, resp.text
    assert resp.json()["downtime_weekday_start"] is None


async def test_device_policy_route_also_rejects_null_on_non_nullable_fields(client):
    """Ruling: the two policy routes are meant to be equivalent -- the same malformed
    request must not corrupt data on one route and 422 on the other."""
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d = await create_device(client, token, name="Mac", child_name="Alex")

    resp = await client.put(f"/api/v1/devices/{d['id']}/policy",
                            json={"screen_time_limit_minutes": None}, headers=h)
    assert resp.status_code == 422


async def test_child_policy_loop_is_deterministic_across_multiple_devices(client):
    """Two devices, each owning its own unlinked (child_id=NULL) Policy row, with no
    child-keyed row yet. Without a deterministic device order, /children/{id}/policy
    could adopt either one -- and adoption writes child_id onto the row, so whoever
    lands first wins permanently. It must always pick the same row: the one keyed to the
    earliest-created device.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Alex2")
    await client.patch(f"/api/v1/devices/{d2['id']}",
                       json={"child_id": d1["child_id"]}, headers=h)
    child_id = d1["child_id"]

    async def _rewrite_policies(session):
        await session.execute(delete(Policy))
        session.add(Policy(device_id=d1["id"], child_id=None, screen_time_limit_minutes=11))
        session.add(Policy(device_id=d2["id"], child_id=None, screen_time_limit_minutes=22))

    await _run_on_app_session(_rewrite_policies)

    for _ in range(3):
        resp = await client.get(f"/api/v1/children/{child_id}/policy", headers=h)
        assert resp.status_code == 200, resp.text
        assert resp.json()["screen_time_limit_minutes"] == 11, (
            "must deterministically resolve to the earliest-created device's policy"
        )


async def test_child_policy_get_is_scoped_to_its_owner(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    d = await create_device(client, token_a, name="Mac", child_name="Alex")

    resp = await client.get(f"/api/v1/children/{d['child_id']}/policy",
                            headers={"Authorization": f"Bearer {token_b}"})
    assert resp.status_code == 404


async def test_child_policy_put_is_scoped_to_its_owner(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    d = await create_device(client, token_a, name="Mac", child_name="Alex")

    resp = await client.put(f"/api/v1/children/{d['child_id']}/policy",
                            json={"screen_time_limit_minutes": 60},
                            headers={"Authorization": f"Bearer {token_b}"})
    assert resp.status_code == 404


async def test_child_grant_bonus_applies_to_every_device(client):
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}

    d1 = await create_device(client, token, name="Mac One", child_name="Alex")
    d2 = await create_device(client, token, name="Mac Two", child_name="Alex2")
    await client.patch(f"/api/v1/devices/{d2['id']}",
                       json={"child_id": d1["child_id"]}, headers=h)

    before = datetime.now(timezone.utc)
    resp = await client.post(f"/api/v1/children/{d1['child_id']}/grant-bonus",
                             json={"minutes": 15}, headers=h)
    assert resp.status_code == 200, resp.text
    bonus_until = datetime.fromisoformat(resp.json()["bonus_until"])
    expected = before + timedelta(minutes=15)
    assert abs((bonus_until - expected).total_seconds()) < 5, (
        f"expected ~{expected}, got {bonus_until}"
    )

    for dev in (d1, d2):
        resp = await client.get("/api/v1/agent/config",
                                headers={"Authorization": f"Bearer {dev['api_token']}"})
        assert resp.status_code == 200, resp.text
        assert resp.json()["bonus_until"] is not None, f"{dev['name']} did not see the bonus"


async def test_child_grant_bonus_rejects_out_of_range(client):
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d = await create_device(client, token, name="Mac", child_name="Alex")

    resp = await client.post(f"/api/v1/children/{d['child_id']}/grant-bonus",
                             json={"minutes": 999}, headers=h)
    assert resp.status_code == 422


async def test_child_grant_bonus_is_scoped_to_its_owner(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    d = await create_device(client, token_a, name="Mac", child_name="Alex")

    resp = await client.post(f"/api/v1/children/{d['child_id']}/grant-bonus",
                             json={"minutes": 15},
                             headers={"Authorization": f"Bearer {token_b}"})
    assert resp.status_code == 404


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
    assert resp.json()["start_time"] == "16:00", "an untouched field must survive the update"

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


async def test_child_activity_update_ignores_explicit_nulls_on_required_fields(client):
    """Every Activity column here is NOT NULL (or, for `enabled`, must never go NULL --
    `/agent/config` filters `Activity.enabled == True`). An explicit null must be
    treated as 'field not supplied' -- never written -- matching
    `/devices/{id}/activities`'s `update_activity`.
    """
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    d = await create_device(client, token, name="Mac", child_name="Alex")
    child_id = d["child_id"]

    resp = await client.post(f"/api/v1/children/{child_id}/activities",
                             json={"name": "Homework", "day_of_week": 1,
                                   "start_time": "16:00", "end_time": "17:00"}, headers=h)
    assert resp.status_code == 200, resp.text
    activity_id = resp.json()["id"]
    original = resp.json()

    resp = await client.put(
        f"/api/v1/children/{child_id}/activities/{activity_id}",
        json={"name": None, "day_of_week": None, "start_time": None, "end_time": None,
              "buffer_before_minutes": None, "buffer_after_minutes": None, "enabled": None},
        headers=h,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json() == original, "an explicit null must leave every field unchanged"

    # And the route stays readable afterwards -- a NULL written to `enabled` would 500
    # every future GET, on both this URL and the device-keyed one.
    resp = await client.get(f"/api/v1/children/{child_id}/activities", headers=h)
    assert resp.status_code == 200
    resp = await client.get(f"/api/v1/devices/{d['id']}/activities", headers=h)
    assert resp.status_code == 200


async def test_child_activity_create_on_device_less_child_is_404(client):
    """No device to stamp device_id with, and nothing ever adopts an unstamped row
    later -- must 404, matching PUT /children/{id}/policy, not create an orphan row."""
    token = await register_user(client)
    h = {"Authorization": f"Bearer {token}"}
    resp = await client.post("/api/v1/children", json={"name": "Bea"}, headers=h)
    child_id = resp.json()["id"]

    resp = await client.post(f"/api/v1/children/{child_id}/activities",
                             json={"name": "Homework", "day_of_week": 1,
                                   "start_time": "16:00", "end_time": "17:00"}, headers=h)
    assert resp.status_code == 404

    async def _activities(conn):
        return (await conn.execute(
            text("SELECT id FROM activities WHERE child_id = :cid"), {"cid": child_id}
        )).all()

    assert await _run_on_app_db(_activities) == [], "no Activity row must exist"


async def test_child_activity_create_is_scoped_to_its_owner(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    d = await create_device(client, token_a, name="Mac", child_name="Alex")

    resp = await client.post(f"/api/v1/children/{d['child_id']}/activities",
                             json={"name": "Homework", "day_of_week": 1,
                                   "start_time": "16:00", "end_time": "17:00"},
                             headers={"Authorization": f"Bearer {token_b}"})
    assert resp.status_code == 404


async def test_child_activity_update_is_scoped_to_its_owner(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    d = await create_device(client, token_a, name="Mac", child_name="Alex")
    h_a = {"Authorization": f"Bearer {token_a}"}

    resp = await client.post(f"/api/v1/children/{d['child_id']}/activities",
                             json={"name": "Homework", "day_of_week": 1,
                                   "start_time": "16:00", "end_time": "17:00"}, headers=h_a)
    activity_id = resp.json()["id"]

    resp = await client.put(f"/api/v1/children/{d['child_id']}/activities/{activity_id}",
                            json={"name": "Piano"},
                            headers={"Authorization": f"Bearer {token_b}"})
    assert resp.status_code == 404


async def test_child_activity_delete_is_scoped_to_its_owner(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    d = await create_device(client, token_a, name="Mac", child_name="Alex")
    h_a = {"Authorization": f"Bearer {token_a}"}

    resp = await client.post(f"/api/v1/children/{d['child_id']}/activities",
                             json={"name": "Homework", "day_of_week": 1,
                                   "start_time": "16:00", "end_time": "17:00"}, headers=h_a)
    activity_id = resp.json()["id"]

    resp = await client.delete(f"/api/v1/children/{d['child_id']}/activities/{activity_id}",
                               headers={"Authorization": f"Bearer {token_b}"})
    assert resp.status_code == 404
