import secrets
from datetime import time, datetime, timedelta, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select, or_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from ..auth import get_current_user, create_agent_token
from ..database import get_db
from ..models.models import User, Device, Policy, UsageLog, Activity, Child
from ..schemas import (
    DeviceCreate, DeviceUpdate, DeviceOut, DeviceListOut,
    PolicyUpdate, PolicyOut,
    UsageOut,
    ActivityCreate, ActivityUpdate, ActivityOut,
    GrantBonusRequest, GrantBonusResponse,
)

router = APIRouter(prefix="/devices", tags=["devices"])


async def _effective_bonus_until(db: AsyncSession, device: Device) -> Optional[datetime]:
    """Bonus window as reported to the parent apps (`DeviceOut.bonus_until`): the
    child's window when this device has a child AND that window is set, falling back to
    the device's own (pre-migration) value whenever the child's is None. Same non-exclusive
    fallback shape as `/agent/config` — grant-bonus writes to the child now, so a live
    child window always shadows a stale device one.

    Note what this does NOT do: a child window that is cleared back to None (nothing does
    that today — there is no revoke path) falls straight back to the device's own value,
    so a stale device window WOULD resurface. Whoever adds a revoke must clear
    `Device.bonus_until` too, or make this fallback conditional on the child never having
    had a window."""
    if device.child_id:
        result = await db.execute(select(Child.bonus_until).where(Child.id == device.child_id))
        bu = result.scalar_one_or_none()
        if bu is not None:
            return bu
    return device.bonus_until


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

# These back non-nullable DB columns (see PolicyOut) -- unlike the per-day and
# weekend/weekday overrides, there is no "clear it" meaning for an explicit null here.
# Writing one either silently mis-enforces the policy (the enabled flags, the downtime
# window) or corrupts the row outright (screen_time_limit_minutes is NOT NULL), and the
# very next read 500s: an IntegrityError on write for the always-NOT-NULL columns, or a
# ResponseValidationError out of PolicyOut for the ones SQLite lets through as NULL.
NON_NULLABLE_POLICY_FIELDS = {
    "downtime_enabled", "downtime_start", "downtime_end",
    "screen_time_enabled", "screen_time_limit_minutes",
}


def _reject_null_policy_fields(data: PolicyUpdate) -> None:
    nulled = sorted(
        f for f in data.model_fields_set
        if f in NON_NULLABLE_POLICY_FIELDS and getattr(data, f) is None
    )
    if nulled:
        raise HTTPException(
            status_code=422,
            detail=f"These fields cannot be null: {', '.join(nulled)}",
        )


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
    if data.child_id:
        result = await db.execute(
            select(Child).where(Child.id == data.child_id, Child.owner_id == user.id)
        )
        child = result.scalar_one_or_none()
        if not child:
            raise HTTPException(status_code=404, detail="Child not found")
    else:
        child = Child(owner_id=user.id, name=data.child_name)
        db.add(child)
        await db.flush()

    # child.name equals data.child_name when a new child was just created above from
    # it; when attaching to an EXISTING child, use the child's real name rather than
    # whatever child_name the caller happened to send — otherwise this denormalised
    # column could show a name that disagrees with the child it's actually attached
    # to (two devices on one child displaying two different "child names" in the
    # parent UI, neither necessarily correct).
    device = Device(
        owner_id=user.id,
        child_id=child.id,
        platform=data.platform,
        name=data.name,
        child_name=child.name,
        api_token="placeholder",
        shared_secret=secrets.token_hex(20),
    )
    db.add(device)
    await db.flush()

    # Generate a real agent token
    device.api_token = create_agent_token(device.id)

    # Create a default policy for the child, but only if it doesn't have one yet —
    # attaching a second device to an existing child must never overwrite the first
    # device's rules. Stamp device_id=device.id on it too (not just child_id): the
    # device-keyed fallback in `/agent/config` and `_resolve_policy` (for a device
    # later re-pointed at a childless/policy-less child, e.g. after a sibling that
    # owned the shared policy is deleted, or the pre-child-migration rewind path
    # covered by test_config_is_byte_identical_across_the_migration) both find their
    # way back to a policy only via `Policy.device_id`. Without it, that fallback
    # query never matches, `/agent/config` falls into its "no policy" branch, and
    # this device silently loses its rules AND its activities (that branch returns
    # before activities are computed).
    result = await db.execute(select(Policy).where(Policy.child_id == child.id))
    child_policy = result.scalar_one_or_none()
    if child_policy is None:
        db.add(Policy(child_id=child.id, device_id=device.id))
    elif child_policy.device_id is None:
        # The child already has a policy, but nothing device-keyed points at it — it was
        # created without a device (an older build's `POST /children`, or `get_policy`'s
        # auto-create before it stamped device_id). Adopt it under this device so the
        # device-keyed fallback described above has a row to find. Safe despite the unique
        # constraint on Policy.device_id: this device was created moments ago, so no other
        # policy row can reference it.
        child_policy.device_id = device.id

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
        bonus_until=await _effective_bonus_until(db, device),
        child_id=device.child_id,
        platform=device.platform,
        daily_cap_minutes=device.daily_cap_minutes,
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
            id=d.id, name=d.name, child_name=d.child_name, agent_version=d.agent_version, last_seen=d.last_seen,
            child_id=d.child_id, platform=d.platform, daily_cap_minutes=d.daily_cap_minutes,
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
        bonus_until=await _effective_bonus_until(db, device),
        child_id=device.child_id,
        platform=device.platform,
        daily_cap_minutes=device.daily_cap_minutes,
    )


