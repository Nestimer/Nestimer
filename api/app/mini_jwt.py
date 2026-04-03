"""Minimal JWT encode/decode using HMAC-SHA256.
No external dependencies — uses only Python stdlib.
"""
import base64
import hashlib
import hmac
import json
import time


class JWTError(Exception):
    pass


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(s: str) -> bytes:
    s += "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)


def encode(payload: dict, secret: str, algorithm: str = "HS256") -> str:
    if algorithm != "HS256":
        raise JWTError(f"Unsupported algorithm: {algorithm}")

    header = {"alg": "HS256", "typ": "JWT"}
    h = _b64url_encode(json.dumps(header, separators=(",", ":")).encode())
    p = _b64url_encode(json.dumps(payload, separators=(",", ":"), default=str).encode())
    signing_input = f"{h}.{p}"
    sig = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{_b64url_encode(sig)}"


def decode(token: str, secret: str, algorithms: list[str] | None = None) -> dict:
    try:
        parts = token.split(".")
        if len(parts) != 3:
            raise JWTError("Invalid token format")

        header = json.loads(_b64url_decode(parts[0]))
        alg = header.get("alg")
        allowed = algorithms or ["HS256"]
        if alg not in allowed:
            raise JWTError(f"Unsupported algorithm: {alg}")

        # Verify signature
        signing_input = f"{parts[0]}.{parts[1]}"
        expected_sig = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
        actual_sig = _b64url_decode(parts[2])
        if not hmac.compare_digest(expected_sig, actual_sig):
            raise JWTError("Invalid signature")

        payload = json.loads(_b64url_decode(parts[1]))

        # Check expiration
        if "exp" in payload:
            exp = payload["exp"]
            if isinstance(exp, (int, float)):
                pass  # already a timestamp
            elif isinstance(exp, str):
                try:
                    from datetime import datetime
                    exp = datetime.fromisoformat(exp).timestamp()
                except ValueError:
                    raise JWTError("Invalid exp format")
            else:
                raise JWTError("Invalid exp type")
            if time.time() > exp:
                raise JWTError("Token expired")

        return payload
    except JWTError:
        raise
    except Exception as e:
        raise JWTError(f"Invalid token: {e}")
