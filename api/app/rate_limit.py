"""Simple in-memory rate limiter for auth endpoints."""
import os
import time
from collections import defaultdict
from fastapi import HTTPException, Request

# Disable rate limiting in tests
_DISABLED = os.getenv("TESTING", "").lower() in ("1", "true")


class RateLimiter:
    """Tracks attempts per key (IP) with a sliding window."""

    def __init__(self, max_attempts: int = 5, window_seconds: int = 60):
        self.max_attempts = max_attempts
        self.window = window_seconds
        self._attempts: dict[str, list[float]] = defaultdict(list)

    def check(self, key: str):
        if _DISABLED:
            return
        now = time.time()
        # Remove old attempts
        self._attempts[key] = [t for t in self._attempts[key] if now - t < self.window]
        if len(self._attempts[key]) >= self.max_attempts:
            raise HTTPException(
                status_code=429,
                detail=f"Too many attempts. Try again in {self.window} seconds.",
            )
        self._attempts[key].append(now)


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


# Shared instances
login_limiter = RateLimiter(max_attempts=5, window_seconds=60)
totp_limiter = RateLimiter(max_attempts=5, window_seconds=300)
register_limiter = RateLimiter(max_attempts=3, window_seconds=300)
