"""Rate limiter for auth and TOTP endpoints, shared across uvicorn workers.

The API runs with `--workers 4`, so an in-memory limiter gives each worker its own
budget (5/min becomes ~20/min). Attempts are stored in the `rate_limit_hits` table
instead. On PostgreSQL a transaction-scoped advisory lock per (scope, key) makes the
count-then-insert atomic across workers.
"""
import os
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import HTTPException, Request
from sqlalchemy import delete, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from .models.models import RateLimitHit

# Disable rate limiting in tests
_DISABLED = os.getenv("TESTING", "").lower() in ("1", "true")


def client_ip(request: Request) -> str:
    """The real client IP for rate limiting.

    Behind host nginx → web-container nginx → uvicorn, `request.client.host` is the
    web container for every request. Host nginx sets X-Real-IP to `$remote_addr`
    (overwriting anything the client sent) and the inner nginx passes it through, so it
    is trustworthy. X-Forwarded-For is deliberately ignored: host nginx appends to it, so
    its leftmost entry is client-controlled. The API port is bound to 127.0.0.1, so only
    the proxies can set X-Real-IP.
    """
    real = (request.headers.get("x-real-ip") or "").strip()
    if real:
        return real
    return request.client.host if request.client else "unknown"


class RateLimiter:
    """At most `max_attempts` per `key` within a sliding `window_seconds`."""

    def __init__(self, scope: str, max_attempts: int = 5, window_seconds: int = 60):
        self.scope = scope
        self.max_attempts = max_attempts
        self.window = window_seconds

    async def check(self, db: AsyncSession, key: str, now: Optional[datetime] = None) -> None:
        """Record an attempt, or raise 429 if the budget is spent.

        Commits its own transaction, so call it first in the endpoint, before any other
        writes are pending on `db`.
        """
        if _DISABLED:
            return
        now = now or datetime.now(timezone.utc)
        cutoff = now - timedelta(seconds=self.window)

        if db.bind.dialect.name == "postgresql":
            await db.execute(
                text("SELECT pg_advisory_xact_lock(hashtext(:k))"),
                {"k": f"rate_limit:{self.scope}:{key}"},
            )

        where = (RateLimitHit.scope == self.scope, RateLimitHit.key == key)
        await db.execute(delete(RateLimitHit).where(*where, RateLimitHit.created_at <= cutoff))
        recent = (await db.execute(select(func.count()).select_from(RateLimitHit).where(*where))).scalar_one()
        if recent >= self.max_attempts:
            await db.commit()  # keep the pruning, release the lock
            raise HTTPException(
                status_code=429,
                detail=f"Too many attempts. Try again in {self.window} seconds.",
            )
        db.add(RateLimitHit(scope=self.scope, key=key, created_at=now))
        await db.commit()


# Shared instances
login_limiter = RateLimiter("login", max_attempts=5, window_seconds=60)
totp_limiter = RateLimiter("totp", max_attempts=5, window_seconds=300)
register_limiter = RateLimiter("register", max_attempts=3, window_seconds=300)
