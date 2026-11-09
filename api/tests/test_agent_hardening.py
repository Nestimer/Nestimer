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


def test_usage_accepts_yesterday_late_in_the_americas():
    """A phone in UTC-5 reports yesterday's last minutes at 08:00 local (13:00 UTC)."""
    from fastapi import HTTPException
    from app.routers.agent import _require_plausible_local_date
    now = datetime(2026, 11, 10, 13, 0, tzinfo=timezone.utc)
    _require_plausible_local_date("2026-11-09", now, allow_previous_day=True)
    with pytest.raises(HTTPException):
        _require_plausible_local_date("2026-11-09", now)  # /config stays strict
    with pytest.raises(HTTPException):
        _require_plausible_local_date("2026-11-08", now, allow_previous_day=True)
    with pytest.raises(HTTPException):
        _require_plausible_local_date("2026-11-12", now, allow_previous_day=True)


async def test_usage_endpoint_accepts_yesterday(client):
    device = await _device(client)
    yesterday = (datetime.now(timezone.utc) - timedelta(hours=12, days=1)).strftime("%Y-%m-%d")
    r = await client.post("/api/v1/agent/usage", json={"date": yesterday, "total_minutes": 5}, headers=_agent(device))
    assert r.status_code == 200, r.text


async def test_totp_stale_read_cannot_reuse_a_code(client):
    """Two concurrent verifies read last_totp_step before either commits; only one may win."""
    from sqlalchemy import select
    from sqlalchemy.orm.attributes import set_committed_value
    from app.models.models import Device
    import app.routers.agent as agent

    device = await _device(client)
    secret = device["shared_secret"]
    code = _code_for_counter(secret, int(datetime.now(timezone.utc).timestamp()) // STEP)
    first = await client.post("/api/v1/agent/verify-totp", json={"code": code}, headers=_agent(device))
    assert first.json()["valid"] is True

    # Simulate the second request having read the row before the first one committed.
    orig_check = agent.totp_limiter.check

    async def check_then_forget(db, device_id):
        await orig_check(db, device_id)
        dev = (await db.execute(select(Device).where(Device.id == device_id))).scalar_one()
        # What a stale, pre-commit read would have seen; not a pending write.
        set_committed_value(dev, "last_totp_step", None)

    agent.totp_limiter.check = check_then_forget
    try:
        again = await client.post("/api/v1/agent/verify-totp", json={"code": code}, headers=_agent(device))
    finally:
        agent.totp_limiter.check = orig_check
    assert again.json()["valid"] is False