@router.patch("/{device_id}", response_model=DeviceOut)
async def update_device(
    device_id: str,
    data: DeviceUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Device).where(Device.id == device_id, Device.owner_id == user.id)
    )
    device = result.scalar_one_or_none()
    if not device:
        raise HTTPException(status_code=404, detail="Device not found")

    if data.name is not None:
        device.name = data.name
    if data.child_name is not None:
        device.child_name = data.child_name

    if data.child_id is not None:
        result = await db.execute(
            select(Child).where(Child.id == data.child_id, Child.owner_id == user.id)
        )
        child = result.scalar_one_or_none()
        if child is None:
            raise HTTPException(status_code=404, detail="Child not found")
        # The denormalised child_name column must follow the real child it's
        # attached to, not whatever child_name the caller last sent — otherwise two
        # devices on one child can show two different (and possibly both wrong)
        # names for that child in the parent UI. This intentionally overrides any
        # child_name supplied in the same request.
        device.child_name = child.name
        if data.child_id != device.child_id:
            device.child_id = data.child_id
            # Re-key ONLY genuine legacy device-keyed rows (child_id IS NULL) onto the
            # new child. Those really do belong to the device -- nothing else points at
            # them -- and without a child_id they would be invisible to the child-first
            # lookup in `/agent/config` on either side of the move.
            #
            # A row that already carries a child_id must keep it. Re-keying those drags
            # the OLD child's schedules onto every OTHER Mac of the destination child:
            # `/agent/config` resolves activities child-first, and an active activity
            # UNLOCKS the screen and pauses counting, so a sibling that had no schedule
            # at all silently becomes unlockable during every window the moved device
            # carried. It is worse for genuinely child-level schedules, which
            # `POST /children/{id}/activities` stamps with the child's oldest device:
            # that stamp made a shared, child-owned schedule follow one device on a move,
            # so the old child's remaining Macs LOST it and the new child's GAINED it.
            await db.execute(
                Activity.__table__.update()
                .where(Activity.device_id == device.id, Activity.child_id.is_(None))
                .values(child_id=data.child_id)
            )

            # For the rows that stay with their own child, re-point device_id at another
            # device of THAT child, so the pre-child device-keyed fallback still reaches
            # them there. Same shape as delete_device, including the no-sibling case:
            # nothing to re-point to, so the stamp is left alone rather than nulled (the
            # old child has no devices left at that point anyway).
            result = await db.execute(
                select(Activity).where(
                    Activity.device_id == device.id,
                    Activity.child_id.isnot(None),
                    Activity.child_id != data.child_id,
                )
            )
            for activity in result.scalars().all():
                sibling_result = await db.execute(
                    select(Device.id).where(
                        Device.child_id == activity.child_id, Device.id != device.id
                    ).limit(1)
                )
                sibling_id = sibling_result.scalar_one_or_none()
                if sibling_id:
                    activity.device_id = sibling_id

            # Make sure the device lands on a child that HAS a policy, and that the
            # policy is reachable by device_id. Moving a device to a child created via
            # "Add Child" (which deliberately creates no policy row) otherwise leaves it
            # with none at all: `/agent/config` finds nothing by child_id and nothing by
            # device_id — this device may never have owned a row, its old child's row
            # being keyed to a sibling — and takes its no-policy branch
            # (screen_time_enabled=False, downtime_enabled=False), i.e. that Mac stops
            # locking. Same create-or-adopt shape as create_device, and for the same
            # rollback reason: device_id is the only route back for pre-child code.
            #
            # Hand off first: the row this device owns may still be the live policy for
            # the child it is LEAVING, whose remaining devices reach it only through
            # `Policy.device_id`. `_detach_devices_policy` moves it to one of those
            # siblings without ever deleting it, which both keeps the old child enforced
            # and frees this device to take a policy on its new child. Gated on that
            # child actually still having another device: in the ordinary merge direction
            # (the old child is left with none) there is nobody to hand it to and the
            # detach would just null `device_id`, throwing away the pre-child rollback
            # anchor for nothing. In that case this device keeps its own row and the
            # create-or-adopt below is skipped — its old rules stay in force via the
            # device-keyed fallback, which fails closed.
            result = await db.execute(select(Policy).where(Policy.device_id == device.id))
            owned = result.scalar_one_or_none()
            if owned is not None and owned.child_id is not None:
                result = await db.execute(
                    select(Device.id)
                    .where(Device.child_id == owned.child_id, Device.id != device.id)
                    .limit(1)
                )
                if result.scalar_one_or_none() is not None:
                    await _detach_devices_policy(db, device.id)

            # Policy.device_id is unique, so this can only run once the device owns no
            # row — either it never did, or the hand-off above just freed it.
            result = await db.execute(select(Policy).where(Policy.device_id == device.id))
            if result.scalar_one_or_none() is None:
                result = await db.execute(
                    select(Policy).where(Policy.child_id == data.child_id)
                )
                child_policy = result.scalar_one_or_none()
                if child_policy is None:
                    db.add(Policy(child_id=data.child_id, device_id=device.id))
                elif child_policy.device_id is None:
                    child_policy.device_id = device.id

    if "daily_cap_minutes" in data.model_fields_set:
        device.daily_cap_minutes = data.daily_cap_minutes

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
        bonus_until=await _effective_bonus_until(db, device),
        child_id=device.child_id,
        platform=device.platform,
        daily_cap_minutes=device.daily_cap_minutes,
    )


