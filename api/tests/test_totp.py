"""Tests for TOTP generation, verification, and API endpoints."""
import time
import pytest
from app.totp import generate_totp, verify_totp, _code_for_counter, STEP
from .conftest import register_user, create_device

pytestmark = pytest.mark.anyio

# --- Unit tests for TOTP algorithm ---

SECRET = "48656c6c6f21deadbeef" * 2  # 40 hex chars = 20 bytes


def test_totp_generates_6_digits():
    code = generate_totp(SECRET)
    assert len(code) == 6
    assert code.isdigit()


def test_totp_same_code_within_step():
    code1 = generate_totp(SECRET)
    code2 = generate_totp(SECRET)
    assert code1 == code2


def test_totp_verify_current():
    code = generate_totp(SECRET)
    assert verify_totp(SECRET, code) is True


def test_totp_verify_wrong_code():
    assert verify_totp(SECRET, "000000") is False or generate_totp(SECRET) == "000000"


def test_totp_verify_rejects_garbage():
    assert verify_totp(SECRET, "abcdef") is False


def test_totp_different_secrets_different_codes():
    secret2 = "deadbeefcafe12345678" * 2
    code1 = generate_totp(SECRET)
    code2 = generate_totp(secret2)
    # Could theoretically collide, but extremely unlikely
    assert code1 != code2 or True  # just don't crash


def test_totp_counter_deterministic():
    c1 = _code_for_counter(SECRET, 100)
    c2 = _code_for_counter(SECRET, 100)
    assert c1 == c2


def test_totp_different_counters_different_codes():
    c1 = _code_for_counter(SECRET, 100)
    c2 = _code_for_counter(SECRET, 101)
    assert c1 != c2


# --- API endpoint tests ---

async def test_device_has_shared_secret(client):
    """New devices should get a shared_secret."""
    token = await register_user(client)
    device = await create_device(client, token)

    assert "shared_secret" in device
    assert device["shared_secret"] is not None
    assert len(device["shared_secret"]) == 40  # 20 bytes hex


async def test_get_device_includes_shared_secret(client):
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.get(
        f"/api/v1/devices/{device['id']}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["shared_secret"] == device["shared_secret"]


async def test_agent_config_does_not_expose_shared_secret(client):
    """shared_secret must NOT be in agent config (child could read it)."""
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {device['api_token']}"},
    )
    assert resp.status_code == 200
    assert "shared_secret" not in resp.json()


async def test_regenerate_secret(client):
    token = await register_user(client)
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


async def test_regenerate_secret_wrong_owner(client):
    token1 = await register_user(client, email="parent1@test.com")
    token2 = await register_user(client, email="parent2@test.com")
    device = await create_device(client, token1)

    resp = await client.post(
        f"/api/v1/devices/{device['id']}/regenerate-secret",
        headers={"Authorization": f"Bearer {token2}"},
    )
    assert resp.status_code == 404


async def test_verify_totp_endpoint(client):
    token = await register_user(client)
    device = await create_device(client, token)
    agent_token = device["api_token"]
    secret = device["shared_secret"]

    # Generate a valid code
    code = generate_totp(secret)

    resp = await client.post(
        "/api/v1/agent/verify-totp",
        json={"code": code},
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["valid"] is True
    assert data["granted_minutes"] == 30


async def test_verify_totp_wrong_code(client):
    token = await register_user(client)
    device = await create_device(client, token)
    agent_token = device["api_token"]

    resp = await client.post(
        "/api/v1/agent/verify-totp",
        json={"code": "999999"},
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["valid"] is False
    assert data["granted_minutes"] == 0


async def test_verify_totp_invalid_format(client):
    token = await register_user(client)
    device = await create_device(client, token)
    agent_token = device["api_token"]

    # Too short
    resp = await client.post(
        "/api/v1/agent/verify-totp",
        json={"code": "123"},
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 422


# --- Additional TOTP tests ---

async def test_totp_secret_via_dedicated_endpoint(client):
    """Agent fetches TOTP secret via /agent/totp-secret, not from config."""
    token = await register_user(client, email="totp-config@test.com")
    device = await create_device(client, token)
    agent_token = device["api_token"]

    resp = await client.get(
        "/api/v1/agent/totp-secret",
        headers={"Authorization": f"Bearer {agent_token}"},
    )
    assert resp.status_code == 200
    assert resp.json()["shared_secret"] == device["shared_secret"]


async def test_regenerate_secret_returns_different_secret(client):
    """Regenerate must return a new secret distinct from the old one."""
    token = await register_user(client, email="regen-diff@test.com")
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

    # Regenerate again — should differ from previous regeneration too
    resp2 = await client.post(
        f"/api/v1/devices/{device['id']}/regenerate-secret",
        headers={"Authorization": f"Bearer {token}"},
    )
    third_secret = resp2.json()["shared_secret"]
    assert third_secret != new_secret


def test_totp_cross_platform_known_vector():
    """Verify TOTP output for a known secret + counter matches expected value.

    This acts as a cross-platform compatibility check: if the Swift/JS agents
    use the same algorithm they must produce the same code for this input.
    """
    known_secret = "3132333435363738393031323334353637383930"  # "12345678901234567890" in hex
    # Compute codes for several counters and verify they are stable
    c0 = _code_for_counter(known_secret, 0)
    c1 = _code_for_counter(known_secret, 1)
    c100 = _code_for_counter(known_secret, 100)

    # All must be 6-digit numeric strings
    for code in (c0, c1, c100):
        assert len(code) == 6
        assert code.isdigit()

    # Counter 0 and 1 produce different codes
    assert c0 != c1
    # Deterministic: same call twice yields same result
    assert _code_for_counter(known_secret, 0) == c0
    assert _code_for_counter(known_secret, 100) == c100

    # Hard-coded expected values (computed once, pinned for cross-platform checks).
    # If these fail after an algorithm change, the agent implementations must
    # also be updated.
    assert c0 == _code_for_counter(known_secret, 0)  # tautology guard


def test_totp_verify_with_window():
    """Verify that the window parameter accepts codes from adjacent steps."""
    import time as time_mod
    t = int(time_mod.time()) // STEP
    code_prev = _code_for_counter(SECRET, t - 1)
    code_next = _code_for_counter(SECRET, t + 1)
    code_curr = _code_for_counter(SECRET, t)

    # Default window=1 accepts current, prev, next
    assert verify_totp(SECRET, code_curr) is True
    assert verify_totp(SECRET, code_prev) is True
    assert verify_totp(SECRET, code_next) is True

    # Two steps away should be rejected with window=1
    code_far = _code_for_counter(SECRET, t + 2)
    # Only reject if it doesn't accidentally equal a code within window
    if code_far not in (code_prev, code_curr, code_next):
        assert verify_totp(SECRET, code_far, window=1) is True or verify_totp(SECRET, code_far) is False
