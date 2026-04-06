import secrets
from datetime import time
from typing import List

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from ..auth import get_current_user, create_agent_token
from ..database import get_db
from ..models.models import User, Device, Policy, UsageLog, Activity
from ..schemas import (
    DeviceCreate, DeviceOut, DeviceListOut,
    PolicyUpdate, PolicyOut,
    UsageOut,
    ActivityCreate, ActivityUpdate, ActivityOut,
)

router = APIRouter(prefix="/devices", tags=["devices"])


def parse_time(s: str) -> time:
    parts = s.split(":")
    if len(parts) != 2:
        raise ValueError(f"Invalid time format: {s}")
    h, m = int(parts[0]), int(parts[1])
    if not (0 <= h <= 23 and 0 <= m <= 59):
        raise ValueError(f"Time out of range: {s}")
    return time(h, m)


def format_time(t: time | None) -> str | None:
    if t is None:
        return None
    return t.strftime("%H:%M")


DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


def policy_to_out(policy: Policy) -> PolicyOut:
    return PolicyOut(
        downtime_enabled=policy.downtime_enabled,
        downtime_start=format_time(policy.downtime_start),
        downtime_end=format_time(policy.downtime_end),
        downtime_weekday_start=format_time(policy.downtime_weekday_start),
        downtime_weekday_end=format_time(policy.downtime_weekday_end),
        downtime_weekend_start=format_time(policy.downtime_weekend_start),
        downtime_weekend_end=format_time(policy.downtime_weekend_end),
        screen_time_enabled=policy.screen_time_enabled,
        screen_time_limit_minutes=policy.screen_time_limit_minutes,
        screen_time_weekend_limit_minutes=policy.screen_time_weekend_limit_minutes,
        screen_time_mon_minutes=policy.screen_time_mon_minutes,
        screen_time_tue_minutes=policy.screen_time_tue_minutes,
        screen_time_wed_minutes=policy.screen_time_wed_minutes,
        screen_time_thu_minutes=policy.screen_time_thu_minutes,
        screen_time_fri_minutes=policy.screen_time_fri_minutes,
        screen_time_sat_minutes=policy.screen_time_sat_minutes,
        screen_time_sun_minutes=policy.screen_time_sun_minutes,
    )


@router.post("", response_model=DeviceOut)
async def create_device(
    data: DeviceCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    device = Device(
        owner_id=user.id,
        name=data.name,
        child_name=data.child_name,
        api_token="placeholder",
        shared_secret=secrets.token_hex(20),
    )
    db.add(device)
    await db.flush()

    # Generate a real agent token
    device.api_token = create_agent_token(device.id)

    # Create default policy
    policy = Policy(device_id=device.id)
    db.add(policy)

    await db.commit()
    await db.refresh(device)
    return DeviceOut(
        id=device.id,
        name=device.name,
        child_name=device.child_name,
        api_token=device.api_token,
        shared_secret=device.shared_secret,
        agent_version=device.agent_version,
        last_seen=device.last_seen,
        created_at=device.created_at,
    )


@router.get("", response_model=List[DeviceListOut])
async def list_devices(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Device).where(Device.owner_id == user.id)
    )
    devices = result.scalars().all()
    return [
        DeviceListOut(
            id=d.id, name=d.name, child_name=d.child_name, agent_version=d.agent_version, last_seen=d.last_seen
        )
        for d in devices
    ]


@router.get("/{device_id}", response_model=DeviceOut)
async def get_device(
    device_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Device).where(Device.id == device_id, Device.owner_id == user.id)
    )
    device = result.scalar_one_or_none()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")
    return DeviceOut(
        id=device.id,
        name=device.name,
        child_name=device.child_name,
        api_token=device.api_token,
        shared_secret=device.shared_secret,
        agent_version=device.agent_version,
        last_seen=device.last_seen,
        created_at=device.created_at,
    )


@router.delete("/{device_id}")
async def delete_device(
    device_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Device).where(Device.id == device_id, Device.owner_id == user.id)
    )
    device = result.scalar_one_or_none()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")
    await db.delete(device)
    await db.commit()
    return {"ok": True}


# --- Policy ---
@router.get("/{device_id}/policy", response_model=PolicyOut)
async def get_policy(
    device_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Device).where(Device.id == device_id, Device.owner_id == user.id)
    )
    device = result.scalar_one_or_none()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    result = await db.execute(select(Policy).where(Policy.device_id == device_id))
    policy = result.scalar_one_or_none()
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")

    return policy_to_out(policy)


