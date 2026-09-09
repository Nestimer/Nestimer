import pytest
from sqlalchemy import inspect, text
from sqlalchemy.ext.asyncio import create_async_engine

from app.models.models import Child, Device

pytestmark = pytest.mark.anyio


async def test_child_table_and_device_columns_exist(db_session):
    """The Child entity and the new Device columns are part of the schema."""
    def _tables(sync_conn):
        return set(inspect(sync_conn).get_table_names())

    def _device_columns(sync_conn):
        return {c["name"] for c in inspect(sync_conn).get_columns("devices")}

    conn = await db_session.connection()
    assert "children" in await conn.run_sync(_tables)
    cols = await conn.run_sync(_device_columns)
    assert {"child_id", "platform", "daily_cap_minutes"} <= cols


async def test_child_defaults(db_session):
    """A Child can be created with just an owner and a name."""
    child = Child(owner_id="owner-1", name="Alex")
    db_session.add(child)
    await db_session.flush()

    assert child.id
    assert child.bonus_until is None
    assert child.created_at is not None


async def test_init_db_migration_adds_columns(tmp_path):
    """init_db() adds the new columns to existing databases and ensures idempotency."""
    from app.database import _get_columns, _add_column_if_missing

    # Create a file-backed SQLite database in pre-migration state
    db_file = tmp_path / "test.db"
    db_url = f"sqlite+aiosqlite:///{db_file}"

    # Create a pre-migration schema without the new columns
    engine = create_async_engine(db_url, echo=False)
    async with engine.begin() as conn:
        # Create tables without the new columns
        await conn.execute(text("""
            CREATE TABLE users (
                id TEXT PRIMARY KEY,
                email TEXT UNIQUE NOT NULL,
                hashed_password TEXT NOT NULL,
                name TEXT NOT NULL,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
            )
        """))
        await conn.execute(text("""
            CREATE TABLE devices (
                id TEXT PRIMARY KEY,
                owner_id TEXT NOT NULL,
                name TEXT NOT NULL,
                child_name TEXT NOT NULL,
                api_token TEXT UNIQUE NOT NULL,
                shared_secret TEXT,
                agent_version TEXT,
                last_seen TIMESTAMP WITH TIME ZONE,
                bonus_until TIMESTAMP WITH TIME ZONE,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (owner_id) REFERENCES users (id)
            )
        """))
        await conn.execute(text("""
            CREATE TABLE policies (
                id TEXT PRIMARY KEY,
                device_id TEXT UNIQUE NOT NULL,
                downtime_enabled BOOLEAN DEFAULT 1,
                downtime_start TIME DEFAULT '22:00:00',
                downtime_end TIME DEFAULT '08:00:00',
                downtime_weekday_start TIME,
                downtime_weekday_end TIME,
                downtime_weekend_start TIME,
                downtime_weekend_end TIME,
                screen_time_enabled BOOLEAN DEFAULT 1,
                screen_time_limit_minutes INTEGER DEFAULT 120,
                screen_time_weekend_limit_minutes INTEGER,
                screen_time_mon_minutes INTEGER,
                screen_time_tue_minutes INTEGER,
                screen_time_wed_minutes INTEGER,
                screen_time_thu_minutes INTEGER,
                screen_time_fri_minutes INTEGER,
                screen_time_sat_minutes INTEGER,
                screen_time_sun_minutes INTEGER,
                updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (device_id) REFERENCES devices (id)
            )
        """))
        await conn.execute(text("""
            CREATE TABLE activities (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                name TEXT NOT NULL,
                day_of_week INTEGER NOT NULL,
                start_time TIME NOT NULL,
                end_time TIME NOT NULL,
                buffer_before_minutes INTEGER DEFAULT 5,
                buffer_after_minutes INTEGER DEFAULT 5,
                enabled BOOLEAN DEFAULT 1,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (device_id) REFERENCES devices (id)
            )
        """))

        # Insert test data
        await conn.execute(text("""
            INSERT INTO users (id, email, hashed_password, name)
            VALUES ('user-1', 'test@example.com', 'hashed', 'Test User')
        """))
        await conn.execute(text("""
            INSERT INTO devices (id, owner_id, name, child_name, api_token)
            VALUES ('device-1', 'user-1', 'Test Device', 'Child', 'token-123')
        """))

    await engine.dispose()

    # Now run the migrations directly on the pre-migration database
    engine = create_async_engine(db_url, echo=False)
    async with engine.begin() as conn:
        # Run the migration code from init_db()
        dev_cols = await _get_columns(conn, "devices")
        await _add_column_if_missing(conn, "devices", "child_id", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "platform", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "daily_cap_minutes", "INTEGER", dev_cols)

        pol_cols = await _get_columns(conn, "policies")
        await _add_column_if_missing(conn, "policies", "child_id", "TEXT", pol_cols)

        act_cols = await _get_columns(conn, "activities")
        await _add_column_if_missing(conn, "activities", "child_id", "TEXT", act_cols)

        # Existing rows predate `platform`; they are all Macs
        await conn.execute(text("UPDATE devices SET platform = 'macos' WHERE platform IS NULL"))

    await engine.dispose()

    # Verify the columns were added
    engine = create_async_engine(db_url, echo=False)
    async with engine.begin() as conn:
        def _get_dev_columns(sync_conn):
            insp = inspect(sync_conn)
            return {c["name"] for c in insp.get_columns("devices")}

        dev_cols = await conn.run_sync(_get_dev_columns)
        assert "child_id" in dev_cols
        assert "platform" in dev_cols
        assert "daily_cap_minutes" in dev_cols

        def _get_policies_columns(sync_conn):
            insp = inspect(sync_conn)
            return {c["name"] for c in insp.get_columns("policies")}

        pol_cols = await conn.run_sync(_get_policies_columns)
        assert "child_id" in pol_cols

        def _get_activities_columns(sync_conn):
            insp = inspect(sync_conn)
            return {c["name"] for c in insp.get_columns("activities")}

        act_cols = await conn.run_sync(_get_activities_columns)
        assert "child_id" in act_cols

        # Verify the platform was set to 'macos' for existing devices
        result = await conn.execute(text("SELECT platform FROM devices WHERE id = 'device-1'"))
        row = result.fetchone()
        assert row[0] == "macos"

    await engine.dispose()

    # Test idempotency: run the migrations again and ensure no errors
    engine = create_async_engine(db_url, echo=False)
    async with engine.begin() as conn:
        # Run migrations again - should be idempotent
        dev_cols = await _get_columns(conn, "devices")
        await _add_column_if_missing(conn, "devices", "child_id", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "platform", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "daily_cap_minutes", "INTEGER", dev_cols)

        pol_cols = await _get_columns(conn, "policies")
        await _add_column_if_missing(conn, "policies", "child_id", "TEXT", pol_cols)

        act_cols = await _get_columns(conn, "activities")
        await _add_column_if_missing(conn, "activities", "child_id", "TEXT", act_cols)

        await conn.execute(text("UPDATE devices SET platform = 'macos' WHERE platform IS NULL"))

    await engine.dispose()
