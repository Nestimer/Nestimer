"""Parent-facing endpoints for managing children."""
from datetime import datetime, timedelta, timezone
from typing import List

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select, update, func, or_
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_current_user
from ..database import get_db
from ..models.models import Activity, Child, Device, Policy, User, UsageLog
from ..schemas import (
    ActivityCreate, ActivityOut, ActivityUpdate,
    ChildCreate, ChildOut, ChildUpdate, GrantBonusRequest, GrantBonusResponse,
    PolicyOut, PolicyUpdate, UsageOut,
)
from .devices import _reject_null_policy_fields, _resolve_policy, activity_to_out, policy_to_out, parse_time

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
    days: int = Query(7, ge=1, le=365),
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

    Ordered by created_at, id: without a deterministic order, this loop and
    `/devices/{id}/policy` can pick different devices -- and therefore different
    policies -- for the same child, and each is a write-on-read (adoption), so whichever
    lands first permanently decides what the whole child inherits. PostgreSQL heap order
    can also shift after an UPDATE or VACUUM, so an unordered query could even pick
    differently on different days for the very same request.
    """
    result = await db.execute(
        select(Device.id).where(Device.child_id == child.id)
        .order_by(Device.created_at, Device.id)
    )
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

    _reject_null_policy_fields(data)

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


@router.get("/{child_id}/activities", response_model=List[ActivityOut])
async def list_child_activities(
    child_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)

    result = await db.execute(select(Device.id).where(Device.child_id == child.id))
    device_ids = list(result.scalars().all())

    # Union the child-keyed rows with rows keyed to any of this child's devices, rather
    # than filtering on child_id alone -- mirrors `/devices/{id}/activities` (see its
    # comment). A device-keyed row that has not been adopted under the child yet ("still
    # enforced by the agent, but no longer visible or deletable here") must not become
    # invisible on the route that is about to be the primary UI. De-duplicate by id since
    # a row that already carries both keys would otherwise match both halves of the OR.
    result = await db.execute(
        select(Activity)
        .where(or_(Activity.child_id == child.id, Activity.device_id.in_(device_ids)))
        .order_by(Activity.day_of_week, Activity.start_time)
    )
    seen = set()
    activities = []
    for a in result.scalars().all():
        if a.id not in seen:
            seen.add(a.id)
            activities.append(a)
    return [activity_to_out(a) for a in activities]


@router.post("/{child_id}/activities", response_model=ActivityOut)
async def create_child_activity(
    child_id: str,
    data: ActivityCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)

    # Stamp a device id as well as the child id. An API rolled back to pre-child code
    # reads activities by device_id alone; a row with device_id NULL would be invisible
    # to it and the scheduled activity would silently stop suppressing the lock. A
    # device-less child has nothing to stamp it with -- and nothing ever adopts an
    # unstamped row later (create_device re-adopts device_id-NULL Policy rows, but has
    # no equivalent for Activity), so this would be a permanent gap, not a transient
    # one. 404, matching `PUT /children/{id}/policy`; the designed UI already shows
    # "Add a device to set limits" for a device-less child and never offers this action.
    result = await db.execute(
        select(Device.id).where(Device.child_id == child.id)
        .order_by(Device.created_at, Device.id)
        .limit(1)
    )
    device_id = result.scalar_one_or_none()
    if device_id is None:
        raise HTTPException(status_code=404, detail="This child has no devices yet")

    activity = Activity(
        device_id=device_id,
        child_id=child.id,
        name=data.name,
        day_of_week=data.day_of_week,
        start_time=parse_time(data.start_time),
        end_time=parse_time(data.end_time),
        buffer_before_minutes=data.buffer_before_minutes,
        buffer_after_minutes=data.buffer_after_minutes,
        enabled=data.enabled,
    )
    db.add(activity)
    await db.commit()
    await db.refresh(activity)
    return activity_to_out(activity)


async def _child_activity(db: AsyncSession, child: Child, activity_id: str) -> Activity:
    """Find one activity by id, scoped to the child first and falling back to (and
    adopting under the child) a pre-existing device-keyed row belonging to one of this
    child's devices -- same non-exclusive fallback shape as devices.py's
    `_resolve_activity`, generalised from a single device_id to the child's whole device
    set. Without this, a legacy row (device_id set, child_id NULL) that `list_child_
    activities`'s union now surfaces would be listed but not editable or deletable here,
    even though `/devices/{id}/activities` can already reach and adopt it.
    """
    result = await db.execute(
        select(Activity).where(Activity.id == activity_id, Activity.child_id == child.id)
    )
    activity = result.scalar_one_or_none()
    if activity is None:
        result = await db.execute(select(Device.id).where(Device.child_id == child.id))
        device_ids = list(result.scalars().all())
        result = await db.execute(
            select(Activity).where(
                Activity.id == activity_id, Activity.device_id.in_(device_ids)
            )
        )
        activity = result.scalar_one_or_none()
        if activity is not None:
            activity.child_id = child.id
    if not activity:
        raise HTTPException(status_code=404, detail="Activity not found")
    return activity


@router.put("/{child_id}/activities/{activity_id}", response_model=ActivityOut)
async def update_child_activity(
    child_id: str,
    activity_id: str,
    data: ActivityUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    activity = await _child_activity(db, child, activity_id)

    # Every Activity column is NOT NULL (unlike Policy's genuinely optional overrides),
    # so this must use `is not None` guards rather than `model_fields_set`, mirroring
    # `/devices/{id}/activities`'s `update_activity` -- there is no "clear it" meaning
    # for an explicit null on any of these fields, and writing one either 500s
    # immediately (IntegrityError) or commits a NULL that silently stops the activity
    # from suppressing the lock (`enabled`) and then 500s every future read of it.
    if data.name is not None:
        activity.name = data.name
    if data.day_of_week is not None:
        activity.day_of_week = data.day_of_week
    if data.start_time is not None:
        activity.start_time = parse_time(data.start_time)
    if data.end_time is not None:
        activity.end_time = parse_time(data.end_time)
    if data.buffer_before_minutes is not None:
        activity.buffer_before_minutes = data.buffer_before_minutes
    if data.buffer_after_minutes is not None:
        activity.buffer_after_minutes = data.buffer_after_minutes
    if data.enabled is not None:
        activity.enabled = data.enabled

    await db.commit()
    await db.refresh(activity)
    return activity_to_out(activity)


@router.delete("/{child_id}/activities/{activity_id}")
async def delete_child_activity(
    child_id: str,
    activity_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await _verify_child_owner(db, child_id, user.id)
    # `_child_activity` may adopt a legacy device-keyed row by setting `child_id` on it;
    # that pending change and the delete below are flushed together by this one commit,
    # so the adoption is never left unpersisted even though the row is about to go away.
    activity = await _child_activity(db, child, activity_id)
    await db.delete(activity)
    await db.commit()
    return {"ok": True}
