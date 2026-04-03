import uuid
from datetime import datetime, time

from sqlalchemy import Column, String, Integer, Boolean, DateTime, Time, ForeignKey, Float
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
    created_at = Column(DateTime, default=datetime.utcnow)

    devices = relationship("Device", back_populates="owner", cascade="all, delete-orphan")


class Device(Base):
    """A child's Mac registered to a parent."""
    __tablename__ = "devices"

    id = Column(String, primary_key=True, default=gen_uuid)
    owner_id = Column(String, ForeignKey("users.id"), nullable=False)
    name = Column(String, nullable=False)  # e.g. "Misha's MacBook"
    child_name = Column(String, nullable=False)
    api_token = Column(String, unique=True, nullable=False)  # agent auth token
    last_seen = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    owner = relationship("User", back_populates="devices")
    policy = relationship("Policy", back_populates="device", uselist=False, cascade="all, delete-orphan")
    usage_logs = relationship("UsageLog", back_populates="device", cascade="all, delete-orphan")


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

    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    device = relationship("Device", back_populates="policy")


class UsageLog(Base):
    """Daily usage tracking reported by the agent."""
    __tablename__ = "usage_logs"

    id = Column(String, primary_key=True, default=gen_uuid)
    device_id = Column(String, ForeignKey("devices.id"), nullable=False)
    date = Column(String, nullable=False)  # YYYY-MM-DD
    total_minutes = Column(Float, default=0.0)
    last_updated = Column(DateTime, default=datetime.utcnow)

    device = relationship("Device", back_populates="usage_logs")
