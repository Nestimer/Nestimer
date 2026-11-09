"""Rate limiting keys on the real client IP and is shared across uvicorn workers.

Production chain: host nginx (sets X-Real-IP = $remote_addr, the real client) →
web-container nginx (passes X-Real-IP through) → uvicorn with 4 workers. The limiter
state lives in the database so all workers see the same attempts.
"""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from starlette.requests import Request

import app.rate_limit as rl
from app.models.models import RateLimitHit
from app.rate_limit import RateLimiter, client_ip

pytestmark = pytest.mark.anyio

T0 = datetime(2026, 11, 9, 12, 0, tzinfo=timezone.utc)


def _request(headers: dict[str, str], host: str = "172.18.0.3") -> Request:
    return Request({
        "type": "http",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
        "client": (host, 12345),
    })


@pytest.fixture()
def enabled(monkeypatch):
    monkeypatch.setattr(rl, "_DISABLED", False)


def test_client_ip_prefers_x_real_ip():
    assert client_ip(_request({"X-Real-IP": "203.0.113.7"})) == "203.0.113.7"


def test_client_ip_falls_back_to_socket_peer():
    assert client_ip(_request({})) == "172.18.0.3"


def test_client_ip_ignores_blank_header():
    assert client_ip(_request({"X-Real-IP": "  "})) == "172.18.0.3"


def test_client_ip_ignores_x_forwarded_for():
    # XFF leftmost is client-controlled (host nginx appends to it), so it is never trusted.
    assert client_ip(_request({"X-Forwarded-For": "1.2.3.4"})) == "172.18.0.3"


async def test_blocks_after_max_attempts(db_session, enabled):
    limiter = RateLimiter("login", max_attempts=2, window_seconds=60)
    await limiter.check(db_session, "203.0.113.7", now=T0)
    await limiter.check(db_session, "203.0.113.7", now=T0)
    with pytest.raises(HTTPException) as exc:
        await limiter.check(db_session, "203.0.113.7", now=T0)
    assert exc.value.status_code == 429


async def test_two_clients_have_separate_budgets(db_session, enabled):
    limiter = RateLimiter("login", max_attempts=2, window_seconds=60)
    await limiter.check(db_session, "203.0.113.7", now=T0)
    await limiter.check(db_session, "203.0.113.7", now=T0)
    await limiter.check(db_session, "198.51.100.9", now=T0)  # must not raise


async def test_scopes_are_independent(db_session, enabled):
    login = RateLimiter("login", max_attempts=1, window_seconds=60)
    register = RateLimiter("register", max_attempts=1, window_seconds=60)
    await login.check(db_session, "203.0.113.7", now=T0)
    await register.check(db_session, "203.0.113.7", now=T0)  # must not raise


async def test_window_expiry_allows_again_and_prunes(db_session, enabled):
    limiter = RateLimiter("login", max_attempts=1, window_seconds=60)
    await limiter.check(db_session, "203.0.113.7", now=T0)
    await limiter.check(db_session, "203.0.113.7", now=T0 + timedelta(seconds=61))
    n = (await db_session.execute(
        select(func.count()).select_from(RateLimitHit).where(RateLimitHit.key == "203.0.113.7")
    )).scalar_one()
    assert n == 1  # the expired hit was deleted


async def test_attempts_are_shared_across_sessions(db_session, enabled):
    """Two sessions on the same database stand in for two uvicorn workers."""
    other = async_sessionmaker(db_session.bind, class_=AsyncSession, expire_on_commit=False)
    limiter = RateLimiter("login", max_attempts=2, window_seconds=60)
    await limiter.check(db_session, "203.0.113.7", now=T0)
    async with other() as s2:
        await RateLimiter("login", max_attempts=2, window_seconds=60).check(s2, "203.0.113.7", now=T0)
        with pytest.raises(HTTPException):
            await limiter.check(s2, "203.0.113.7", now=T0)


async def test_disabled_in_tests_records_nothing(db_session):
    limiter = RateLimiter("login", max_attempts=1, window_seconds=60)
    for _ in range(3):
        await limiter.check(db_session, "203.0.113.7", now=T0)
    n = (await db_session.execute(select(func.count()).select_from(RateLimitHit))).scalar_one()
    assert n == 0


async def test_old_rows_of_other_keys_are_swept(db_session, enabled):
    limiter = RateLimiter("login", max_attempts=5, window_seconds=60)
    await limiter.check(db_session, "203.0.113.7", now=T0)  # never comes back
    await limiter.check(db_session, "198.51.100.9", now=T0 + timedelta(hours=2))
    keys = (await db_session.execute(select(RateLimitHit.key))).scalars().all()
    assert keys == ["198.51.100.9"]
