"""The child controls the device clock: the server must not trust a date or a code blindly."""
from datetime import datetime, timedelta, timezone

import pytest

from app.totp import _code_for_counter, STEP
from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


@pytest.fixture(autouse=True)
def _strict_dates(monkeypatch, _historical_dates_allowed):
    import app.routers.agent as agent
    monkeypatch.setattr(agent, "ENFORCE_PLAUSIBLE_DATES", True)


def _agent(device):
    return {"Authorization": f"Bearer {device['api_token']}"}


async def _device(client):
    token = await register_user(client)
    return await create_device(client, token)


def _d(delta_days=0):
    return (datetime.now(timezone.utc) + timedelta(days=delta_days)).strftime("%Y-%m-%d")


async def test_config_accepts_any_real_time_zones_local_date(client):
    device = await _device(client)
    now = datetime.now(timezone.utc)
    for hours in (-12, 0, 14):  # UTC-12 … UTC+14
        local = (now + timedelta(hours=hours)).strftime("%Y-%m-%d")
        r = await client.get(f"/api/v1/agent/config?date={local}", headers=_agent(device))
        assert r.status_code == 200, (hours, r.text)


async def test_config_rejects_a_date_days_away(client):
    device = await _device(client)
    for delta in (2, -2, 30):
        r = await client.get(f"/api/v1/agent/config?date={_d(delta)}", headers=_agent(device))
        assert r.status_code == 400, delta


async def test_usage_rejects_a_date_days_away(client):
    device = await _device(client)
    r = await client.post("/api/v1/agent/usage", json={"date": _d(3), "total_minutes": 5}, headers=_agent(device))
    assert r.status_code == 400
    r = await client.post("/api/v1/agent/usage", json={"date": _d(0), "total_minutes": 5}, headers=_agent(device))
    assert r.status_code == 200


async def test_totp_code_is_one_time(client):
    device = await _device(client)
    secret = device["shared_secret"]
    code = _code_for_counter(secret, int(datetime.now(timezone.utc).timestamp()) // STEP)
    first = await client.post("/api/v1/agent/verify-totp", json={"code": code}, headers=_agent(device))
    assert first.json()["valid"] is True
    again = await client.post("/api/v1/agent/verify-totp", json={"code": code}, headers=_agent(device))
    assert again.json()["valid"] is False


async def test_older_code_rejected_after_newer_one_used(client):
    device = await _device(client)
    secret = device["shared_secret"]
    now = int(datetime.now(timezone.utc).timestamp()) // STEP
    newer = await client.post("/api/v1/agent/verify-totp", json={"code": _code_for_counter(secret, now)}, headers=_agent(device))
    assert newer.json()["valid"] is True
    older = await client.post("/api/v1/agent/verify-totp", json={"code": _code_for_counter(secret, now - 1)}, headers=_agent(device))
    assert older.json()["valid"] is False
