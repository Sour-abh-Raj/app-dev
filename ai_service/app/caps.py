"""O6 cap policy: every AI route is capped per user. Pure functions only — the
atomic counting lives in the store."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from enum import Enum
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


class Tier(str, Enum):
    FREE = "free"  # never subscribed, or expired (grace mode == free allowances)
    PRO = "pro"  # active, trialing, billing-grace, or promo


class Kind(str, Enum):
    PLAN_GENERATE = "plan_generate"
    PLAN_REGEN = "plan_regen"
    PHOTO = "photo"
    MEAL = "meal"
    CHAT = "chat"
    RENDER = "render"


class Period(str, Enum):
    DAY = "day"
    MONTH = "month"
    LIFETIME = "life"


@dataclass(frozen=True)
class Limit:
    period: Period
    max: int


# A limit of 0 means "not included in this tier" (the 429 carries the paywall link).
LIMITS: dict[Tier, dict[Kind, tuple[Limit, ...]]] = {
    Tier.FREE: {
        Kind.PLAN_GENERATE: (Limit(Period.LIFETIME, 1),),  # 1 static starter plan
        Kind.PLAN_REGEN: (Limit(Period.MONTH, 0),),
        Kind.PHOTO: (Limit(Period.MONTH, 0),),
        Kind.MEAL: (Limit(Period.DAY, 3),),
        Kind.CHAT: (Limit(Period.LIFETIME, 5),),  # 5 total chat messages
        Kind.RENDER: (Limit(Period.MONTH, 0),),
    },
    Tier.PRO: {
        Kind.PLAN_GENERATE: (Limit(Period.MONTH, 3),),
        Kind.PLAN_REGEN: (Limit(Period.MONTH, 6),),
        Kind.PHOTO: (Limit(Period.MONTH, 6),),  # weekly check-ins + a retry
        Kind.MEAL: (Limit(Period.DAY, 15), Limit(Period.MONTH, 150)),
        Kind.CHAT: (Limit(Period.MONTH, 20),),
        Kind.RENDER: (Limit(Period.MONTH, 1),),
    },
}

LIFETIME_RETRY_AFTER_S = 30 * 24 * 3600


def _tz(name: str | None) -> ZoneInfo:
    try:
        return ZoneInfo(name or "UTC")
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("UTC")


def period_key(period: Period, now: datetime, tz_name: str | None = None) -> str:
    local = now.astimezone(_tz(tz_name))
    if period is Period.DAY:
        return f"d:{local:%Y-%m-%d}"
    if period is Period.MONTH:
        return f"m:{local:%Y-%m}"
    return "life"


def seconds_until_reset(period: Period, now: datetime, tz_name: str | None = None) -> int:
    local = now.astimezone(_tz(tz_name))
    if period is Period.DAY:
        nxt = (local + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    elif period is Period.MONTH:
        y, m = (local.year + 1, 1) if local.month == 12 else (local.year, local.month + 1)
        nxt = local.replace(year=y, month=m, day=1, hour=0, minute=0, second=0, microsecond=0)
    else:
        return LIFETIME_RETRY_AFTER_S
    return max(1, int((nxt - local).total_seconds()))


@dataclass(frozen=True)
class Bucket:
    kind: Kind
    key: str  # e.g. "meal|d:2026-10-21"
    max: int
    period: Period


def buckets_for(
    tier: Tier, kind: Kind, now: datetime, tz_name: str | None = None
) -> list[Bucket]:
    return [
        Bucket(kind, f"{kind.value}|{period_key(lim.period, now, tz_name)}", lim.max, lim.period)
        for lim in LIMITS[tier][kind]
    ]


def month_key(now: datetime) -> str:
    return f"{now.astimezone(timezone.utc):%Y-%m}"


# USD per 1M tokens (input, output). Used only for the spend ledger.
PRICES_PER_MTOK: dict[str, tuple[float, float]] = {
    "claude-opus-5-5": (4.00, 20.00),
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-haiku-5-5": (0.10, 0.50),
    "mock": (0.0, 0.0),
}


def cost_usd(model: str, input_tokens: int, output_tokens: int) -> float:
    pin, pout = PRICES_PER_MTOK.get(model, PRICES_PER_MTOK["claude-opus-5-5"])
    return (input_tokens * pin + output_tokens * pout) / 1_000_000
