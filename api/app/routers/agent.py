"""Endpoints called by the macOS agent on the child's computer."""
import hashlib
import os
import re
from datetime import datetime, time, timezone
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_device_by_token
from ..database import get_db
from ..models.models import Device, Policy, UsageLog, Activity
from ..schemas import AgentConfig, UsageReport, TOTPVerifyRequest, TOTPVerifyResponse, ActivityOut
from ..totp import verify_totp

router = APIRouter(prefix="/agent", tags=["agent"])


def format_time(t: time | None) -> str:
    if t is None:
        return "00:00"
    return t.strftime("%H:%M")


def get_effective_downtime(policy: Policy, weekday: int) -> tuple[str, str]:
    """Return the effective downtime start/end for today (considering weekday/weekend overrides)."""
    is_weekend = weekday >= 5

    if is_weekend and policy.downtime_weekend_start is not None:
        return format_time(policy.downtime_weekend_start), format_time(policy.downtime_weekend_end)
    if not is_weekend and policy.downtime_weekday_start is not None:
        return format_time(policy.downtime_weekday_start), format_time(policy.downtime_weekday_end)
    return format_time(policy.downtime_start), format_time(policy.downtime_end)


def get_effective_limit(policy: Policy, weekday: int) -> int:
    # Check per-day override first
    day_fields = ["screen_time_mon_minutes", "screen_time_tue_minutes", "screen_time_wed_minutes",
                  "screen_time_thu_minutes", "screen_time_fri_minutes", "screen_time_sat_minutes",
                  "screen_time_sun_minutes"]
    day_value = getattr(policy, day_fields[weekday], None)
    if day_value is not None:
        return day_value
    # Fall back to weekend/weekday default
    is_weekend = weekday >= 5
    if is_weekend and policy.screen_time_weekend_limit_minutes is not None:
        return policy.screen_time_weekend_limit_minutes
    return policy.screen_time_limit_minutes


@router.get("/config", response_model=AgentConfig)
async def get_config(
    device: Device = Depends(get_device_by_token),
    db: AsyncSession = Depends(get_db),
    date: Optional[str] = Query(None, description="Agent's local date YYYY-MM-DD"),
):
    """Agent polls this to get current rules and usage.

    If `date` is provided (agent's local date), usage is looked up for that date
    instead of UTC today. This avoids timezone mismatches at day boundaries.
    """
    now = datetime.now(timezone.utc)
    # Use agent-provided date if valid, otherwise fall back to UTC date
    if date and re.match(r"^\d{4}-\d{2}-\d{2}$", date):
        today = date
        # Parse agent's local date to get correct weekday for limit/downtime
        agent_date = datetime.strptime(date, "%Y-%m-%d")
        agent_weekday = agent_date.weekday()  # 0=Mon, 6=Sun
    else:
        today = now.strftime("%Y-%m-%d")
        agent_weekday = now.weekday()

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
            shared_secret=device.shared_secret,
        )

    # Get today's usage
    result = await db.execute(
        select(UsageLog).where(UsageLog.device_id == device.id, UsageLog.date == today)
    )
    usage = result.scalar_one_or_none()
    used_today = usage.total_minutes if usage else 0.0

    ds, de = get_effective_downtime(policy, agent_weekday)
    limit = get_effective_limit(policy, agent_weekday)

    # Load all enabled activities for this device
    result = await db.execute(
        select(Activity).where(Activity.device_id == device.id, Activity.enabled == True)
    )
    activities = [
        ActivityOut(
            id=a.id,
            name=a.name,
            day_of_week=a.day_of_week,
            start_time=a.start_time.strftime("%H:%M"),
            end_time=a.end_time.strftime("%H:%M"),
            buffer_before_minutes=a.buffer_before_minutes,
            buffer_after_minutes=a.buffer_after_minutes,
            enabled=a.enabled,
        )
        for a in result.scalars().all()
    ]

    return AgentConfig(
        downtime_enabled=policy.downtime_enabled,
        downtime_start=ds,
        downtime_end=de,
        screen_time_enabled=policy.screen_time_enabled,
        screen_time_limit_minutes=limit,
        used_minutes_today=used_today,
        shared_secret=device.shared_secret,
        activities=activities,
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
        log.last_updated = datetime.now(timezone.utc)
    else:
        log = UsageLog(
            device_id=device.id,
            date=report.date,
            total_minutes=report.total_minutes,
        )
        db.add(log)

    device.last_seen = datetime.now(timezone.utc)
    await db.commit()
    return {"ok": True}


@router.post("/verify-totp", response_model=TOTPVerifyResponse)
async def verify_totp_endpoint(
    body: TOTPVerifyRequest,
    device: Device = Depends(get_device_by_token),
    db: AsyncSession = Depends(get_db),
):
    """Verify a TOTP code (optional online verification by the agent)."""
    if not device.shared_secret:
        raise HTTPException(status_code=400, detail="No shared secret configured")
    valid = verify_totp(device.shared_secret, body.code)
    return TOTPVerifyResponse(valid=valid, granted_minutes=30 if valid else 0)


# --- Agent auto-update ---
# Parent uploads UsageTimeAgent.zip to data/agent-update/ on the server.
# Agent (watchdog) checks this endpoint and downloads if version differs.

UPDATE_DIR = Path("/app/data/agent-update")


@router.get("/update/check")
async def check_update():
    """Returns current agent version and sha256. No auth required (public)."""
    version_file = UPDATE_DIR / "version.txt"
    zip_file = UPDATE_DIR / "UsageTimeAgent.zip"
    if not version_file.exists() or not zip_file.exists():
        return {"version": None, "sha256": None}
    version = version_file.read_text().strip()
    sha256 = hashlib.sha256(zip_file.read_bytes()).hexdigest()
    return {"version": version, "sha256": sha256}


@router.get("/update/download")
async def download_update():
    """Download the agent zip. No auth (watchdog runs as root, no token)."""
    zip_file = UPDATE_DIR / "UsageTimeAgent.zip"
    if not zip_file.exists():
        raise HTTPException(status_code=404, detail="No update available")
    return FileResponse(str(zip_file), filename="UsageTimeAgent.zip", media_type="application/zip")
