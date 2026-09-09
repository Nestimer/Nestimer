import pytest
from sqlalchemy import inspect

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
