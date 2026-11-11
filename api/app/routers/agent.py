"""Endpoints called by the macOS agent on the child's computer."""
import hashlib
import logging
import os
import re
from datetime import datetime, time, timedelta, timezone
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import FileResponse
from sqlalchemy import select, func, update, or_, delete
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_device_by_token
from ..database import get_db
from ..models.models import Device, Policy, UsageLog, UsageReportLog, Activity, Child
from ..schemas import AgentConfig, UsageReport, TOTPVerifyRequest, TOTPVerifyResponse, ActivityOut
from ..totp import matching_step
from ..rate_limit import totp_limiter
from .devices import activity_applies_to

router = APIRouter(prefix="/agent", tags=["agent"])

logger = logging.getLogger(__name__)

# How much a usage report may exceed real elapsed time before we treat it as bogus.
# The agent counts wall-clock minutes, so between two reports it can only have gained
# the time that actually passed; the slack absorbs sync jitter — the gap between the
# tick that produced the number and the POST that delivers it, a retry after a failed
# request, and modest clock skew between the child's Mac and the server. Two minutes is
# comfortably above one 60s sync interval and far below any limit worth enforcing.
USAGE_REPORT_SLACK_MINUTES = 2.0

# How long every raw usage report is kept (`usage_reports`), to trace disputed counts.
USAGE_JOURNAL_DAYS = 7


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


# Tests pin historical dates (e.g. a known weekday); they switch this off. Production never does.
ENFORCE_PLAUSIBLE_DATES = True


def _require_plausible_local_date(date: str, now: datetime, allow_previous_day: bool = False) -> None:
    """A local date must exist somewhere on Earth right now (UTC-12 … UTC+14).

    Agents send their own local date, and the child controls the device clock. Without
    this check, moving the clock a day forward fetches a fresh, unused budget.

    `allow_previous_day` (usage reports only): a phone reports yesterday's last minutes on
    its first sync of the morning, which in the Americas is after yesterday has ended
    everywhere. Accepting an older date doesn't help the forward-clock trick.
    """
    if not ENFORCE_PLAUSIBLE_DATES:
        return
    hours = (-36, -12, 0, 14) if allow_previous_day else (-12, 0, 14)
    plausible = {(now + timedelta(hours=h)).strftime("%Y-%m-%d") for h in hours}
    if date not in plausible:
        raise HTTPException(status_code=400, detail="Date out of range: check the device's date and time")


