"""An activity can apply to all of a child's devices (default) or only to chosen ones.

A device the activity doesn't name gets no unlock window: it keeps counting and locking
as usual. E.g. English class unlocks the Mac, while the phone stays on the budget.
"""
import pytest

from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio

ACTIVITY = {"name": "English", "day_of_week": 2, "start_time": "14:00", "end_time": "15:00"}


def _parent(token):
    return {"Authorization": f"Bearer {token}"}


def _agent(device):
    return {"Authorization": f"Bearer {device['api_token']}"}


async def _family(client, email="parent@test.com"):
    """One child with a Mac and an iPhone."""
    token = await register_user(client, email=email)
    child = (await client.post("/api/v1/children", json={"name": "Alex"}, headers=_parent(token))).json()
    resp = await client.post("/api/v1/devices", json={"name": "Mac", "child_name": "Alex", "child_id": child["id"]},
                             headers=_parent(token))
    mac = resp.json()
    resp = await client.post("/api/v1/devices", json={"name": "iPhone", "child_name": "Alex",
                                                      "child_id": child["id"], "platform": "ios"},
                             headers=_parent(token))
    phone = resp.json()
    return token, child["id"], mac, phone


async def _agent_activity_names(client, device):
    resp = await client.get("/api/v1/agent/config", headers=_agent(device))
    assert resp.status_code == 200
    return [a["name"] for a in resp.json()["activities"]]


async def test_default_activity_applies_to_every_device(client):
    token, child_id, mac, phone = await _family(client)
    resp = await client.post(f"/api/v1/children/{child_id}/activities", json=ACTIVITY, headers=_parent(token))
    assert resp.status_code == 200
    assert resp.json()["device_ids"] is None

    assert await _agent_activity_names(client, mac) == ["English"]
    assert await _agent_activity_names(client, phone) == ["English"]


async def test_activity_for_chosen_devices_only_reaches_them(client):
    token, child_id, mac, phone = await _family(client)
    resp = await client.post(f"/api/v1/children/{child_id}/activities",
                             json={**ACTIVITY, "device_ids": [mac["id"]]}, headers=_parent(token))
    assert resp.status_code == 200
    assert resp.json()["device_ids"] == [mac["id"]]

    assert await _agent_activity_names(client, mac) == ["English"]
    assert await _agent_activity_names(client, phone) == []


async def test_device_endpoint_accepts_device_ids_too(client):
    token, child_id, mac, phone = await _family(client)
    resp = await client.post(f"/api/v1/devices/{mac['id']}/activities",
                             json={**ACTIVITY, "device_ids": [phone["id"]]}, headers=_parent(token))
    assert resp.status_code == 200
    assert await _agent_activity_names(client, mac) == []
    assert await _agent_activity_names(client, phone) == ["English"]

    listed = (await client.get(f"/api/v1/devices/{mac['id']}/activities", headers=_parent(token))).json()
    assert listed[0]["device_ids"] == [phone["id"]]


async def test_update_changes_devices_and_null_means_all_again(client):
    token, child_id, mac, phone = await _family(client)
    act = (await client.post(f"/api/v1/children/{child_id}/activities", json=ACTIVITY,
                             headers=_parent(token))).json()
    url = f"/api/v1/children/{child_id}/activities/{act['id']}"

    resp = await client.put(url, json={"device_ids": [phone["id"]]}, headers=_parent(token))
    assert resp.status_code == 200
    assert resp.json()["device_ids"] == [phone["id"]]
    assert await _agent_activity_names(client, mac) == []

    # Updating another field leaves the device choice alone.
    resp = await client.put(url, json={"name": "English B"}, headers=_parent(token))
    assert resp.json()["device_ids"] == [phone["id"]]

    resp = await client.put(url, json={"device_ids": None}, headers=_parent(token))
    assert resp.json()["device_ids"] is None
    assert await _agent_activity_names(client, mac) == ["English B"]


async def test_update_through_device_endpoint(client):
    token, child_id, mac, phone = await _family(client)
    act = (await client.post(f"/api/v1/devices/{mac['id']}/activities", json=ACTIVITY,
                             headers=_parent(token))).json()
    resp = await client.put(f"/api/v1/devices/{mac['id']}/activities/{act['id']}",
                            json={"device_ids": [mac["id"]]}, headers=_parent(token))
    assert resp.status_code == 200
    assert await _agent_activity_names(client, phone) == []


async def test_empty_device_list_is_rejected(client):
    token, child_id, mac, phone = await _family(client)
    resp = await client.post(f"/api/v1/children/{child_id}/activities",
                             json={**ACTIVITY, "device_ids": []}, headers=_parent(token))
    assert resp.status_code == 422


async def test_device_of_another_child_is_rejected(client):
    token, child_id, mac, phone = await _family(client)
    other = await create_device(client, token, name="Sister Mac", child_name="Sister")
    resp = await client.post(f"/api/v1/children/{child_id}/activities",
                             json={**ACTIVITY, "device_ids": [mac["id"], other["id"]]}, headers=_parent(token))
    assert resp.status_code == 422


async def test_device_of_another_parent_is_rejected(client):
    token, child_id, mac, phone = await _family(client)
    _, _, stranger_mac, _ = await _family(client, email="other@test.com")
    resp = await client.post(f"/api/v1/children/{child_id}/activities",
                             json={**ACTIVITY, "device_ids": [stranger_mac["id"]]}, headers=_parent(token))
    assert resp.status_code == 422

    act = (await client.post(f"/api/v1/children/{child_id}/activities", json=ACTIVITY,
                             headers=_parent(token))).json()
    resp = await client.put(f"/api/v1/children/{child_id}/activities/{act['id']}",
                            json={"device_ids": [stranger_mac["id"]]}, headers=_parent(token))
    assert resp.status_code == 422


async def test_deleted_device_drops_out_of_the_listed_choice(client):
    token, child_id, mac, phone = await _family(client)
    await client.post(f"/api/v1/children/{child_id}/activities",
                      json={**ACTIVITY, "device_ids": [mac["id"], phone["id"]]}, headers=_parent(token))
    resp = await client.delete(f"/api/v1/devices/{phone['id']}", headers=_parent(token))
    assert resp.status_code == 200

    listed = (await client.get(f"/api/v1/children/{child_id}/activities", headers=_parent(token))).json()
    assert listed[0]["device_ids"] == [mac["id"]]
    assert await _agent_activity_names(client, mac) == ["English"]
