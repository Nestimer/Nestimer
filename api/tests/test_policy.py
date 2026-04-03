import pytest
from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


async def test_default_policy(client):
    """New device gets a default policy."""
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.get(
        f"/api/v1/devices/{device['id']}/policy",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    policy = resp.json()

    assert policy["downtime_enabled"] is True
    assert policy["downtime_start"] == "22:00"
    assert policy["downtime_end"] == "08:00"
    assert policy["screen_time_enabled"] is True
    assert policy["screen_time_limit_minutes"] == 120
    assert policy["screen_time_weekend_limit_minutes"] is None


async def test_update_downtime(client):
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={
            "downtime_start": "21:00",
            "downtime_end": "09:30",
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    policy = resp.json()
    assert policy["downtime_start"] == "21:00"
    assert policy["downtime_end"] == "09:30"


async def test_disable_downtime(client):
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={"downtime_enabled": False},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["downtime_enabled"] is False


async def test_update_screen_time_limit(client):
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={"screen_time_limit_minutes": 60},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["screen_time_limit_minutes"] == 60


async def test_weekend_overrides(client):
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={
            "downtime_weekend_start": "23:00",
            "downtime_weekend_end": "10:00",
            "screen_time_weekend_limit_minutes": 180,
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    policy = resp.json()
    assert policy["downtime_weekend_start"] == "23:00"
    assert policy["downtime_weekend_end"] == "10:00"
    assert policy["screen_time_weekend_limit_minutes"] == 180
    # Weekday defaults unchanged
    assert policy["downtime_start"] == "22:00"
    assert policy["screen_time_limit_minutes"] == 120


async def test_partial_update_preserves_other_fields(client):
    """Updating one field shouldn't reset others."""
    token = await register_user(client)
    device = await create_device(client, token)

    # First update
    await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={"screen_time_limit_minutes": 90, "downtime_start": "20:00"},
        headers={"Authorization": f"Bearer {token}"},
    )

    # Second update — only change downtime end
    resp = await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={"downtime_end": "07:00"},
        headers={"Authorization": f"Bearer {token}"},
    )
    policy = resp.json()
    assert policy["screen_time_limit_minutes"] == 90  # preserved
    assert policy["downtime_start"] == "20:00"  # preserved
    assert policy["downtime_end"] == "07:00"  # updated


async def test_policy_access_other_user(client):
    token1 = await register_user(client, email="owner@test.com")
    token2 = await register_user(client, email="other@test.com")
    device = await create_device(client, token1)

    resp = await client.get(
        f"/api/v1/devices/{device['id']}/policy",
        headers={"Authorization": f"Bearer {token2}"},
    )
    assert resp.status_code == 404
