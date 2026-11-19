"""A Mac agent's sync that straddles local midnight used to post yesterday's total under
today's date; the server took the first report for a new date as-is, so the child began
the day with yesterday's minutes already spent (2026-11-19: 104 min "used" on a Mac
nobody had touched)."""
import pytest

from app.routers.agent import USAGE_REPORT_SLACK_MINUTES

from .conftest import register_user, create_device, simulate_elapsed_time

pytestmark = pytest.mark.anyio


async def _report(client, device, date, minutes):
    resp = await client.post(
        "/api/v1/agent/usage",
        json={"date": date, "total_minutes": minutes},
        headers={"Authorization": f"Bearer {device['api_token']}"},
    )
    assert resp.status_code == 200


async def _device_used(client, device, date):
    resp = await client.get(
        f"/api/v1/agent/config?date={date}",
        headers={"Authorization": f"Bearer {device['api_token']}"},
    )
    assert resp.status_code == 200
    return resp.json()["device_used_minutes"]


async def test_yesterdays_total_cannot_open_a_new_day_on_a_mac(client):
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")

    await _report(client, mac, "2026-11-18", 104.0)
    # Seconds later, the same total arrives stamped with the new date.
    await _report(client, mac, "2026-11-19", 104.0)

    assert await _device_used(client, mac, "2026-11-19") <= USAGE_REPORT_SLACK_MINUTES + 0.5
    assert await _device_used(client, mac, "2026-11-18") == 104.0, "yesterday is untouched"


async def test_a_mac_offline_across_midnight_keeps_its_catch_up_total(client):
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")

    await _report(client, mac, "2026-11-18", 60.0)
    await simulate_elapsed_time(180)
    await _report(client, mac, "2026-11-19", 150.0)

    assert await _device_used(client, mac, "2026-11-19") == 150.0


async def test_a_devices_very_first_report_is_accepted_as_is(client):
    token = await register_user(client)
    mac = await create_device(client, token, name="Mac")

    await _report(client, mac, "2026-11-19", 50.0)

    assert await _device_used(client, mac, "2026-11-19") == 50.0


async def test_a_phone_may_flush_yesterday_and_then_report_today(client):
    """Phones report retroactively: the morning sync posts yesterday's last minutes and
    then today's total back to back. That is honest and must not be clamped."""
    token = await register_user(client)
    resp = await client.post(
        "/api/v1/devices",
        json={"name": "Phone", "child_name": "Alex", "platform": "ios"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    phone = resp.json()

    await _report(client, phone, "2026-11-18", 35.0)
    await _report(client, phone, "2026-11-19", 35.0)

    assert await _device_used(client, phone, "2026-11-19") == 35.0
