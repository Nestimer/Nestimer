import pytest
from .conftest import register_user

pytestmark = pytest.mark.anyio


async def test_register(client):
    resp = await client.post("/api/v1/auth/register", json={
        "email": "test@example.com",
        "password": "password123",
        "name": "Test User",
    })
    assert resp.status_code == 200
    data = resp.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"


async def test_register_duplicate_email(client):
    await register_user(client, email="dup@test.com")

    resp = await client.post("/api/v1/auth/register", json={
        "email": "dup@test.com",
        "password": "password123",
        "name": "Another User",
    })
    assert resp.status_code == 400
    assert "already registered" in resp.json()["detail"]


async def test_login_success(client):
    await register_user(client, email="login@test.com", password="mypass")

    resp = await client.post("/api/v1/auth/login", json={
        "email": "login@test.com",
        "password": "mypass",
    })
    assert resp.status_code == 200
    assert "access_token" in resp.json()


async def test_login_wrong_password(client):
    await register_user(client, email="wrong@test.com", password="correct")

    resp = await client.post("/api/v1/auth/login", json={
        "email": "wrong@test.com",
        "password": "incorrect",
    })
    assert resp.status_code == 401


async def test_login_nonexistent_user(client):
    resp = await client.post("/api/v1/auth/login", json={
        "email": "nobody@test.com",
        "password": "password",
    })
    assert resp.status_code == 401


async def test_me(client):
    token = await register_user(client, email="me@test.com", name="My Name")

    resp = await client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    data = resp.json()
    assert data["email"] == "me@test.com"
    assert data["name"] == "My Name"


async def test_me_invalid_token(client):
    resp = await client.get("/api/v1/auth/me", headers={"Authorization": "Bearer invalid"})
    assert resp.status_code == 401
