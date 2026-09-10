import asyncio
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker

from app.database import Base, get_db
from app.main import app

# In-memory SQLite for tests
TEST_DB_URL = "sqlite+aiosqlite:///:memory:"


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


@pytest.fixture()
async def db_session():
    engine = create_async_engine(TEST_DB_URL, echo=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    async with session_factory() as session:
        yield session

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


@pytest.fixture()
async def client(db_session):
    """AsyncClient wired to a fresh in-memory database."""
    engine = create_async_engine(TEST_DB_URL, echo=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    async def override_get_db():
        async with session_factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_get_db

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac

    app.dependency_overrides.clear()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


# --- Helper functions ---

async def register_user(client: AsyncClient, email="parent@test.com", password="test1234", name="Test Parent"):
    resp = await client.post("/api/v1/auth/register", json={
        "email": email, "password": password, "name": name
    })
    assert resp.status_code == 200
    return resp.json()["access_token"]


async def create_device(client: AsyncClient, token: str, name="MacBook Test", child_name="Alex"):
    resp = await client.post(
        "/api/v1/devices",
        json={"name": name, "child_name": child_name},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    return resp.json()


async def simulate_elapsed_time(minutes: float) -> None:
    """Backdate every usage row's `last_updated`, as if that many minutes had passed.

    `POST /agent/usage` clamps a report to what the device could actually have
    accumulated since its previous report (see `USAGE_REPORT_SLACK_MINUTES`): a counter
    only grows with wall-clock time. A test that reports "30 minutes in" and then
    "60 minutes in" milliseconds later is describing a jump no honest agent can make, so
    it has to move the row's clock the way it claims the clock moved. This is the same
    path a device that was off or offline for an hour takes when it comes back and
    reports its catch-up total.
    """
    from datetime import datetime, timedelta, timezone

    from sqlalchemy import text

    override = app.dependency_overrides[get_db]
    gen = override()
    session = await gen.__anext__()
    try:
        conn = await session.connection()
        await conn.execute(
            text("UPDATE usage_logs SET last_updated = :ts"),
            {"ts": datetime.now(timezone.utc) - timedelta(minutes=minutes)},
        )
        await session.commit()
    finally:
        await gen.aclose()
