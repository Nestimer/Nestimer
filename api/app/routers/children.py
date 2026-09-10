"""Parent-facing endpoints for managing children."""
from typing import List

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_current_user
from ..database import get_db
from ..models.models import Child, Device, User
from ..schemas import ChildCreate, ChildOut, ChildUpdate

router = APIRouter(prefix="/children", tags=["children"])


async def _verify_child_owner(db: AsyncSession, child_id: str, user_id: str) -> Child:
    result = await db.execute(
        select(Child).where(Child.id == child_id, Child.owner_id == user_id)
    )
    child = result.scalar_one_or_none()
    if not child:
        raise HTTPException(status_code=404, detail="Child not found")
    return child


async def _to_out(db: AsyncSession, child: Child) -> ChildOut:
    result = await db.execute(select(Device.id).where(Device.child_id == child.id))
    return ChildOut(
        id=child.id,
        name=child.name,
        bonus_until=child.bonus_until,
        created_at=child.created_at,
        device_ids=list(result.scalars().all()),
    )


@router.post("", response_model=ChildOut)
async def create_child(
    data: ChildCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = Child(owner_id=user.id, name=data.name)
    db.add(child)
    await db.flush()
    # Deliberately NO default policy row here. A child with no devices has nothing to
    # enforce a policy on and no UI that reads one (policies are edited per device, via
    # /devices/{id}/policy), so the row would buy nothing — while a `Policy(child_id=...)`
    # with `device_id` left NULL is actively dangerous: `POST /devices` skips creating a
    # policy when the child already has one, so the device that attaches later would never
    # get its `device_id` stamped on any policy row. Roll the API back with the database
    # still migrated and the old, device-keyed lookup finds nothing, takes its "no policy"
    # branch (screen_time_enabled=False, downtime_enabled=False) and the child's Mac stops
    # locking altogether. `POST /devices` creates the policy — with `device_id` set — when
    # the first device attaches.
    await db.commit()
    return await _to_out(db, child)


@router.get("", response_model=List[ChildOut])
async def list_children(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(Child).where(Child.owner_id == user.id))
    return [await _to_out(db, c) for c in result.scalars().all()]


@router.patch("/{child_id}", response_model=ChildOut)
async def update_child(
    child_id: str,
    data: ChildUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    if data.name is not None:
        child.name = data.name
        # `Device.child_name` is a denormalised copy of this name, and it is what the web
        # dashboard's device cards and the iOS parent app (which we cannot update in
        # lockstep) display. Without this the group heading renames and every device card
        # underneath it keeps showing the old name.
        await db.execute(
            update(Device)
            .where(Device.child_id == child.id)
            .values(child_name=data.name)
        )
    await db.commit()
    await db.refresh(child)
    return await _to_out(db, child)


@router.delete("/{child_id}")
async def delete_child(
    child_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    result = await db.execute(select(Device.id).where(Device.child_id == child.id))
    if result.scalars().first():
        raise HTTPException(
            status_code=400,
            detail="Move or delete this child's devices first",
        )
    await db.delete(child)
    await db.commit()
    return {"ok": True}
