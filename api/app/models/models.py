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


class Device(Base):
    """A child's Mac registered to a parent."""
    __tablename__ = "devices"

    id = Column(String, primary_key=True, default=gen_uuid)
    owner_id = Column(String, ForeignKey("users.id"), nullable=False)
    name = Column(String, nullable=False)  # e.g. "Alex's MacBook"
    child_name = Column(String, nullable=False)
    api_token = Column(String, unique=True, nullable=False)  # agent auth token
    shared_secret = Column(String, nullable=True)  # TOTP shared secret (hex-encoded, 40 chars)
    agent_version = Column(String, nullable=True)  # e.g. "1.7"
    last_seen = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    owner = relationship("User", back_populates="devices")
    policy = relationship("Policy", back_populates="device", uselist=False, cascade="all, delete-orphan")
    usage_logs = relationship("UsageLog", back_populates="device", cascade="all, delete-orphan")
    activities = relationship("Activity", back_populates="device", cascade="all, delete-orphan")


class Policy(Base):
    """Time control policy for a device."""
    __tablename__ = "policies"

    id = Column(String, primary_key=True, default=gen_uuid)
    device_id = Column(String, ForeignKey("devices.id"), unique=True, nullable=False)

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


class Activity(Base):
    """A scheduled activity (e.g. English class) — screen time is not counted during these windows."""
    __tablename__ = "activities"

    id = Column(String, primary_key=True, default=gen_uuid)
    device_id = Column(String, ForeignKey("devices.id"), nullable=False, index=True)
    name = Column(String, nullable=False)  # e.g. "English"
    day_of_week = Column(Integer, nullable=False)  # 0=Mon, 6=Sun
    start_time = Column(Time, nullable=False)
    end_time = Column(Time, nullable=False)
    buffer_before_minutes = Column(Integer, default=5)
    buffer_after_minutes = Column(Integer, default=5)
    enabled = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    device = relationship("Device", back_populates="activities")