async def _detach_devices_policy(db: AsyncSession, device_id: str, _seen: set | None = None) -> None:
    """Move the Policy row `device_id` currently owns (if any) off of it -- NEVER by
    deleting the row.

    A device's own Policy row and its own child_id are independent columns that can
    diverge: update_device deliberately does not re-key a device's pre-existing Policy
    row when that device is merged onto a different child (see its comment on why).
    So a device about to be deleted may own a Policy row that is still the live,
    currently-enforced policy for some OTHER child that still has devices of its own --
    "this device is being deleted" says nothing about that row's relevance. The only
    safe destination for the row is therefore a device of ITS OWN child (policy.child_id),
    never this device's current child_id.

    If the row has no child_id at all, there is no "own child" to look on -- clear its
    device_id and leave the row in place (still never deleted).

    If a same-child candidate device already owns a Policy row of its own,
    Policy.device_id's unique constraint forbids also pointing this row at it --
    recursively free that candidate up the same way first.

    `_seen` is not a defensive impossibility guard -- cycles are reachable through
    ordinary API use, with just two devices and two PATCHes, precisely because
    update_device never re-keys a device's pre-existing Policy row on merge (the same
    divergence this whole function exists to handle, applied in both directions at
    once):

        POST /devices {name: A, child_name: C2}   -> A.child=C2, P_A(child=C2, device=A)
        POST /devices {name: B, child_name: C1}   -> B.child=C1, P_B(child=C1, device=B)
        PATCH A {child_id: C1}                    -> A.child=C1, P_A untouched (child=C2)
        PATCH B {child_id: C2}                    -> B.child=C2, P_B untouched (child=C1)

    Now P_A's only candidate (for C2) is B, and P_B's only candidate (for C1) is A --
    each needs the other freed first. `_seen` breaks the cycle: a candidate already on
    this call stack cannot be recursed into (that would be a silent no-op, since the
    top-of-function guard would return immediately without freeing anything), so it is
    never selected as `free` in the first place -- it falls back to `device_id = None`
    instead. The NULL anchor is not permanent: create_device's adopt branch and
    update_device both re-anchor a `device_id IS NULL` policy the next time a device
    attaches to that child.

    Every mutation below is followed by an explicit `db.flush()`. A plain attribute
    assignment is only queued in the session's unit of work; when several of these
    queue up across a recursive chain, SQLAlchemy is free to batch and reorder them at
    flush time, which can apply a later step's UPDATE before an earlier step's has
    landed and trip the very unique constraint this function exists to avoid. Flushing
    immediately after each assignment makes the DB state match this function's logical
    order at every step, not just at the end.
    """
    _seen = _seen if _seen is not None else set()
    if device_id in _seen:
        return
    _seen.add(device_id)

    result = await db.execute(select(Policy).where(Policy.device_id == device_id))
    policy = result.scalar_one_or_none()
    if policy is None:
        return

    if policy.child_id is None:
        policy.device_id = None
        await db.flush()
        return

    result = await db.execute(
        select(Device.id).where(Device.child_id == policy.child_id, Device.id != device_id)
    )
    candidates = [row[0] for row in result.all()]
    if not candidates:
        policy.device_id = None
        await db.flush()
        return

    result = await db.execute(select(Policy.device_id).where(Policy.device_id.in_(candidates)))
    busy = {row[0] for row in result.all()}
    free = next((c for c in candidates if c not in busy), None)
    if free is None:
        # Every candidate already owns a Policy row of its own. Only recurse into one
        # NOT already in _seen -- one that IS in _seen is on this call stack right now
        # (a cycle), so recursing into it would be a silent no-op and it would stay
        # busy. Never assign to a candidate the recursion did not actually free.
        freeable = next((c for c in candidates if c not in _seen), None)
        if freeable is not None:
            await _detach_devices_policy(db, freeable, _seen)
            free = freeable

    if free is None:
        # A cycle closed with nothing left to free -- detach rather than risk the
        # unique constraint. The row survives; see the cycle note above.
        policy.device_id = None
    else:
        policy.device_id = free
    await db.flush()


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

    # Device.policy and Device.activities are cascade="all, delete-orphan": when
    # db.delete(device) below lazy-loads those relationships, any row still pointing at
    # this device's id is deleted with it. Re-point everything that must survive BEFORE
    # that happens -- the lazy load autoflushes our pending ORM changes first, so by the
    # time it queries, nothing pointing at this device is left to find. (This is an ORM-
    # level mechanism, identical on PostgreSQL; nothing SQLite-specific about it.)
    await _detach_devices_policy(db, device.id)

    # Activities have no uniqueness constraint on device_id, so there is no collision to
    # avoid -- but a row this device owns for some OTHER live child must not be dropped
    # just because this device is going away. Re-point each such row onto another device
    # of the ACTIVITY's own child (not this device's current child_id, for the same
    # divergence reason as Policy above). An activity with no such sibling, or no
    # child_id at all, is truly orphaned and is left to cascade away -- that is correct.
    result = await db.execute(select(Activity).where(Activity.device_id == device.id))
    for activity in result.scalars().all():
        if activity.child_id is None:
            continue
        sibling_result = await db.execute(
            select(Device.id).where(
                Device.child_id == activity.child_id, Device.id != device.id
            ).limit(1)
        )
        sibling_id = sibling_result.scalar_one_or_none()
        if sibling_id:
            activity.device_id = sibling_id

    await db.delete(device)
    await db.commit()
    return {"ok": True}


