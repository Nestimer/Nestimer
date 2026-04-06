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


# ---------------------------------------------------------------------------
# Per-day limit tests
# ---------------------------------------------------------------------------

async def test_set_per_day_limit(client):
    """Setting a per-day limit (e.g. Monday) should persist."""
    token = await register_user(client, email="perday@test.com")
    device = await create_device(client, token)

    resp = await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={"screen_time_mon_minutes": 30},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    policy = resp.json()
    assert policy["screen_time_mon_minutes"] == 30
    # Other days remain None
    assert policy["screen_time_tue_minutes"] is None
    assert policy["screen_time_sun_minutes"] is None


async def test_per_day_limit_appears_in_policy_response(client):
    """After setting a per-day limit, GET policy also returns it."""
    token = await register_user(client, email="perday-get@test.com")
    device = await create_device(client, token)

    await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={"screen_time_fri_minutes": 45},
        headers={"Authorization": f"Bearer {token}"},
    )

    resp = await client.get(
        f"/api/v1/devices/{device['id']}/policy",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["screen_time_fri_minutes"] == 45


async def test_multiple_per_day_limits_coexist(client):
    """Multiple per-day limits can be set simultaneously."""
    token = await register_user(client, email="multi-day@test.com")
    device = await create_device(client, token)

    resp = await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={
            "screen_time_mon_minutes": 30,
            "screen_time_wed_minutes": 60,
            "screen_time_sat_minutes": 180,
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    policy = resp.json()
    assert policy["screen_time_mon_minutes"] == 30
    assert policy["screen_time_wed_minutes"] == 60
    assert policy["screen_time_sat_minutes"] == 180
    # Others remain None
    assert policy["screen_time_tue_minutes"] is None
    assert policy["screen_time_thu_minutes"] is None


async def test_effective_limit_per_day_over_weekend_over_default(client):
    """get_effective_limit priority: per-day > weekend > default.

    Verified via the agent config endpoint with a known date.
    """
    token = await register_user(client, email="effective@test.com")
    device = await create_device(client, token)
    agent_token = device["api_token"]

    # Set default=120 (already default), weekend=200, Saturday=45
    await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={
            "screen_time_limit_minutes": 120,
            "screen_time_weekend_limit_minutes": 200,
            "screen_time_sat_minutes": 45,
        },
        headers={"Authorization": f"Bearer {token}"},
    )

    # Saturday 2026-04-04 is actually a Saturday (weekday=5)
    # Use a known Saturday: 2026-01-03 is a Saturday
    resp = await client.get(
        "/api/v1/agent/config?date=2026-01-03",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    config = resp.json()
    # Per-day Saturday override (45) takes priority over weekend (200)
    assert config["screen_time_limit_minutes"] == 45

    # Sunday with no per-day override should use weekend limit
    resp = await client.get(
        "/api/v1/agent/config?date=2026-01-04",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    config = resp.json()
    assert config["screen_time_limit_minutes"] == 200

    # Monday (no per-day, not weekend) should use default
    resp = await client.get(
        "/api/v1/agent/config?date=2026-01-05",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    config = resp.json()
    assert config["screen_time_limit_minutes"] == 120


async def test_clear_override_by_sending_null(client):
    """Sending explicit null for an override field should clear it."""
    token = await register_user(client, email="clear@test.com")
    device = await create_device(client, token)

    # Set overrides
    resp = await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={
            "downtime_weekday_start": "23:00",
            "downtime_weekday_end": "07:00",
            "screen_time_weekend_limit_minutes": 200,
            "screen_time_mon_minutes": 30,
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    policy = resp.json()
    assert policy["downtime_weekday_start"] == "23:00"
    assert policy["screen_time_weekend_limit_minutes"] == 200
    assert policy["screen_time_mon_minutes"] == 30

    # Clear overrides by sending null
    resp = await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={
            "downtime_weekday_start": None,
            "downtime_weekday_end": None,
            "screen_time_weekend_limit_minutes": None,
            "screen_time_mon_minutes": None,
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    policy = resp.json()
    assert policy["downtime_weekday_start"] is None
    assert policy["downtime_weekday_end"] is None
    assert policy["screen_time_weekend_limit_minutes"] is None
    assert policy["screen_time_mon_minutes"] is None
    # Other fields should be preserved
    assert policy["downtime_start"] == "22:00"
    assert policy["screen_time_limit_minutes"] == 120
