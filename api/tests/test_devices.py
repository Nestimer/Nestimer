import pytest
from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


async def test_create_device(client):
    token = await register_user(client)
    device = await create_device(client, token)

    assert device["name"] == "MacBook Test"
    assert device["child_name"] == "Миша"
    assert "api_token" in device
    assert device["api_token"]  # not empty


async def test_list_devices(client):
    token = await register_user(client)
    await create_device(client, token, name="Mac 1", child_name="Миша")
    await create_device(client, token, name="Mac 2", child_name="Петя")

    resp = await client.get("/api/v1/devices", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    devices = resp.json()
    assert len(devices) == 2
    names = {d["name"] for d in devices}
    assert names == {"Mac 1", "Mac 2"}


async def test_list_devices_isolation(client):
    """Each user sees only their own devices."""
    token1 = await register_user(client, email="user1@test.com")
    token2 = await register_user(client, email="user2@test.com")

    await create_device(client, token1, name="User1 Mac")
    await create_device(client, token2, name="User2 Mac")

    resp1 = await client.get("/api/v1/devices", headers={"Authorization": f"Bearer {token1}"})
    resp2 = await client.get("/api/v1/devices", headers={"Authorization": f"Bearer {token2}"})

    assert len(resp1.json()) == 1
    assert resp1.json()[0]["name"] == "User1 Mac"
    assert len(resp2.json()) == 1
    assert resp2.json()[0]["name"] == "User2 Mac"


async def test_get_device(client):
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.get(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "MacBook Test"


async def test_get_device_not_found(client):
    token = await register_user(client)
    resp = await client.get(
        "/api/v1/devices/nonexistent-id",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 404


async def test_get_device_other_user(client):
    """Can't access another user's device."""
    token1 = await register_user(client, email="owner@test.com")
    token2 = await register_user(client, email="other@test.com")

    device = await create_device(client, token1)

    resp = await client.get(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token2}"},
    )
    assert resp.status_code == 404


async def test_delete_device(client):
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.delete(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200

    # Verify deleted
    resp = await client.get("/api/v1/devices", headers={"Authorization": f"Bearer {token}"})
    assert len(resp.json()) == 0