async def _child_id_for_device(db: AsyncSession, device: Device) -> str:
    """Resolve a device to its child, creating one if the row predates the migration."""
    if device.child_id:
        return device.child_id
    child = Child(owner_id=device.owner_id, name=device.child_name or "Child")
    db.add(child)
    await db.flush()
    device.child_id = child.id
    return child.id


async def _resolve_policy(db: AsyncSession, child_id: str, device_id: str) -> Policy | None:
    """Find the child's policy, falling back to (and, for a genuine pre-migration row,
    adopting under the child) a pre-existing device-keyed row for a device resolved to a
    child for the first time just now. Mirrors the non-exclusive fallback chain
    `/agent/config` uses — never drop a device's real policy just because its child
    doesn't have one of its own yet.

    The adoption is deliberately restricted to rows whose `child_id` IS NULL — the only
    case it exists for. `Policy.child_id` is unique, so writing it on a row that already
    names a child does not ADD a key, it MOVES one: that child is left with zero policy
    rows, `/agent/config` finds nothing by child_id and nothing by device_id, and every
    remaining Mac of theirs takes the no-policy branch (screen_time_enabled=False,
    limit=999) and stops locking, permanently. Reachable from a plain read: a parent
    moving the device that happens to own the row, then this endpoint refetching the
    policy for its new child. A row that already carries a child_id belongs to that
    child; a device sitting on some other child just reads it, it does not take it.
    """
    result = await db.execute(select(Policy).where(Policy.child_id == child_id))
    policy = result.scalar_one_or_none()
    if policy is not None:
        return policy

    result = await db.execute(select(Policy).where(Policy.device_id == device_id))
    policy = result.scalar_one_or_none()
    if policy is not None and policy.child_id is None:
        policy.child_id = child_id
    return policy


