"""Every usage report is journaled for a week, so a disputed count can be traced later."""
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.database import get_db
from app.main import app
from app.models.models import UsageReportLog
from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio


def _agent(device):
    return {"Authorization": f"Bearer {device['api_token']}"}


def _today():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


@asynccontextmanager
async def _session():
    gen = app.dependency_overrides[get_db]()
    try:
        yield await gen.__anext__()
    finally:
        await gen.aclose()


async def _rows(device_id):
    async with _session() as db:
        result = await db.execute(
            select(UsageReportLog).where(UsageReportLog.device_id == device_id)
            .order_by(UsageReportLog.received_at)
        )
        return result.scalars().all()


async def test_each_report_is_journaled_with_reported_and_stored_minutes(client):
    token = await register_user(client)
    device = await create_device(client, token)

    for minutes in (5.0, 6.5):
        r = await client.post("/api/v1/agent/usage", json={"date": _today(), "total_minutes": minutes},
                              headers=_agent(device))
        assert r.status_code == 200

    # A jump the server can't believe: journaled with what was sent AND what was kept.
    r = await client.post("/api/v1/agent/usage", json={"date": _today(), "total_minutes": 500},
                          headers=_agent(device))
    assert r.status_code == 200

    rows = await _rows(device["id"])
    assert [(r.date, r.reported_minutes) for r in rows] == [(_today(), 5.0), (_today(), 6.5), (_today(), 500.0)]
    assert rows[0].stored_minutes == 5.0
    assert rows[1].stored_minutes == 6.5
    assert rows[2].stored_minutes < 10, "the clamped value is what was stored"
    assert all(r.received_at is not None for r in rows)


async def test_journal_keeps_one_week(client, monkeypatch):
    import app.routers.agent as agent
    monkeypatch.setattr(agent, "_last_journal_purge", 0.0)
    token = await register_user(client)
    device = await create_device(client, token)

    now = datetime.now(timezone.utc)
    async with _session() as db:
        db.add(UsageReportLog(device_id=device["id"], date="2026-01-01", reported_minutes=1,
                              stored_minutes=1, received_at=now - timedelta(days=8)))
        db.add(UsageReportLog(device_id=device["id"], date="2026-01-02", reported_minutes=2,
                              stored_minutes=2, received_at=now - timedelta(days=6)))
        await db.commit()

    r = await client.post("/api/v1/agent/usage", json={"date": _today(), "total_minutes": 3},
                          headers=_agent(device))
    assert r.status_code == 200

    assert [r.reported_minutes for r in await _rows(device["id"])] == [2, 3]


async def test_identical_repeat_reports_are_not_journaled_again(client):
    """A locked Mac re-sends the same total every few seconds: one row, not thousands."""
    token = await register_user(client)
    device = await create_device(client, token)
    for minutes in (7.0, 7.0, 7.0, 8.0, 8.0):
        r = await client.post("/api/v1/agent/usage", json={"date": _today(), "total_minutes": minutes},
                              headers=_agent(device))
        assert r.status_code == 200
    assert [r.reported_minutes for r in await _rows(device["id"])] == [7.0, 8.0]


async def test_journal_rows_per_device_per_day_are_capped(client, monkeypatch):
    """A child replaying the device token in a loop must not fill the server's disk."""
    import app.routers.agent as agent
    monkeypatch.setattr(agent, "USAGE_JOURNAL_MAX_ROWS_PER_DAY", 3)
    token = await register_user(client)
    device = await create_device(client, token)
    for minutes in (1, 2, 3, 4, 5):
        r = await client.post("/api/v1/agent/usage", json={"date": _today(), "total_minutes": minutes},
                              headers=_agent(device))
        assert r.status_code == 200, "the report itself is still accepted"
    assert len(await _rows(device["id"])) == 3
