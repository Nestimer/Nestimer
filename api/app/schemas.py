from datetime import time, datetime
from typing import Optional

from pydantic import BaseModel, EmailStr


# --- Auth ---
class UserCreate(BaseModel):
    email: str
    password: str
    name: str


class UserLogin(BaseModel):
    email: str
    password: str


class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserOut(BaseModel):
    id: str
    email: str
    name: str


# --- Device ---
class DeviceCreate(BaseModel):
    name: str
    child_name: str


class DeviceOut(BaseModel):
    id: str
    name: str
    child_name: str
    api_token: str
    last_seen: Optional[datetime] = None
    created_at: datetime


class DeviceListOut(BaseModel):
    id: str
    name: str
    child_name: str
    last_seen: Optional[datetime] = None


# --- Policy ---
class PolicyUpdate(BaseModel):
    downtime_enabled: Optional[bool] = None
    downtime_start: Optional[str] = None  # "HH:MM"
    downtime_end: Optional[str] = None
    downtime_weekday_start: Optional[str] = None
    downtime_weekday_end: Optional[str] = None
    downtime_weekend_start: Optional[str] = None
    downtime_weekend_end: Optional[str] = None
    screen_time_enabled: Optional[bool] = None
    screen_time_limit_minutes: Optional[int] = None
    screen_time_weekend_limit_minutes: Optional[int] = None


class PolicyOut(BaseModel):
    downtime_enabled: bool
    downtime_start: str  # "HH:MM"
    downtime_end: str
    downtime_weekday_start: Optional[str] = None
    downtime_weekday_end: Optional[str] = None
    downtime_weekend_start: Optional[str] = None
    downtime_weekend_end: Optional[str] = None
    screen_time_enabled: bool
    screen_time_limit_minutes: int
    screen_time_weekend_limit_minutes: Optional[int] = None


# --- Usage ---
class UsageReport(BaseModel):
    """Sent by the macOS agent to report usage."""
    date: str  # YYYY-MM-DD
    total_minutes: float


class UsageOut(BaseModel):
    date: str
    total_minutes: float


# --- Agent config (what the agent polls) ---
class AgentConfig(BaseModel):
    """Full config the agent needs to enforce rules."""
    downtime_enabled: bool
    downtime_start: str
    downtime_end: str
    screen_time_enabled: bool
    screen_time_limit_minutes: int
    # Today's usage so far
    used_minutes_today: float