# --- Policy ---
@router.get("/{device_id}/policy", response_model=PolicyOut)
async def get_policy(
    device_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # GET that can still write: _child_id_for_device may lazily create and persist a
    # Child for a device that predates the migration, and _resolve_policy may adopt a
    # legacy device-keyed row under it — both need a commit to survive past this
    # request, even though this handler is otherwise a plain read.
    device = await _verify_device_owner(db, device_id, user.id)
    child_id = await _child_id_for_device(db, device)

    policy = await _resolve_policy(db, child_id, device_id)
    if policy is None:
        # Stamp device_id as well as child_id: the device-keyed lookup is the only route
        # back to this row for an API rolled back to pre-child code against a migrated
        # database, and that code's no-policy branch leaves the device unlocked forever.
        # Same reasoning as create_device — see the long comment there.
        policy = Policy(child_id=child_id, device_id=device_id)
        db.add(policy)

    await db.commit()
    await db.refresh(policy)

    return policy_to_out(policy)


@router.put("/{device_id}/policy", response_model=PolicyOut)
async def update_policy(
    device_id: str,
    data: PolicyUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    device = await _verify_device_owner(db, device_id, user.id)
    child_id = await _child_id_for_device(db, device)

    policy = await _resolve_policy(db, child_id, device_id)
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")

    _reject_null_policy_fields(data)

    # Use model_fields_set to distinguish "not sent" from "sent as null".
    # This allows clients to clear optional overrides by sending null.
    supplied = data.model_fields_set
    time_fields = {
        "downtime_start", "downtime_end",
        "downtime_weekday_start", "downtime_weekday_end",
        "downtime_weekend_start", "downtime_weekend_end",
    }

    for field_name in supplied:
        value = getattr(data, field_name)
        if field_name in time_fields:
            value = parse_time(value) if value is not None else None
        setattr(policy, field_name, value)

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


@router.post("/{device_id}/grant-bonus", response_model=GrantBonusResponse)
async def grant_bonus(
    device_id: str,
    data: GrantBonusRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Grant temporary unlock without changing daily limit.

    The bonus window starts now and lasts `minutes` minutes. During this window
    the agent unlocks the screen and pauses usage counting.
    Calling again replaces the previous window (does not stack).
    """
    device = await _verify_device_owner(db, device_id, user.id)
    child_id = await _child_id_for_device(db, device)

    result = await db.execute(select(Child).where(Child.id == child_id))
    child = result.scalar_one()
    child.bonus_until = datetime.now(timezone.utc) + timedelta(minutes=data.minutes)
    await db.commit()
    return GrantBonusResponse(bonus_until=child.bonus_until)


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
        bonus_until=await _effective_bonus_until(db, device),
        child_id=device.child_id,
        platform=device.platform,
        daily_cap_minutes=device.daily_cap_minutes,
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


async def _resolve_activity(
    db: AsyncSession, activity_id: str, child_id: str, device_id: str
) -> Activity | None:
    """Find one activity by id, scoped to the child first and falling back to (and
    adopting under the child) a pre-existing device-keyed row — same non-exclusive
    fallback shape as `_resolve_policy`."""
    result = await db.execute(
        select(Activity).where(Activity.id == activity_id, Activity.child_id == child_id)
    )
    activity = result.scalar_one_or_none()
    if activity is not None:
        return activity

    result = await db.execute(
        select(Activity).where(Activity.id == activity_id, Activity.device_id == device_id)
    )
    activity = result.scalar_one_or_none()
    if activity is not None:
        activity.child_id = child_id
    return activity


@router.get("/{device_id}/activities", response_model=List[ActivityOut])
async def list_activities(
    device_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # GET that can still write: _child_id_for_device may lazily create and persist a
    # Child for a device that predates the migration, so this list is complete on the
    # very first call rather than only after some later PUT/POST resolves it.
    device = await _verify_device_owner(db, device_id, user.id)
    child_id = await _child_id_for_device(db, device)

    # Union the child-keyed rows with this device's own device-keyed rows, rather than
    # only falling back when the child list is empty: once Task 6 lets a parent move a
    # device onto a child that already has activities, an else-branch would silently
    # drop this device's own legacy rows from the list — still enforced by the agent,
    # but no longer visible or deletable here. De-duplicate by id since a row that
    # already carries both keys would otherwise match both halves of the OR.
    result = await db.execute(
        select(Activity)
        .where(or_(Activity.child_id == child_id, Activity.device_id == device_id))
        .order_by(Activity.day_of_week, Activity.start_time)
    )
    seen = set()
    activities = []
    for a in result.scalars().all():
        if a.id not in seen:
            seen.add(a.id)
            activities.append(a)

    await db.commit()
    return [activity_to_out(a) for a in activities]


@router.post("/{device_id}/activities", response_model=ActivityOut)
async def create_activity(
    device_id: str,
    data: ActivityCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    device = await _verify_device_owner(db, device_id, user.id)
    child_id = await _child_id_for_device(db, device)
    activity = Activity(
        device_id=device_id,
        child_id=child_id,
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
    device = await _verify_device_owner(db, device_id, user.id)
    child_id = await _child_id_for_device(db, device)
    activity = await _resolve_activity(db, activity_id, child_id, device_id)
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
    device = await _verify_device_owner(db, device_id, user.id)
    child_id = await _child_id_for_device(db, device)
    activity = await _resolve_activity(db, activity_id, child_id, device_id)
    if not activity:
        raise HTTPException(status_code=404, detail="Activity not found")
    await db.delete(activity)
    await db.commit()
    return {"ok": True}