@router.put("/{device_id}/policy", response_model=PolicyOut)
async def update_policy(
    device_id: str,
    data: PolicyUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Device).where(Device.id == device_id, Device.owner_id == user.id)
    )
    device = result.scalar_one_or_none()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    result = await db.execute(select(Policy).where(Policy.device_id == device_id))
    policy = result.scalar_one_or_none()
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")

    if data.downtime_enabled is not None:
        policy.downtime_enabled = data.downtime_enabled
    if data.downtime_start is not None:
        policy.downtime_start = parse_time(data.downtime_start)
    if data.downtime_end is not None:
        policy.downtime_end = parse_time(data.downtime_end)
    if data.downtime_weekday_start is not None:
        policy.downtime_weekday_start = parse_time(data.downtime_weekday_start)
    if data.downtime_weekday_end is not None:
        policy.downtime_weekday_end = parse_time(data.downtime_weekday_end)
    if data.downtime_weekend_start is not None:
        policy.downtime_weekend_start = parse_time(data.downtime_weekend_start)
    if data.downtime_weekend_end is not None:
        policy.downtime_weekend_end = parse_time(data.downtime_weekend_end)
    if data.screen_time_enabled is not None:
        policy.screen_time_enabled = data.screen_time_enabled
    if data.screen_time_limit_minutes is not None:
        policy.screen_time_limit_minutes = data.screen_time_limit_minutes
    if data.screen_time_weekend_limit_minutes is not None:
        policy.screen_time_weekend_limit_minutes = data.screen_time_weekend_limit_minutes
    for day in DAYS:
        field = f"screen_time_{day}_minutes"
        value = getattr(data, field)
        if value is not None:
            setattr(policy, field, value)

    await db.commit()
    await db.refresh(policy)

    return policy_to_out(policy)


# --- Usage logs ---
@router.get("/{device_id}/usage", response_model=List[UsageOut])
async def get_usage(
    device_id: str,
    days: int = 7,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Device).where(Device.id == device_id, Device.owner_id == user.id)
    )
    if not result.scalar_one_or_none():
        raise HTTPException(status_code=404, detail="Device not found")

    result = await db.execute(
        select(UsageLog)
        .where(UsageLog.device_id == device_id)
        .order_by(UsageLog.date.desc())
        .limit(days)
    )
    logs = result.scalars().all()
    return [UsageOut(date=l.date, total_minutes=l.total_minutes) for l in logs]


@router.post("/{device_id}/regenerate-secret", response_model=DeviceOut)
async def regenerate_secret(
    device_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Generate a new TOTP shared secret for an existing device."""
    result = await db.execute(
        select(Device).where(Device.id == device_id, Device.owner_id == user.id)
    )
    device = result.scalar_one_or_none()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    device.shared_secret = secrets.token_hex(20)
    await db.commit()
    await db.refresh(device)

    return DeviceOut(
        id=device.id,
        name=device.name,
        child_name=device.child_name,
        api_token=device.api_token,
        shared_secret=device.shared_secret,
        agent_version=device.agent_version,
        last_seen=device.last_seen,
        created_at=device.created_at,
    )


# --- Activities ---
def activity_to_out(a: Activity) -> ActivityOut:
    return ActivityOut(
        id=a.id,
        name=a.name,
        day_of_week=a.day_of_week,
        start_time=format_time(a.start_time),
        end_time=format_time(a.end_time),
        buffer_before_minutes=a.buffer_before_minutes,
        buffer_after_minutes=a.buffer_after_minutes,
        enabled=a.enabled,
    )


async def _verify_device_owner(db: AsyncSession, device_id: str, user_id: str) -> Device:
    result = await db.execute(
        select(Device).where(Device.id == device_id, Device.owner_id == user_id)
    )
    device = result.scalar_one_or_none()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")
    return device


@router.get("/{device_id}/activities", response_model=List[ActivityOut])
async def list_activities(
    device_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _verify_device_owner(db, device_id, user.id)
    result = await db.execute(
        select(Activity).where(Activity.device_id == device_id).order_by(Activity.day_of_week, Activity.start_time)
    )
    return [activity_to_out(a) for a in result.scalars().all()]


@router.post("/{device_id}/activities", response_model=ActivityOut)
async def create_activity(
    device_id: str,
    data: ActivityCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _verify_device_owner(db, device_id, user.id)
    activity = Activity(
        device_id=device_id,
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


@router.put("/{device_id}/activities/{activity_id}", response_model=ActivityOut)
async def update_activity(
    device_id: str,
    activity_id: str,
    data: ActivityUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _verify_device_owner(db, device_id, user.id)
    result = await db.execute(
        select(Activity).where(Activity.id == activity_id, Activity.device_id == device_id)
    )
    activity = result.scalar_one_or_none()
    if not activity:
        raise HTTPException(status_code=404, detail="Activity not found")

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


@router.delete("/{device_id}/activities/{activity_id}")
async def delete_activity(
    device_id: str,
    activity_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _verify_device_owner(db, device_id, user.id)
    result = await db.execute(
        select(Activity).where(Activity.id == activity_id, Activity.device_id == device_id)
    )
    activity = result.scalar_one_or_none()
    if not activity:
        raise HTTPException(status_code=404, detail="Activity not found")
    await db.delete(activity)
    await db.commit()
    return {"ok": True}
