"""Endpoints called by the macOS agent on the child's computer."""
from datetime import datetime, time

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_device_by_token
from ..database import get_db
from ..models.models import Device, Policy, UsageLog
from ..schemas import AgentConfig, UsageReport

router = APIRouter(prefix="/agent", tags=["agent"])


def format_time(t: time | None) -> str:
    if t is None:
        return "00:00"
    return t.strftime("%H:%M")


def get_effective_downtime(policy: Policy, now: datetime) -> tuple[str, str]:
    """Return the effective downtime start/end for today (considering weekday/weekend overrides)."""
    weekday = now.weekday()  # 0=Mon, 6=Sun
    is_weekend = weekday >= 5

    if is_weekend and policy.downtime_weekend_start is not None:
        return format_time(policy.downtime_weekend_start), format_time(policy.downtime_weekend_end)
    if not is_weekend and policy.downtime_weekday_start is not None:
        return format_time(policy.downtime_weekday_start), format_time(policy.downtime_weekday_end)
    return format_time(policy.downtime_start), format_time(policy.downtime_end)


def get_effective_limit(policy: Policy, now: datetime) -> int:
    weekday = now.weekday()
    is_weekend = weekday >= 5
    if is_weekend and policy.screen_time_weekend_limit_minutes is not None:
        return policy.screen_time_weekend_limit_minutes
    return policy.screen_time_limit_minutes


@router.get("/config", response_model=AgentConfig)
async def get_config(
    device: Device = Depends(get_device_by_token),
    db: AsyncSession = Depends(get_db),
):
    """Agent polls this to get current rules and usage."""
    now = datetime.utcnow()
    today = now.strftime("%Y-%m-%d")

    # Update last_seen
    device.last_seen = now
    await db.commit()

    # Get policy
    result = await db.execute(select(Policy).where(Policy.device_id == device.id))
    policy = result.scalar_one_or_none()

    if not policy:
        return AgentConfig(
            downtime_enabled=False,
            downtime_start="22:00",
            downtime_end="08:00",
            screen_time_enabled=False,
            screen_time_limit_minutes=999,
            used_minutes_today=0,
        )

    # Get today's usage
    result = await db.execute(
        select(UsageLog).where(UsageLog.device_id == device.id, UsageLog.date == today)
    )
    usage = result.scalar_one_or_none()
    used_today = usage.total_minutes if usage else 0.0

    ds, de = get_effective_downtime(policy, now)
    limit = get_effective_limit(policy, now)

    return AgentConfig(
        downtime_enabled=policy.downtime_enabled,
        downtime_start=ds,
        downtime_end=de,
        screen_time_enabled=policy.screen_time_enabled,
        screen_time_limit_minutes=limit,
        used_minutes_today=used_today,
    )


@router.post("/usage")
async def report_usage(
    report: UsageReport,
    device: Device = Depends(get_device_by_token),
    db: AsyncSession = Depends(get_db),
):
    """Agent reports accumulated usage for a date."""
    result = await db.execute(
        select(UsageLog).where(
            UsageLog.device_id == device.id, UsageLog.date == report.date
        )
    )
    log = result.scalar_one_or_none()

    if log:
        log.total_minutes = report.total_minutes
        log.last_updated = datetime.utcnow()
    else:
        log = UsageLog(
            device_id=device.id,
            date=report.date,
            total_minutes=report.total_minutes,
        )
        db.add(log)

    device.last_seen = datetime.utcnow()
    await db.commit()
    return {"ok": True}
