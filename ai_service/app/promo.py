"""Server-side staff/test promo codes (O8). Codes are stored only as HMAC hashes;
plaintext codes never exist in the app or in Firestore."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import re
import urllib.request
from datetime import datetime

log = logging.getLogger("forme.promo")

_ALLOWED = re.compile(r"^[A-Z0-9-]{4,40}$")


def normalize(code: str) -> str | None:
    c = re.sub(r"\s+", "", code).upper()
    return c if _ALLOWED.match(c) else None


def code_hash(code: str, pepper: str) -> str:
    if not pepper:
        raise RuntimeError("PROMO_PEPPER is not configured")
    return hmac.new(pepper.encode(), code.encode(), hashlib.sha256).hexdigest()


def grant_revenuecat_promotional(secret: str, uid: str, expires_at: datetime) -> bool:
    """Mirror the grant into RevenueCat so the SDK's CustomerInfo shows `pro`.
    Returns False (and the Firestore mirror still applies) if RC is unreachable."""
    if not secret:
        log.warning("REVENUECAT_SECRET_KEY unset; promo granted in Firestore mirror only")
        return False
    url = (f"https://api.revenuecat.com/v1/subscribers/{uid}"
           "/entitlements/pro/promotional")
    body = json.dumps({"end_time_ms": int(expires_at.timestamp() * 1000)}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {secret}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return 200 <= resp.status < 300
    except Exception as e:  # never fail the redemption on a mirror error
        log.error("revenuecat promotional grant failed: %s", type(e).__name__)
        return False
