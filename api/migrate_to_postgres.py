#!/usr/bin/env python3
"""Migrate data from SQLite to PostgreSQL.

Usage (inside the api container):
    python migrate_to_postgres.py /app/data/usagetime.db
"""
import asyncio
import sqlite3
import sys
from datetime import datetime, time, timezone

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from app.config import settings
from app.database import Base


TABLES = ["users", "devices", "policies", "usage_logs", "activities"]

# Columns that store datetime values (as strings in SQLite)
DATETIME_COLUMNS = {"created_at", "last_seen", "updated_at", "last_updated"}
TIME_COLUMNS = {
    "downtime_start", "downtime_end",
    "downtime_weekday_start", "downtime_weekday_end",
    "downtime_weekend_start", "downtime_weekend_end",
    "start_time", "end_time",
}


def convert_value(col_name: str, value):
    """Convert SQLite string values to proper Python types for PostgreSQL."""
    if value is None:
        return None

    if col_name in DATETIME_COLUMNS and isinstance(value, str):
        # Try various datetime formats
        for fmt in (
            "%Y-%m-%d %H:%M:%S.%f",
            "%Y-%m-%d %H:%M:%S.%f+00:00",
            "%Y-%m-%dT%H:%M:%S.%f",
            "%Y-%m-%dT%H:%M:%S.%f+00:00",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%dT%H:%M:%S",
        ):
            try:
                dt = datetime.strptime(value, fmt)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return dt
            except ValueError:
                continue
        print(f"    WARNING: could not parse datetime '{value}' for column {col_name}")
        return None

    if col_name in TIME_COLUMNS and isinstance(value, str):
        try:
            parts = value.split(":")
            return time(int(parts[0]), int(parts[1]))
        except (ValueError, IndexError):
            print(f"    WARNING: could not parse time '{value}' for column {col_name}")
            return None

    return value


async def migrate(sqlite_path: str):
    src = sqlite3.connect(sqlite_path)
    src.row_factory = sqlite3.Row

    engine = create_async_engine(settings.database_url, echo=False)

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    for table in TABLES:
        try:
            rows = src.execute(f"SELECT * FROM {table}").fetchall()
        except sqlite3.OperationalError:
            print(f"  {table}: not found in SQLite, skipping")
            continue

        if not rows:
            print(f"  {table}: empty, skipping")
            continue

        columns = rows[0].keys()
        col_list = ", ".join(columns)
        placeholders = ", ".join(f":{c}" for c in columns)

        async with engine.begin() as conn:
            await conn.execute(text(f"DELETE FROM {table}"))
            for row in rows:
                values = {c: convert_value(c, row[c]) for c in columns}
                await conn.execute(
                    text(f"INSERT INTO {table} ({col_list}) VALUES ({placeholders})"),
                    values,
                )

        print(f"  {table}: {len(rows)} rows migrated")

    src.close()
    await engine.dispose()
    print("\nMigration complete!")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python migrate_to_postgres.py <sqlite-db-path>")
        sys.exit(1)
    asyncio.run(migrate(sys.argv[1]))
