import re
from datetime import time, datetime
from typing import Optional

from pydantic import BaseModel, field_validator, Field


# --- Auth ---
class UserCreate(BaseModel):
    email: str
    password: str = Field(min_length=6)
    name: str = Field(min_length=1)

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", v):
            raise ValueError("Invalid email format")
        return v.lower().strip()


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
    name: str = Field(min_length=1, max_length=100)
    child_name: str = Field(min_length=1, max_length=100)


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
TIME_PATTERN = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


def validate_time_str(v: str | None) -> str | None:
    if v is None:
        return None
    if not TIME_PATTERN.match(v):
        raise ValueError(f"Invalid time format '{v}', expected HH:MM (00:00-23:59)")
    return v


class PolicyUpdate(BaseModel):
    downtime_enabled: Optional[bool] = None
    downtime_start: Optional[str] = None
    downtime_end: Optional[str] = None
    downtime_weekday_start: Optional[str] = None
    downtime_weekday_end: Optional[str] = None
    downtime_weekend_start: Optional[str] = None
    downtime_weekend_end: Optional[str] = None
    screen_time_enabled: Optional[bool] = None
    screen_time_limit_minutes: Optional[int] = Field(None, ge=15, le=1440)
    screen_time_weekend_limit_minutes: Optional[int] = Field(None, ge=15, le=1440)

    @field_validator(
        "downtime_start", "downtime_end",
        "downtime_weekday_start", "downtime_weekday_end",
        "downtime_weekend_start", "downtime_weekend_end",
    )
    @classmethod
    def check_time_format(cls, v):
        return validate_time_str(v)


class PolicyOut(BaseModel):
    downtime_enabled: bool
    downtime_start: str
    downtime_end: str
    downtime_weekday_start: Optional[str] = None
    downtime_weekday_end: Optional[str] = None
    downtime_weekend_start: Optional[str] = None
    downtime_weekend_end: Optional[str] = None
    screen_time_enabled: bool
    screen_time_limit_minutes: int
    screen_time_weekend_limit_minutes: Optional[int] = None


# --- Usage ---
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class UsageReport(BaseModel):
    """Sent by the macOS agent to report usage."""
    date: str
    total_minutes: float = Field(ge=0.0)

    @field_validator("date")
    @classmethod
    def validate_date(cls, v: str) -> str:
        if not DATE_PATTERN.match(v):
            raise ValueError("Invalid date format, expected YYYY-MM-DD")
        return v


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
    used_minutes_today: float
