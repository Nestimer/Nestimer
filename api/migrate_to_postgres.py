#!/usr/bin/env python3
"""Migrate data from SQLite to PostgreSQL.

Usage (inside the api container):
    python migrate_to_postgres.py /app/data/usagetime.db

Reads all tables from SQLite and inserts into the PostgreSQL DB
configured via DATABASE_URL env var.
"""
import asyncio
import sqlite3
import sys

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from app.config import settings
from app.database import Base


TABLES = ["users", "devices", "policies", "usage_logs", "activities"]


async def migrate(sqlite_path: str):
    # Source: SQLite
    src = sqlite3.connect(sqlite_path)
    src.row_factory = sqlite3.Row

    # Dest: PostgreSQL
    engine = create_async_engine(settings.database_url, echo=False)

    # Create tables
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    for table in TABLES:
        try:
            rows = src.execute(f"SELECT * FROM {table}").fetchall()
        except sqlite3.OperationalError:
            print(f"  {table}: table not found in SQLite, skipping")
            continue

        if not rows:
            print(f"  {table}: empty, skipping")
            continue

        columns = rows[0].keys()
        col_list = ", ".join(columns)
        placeholders = ", ".join(f":{c}" for c in columns)

        async with engine.begin() as conn:
            # Clear existing data to avoid conflicts
            await conn.execute(text(f"DELETE FROM {table}"))
            for row in rows:
                values = {c: row[c] for c in columns}
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
