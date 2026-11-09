"""Rate limiting must key on the real client IP, not the proxy hop.

Production chain: host nginx (sets X-Real-IP = $remote_addr, the real client) →
web-container nginx (passes X-Real-IP through) → uvicorn. request.client.host is
the web container for every request, which made the per-IP limit global.
"""
from starlette.requests import Request

from app.rate_limit import RateLimiter, client_ip


def _request(headers: dict[str, str], host: str = "172.18.0.3") -> Request:
    return Request({
        "type": "http",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
        "client": (host, 12345),
    })


def test_client_ip_prefers_x_real_ip():
    assert client_ip(_request({"X-Real-IP": "203.0.113.7"})) == "203.0.113.7"


def test_client_ip_falls_back_to_socket_peer():
    assert client_ip(_request({})) == "172.18.0.3"


def test_client_ip_ignores_blank_header():
    assert client_ip(_request({"X-Real-IP": "  "})) == "172.18.0.3"


def test_client_ip_ignores_x_forwarded_for():
    # XFF leftmost is client-controlled (host nginx appends to it), so it is never trusted.
    assert client_ip(_request({"X-Forwarded-For": "1.2.3.4"})) == "172.18.0.3"


def test_two_clients_behind_same_proxy_have_separate_budgets(monkeypatch):
    import app.rate_limit as rl
    monkeypatch.setattr(rl, "_DISABLED", False)
    limiter = RateLimiter(max_attempts=2, window_seconds=60)
    a = client_ip(_request({"X-Real-IP": "203.0.113.7"}))
    b = client_ip(_request({"X-Real-IP": "198.51.100.9"}))
    limiter.check(a)
    limiter.check(a)
    limiter.check(b)  # must not raise: b has its own budget


def test_idle_keys_are_dropped(monkeypatch):
    import app.rate_limit as rl
    monkeypatch.setattr(rl, "_DISABLED", False)
    limiter = RateLimiter(max_attempts=2, window_seconds=60)
    t = [1000.0]
    monkeypatch.setattr(rl.time, "time", lambda: t[0])
    limiter.check("203.0.113.7")
    t[0] += 61
    limiter.check("198.51.100.9")
    limiter.check("203.0.113.7")  # window expired: allowed again, old entries pruned
    assert limiter._attempts["203.0.113.7"] == [t[0]]
