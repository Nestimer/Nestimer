import pytest
from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


async def test_create_device(client):
    token = await register_user(client)
    device = await create_device(client, token)

    assert device["name"] == "MacBook Test"
    assert device["child_name"] == "Alex"
    assert "api_token" in device
    assert device["api_token"]  # not empty


async def test_list_devices(client):
    token = await register_user(client)
    await create_device(client, token, name="Mac 1", child_name="Alex")
    await create_device(client, token, name="Mac 2", child_name="Sam")

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


async def test_update_device_name(client):
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.patch(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token}"},
        json={"name": "New MacBook", "child_name": "Sam"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["name"] == "New MacBook"
    assert data["child_name"] == "Sam"

    # Verify persisted
    resp = await client.get(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.json()["name"] == "New MacBook"
    assert resp.json()["child_name"] == "Sam"


async def test_update_device_partial(client):
    """Can update only name or only child_name."""
    token = await register_user(client, email="partial@test.com")
    device = await create_device(client, token)

    resp = await client.patch(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token}"},
        json={"name": "iMac"},
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "iMac"
    assert resp.json()["child_name"] == "Alex"  # unchanged


async def test_update_device_not_found(client):
    token = await register_user(client, email="notfound@test.com")
    resp = await client.patch(
        "/api/v1/devices/nonexistent",
        headers={"Authorization": f"Bearer {token}"},
        json={"name": "X"},
    )
    assert resp.status_code == 404


async def test_update_device_other_user(client):
    """Can't update another user's device."""
    token1 = await register_user(client, email="owner-upd@test.com")
    token2 = await register_user(client, email="other-upd@test.com")
    device = await create_device(client, token1)

    resp = await client.patch(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token2}"},
        json={"name": "Hacked"},
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


# ---------------------------------------------------------------------------
# Shared secret tests
# ---------------------------------------------------------------------------

async def test_device_creation_includes_shared_secret(client):
    """New device must have a shared_secret that is 40 hex chars (20 bytes)."""
    token = await register_user(client, email="secret-create@test.com")
    device = await create_device(client, token)

    secret = device["shared_secret"]
    assert secret is not None
    assert len(secret) == 40
    # Must be valid hex
    int(secret, 16)


async def test_shared_secret_in_device_detail(client):
    """GET /devices/{id} should include shared_secret."""
    token = await register_user(client, email="secret-detail@test.com")
    device = await create_device(client, token)

    resp = await client.get(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["shared_secret"] == device["shared_secret"]
    assert len(data["shared_secret"]) == 40


async def test_regenerate_secret_changes_the_secret(client):
    """Regenerate endpoint must produce a new, different secret."""
    token = await register_user(client, email="regen@test.com")
    device = await create_device(client, token)
    old_secret = device["shared_secret"]

    resp = await client.post(
        f"/api/v1/devices/{device['id']}/regenerate-secret",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    new_secret = resp.json()["shared_secret"]
    assert new_secret != old_secret
    assert len(new_secret) == 40
    # Must be valid hex
    int(new_secret, 16)

    # Verify the change persists on subsequent GET
    resp = await client.get(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.json()["shared_secret"] == new_secret


async def test_each_device_gets_unique_secret(client):
    """Two devices created by the same user should have different secrets."""
    token = await register_user(client, email="unique-secret@test.com")
    dev1 = await create_device(client, token, name="Mac 1", child_name="Kid1")
    dev2 = await create_device(client, token, name="Mac 2", child_name="Kid2")

    assert dev1["shared_secret"] != dev2["shared_secret"]


async def test_shared_secret_not_in_list_endpoint(client):
    """The list endpoint (DeviceListOut) should NOT expose shared_secret."""
    token = await register_user(client, email="list-secret@test.com")
    await create_device(client, token)

    resp = await client.get("/api/v1/devices", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    device_list_item = resp.json()[0]
    assert "shared_secret" not in device_list_item