@router.get("/config", response_model=AgentConfig)
async def get_config(
    device: Device = Depends(get_device_by_token),
    db: AsyncSession = Depends(get_db),
    date: Optional[str] = Query(None, description="Agent's local date YYYY-MM-DD"),
    version: Optional[str] = Query(None, description="Agent version"),
):
    """Agent polls this to get current rules and usage.

    If `date` is provided (agent's local date), usage is looked up for that date
    instead of UTC today. This avoids timezone mismatches at day boundaries.
    """
    now = datetime.now(timezone.utc)
    # Use agent-provided date if valid, otherwise fall back to UTC date
    if date and re.match(r"^\d{4}-\d{2}-\d{2}$", date):
        _require_plausible_local_date(date, now)
        today = date
        # Parse agent's local date to get correct weekday for limit/downtime
        agent_date = datetime.strptime(date, "%Y-%m-%d")
        agent_weekday = agent_date.weekday()  # 0=Mon, 6=Sun
    else:
        today = now.strftime("%Y-%m-%d")
        agent_weekday = now.weekday()

    # Update last_seen + agent version (committed together with response, no extra round-trip)
    device.last_seen = now
    if version:
        device.agent_version = version

    # Policy lives on the child; fall back to the device if the child has no policy row
    # of its own (e.g. a sibling device whose child's policy-owning device was deleted —
    # NEVER fall through to "no policy" for a device that has a device-keyed policy, since
    # that early-returns with screen_time_enabled=False / no downtime, i.e. unlocked forever).
    policy = None
    if device.child_id:
        result = await db.execute(select(Policy).where(Policy.child_id == device.child_id))
        policy = result.scalar_one_or_none()
    if policy is None:
        result = await db.execute(select(Policy).where(Policy.device_id == device.id))
        policy = result.scalar_one_or_none()

    # Bonus window lives on the child; fall back to the device's own (pre-migration)
    # window only when the child doesn't have one — same non-exclusive shape as the
    # policy fallback above.
    bu = None
    if device.child_id:
        result = await db.execute(select(Child.bonus_until).where(Child.id == device.child_id))
        bu = result.scalar_one_or_none()
    if bu is None:
        bu = device.bonus_until  # pre-migration fallback
    # SQLite returns naive datetimes even for tz-aware columns — coerce to UTC.
    if bu is not None and bu.tzinfo is None:
        bu = bu.replace(tzinfo=timezone.utc)
    bonus_until = bu if bu and bu > now else None

    # This device's own counter (used for the per-device ceiling). Computed before the
    # no-policy early return too, so device_used_minutes is never inconsistent with the
    # real device_cap_minutes we report alongside it.
    result = await db.execute(
        select(UsageLog).where(UsageLog.device_id == device.id, UsageLog.date == today)
    )
    own = result.scalar_one_or_none()
    device_used = own.total_minutes if own else 0.0

    if not policy:
        await db.commit()
        return AgentConfig(
            downtime_enabled=False,
            downtime_start="22:00",
            downtime_end="08:00",
            screen_time_enabled=False,
            screen_time_limit_minutes=999,
            used_minutes_today=0,
            device_used_minutes=device_used,
            device_cap_minutes=device.daily_cap_minutes,
            bonus_until=bonus_until,
        )

    # The child's shared counter: the sum over every device they own (scoped to the same
    # owner too, as defense in depth against a device ever mis-linking to another user's child).
    if device.child_id:
        result = await db.execute(
            select(func.coalesce(func.sum(UsageLog.total_minutes), 0.0))
            .select_from(UsageLog)
            .join(Device, Device.id == UsageLog.device_id)
            .where(
                Device.child_id == device.child_id,
                Device.owner_id == device.owner_id,
                UsageLog.date == today,
            )
        )
        used_today = float(result.scalar_one())
    else:
        used_today = device_used

    ds, de = get_effective_downtime(policy, agent_weekday)
    limit = get_effective_limit(policy, agent_weekday)

    # Activities live on the child now; fall back to the device's own (pre-migration)
    # activities when the child has none of its own — same non-exclusive shape as the
    # policy fallback above. A device with no child skips straight to its own rows
    # (today's behaviour, unchanged); a device whose child has activities gets those
    # instead of whatever this one device happens to carry, so a schedule created on
    # a sibling device is actually enforced here, not just visible in the parent UI.
    activities_rows = []
    if device.child_id:
        result = await db.execute(
            select(Activity).where(Activity.child_id == device.child_id, Activity.enabled == True)
        )
        activities_rows = result.scalars().all()
    if not activities_rows:
        result = await db.execute(
            select(Activity).where(Activity.device_id == device.id, Activity.enabled == True)
        )
        activities_rows = result.scalars().all()

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
        for a in activities_rows
        # Filter AFTER the child-vs-device fallback above: a child whose activities all
        # name other devices still "has activities", so this device must not fall back
        # to device-keyed rows (child-level rows are stamped with a device id too).
        if activity_applies_to(a, device.id)
    ]

    # Single commit for last_seen + version update
    await db.commit()

    return AgentConfig(
        downtime_enabled=policy.downtime_enabled,
        downtime_start=ds,
        downtime_end=de,
        screen_time_enabled=policy.screen_time_enabled,
        screen_time_limit_minutes=limit,
        used_minutes_today=used_today,
        device_used_minutes=device_used,
        device_cap_minutes=device.daily_cap_minutes,
        activities=activities,
        bonus_until=bonus_until,
    )


def _clamp_reported_minutes(
    *,
    reported: float,
    previous: float,
    last_updated: Optional[datetime],
    now: datetime,
    device_id: str,
    date: str,
) -> float:
    """Cap an absolute usage report at what this device could actually have accumulated.

    A device's counter can only grow with wall-clock time, so between two reports it
    can gain at most the elapsed time (plus `USAGE_REPORT_SLACK_MINUTES`). Anything
    above that is a misbehaving agent — notably agent 2.9, which ratchets its local
    counter up to `used_minutes_today` (now the CHILD's combined total across devices)
    and then posts that back as this device's own total. Without this clamp two Macs
    sharing a child echo each other's sums and both counters explode within a few sync
    rounds, locking the child out until someone edits the database by hand.

    What this deliberately still allows:
      * Offline catch-up. `last_updated` only advances when the device reports, so a
        Mac that was off (or offline) for three hours has three hours of elapsed time
        to spend and may legitimately report ~180 extra minutes.
      * Parent-initiated resets. A report LOWER than the stored value is always
        accepted untouched — the agent honours a downward correction on its next sync.
      * A brand-new row for the date (handled by the caller): accepted as-is.
    """
    if reported <= previous:
        return reported  # parent reset or a no-op re-send of the same total
    if last_updated is None:
        return reported  # no anchor to measure elapsed time against

    # SQLite hands back naive datetimes even for timezone-aware columns.
    if last_updated.tzinfo is None:
        last_updated = last_updated.replace(tzinfo=timezone.utc)

    elapsed_minutes = max(0.0, (now - last_updated).total_seconds() / 60.0)
    ceiling = previous + elapsed_minutes + USAGE_REPORT_SLACK_MINUTES
    if reported <= ceiling:
        return reported

    logger.warning(
        "Clamped usage report for device=%s date=%s: reported %.1fm but only %.1fm "
        "was reachable (previous %.1fm + %.1fm elapsed + %.1fm slack). "
        "An agent is reporting time it cannot have accumulated.",
        device_id, date, reported, ceiling, previous, elapsed_minutes,
        USAGE_REPORT_SLACK_MINUTES,
    )
    return ceiling


