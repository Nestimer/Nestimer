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

    from datetime import datetime, timezone
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

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


# ---------------------------------------------------------------------------
# Agent config with ?date= parameter (timezone handling)
# ---------------------------------------------------------------------------

async def test_agent_config_with_date_param(client):
    """Agent can pass ?date= to get usage for a specific local date."""
    token = await register_user(client, email="dateagent@test.com")
    device = await create_device(client, token)
    agent_token = device["api_token"]

    # Report usage for a specific date
    await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-03-15", "total_minutes": 77.0},
        headers={"Authorization": f"Bearer {agent_token}"},
    )

    # Fetch config with that date
    resp = await client.get(
        "/api/v1/agent/config?date=2026-03-15",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["used_minutes_today"] == 77.0


async def test_agent_config_date_correct_weekday_limit(client):
    """?date= should pick the correct weekday for limit calculation."""
    token = await register_user(client, email="weekday-limit@test.com")
    device = await create_device(client, token)
    agent_token = device["api_token"]

    # Set a Tuesday-specific limit
    await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={"screen_time_tue_minutes": 55},
        headers={"Authorization": f"Bearer {token}"},
    )

    # 2026-01-06 is a Tuesday (weekday=1)
    resp = await client.get(
        "/api/v1/agent/config?date=2026-01-06",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.json()["screen_time_limit_minutes"] == 55


async def test_agent_config_weekend_date_returns_weekend_limit(client):
    """Passing a weekend date should use the weekend limit."""
    token = await register_user(client, email="weekend-cfg@test.com")
    device = await create_device(client, token)
    agent_token = device["api_token"]

    await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={
            "screen_time_limit_minutes": 120,
            "screen_time_weekend_limit_minutes": 240,
        },
        headers={"Authorization": f"Bearer {token}"},
    )

    # 2026-01-04 is a Sunday (weekday=6)
    resp = await client.get(
        "/api/v1/agent/config?date=2026-01-04",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.json()["screen_time_limit_minutes"] == 240


async def test_agent_config_per_day_override_over_weekend(client):
    """A per-day override should take priority over the weekend limit."""
    token = await register_user(client, email="perday-agent@test.com")
    device = await create_device(client, token)
    agent_token = device["api_token"]

    await client.put(
        f"/api/v1/devices/{device['id']}/policy",
        json={
            "screen_time_limit_minutes": 100,
            "screen_time_weekend_limit_minutes": 200,
            "screen_time_sun_minutes": 60,
        },
        headers={"Authorization": f"Bearer {token}"},
    )

    # 2026-01-04 is Sunday
    resp = await client.get(
        "/api/v1/agent/config?date=2026-01-04",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    # Per-day Sunday (60) beats weekend (200)
    assert resp.json()["screen_time_limit_minutes"] == 60


async def test_agent_config_invalid_date_falls_back(client):
    """Invalid ?date= should fall back to UTC today without error."""
    token = await register_user(client, email="baddate@test.com")
    device = await create_device(client, token)
    agent_token = device["api_token"]

    resp = await client.get(
        "/api/v1/agent/config?date=not-a-date",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200
    # Should still return a valid config
    assert "screen_time_limit_minutes" in resp.json()


async def test_agent_config_no_policy_defaults(client):
    """If no policy exists (edge case), agent config returns safe defaults."""
    # This is tested implicitly, but let's verify the activities list is empty too
    token = await register_user(client, email="nopolicy@test.com")
    device = await create_device(client, token)
    agent_token = device["api_token"]

    # Device creation always makes a policy, but let's just verify defaults
    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    config = resp.json()
    assert config["activities"] == []
    assert config["shared_secret"] is not None


# ---------------------------------------------------------------------------
# Agent update/check endpoint
# ---------------------------------------------------------------------------

async def test_agent_update_check_no_update(client):
    """When no update files exist, check returns null version and sha256."""
    resp = await client.get("/api/v1/agent/update/check")
    assert resp.status_code == 200
    data = resp.json()
    assert data["version"] is None
    assert data["sha256"] is None


async def test_agent_update_download_404_when_no_update(client):
    """Download endpoint returns 404 when no update zip exists."""
    resp = await client.get("/api/v1/agent/update/download")
    assert resp.status_code == 404
    assert "No update available" in resp.json()["detail"]
