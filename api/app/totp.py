"""TOTP-like code generation and verification.

Uses HMAC-SHA1 with a 5-minute step (300 seconds) to generate 6-digit codes.
Compatible with the Swift and JavaScript implementations in the agent and dashboards.
"""

import hashlib
import hmac
import struct
import time as time_module


STEP = 300  # 5 minutes


def generate_totp(secret_hex: str, step: int = STEP) -> str:
    """Generate a 6-digit TOTP code from a hex-encoded secret."""
    t = int(time_module.time()) // step
    return _code_for_counter(secret_hex, t)


def verify_totp(secret_hex: str, code: str, step: int = STEP, window: int = 1) -> bool:
    """Verify a TOTP code, checking current step +/- window for clock drift tolerance."""
    t = int(time_module.time()) // step
    for offset in range(-window, window + 1):
        if _code_for_counter(secret_hex, t + offset) == code:
            return True
    return False


def _code_for_counter(secret_hex: str, counter: int) -> str:
    key = bytes.fromhex(secret_hex)
    msg = struct.pack(">Q", counter)
    h = hmac.new(key, msg, hashlib.sha1).digest()
    offset = h[-1] & 0x0F
    truncated = struct.unpack(">I", h[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(truncated % 1_000_000).zfill(6)