@router.post("/usage")
async def report_usage(
    report: UsageReport,
    device: Device = Depends(get_device_by_token),
    db: AsyncSession = Depends(get_db),
):
    """Agent reports accumulated usage for a date.

    The value is absolute (this device's total for that date), not a delta, and it is
    clamped to what could physically have been accumulated since this device's previous
    report — see `_clamp_reported_minutes`.
    """
    now = datetime.now(timezone.utc)
    _require_plausible_local_date(report.date, now, allow_previous_day=True)
    result = await db.execute(
        select(UsageLog).where(
            UsageLog.device_id == device.id, UsageLog.date == report.date
        )
    )
    log = result.scalar_one_or_none()

    if log:
        log.total_minutes = _clamp_reported_minutes(
            reported=report.total_minutes,
            previous=log.total_minutes or 0.0,
            last_updated=log.last_updated,
            now=now,
            device_id=device.id,
            date=report.date,
        )
        log.last_updated = now
    else:
        # First report for this device/date: there is no previous total to measure
        # growth against, and the agent may legitimately have been counting offline
        # for hours before its first successful sync. Accept it as-is.
        log = UsageLog(
            device_id=device.id,
            date=report.date,
            total_minutes=report.total_minutes,
        )
        db.add(log)

    db.add(UsageReportLog(
        device_id=device.id,
        date=report.date,
        reported_minutes=report.total_minutes,
        stored_minutes=log.total_minutes,
        received_at=now,
    ))
    await db.execute(
        delete(UsageReportLog).where(UsageReportLog.received_at < now - timedelta(days=USAGE_JOURNAL_DAYS))
    )

    device.last_seen = now
    await db.commit()
    return {"ok": True}


@router.get("/totp-secret")
async def get_totp_secret(
    device: Device = Depends(get_device_by_token),
    db: AsyncSession = Depends(get_db),
):
    """One-time fetch of TOTP secret. Agent stores it in Keychain."""
    if not device.shared_secret:
        raise HTTPException(status_code=404, detail="No secret configured")
    return {"shared_secret": device.shared_secret}


@router.post("/verify-totp", response_model=TOTPVerifyResponse)
async def verify_totp_endpoint(
    body: TOTPVerifyRequest,
    request: Request,
    device: Device = Depends(get_device_by_token),
    db: AsyncSession = Depends(get_db),
):
    """Verify a TOTP code — rate limited to prevent brute-force."""
    await totp_limiter.check(db, device.id)  # Rate limit per device, not IP
    if not device.shared_secret:
        raise HTTPException(status_code=400, detail="No shared secret configured")
    step = matching_step(device.shared_secret, body.code)
    # One-time codes: a step at or below the last accepted one is spent. Without this a
    # child can replay one code for ~10 minutes of repeated 5-minute unlocks.
    # Compare-and-set in one statement: two concurrent requests with the same code can't
    # both win (the ORM's copy of the row may be stale).
    valid = False
    if step is not None:
        result = await db.execute(
            update(Device)
            .where(Device.id == device.id)
            .where(or_(Device.last_totp_step.is_(None), Device.last_totp_step < step))
            .values(last_totp_step=step)
            .execution_options(synchronize_session=False)
        )
        await db.commit()
        valid = result.rowcount == 1
    return TOTPVerifyResponse(valid=valid, granted_minutes=5 if valid else 0)


# --- Agent auto-update ---
# Parent uploads NesTimerAgent.zip to data/agent-update/ on the server.
# Agent (watchdog) checks this endpoint and downloads if version differs.

UPDATE_DIR = Path("/app/data/agent-update")


@router.get("/update/check")
async def check_update():
    """Returns current agent version and sha256. No auth required (public)."""
    version_file = UPDATE_DIR / "version.txt"
    zip_file = UPDATE_DIR / "NesTimerAgent.zip"
    if not version_file.exists() or not zip_file.exists():
        return {"version": None, "sha256": None}
    version = version_file.read_text().strip()
    sha256 = hashlib.sha256(zip_file.read_bytes()).hexdigest()
    return {"version": version, "sha256": sha256}


@router.get("/update/download")
async def download_update():
    """Download the agent zip. No auth (watchdog runs as root, no token)."""
    zip_file = UPDATE_DIR / "NesTimerAgent.zip"
    if not zip_file.exists():
        raise HTTPException(status_code=404, detail="No update available")
    return FileResponse(str(zip_file), filename="NesTimerAgent.zip", media_type="application/zip")
