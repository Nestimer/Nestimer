import pytest
from sqlalchemy import text

from .conftest import register_user, create_device
from app.main import app
from app.database import get_db

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
