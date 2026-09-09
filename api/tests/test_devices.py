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


async def test_grant_bonus_sets_bonus_until(client):
    """grant-bonus returns bonus_until timestamp and exposes it via /agent/config."""
    from datetime import datetime, timezone
    token = await register_user(client, email="bonus@test.com")
    device = await create_device(client, token)
    agent_token = device["api_token"]

    resp = await client.post(
        f"/api/v1/devices/{device['id']}/grant-bonus",
        json={"minutes": 5},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    bonus_until_str = resp.json()["bonus_until"]
    bonus_until = datetime.fromisoformat(bonus_until_str)
    delta = (bonus_until - datetime.now(timezone.utc)).total_seconds()
    assert 240 < delta <= 300  # ~5 min from now

    # Agent config should now expose bonus_until
    cfg = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert cfg.status_code == 200
    assert cfg.json()["bonus_until"] is not None


async def test_grant_bonus_validation(client):
    """Minutes must be in [1, 120]."""
    token = await register_user(client, email="bonus-val@test.com")
    device = await create_device(client, token)

    for bad in [0, -5, 121, 1000]:
        resp = await client.post(
            f"/api/v1/devices/{device['id']}/grant-bonus",
            json={"minutes": bad},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 422


async def test_grant_bonus_requires_owner(client):
    """Other users cannot grant bonus on someone else's device."""
    owner = await register_user(client, email="bonus-owner@test.com")
    intruder = await register_user(client, email="bonus-intruder@test.com")
    device = await create_device(client, owner)

    resp = await client.post(
        f"/api/v1/devices/{device['id']}/grant-bonus",
        json={"minutes": 5},
        headers={"Authorization": f"Bearer {intruder}"},
    )
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Child assignment, platform and per-device cap
# ---------------------------------------------------------------------------

async def test_device_can_be_moved_to_another_child(client):
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac", child_name="Alex")
    phone = await create_device(client, token, name="Phone", child_name="Sam")

    child_id = (await client.get(f"/api/v1/devices/{mac['id']}", headers=headers)).json()["child_id"]
    resp = await client.patch(
        f"/api/v1/devices/{phone['id']}", json={"child_id": child_id}, headers=headers
    )
    assert resp.status_code == 200
    assert resp.json()["child_id"] == child_id

    # The denormalised child_name column must follow the child it's now attached
    # to (Alex), not the name the phone was created under (Sam) — otherwise two
    # devices on one child could disagree about that child's name in the parent UI.
    resp = await client.get(f"/api/v1/devices/{phone['id']}", headers=headers)
    assert resp.json()["child_name"] == "Alex"


async def test_cannot_move_a_device_to_another_parents_child(client):
    token_a = await register_user(client, email="a@test.com")
    token_b = await register_user(client, email="b@test.com")
    device_a = await create_device(client, token_a, name="Mac A")
    device_b = await create_device(client, token_b, name="Mac B")

    child_a = (await client.get(
        f"/api/v1/devices/{device_a['id']}", headers={"Authorization": f"Bearer {token_a}"}
    )).json()["child_id"]

    resp = await client.patch(
        f"/api/v1/devices/{device_b['id']}",
        json={"child_id": child_a},
        headers={"Authorization": f"Bearer {token_b}"},
    )
    assert resp.status_code == 404


async def test_cannot_create_device_with_another_parents_child(client):
    """POST /devices must apply the same ownership check on child_id as PATCH does —
    a client should never be able to attach a brand-new device to a child it doesn't
    own by passing that child's id at creation time."""
    token_a = await register_user(client, email="create-a@test.com")
    token_b = await register_user(client, email="create-b@test.com")
    device_a = await create_device(client, token_a, name="Mac A")

    child_a = (await client.get(
        f"/api/v1/devices/{device_a['id']}", headers={"Authorization": f"Bearer {token_a}"}
    )).json()["child_id"]

    resp = await client.post(
        "/api/v1/devices",
        json={"name": "Mac B", "child_name": "Doesn't matter", "child_id": child_a},
        headers={"Authorization": f"Bearer {token_b}"},
    )
    assert resp.status_code == 404


async def test_daily_cap_can_be_set_and_cleared(client):
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac")

    resp = await client.patch(
        f"/api/v1/devices/{mac['id']}", json={"daily_cap_minutes": 60}, headers=headers
    )
    assert resp.json()["daily_cap_minutes"] == 60

    resp = await client.patch(
        f"/api/v1/devices/{mac['id']}", json={"daily_cap_minutes": None}, headers=headers
    )
    assert resp.json()["daily_cap_minutes"] is None


async def test_unrelated_patch_does_not_clear_the_daily_cap(client):
    """A PATCH that never mentions daily_cap_minutes must leave it alone — pins the
    'absent field' half of the model_fields_set check, which set_and_cleared above
    doesn't exercise (a regression to unconditionally assigning data.daily_cap_minutes
    would pass both of that test's assertions while silently wiping the cap here)."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac")

    resp = await client.patch(
        f"/api/v1/devices/{mac['id']}", json={"daily_cap_minutes": 60}, headers=headers
    )
    assert resp.json()["daily_cap_minutes"] == 60

    resp = await client.patch(
        f"/api/v1/devices/{mac['id']}", json={"name": "Renamed"}, headers=headers
    )
    assert resp.json()["name"] == "Renamed"
    assert resp.json()["daily_cap_minutes"] == 60, "an unrelated field update must not clear the cap"


async def test_device_defaults_to_macos_platform(client):
    token = await register_user(client)
    device = await create_device(client, token, name="Mac")
    assert device["platform"] == "macos"


async def test_moving_device_rekeys_its_activities_to_the_new_child(client):
    """A device's own scheduled activities must keep being enforced (and stay visible
    in this device's activity list) after it moves to a different child — even once
    that child has activities of its own. `_child_id_for_device`/`_resolve_activity`
    resolve child-first, so a moved device's legacy child-keyed rows would otherwise
    become invisible to /agent/config the moment the new child gets any activity of
    its own, while still showing up (unenforced) in this device's parent-facing list."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    mac = await create_device(client, token, name="Mac")
    phone = await create_device(client, token, name="Phone")

    # Give the phone (about to move) an activity of its own.
    resp = await client.post(
        f"/api/v1/devices/{phone['id']}/activities",
        json={"name": "Piano", "day_of_week": 1, "start_time": "16:00", "end_time": "17:00"},
        headers=headers,
    )
    assert resp.status_code == 200
    activity_id = resp.json()["id"]

    # The destination child (mac's) already has an activity of its own.
    mac_child_id = (await client.get(f"/api/v1/devices/{mac['id']}", headers=headers)).json()["child_id"]
    resp = await client.post(
        f"/api/v1/devices/{mac['id']}/activities",
        json={"name": "English", "day_of_week": 2, "start_time": "10:00", "end_time": "11:00"},
        headers=headers,
    )
    assert resp.status_code == 200

    # Move the phone onto the mac's child.
    resp = await client.patch(
        f"/api/v1/devices/{phone['id']}", json={"child_id": mac_child_id}, headers=headers
    )
    assert resp.status_code == 200

    # The phone's own activity must still be listed under the phone...
    resp = await client.get(f"/api/v1/devices/{phone['id']}/activities", headers=headers)
    names = {a["name"] for a in resp.json()}
    assert "Piano" in names

    # ...and must still be enforced: /agent/config for the phone must include it now
    # that the new child already has an activity of its own (the child-first lookup
    # would otherwise hide a legacy device-keyed row here).
    resp = await client.get(
        "/api/v1/agent/config", headers={"Authorization": f"Bearer {phone['api_token']}"}
    )
    config_names = {a["name"] for a in resp.json()["activities"]}
    assert "Piano" in config_names, "moved device's own activity must still be enforced"


async def test_moving_a_device_removes_the_activity_from_a_sibling_left_behind(client):
    """Pins the intentional side effect of re-keying: a SIBLING device that stayed on
    the old child and was only inheriting an activity through the child-first lookup
    (no device-keyed row of its own for it) loses that activity the instant the owning
    device moves away. The activity belongs to the device that moved, not to the old
    child in general, so the sibling losing it is correct — but it is a real, visible
    change and must be pinned by a test, not just asserted in a comment."""
    token = await register_user(client)
    headers = {"Authorization": f"Bearer {token}"}
    phone = await create_device(client, token, name="Phone")
    sibling = await create_device(client, token, name="Sibling")
    mac = await create_device(client, token, name="Mac")

    old_child_id = (await client.get(f"/api/v1/devices/{phone['id']}", headers=headers)).json()["child_id"]
    new_child_id = (await client.get(f"/api/v1/devices/{mac['id']}", headers=headers)).json()["child_id"]

    # Put the sibling on the phone's child, with no activity of its own.
    resp = await client.patch(
        f"/api/v1/devices/{sibling['id']}", json={"child_id": old_child_id}, headers=headers
    )
    assert resp.status_code == 200

    # The phone's own activity, inherited by the sibling via the child-first lookup.
    resp = await client.post(
        f"/api/v1/devices/{phone['id']}/activities",
        json={"name": "Piano", "day_of_week": 1, "start_time": "16:00", "end_time": "17:00"},
        headers=headers,
    )
    assert resp.status_code == 200

    resp = await client.get(
        "/api/v1/agent/config", headers={"Authorization": f"Bearer {sibling['api_token']}"}
    )
    assert {a["name"] for a in resp.json()["activities"]} == {"Piano"}, \
        "sibling must inherit the activity through the child before the move"

    # Move the phone (and its activity) to a different child.
    resp = await client.patch(
        f"/api/v1/devices/{phone['id']}", json={"child_id": new_child_id}, headers=headers
    )
    assert resp.status_code == 200

    resp = await client.get(
        "/api/v1/agent/config", headers={"Authorization": f"Bearer {sibling['api_token']}"}
    )
    assert resp.json()["activities"] == [], \
        "the sibling left behind on the old child must no longer see the moved activity"
