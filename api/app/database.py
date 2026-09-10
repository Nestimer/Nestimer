import uuid
from datetime import datetime, timezone

from sqlalchemy import text, inspect
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase

from .config import settings

engine = create_async_engine(settings.database_url, echo=False)
async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def get_db():
    async with async_session() as session:
        yield session


async def _get_columns(conn, table: str) -> set[str]:
    """Get column names for a table (works with both SQLite and PostgreSQL)."""
    def _inspect(sync_conn):
        insp = inspect(sync_conn)
        if insp.has_table(table):
            return {col["name"] for col in insp.get_columns(table)}
        return set()
    return await conn.run_sync(_inspect)


async def _add_column_if_missing(conn, table: str, column: str, col_type: str, columns: set[str]):
    """Add a column if it doesn't exist yet."""
    if column not in columns:
        await conn.execute(text(f'ALTER TABLE {table} ADD COLUMN {column} {col_type}'))


async def _backfill_children(conn):
    """Give every device without a child its own child (strictly 1:1).

    Merging devices under one child is an explicit parent action in the UI —
    guessing it here from a matching child_name would silently halve the
    effective daily limit for real users. Idempotent: init_db runs on every boot.
    """
    rows = (await conn.execute(text(
        "SELECT id, owner_id, child_name, bonus_until FROM devices WHERE child_id IS NULL"
    ))).fetchall()

    for dev_id, owner_id, child_name, bonus_until in rows:
        child_id = str(uuid.uuid4())
        await conn.execute(
            text(
                "INSERT INTO children (id, owner_id, name, bonus_until, created_at) "
                "VALUES (:id, :owner_id, :name, :bonus_until, :created_at)"
            ),
            {
                "id": child_id,
                "owner_id": owner_id,
                "name": child_name or "Child",
                "bonus_until": bonus_until,
                "created_at": datetime.now(timezone.utc),
            },
        )
        for stmt in (
            "UPDATE devices SET child_id = :child_id WHERE id = :dev_id",
            "UPDATE policies SET child_id = :child_id WHERE device_id = :dev_id",
            "UPDATE activities SET child_id = :child_id WHERE device_id = :dev_id",
        ):
            await conn.execute(text(stmt), {"child_id": child_id, "dev_id": dev_id})


async def init_db():
    async with engine.begin() as conn:
        # init_db() runs once per uvicorn worker (FastAPI lifespan, --workers 4 in the
        # Dockerfile), so every migration below would otherwise run four times
        # concurrently against the same database. Serialize them. The _xact_ variant
        # releases automatically when this transaction ends, including on crash.
        if conn.dialect.name == "postgresql":
            await conn.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": 8274613905})

        await conn.run_sync(Base.metadata.create_all)

        # --- Migrations for existing databases ---

        # devices table
        dev_cols = await _get_columns(conn, "devices")
        await _add_column_if_missing(conn, "devices", "shared_secret", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "agent_version", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "bonus_until", "TIMESTAMP WITH TIME ZONE", dev_cols)

        # policies table — per-day screen time limits
        pol_cols = await _get_columns(conn, "policies")
        for day in ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]:
            await _add_column_if_missing(conn, "policies", f"screen_time_{day}_minutes", "INTEGER", pol_cols)

        # children / shared-budget migration (see docs/superpowers/specs/2026-09-09-cross-platform-shared-budget-design.md)
        await _add_column_if_missing(conn, "devices", "child_id", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "platform", "TEXT", dev_cols)
        await _add_column_if_missing(conn, "devices", "daily_cap_minutes", "INTEGER", dev_cols)
        await _add_column_if_missing(conn, "policies", "child_id", "TEXT", pol_cols)

        act_cols = await _get_columns(conn, "activities")
        await _add_column_if_missing(conn, "activities", "child_id", "TEXT", act_cols)

        # Existing rows predate `platform`; they are all Macs.
        await conn.execute(text("UPDATE devices SET platform = 'macos' WHERE platform IS NULL"))

        # Policies and activities may now belong to a child instead of a device.
        # SQLite cannot drop NOT NULL, but its test databases are created fresh
        # from the models, where these columns are already nullable.
        if conn.dialect.name == "postgresql":
            await conn.execute(text("ALTER TABLE policies ALTER COLUMN device_id DROP NOT NULL"))
            await conn.execute(text("ALTER TABLE activities ALTER COLUMN device_id DROP NOT NULL"))
            await conn.execute(text(
                "CREATE UNIQUE INDEX IF NOT EXISTS uq_policies_child_id ON policies (child_id)"
            ))
            await conn.execute(text(
                "CREATE INDEX IF NOT EXISTS ix_devices_child_id ON devices (child_id)"
            ))

        await _backfill_children(conn)
