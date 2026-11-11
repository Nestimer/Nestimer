import uuid
from datetime import datetime, time, timezone

from sqlalchemy import Column, String, Integer, Boolean, DateTime, Time, ForeignKey, Float, UniqueConstraint, Index
from sqlalchemy.orm import relationship

from ..database import Base


def gen_uuid():
    return str(uuid.uuid4())


class User(Base):
    """Parent user account."""
    __tablename__ = "users"

    id = Column(String, primary_key=True, default=gen_uuid)
    email = Column(String, unique=True, nullable=False, index=True)
    hashed_password = Column(String, nullable=False)
    name = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    devices = relationship("Device", back_populates="owner", cascade="all, delete-orphan")


class Child(Base):
    """A child. Owns the policy, activities and bonus window shared by all their devices."""
    __tablename__ = "children"

    id = Column(String, primary_key=True, default=gen_uuid)
    owner_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    name = Column(String, nullable=False)
    bonus_until = Column(DateTime(timezone=True), nullable=True)  # parent-granted temporary unlock
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    devices = relationship("Device", back_populates="child")


class Device(Base):
    """A child's Mac registered to a parent."""
    __tablename__ = "devices"

    id = Column(String, primary_key=True, default=gen_uuid)
    owner_id = Column(String, ForeignKey("users.id"), nullable=False)
    child_id = Column(String, ForeignKey("children.id"), nullable=True, index=True)
    platform = Column(String, nullable=False, default="macos")  # macos | android | ios
    daily_cap_minutes = Column(Integer, nullable=True)  # per-device ceiling; null = no ceiling
    name = Column(String, nullable=False)  # e.g. "Alex's MacBook"
    child_name = Column(String, nullable=False)
    api_token = Column(String, unique=True, nullable=False)  # agent auth token
    shared_secret = Column(String, nullable=True)  # TOTP shared secret (hex-encoded, 40 chars)
    agent_version = Column(String, nullable=True)  # e.g. "1.7"
    # Highest TOTP step accepted by /agent/verify-totp; codes at or below it are spent.
    last_totp_step = Column(Integer, nullable=True)
    last_seen = Column(DateTime(timezone=True), nullable=True)
    bonus_until = Column(DateTime(timezone=True), nullable=True)  # parent-granted temporary unlock
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    owner = relationship("User", back_populates="devices")
    child = relationship("Child", back_populates="devices")
    policy = relationship("Policy", back_populates="device", uselist=False, cascade="all, delete-orphan")
    usage_logs = relationship("UsageLog", back_populates="device", cascade="all, delete-orphan")
    activities = relationship("Activity", back_populates="device", cascade="all, delete-orphan")


class Policy(Base):
    """Time control policy for a device."""
    __tablename__ = "policies"

    id = Column(String, primary_key=True, default=gen_uuid)
    device_id = Column(String, ForeignKey("devices.id"), unique=True, nullable=True)
    child_id = Column(String, ForeignKey("children.id"), unique=True, nullable=True)

    # Downtime: when the computer is fully locked
    downtime_enabled = Column(Boolean, default=True)
    downtime_start = Column(Time, default=time(22, 0))   # 22:00
    downtime_end = Column(Time, default=time(8, 0))       # 08:00

    # Per-day downtime overrides (JSON-like, but we keep it simple with per-day columns)
    # Weekday = Mon-Fri, Weekend = Sat-Sun
    downtime_weekday_start = Column(Time, nullable=True)  # if set, overrides for Mon-Fri
    downtime_weekday_end = Column(Time, nullable=True)
    downtime_weekend_start = Column(Time, nullable=True)  # if set, overrides for Sat-Sun
    downtime_weekend_end = Column(Time, nullable=True)

    # Screen time: max hours per day outside downtime
    screen_time_enabled = Column(Boolean, default=True)
    screen_time_limit_minutes = Column(Integer, default=120)  # 2 hours default

    # Weekend can have different limit
    screen_time_weekend_limit_minutes = Column(Integer, nullable=True)  # if null, use weekday limit

    # Per-day overrides (Mon=0, Sun=6). If null, fall back to weekend/weekday/default.
    screen_time_mon_minutes = Column(Integer, nullable=True)
    screen_time_tue_minutes = Column(Integer, nullable=True)
    screen_time_wed_minutes = Column(Integer, nullable=True)
    screen_time_thu_minutes = Column(Integer, nullable=True)
    screen_time_fri_minutes = Column(Integer, nullable=True)
    screen_time_sat_minutes = Column(Integer, nullable=True)
    screen_time_sun_minutes = Column(Integer, nullable=True)

    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    device = relationship("Device", back_populates="policy")


class UsageLog(Base):
    """Daily usage tracking reported by the agent."""
    __tablename__ = "usage_logs"
    __table_args__ = (
        UniqueConstraint("device_id", "date", name="uq_usage_device_date"),
        Index("ix_usage_device_date", "device_id", "date"),
    )

    id = Column(String, primary_key=True, default=gen_uuid)
    device_id = Column(String, ForeignKey("devices.id"), nullable=False)
    date = Column(String, nullable=False)  # YYYY-MM-DD
    total_minutes = Column(Float, default=0.0)
    last_updated = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    device = relationship("Device", back_populates="usage_logs")


class UsageReportLog(Base):
    """Every usage report as received, kept one week, to trace a disputed daily count.

    No FK on device_id: the journal must not block deleting a device, and stale rows
    age out on their own.
    """
    __tablename__ = "usage_reports"
    __table_args__ = (
        Index("ix_usage_reports_device_received", "device_id", "received_at"),
        Index("ix_usage_reports_received", "received_at"),
    )

    id = Column(String, primary_key=True, default=gen_uuid)
    device_id = Column(String, nullable=False)
    date = Column(String, nullable=False)  # the agent's local YYYY-MM-DD
    reported_minutes = Column(Float, nullable=False)
    stored_minutes = Column(Float, nullable=False)  # after the clamp
    received_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


class Activity(Base):
    """A scheduled activity (e.g. English class) — screen time is not counted during these windows."""
    __tablename__ = "activities"

    id = Column(String, primary_key=True, default=gen_uuid)
    device_id = Column(String, ForeignKey("devices.id"), nullable=True, index=True)
    child_id = Column(String, ForeignKey("children.id"), nullable=True, index=True)
    name = Column(String, nullable=False)  # e.g. "English"
    day_of_week = Column(Integer, nullable=False)  # 0=Mon, 6=Sun
    start_time = Column(Time, nullable=False)
    end_time = Column(Time, nullable=False)
    buffer_before_minutes = Column(Integer, default=5)
    buffer_after_minutes = Column(Integer, default=5)
    enabled = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    device = relationship("Device", back_populates="activities")


class RateLimitHit(Base):
    """One rate-limited attempt (login, register, TOTP verify).

    Lives in the database rather than process memory so the limit holds across all
    uvicorn workers. Every check deletes rows older than `SWEEP_AFTER` for all keys,
    so IPs that never return don't accumulate.
    """
    __tablename__ = "rate_limit_hits"
    __table_args__ = (
        Index("ix_rate_limit_scope_key_at", "scope", "key", "created_at"),
        Index("ix_rate_limit_created_at", "created_at"),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    scope = Column(String, nullable=False)
    key = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False)
