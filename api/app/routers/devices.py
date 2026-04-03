import secrets
from datetime import time
from typing import List

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from ..auth import get_current_user, create_agent_token
from ..database import get_db
from ..models.models import User, Device, Policy, UsageLog
from ..schemas import (
    DeviceCreate, DeviceOut, DeviceListOut,
    PolicyUpdate, PolicyOut,
    UsageOut,
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
            id=d.id, name=d.name, child_name=d.child_name, last_seen=d.last_seen
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
    )


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

    await db.commit()
    await db.refresh(policy)

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
    )


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
        last_seen=device.last_seen,
        created_at=device.created_at,
    )
