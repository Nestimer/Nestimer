"""Parent-facing endpoints for managing children."""
from datetime import datetime, timedelta, timezone
from typing import List

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select, update, func
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_current_user
from ..database import get_db
from ..models.models import Child, Device, Policy, User, UsageLog
from ..schemas import (
    ChildCreate, ChildOut, ChildUpdate, GrantBonusRequest, GrantBonusResponse,
    PolicyOut, PolicyUpdate, UsageOut,
)
from .devices import _resolve_policy, policy_to_out, parse_time

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


@router.get("/{child_id}/usage", response_model=List[UsageOut])
async def get_child_usage(
    child_id: str,
    days: int = 7,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Per-day totals across every device this child owns.

    Mirrors the aggregation `/agent/config` uses for the shared counter, so the number a
    parent sees and the number the agent enforces against cannot disagree.
    """
    child = await _verify_child_owner(db, child_id, user.id)

    result = await db.execute(
        select(UsageLog.date, func.sum(UsageLog.total_minutes))
        .select_from(UsageLog)
        .join(Device, Device.id == UsageLog.device_id)
        .where(Device.child_id == child.id)
        .group_by(UsageLog.date)
        .order_by(UsageLog.date.desc())
        .limit(days)
    )
    return [UsageOut(date=row[0], total_minutes=float(row[1])) for row in result.all()]


async def _child_policy(db: AsyncSession, child: Child) -> Policy | None:
    """The child's policy, reusing the device route's resolver so the two URLs cannot
    diverge. Tries each of the child's devices in turn so a legacy device-keyed row is
    still found and adopted, exactly as `/devices/{id}/policy` would.
    """
    result = await db.execute(select(Device.id).where(Device.child_id == child.id))
    for device_id in result.scalars().all():
        policy = await _resolve_policy(db, child.id, device_id)
        if policy is not None:
            return policy
    return None


@router.get("/{child_id}/policy", response_model=PolicyOut)
async def get_child_policy(
    child_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    policy = await _child_policy(db, child)
    if policy is None:
        raise HTTPException(status_code=404, detail="This child has no devices yet")
    await db.commit()  # _resolve_policy may have adopted a legacy row under the child
    return policy_to_out(policy)


@router.put("/{child_id}/policy", response_model=PolicyOut)
async def update_child_policy(
    child_id: str,
    data: PolicyUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Never creates a Policy row. A child with no devices has no policy, and a row with
    `device_id` NULL would leave a later-attaching device without one -- see the long
    comment in `create_child`.
    """
    child = await _verify_child_owner(db, child_id, user.id)
    policy = await _child_policy(db, child)
    if policy is None:
        raise HTTPException(status_code=404, detail="This child has no devices yet")

    time_fields = {
        "downtime_start", "downtime_end",
        "downtime_weekday_start", "downtime_weekday_end",
        "downtime_weekend_start", "downtime_weekend_end",
    }
    for field_name in data.model_fields_set:
        value = getattr(data, field_name)
        if field_name in time_fields:
            value = parse_time(value) if value is not None else None
        setattr(policy, field_name, value)

    await db.commit()
    await db.refresh(policy)
    return policy_to_out(policy)


@router.post("/{child_id}/grant-bonus", response_model=GrantBonusResponse)
async def grant_child_bonus(
    child_id: str,
    data: GrantBonusRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Bonus is inherently shared: `bonus_until` lives on the child, so the window
    applies to every device that child owns. Calling again replaces the window rather
    than extending it, matching `/devices/{id}/grant-bonus`.
    """
    child = await _verify_child_owner(db, child_id, user.id)
    child.bonus_until = datetime.now(timezone.utc) + timedelta(minutes=data.minutes)
    await db.commit()
    return GrantBonusResponse(bonus_until=child.bonus_until)
