"""Parent-facing endpoints for managing children."""
from typing import List

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_current_user
from ..database import get_db
from ..models.models import Child, Device, Policy, User
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
    db.add(Policy(child_id=child.id))  # default policy, same defaults as a new device
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
