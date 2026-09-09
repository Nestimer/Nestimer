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
