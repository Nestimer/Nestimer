from sqlalchemy import text
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


async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # Migrate: add shared_secret column if missing (for DBs created before TOTP feature)
        result = await conn.execute(text("PRAGMA table_info(devices)"))
        columns = [row[1] for row in result.fetchall()]
        if "shared_secret" not in columns:
            await conn.execute(text("ALTER TABLE devices ADD COLUMN shared_secret TEXT"))

        # Per-day screen time limits
        result = await conn.execute(text("PRAGMA table_info(policies)"))
        policy_columns = {row[1] for row in result.fetchall()}
        for day in ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]:
            col = f"screen_time_{day}_minutes"
            if col not in policy_columns:
                await conn.execute(text(f"ALTER TABLE policies ADD COLUMN {col} INTEGER"))

        # activities table is created by metadata.create_all if missing — nothing to do
