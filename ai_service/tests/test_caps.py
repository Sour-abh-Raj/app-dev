from datetime import datetime, timezone

import pytest

from app.caps import (LIFETIME_RETRY_AFTER_S, LIMITS, Kind, Period, Tier, buckets_for, cost_usd,
                      period_key, seconds_until_reset)

NOW = datetime(2026, 10, 21, 23, 30, tzinfo=timezone.utc)


def test_every_kind_is_capped_for_every_tier():
    for tier in Tier:
        for kind in Kind:
            assert LIMITS[tier][kind], f"{tier}/{kind} has no cap (O6 forbids uncapped routes)"


def test_free_tier_matches_spec():
    free = LIMITS[Tier.FREE]
    assert free[Kind.MEAL][0].period is Period.DAY and free[Kind.MEAL][0].max == 3
    assert free[Kind.CHAT][0].period is Period.LIFETIME and free[Kind.CHAT][0].max == 5
    assert free[Kind.PHOTO][0].max == 0 and free[Kind.RENDER][0].max == 0
    assert free[Kind.PLAN_REGEN][0].max == 0


def test_pro_tier_matches_spec():
    pro = LIMITS[Tier.PRO]
    assert pro[Kind.CHAT][0].max == 20 and pro[Kind.CHAT][0].period is Period.MONTH
    assert pro[Kind.RENDER][0].max == 1


def test_period_keys_respect_timezone():
    assert period_key(Period.DAY, NOW, "UTC") == "d:2026-10-21"
    assert period_key(Period.DAY, NOW, "Asia/Kolkata") == "d:2026-10-22"
    assert period_key(Period.MONTH, NOW, None) == "m:2026-10"
    assert period_key(Period.LIFETIME, NOW) == "life"
    assert period_key(Period.DAY, NOW, "Not/AZone") == "d:2026-10-21"


@pytest.mark.parametrize("period,tz,expected", [
    (Period.DAY, "UTC", 30 * 60),
    (Period.LIFETIME, "UTC", LIFETIME_RETRY_AFTER_S),
])
def test_seconds_until_reset(period, tz, expected):
    assert seconds_until_reset(period, NOW, tz) == expected


def test_month_reset_handles_december():
    dec = datetime(2026, 12, 31, 23, 0, tzinfo=timezone.utc)
    assert seconds_until_reset(Period.MONTH, dec, "UTC") == 3600


def test_buckets_include_all_limits():
    b = buckets_for(Tier.PRO, Kind.MEAL, NOW)
    assert [x.key for x in b] == ["meal|d:2026-10-21", "meal|m:2026-10"]


def test_cost():
    assert cost_usd("claude-opus-5-5", 1_000_000, 0) == pytest.approx(4.0)
    assert cost_usd("unknown-model", 0, 1_000_000) == pytest.approx(25.0)  # conservative
    assert cost_usd("mock", 10, 10) == 0
