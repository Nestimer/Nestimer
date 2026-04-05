"""Tests for activity CRUD endpoints on devices."""
import pytest
from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _setup(client):
    """Register a user, create a device, return (parent_token, device_dict)."""
    token = await register_user(client)
    device = await create_device(client, token)
    return token, device


async def _create_activity(client, token, device_id, **overrides):
    """Create an activity with sensible defaults; override any field via kwargs."""
    payload = {
        "name": "English class",
        "day_of_week": 1,
        "start_time": "15:00",
        "end_time": "16:00",
        "buffer_before_minutes": 5,
        "buffer_after_minutes": 5,
        "enabled": True,
    }
    payload.update(overrides)
    resp = await client.post(
        f"/api/v1/devices/{device_id}/activities",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
    )
    return resp


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

async def test_create_activity_all_fields(client):
    token, device = await _setup(client)
    resp = await _create_activity(
        client, token, device["id"],
        name="Math tutoring",
        day_of_week=3,
        start_time="10:00",
        end_time="11:30",
        buffer_before_minutes=10,
        buffer_after_minutes=15,
        enabled=True,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["name"] == "Math tutoring"
    assert data["day_of_week"] == 3
    assert data["start_time"] == "10:00"
    assert data["end_time"] == "11:30"
    assert data["buffer_before_minutes"] == 10
    assert data["buffer_after_minutes"] == 15
    assert data["enabled"] is True
    assert "id" in data


async def test_create_activity_defaults(client):
    """Buffer defaults to 5 and enabled defaults to True when omitted."""
    token, device = await _setup(client)
    resp = await client.post(
        f"/api/v1/devices/{device['id']}/activities",
        json={
            "name": "Piano",
            "day_of_week": 0,
            "start_time": "09:00",
            "end_time": "10:00",
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["buffer_before_minutes"] == 5
    assert data["buffer_after_minutes"] == 5
    assert data["enabled"] is True


# ---------------------------------------------------------------------------
# Validation errors
# ---------------------------------------------------------------------------

async def test_create_activity_invalid_day_too_high(client):
    token, device = await _setup(client)
    resp = await _create_activity(client, token, device["id"], day_of_week=7)
    assert resp.status_code == 422


async def test_create_activity_invalid_day_negative(client):
    token, device = await _setup(client)
    resp = await _create_activity(client, token, device["id"], day_of_week=-1)
    assert resp.status_code == 422


async def test_create_activity_invalid_time_format(client):
    token, device = await _setup(client)
    resp = await _create_activity(client, token, device["id"], start_time="3pm")
    assert resp.status_code == 422


async def test_create_activity_invalid_time_out_of_range(client):
    token, device = await _setup(client)
    resp = await _create_activity(client, token, device["id"], start_time="25:00")
    assert resp.status_code == 422


async def test_create_activity_name_too_long(client):
    token, device = await _setup(client)
    resp = await _create_activity(client, token, device["id"], name="x" * 101)
    assert resp.status_code == 422


async def test_create_activity_name_empty(client):
    token, device = await _setup(client)
    resp = await _create_activity(client, token, device["id"], name="")
    assert resp.status_code == 422


# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------

async def test_list_activities_empty(client):
    token, device = await _setup(client)
    resp = await client.get(
        f"/api/v1/devices/{device['id']}/activities",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.json() == []


async def test_list_activities_sorted_by_day_and_time(client):
    token, device = await _setup(client)
    did = device["id"]

    # Create in non-sorted order
    await _create_activity(client, token, did, name="Wed late", day_of_week=2, start_time="17:00", end_time="18:00")
    await _create_activity(client, token, did, name="Mon early", day_of_week=0, start_time="08:00", end_time="09:00")
    await _create_activity(client, token, did, name="Mon late", day_of_week=0, start_time="14:00", end_time="15:00")
    await _create_activity(client, token, did, name="Wed early", day_of_week=2, start_time="09:00", end_time="10:00")

    resp = await client.get(
        f"/api/v1/devices/{did}/activities",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    acts = resp.json()
    assert len(acts) == 4
    # Should be sorted by day_of_week first, then start_time
    assert acts[0]["name"] == "Mon early"
    assert acts[1]["name"] == "Mon late"
    assert acts[2]["name"] == "Wed early"
    assert acts[3]["name"] == "Wed late"


# ---------------------------------------------------------------------------
# Update (partial)
# ---------------------------------------------------------------------------

async def test_update_activity_partial(client):
    token, device = await _setup(client)
    resp = await _create_activity(client, token, device["id"])
    activity_id = resp.json()["id"]

    resp = await client.put(
        f"/api/v1/devices/{device['id']}/activities/{activity_id}",
        json={"name": "Updated name", "buffer_before_minutes": 10},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["name"] == "Updated name"
    assert data["buffer_before_minutes"] == 10
    # Unchanged fields preserved
    assert data["day_of_week"] == 1
    assert data["start_time"] == "15:00"
    assert data["end_time"] == "16:00"


async def test_update_activity_not_found(client):
    token, device = await _setup(client)
    resp = await client.put(
        f"/api/v1/devices/{device['id']}/activities/nonexistent-id",
        json={"name": "Nope"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Toggle enabled/disabled
# ---------------------------------------------------------------------------

async def test_toggle_activity_enabled(client):
    token, device = await _setup(client)
    resp = await _create_activity(client, token, device["id"], enabled=True)
    activity_id = resp.json()["id"]

    # Disable
    resp = await client.put(
        f"/api/v1/devices/{device['id']}/activities/{activity_id}",
        json={"enabled": False},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["enabled"] is False

    # Re-enable
    resp = await client.put(
        f"/api/v1/devices/{device['id']}/activities/{activity_id}",
        json={"enabled": True},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["enabled"] is True


# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------

async def test_delete_activity(client):
    token, device = await _setup(client)
    resp = await _create_activity(client, token, device["id"])
    activity_id = resp.json()["id"]

    resp = await client.delete(
        f"/api/v1/devices/{device['id']}/activities/{activity_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200

    # Verify it's gone
    resp = await client.get(
        f"/api/v1/devices/{device['id']}/activities",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.json() == []


async def test_delete_activity_not_found(client):
    token, device = await _setup(client)
    resp = await client.delete(
        f"/api/v1/devices/{device['id']}/activities/nonexistent-id",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Per-device isolation
# ---------------------------------------------------------------------------

async def test_activities_per_device_isolation(client):
    """Activities on device A are not visible on device B."""
    token = await register_user(client)
    dev_a = await create_device(client, token, name="Mac A", child_name="A")
    dev_b = await create_device(client, token, name="Mac B", child_name="B")

    # Create activity on device A
    await _create_activity(client, token, dev_a["id"], name="Only on A")

    # Device A has 1 activity
    resp = await client.get(
        f"/api/v1/devices/{dev_a['id']}/activities",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert len(resp.json()) == 1

    # Device B has 0 activities
    resp = await client.get(
        f"/api/v1/devices/{dev_b['id']}/activities",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert len(resp.json()) == 0


# ---------------------------------------------------------------------------
# Per-owner isolation
# ---------------------------------------------------------------------------

async def test_activities_per_owner_isolation(client):
    """User A cannot access or modify user B's device activities."""
    token_a = await register_user(client, email="usera@test.com")
    token_b = await register_user(client, email="userb@test.com")
    device = await create_device(client, token_a, name="A's Mac", child_name="KidA")

    # Create activity as owner
    resp = await _create_activity(client, token_a, device["id"], name="Owner's activity")
    assert resp.status_code == 200
    activity_id = resp.json()["id"]

    # User B cannot list
    resp = await client.get(
        f"/api/v1/devices/{device['id']}/activities",
        headers={"Authorization": f"Bearer {token_b}"},
    )
    assert resp.status_code == 404

    # User B cannot create
    resp = await _create_activity(client, token_b, device["id"], name="Intruder")
    assert resp.status_code == 404

    # User B cannot update
    resp = await client.put(
        f"/api/v1/devices/{device['id']}/activities/{activity_id}",
        json={"name": "Hacked"},
        headers={"Authorization": f"Bearer {token_b}"},
    )
    assert resp.status_code == 404

    # User B cannot delete
    resp = await client.delete(
        f"/api/v1/devices/{device['id']}/activities/{activity_id}",
        headers={"Authorization": f"Bearer {token_b}"},
    )
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Activities in agent config
# ---------------------------------------------------------------------------

async def test_activities_appear_in_agent_config(client):
    token, device = await _setup(client)
    agent_token = device["api_token"]

    await _create_activity(client, token, device["id"], name="English", day_of_week=2,
                           start_time="14:00", end_time="15:00")

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200
    config = resp.json()
    assert len(config["activities"]) == 1
    act = config["activities"][0]
    assert act["name"] == "English"
    assert act["day_of_week"] == 2
    assert act["start_time"] == "14:00"
    assert act["end_time"] == "15:00"


async def test_only_enabled_activities_in_agent_config(client):
    """Disabled activities must not appear in agent config."""
    token, device = await _setup(client)
    agent_token = device["api_token"]

    await _create_activity(client, token, device["id"], name="Enabled", enabled=True)
    await _create_activity(client, token, device["id"], name="Disabled", enabled=False,
                           day_of_week=3, start_time="10:00", end_time="11:00")

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    config = resp.json()
    names = [a["name"] for a in config["activities"]]
    assert "Enabled" in names
    assert "Disabled" not in names


async def test_agent_config_no_activities_when_none_exist(client):
    token, device = await _setup(client)
    agent_token = device["api_token"]

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.json()["activities"] == []
