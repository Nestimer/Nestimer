import pytest
from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


async def get_agent_token(client, parent_token: str) -> str:
    """Helper: create a device and return its agent API token."""
    device = await create_device(client, parent_token)
    return device["api_token"]


async def test_agent_get_config(client):
    token = await register_user(client)
    agent_token = await get_agent_token(client, token)

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200
    config = resp.json()

    assert config["downtime_enabled"] is True
    assert config["downtime_start"] == "22:00"
    assert config["downtime_end"] == "08:00"
    assert config["screen_time_enabled"] is True
    assert config["screen_time_limit_minutes"] == 120
    assert config["used_minutes_today"] == 0.0


async def test_agent_config_reflects_policy_changes(client):
    """When parent changes policy, agent should see the new config."""
    token = await register_user(client)
    device = await create_device(client, token)
    agent_token = device["api_token"]

    # Parent updates policy
    await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={"screen_time_limit_minutes": 45, "downtime_start": "21:30"},
        headers={"Authorization": f"Bearer {token}"},
    )

    # Agent fetches config
    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    config = resp.json()
    assert config["screen_time_limit_minutes"] == 45
    assert config["downtime_start"] == "21:30"


async def test_agent_report_usage(client):
    token = await register_user(client)
    device = await create_device(client, token)
    agent_token = device["api_token"]

    # Report usage
    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-04-03", "total_minutes": 55.5},
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200

    # Verify via parent's usage endpoint
    resp = await client.get(
        f"/api/v1/devices/{device['id']}/usage?days=7",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    usage = resp.json()
    assert len(usage) == 1
    assert usage[0]["date"] == "2026-04-03"
    assert usage[0]["total_minutes"] == 55.5


async def test_agent_usage_updates_not_duplicates(client):
    """Reporting usage for the same date should update, not create duplicate."""
    token = await register_user(client)
    device = await create_device(client, token)
    agent_token = device["api_token"]

    # Report twice for same date
    await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-04-03", "total_minutes": 30.0},
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-04-03", "total_minutes": 75.0},
        headers={"Authorization": f"Bearer {agent_token}"},
    )

    resp = await client.get(
        f"/api/v1/devices/{device['id']}/usage?days=7",
        headers={"Authorization": f"Bearer {token}"},
    )
    usage = resp.json()
    assert len(usage) == 1
    assert usage[0]["total_minutes"] == 75.0  # updated, not duplicated


async def test_agent_config_shows_today_usage(client):
    """Agent config should include today's accumulated usage."""
    token = await register_user(client)
    device = await create_device(client, token)
    agent_token = device["api_token"]

    from datetime import datetime
    today = datetime.utcnow().strftime("%Y-%m-%d")

    # Report usage for today
    await client.post(
        "/api/v1/agent/usage",
        json={"date": today, "total_minutes": 42.0},
        headers={"Authorization": f"Bearer {agent_token}"},
    )

    # Agent fetches config — should see today's usage
    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.json()["used_minutes_today"] == 42.0


async def test_agent_invalid_token(client):
    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": "Bearer totally-invalid"},
    )
    assert resp.status_code == 401


async def test_agent_parent_token_rejected(client):
    """Parent tokens should not work on agent endpoints."""
    token = await register_user(client)

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 401


async def test_agent_updates_last_seen(client):
    """Fetching config should update device's last_seen."""
    token = await register_user(client)
    device = await create_device(client, token)
    agent_token = device["api_token"]

    # Initially no last_seen
    assert device.get("last_seen") is None

    # Agent fetches config
    await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )

    # Check last_seen is now set
    resp = await client.get(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.json()["last_seen"] is not None
