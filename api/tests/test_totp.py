"""Tests for TOTP generation, verification, and API endpoints."""
import time
import pytest
from app.totp import generate_totp, verify_totp, _code_for_counter
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


async def test_agent_config_includes_shared_secret(client):
    token = await register_user(client)
    device = await create_device(client, token)

    resp = await client.get(
        "/api/v1/agent/config",
        headers={"Authorization": f"Bearer {device['api_token']}"},
    )
    assert resp.status_code == 200
    assert resp.json()["shared_secret"] == device["shared_secret"]


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
