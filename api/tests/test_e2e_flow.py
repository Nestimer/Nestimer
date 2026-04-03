"""
End-to-end flow test: simulates the full parent + agent lifecycle.

1. Parent registers
2. Parent adds a device → gets agent token
3. Parent configures downtime and screen time
4. Agent fetches config → sees correct policy
5. Agent reports usage over time
6. Parent checks usage stats
7. Agent exceeds limit → parent verifies
8. Parent changes limit → agent sees update
"""
import pytest
from datetime import datetime

from .conftest import register_user

pytestmark = pytest.mark.anyio


async def test_full_lifecycle(client):
    # === STEP 1: Parent registers ===
    parent_token = await register_user(client, email="parent@family.com", name="Мама")

    # Verify parent identity
    resp = await client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {parent_token}"})
    assert resp.json()["name"] == "Мама"

    # === STEP 2: Parent adds child's device ===
    resp = await client.post(
        "/api/v1/devices",
        json={"name": "MacBook Миши", "child_name": "Миша"},
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert resp.status_code == 200
    device = resp.json()
    device_id = device["id"]
    agent_token = device["api_token"]
    assert agent_token  # not empty

    # === STEP 3: Parent configures policy ===
    resp = await client.put(
        f"/api/v1/devices/{device_id}/policy",
        json={
            "downtime_start": "21:00",
            "downtime_end": "07:30",
            "screen_time_limit_minutes": 90,
            "screen_time_weekend_limit_minutes": 150,
        },
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert resp.status_code == 200
    policy = resp.json()
    assert policy["downtime_start"] == "21:00"
    assert policy["downtime_end"] == "07:30"
    assert policy["screen_time_limit_minutes"] == 90
    assert policy["screen_time_weekend_limit_minutes"] == 150

    # === STEP 4: Agent fetches config ===
    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200
    agent_config = resp.json()
    assert agent_config["downtime_enabled"] is True
    assert agent_config["downtime_start"] == "21:00"
    assert agent_config["downtime_end"] == "07:30"
    assert agent_config["screen_time_enabled"] is True
    # Note: limit may be 90 or 150 depending on day of week
    assert agent_config["screen_time_limit_minutes"] in [90, 150]
    assert agent_config["used_minutes_today"] == 0.0

    # Device should now have last_seen set
    resp = await client.get(
        f"/api/v1/devices/{device_id}",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert resp.json()["last_seen"] is not None

    # === STEP 5: Agent reports usage over time (simulating 30-second ticks) ===
    today = datetime.utcnow().strftime("%Y-%m-%d")

    # After 30 minutes
    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": today, "total_minutes": 30.0},
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200

    # After 60 minutes
    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": today, "total_minutes": 60.0},
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200

    # === STEP 6: Parent checks usage ===
    resp = await client.get(
        f"/api/v1/devices/{device_id}/usage?days=7",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert resp.status_code == 200
    usage = resp.json()
    assert len(usage) == 1
    assert usage[0]["date"] == today
    assert usage[0]["total_minutes"] == 60.0

    # Agent config should reflect accumulated usage
    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.json()["used_minutes_today"] == 60.0

    # === STEP 7: Agent reports exceeding limit ===
    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": today, "total_minutes": 95.0},  # > 90 minute limit
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200

    # Agent fetches config — should see the usage
    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    config = resp.json()
    assert config["used_minutes_today"] == 95.0
    # In the agent, this would trigger lock since 95 > 90 (or 150)

    # === STEP 8: Parent grants more time ===
    resp = await client.put(
        f"/api/v1/devices/{device_id}/policy",
        json={"screen_time_limit_minutes": 180},
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert resp.json()["screen_time_limit_minutes"] == 180

    # Agent sees the updated limit on next sync
    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    config = resp.json()
    # Now the limit is 180, and used is 95 — agent should unlock
    assert config["screen_time_limit_minutes"] in [150, 180]  # weekend might override
    assert config["used_minutes_today"] == 95.0

    # === STEP 9: Verify multi-day usage tracking ===
    # Report usage for yesterday
    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": "2026-04-02", "total_minutes": 88.0},
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200

    # Parent sees both days
    resp = await client.get(
        f"/api/v1/devices/{device_id}/usage?days=7",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    usage = resp.json()
    assert len(usage) == 2
    dates = {u["date"] for u in usage}
    assert today in dates
    assert "2026-04-02" in dates

    # === STEP 10: Multi-device support ===
    resp = await client.post(
        "/api/v1/devices",
        json={"name": "iPad Пети", "child_name": "Петя"},
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    device2 = resp.json()

    resp = await client.get("/api/v1/devices", headers={"Authorization": f"Bearer {parent_token}"})
    assert len(resp.json()) == 2

    # Devices are independent — device2 has no usage
    resp = await client.get(
        f"/api/v1/devices/{device2['id']}/usage?days=7",
        headers={"Authorization": f"Bearer {parent_token}"},
    )
    assert len(resp.json()) == 0

    print("=== E2E test passed: full parent + agent lifecycle ===")
