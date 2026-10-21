"""FirestoreStore against the emulator. Run via:
  firebase emulators:exec --only firestore "cd ai_service && .venv/bin/pytest -m emulator"
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from app.caps import Kind, Tier, buckets_for
from app.store import FirestoreStore, PromoError

pytestmark = [
    pytest.mark.emulator,
    pytest.mark.skipif(not os.environ.get("FIRESTORE_EMULATOR_HOST"),
                       reason="needs FIRESTORE_EMULATOR_HOST"),
]

NOW = datetime(2026, 10, 21, 12, tzinfo=timezone.utc)


@pytest.fixture
def fs():
    os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "forme-store-test")
    return FirestoreStore()


@pytest.fixture
def uid():
    return f"u-{uuid.uuid4().hex[:8]}"


def test_consume_is_atomic_and_mirrors_usage(fs, uid):
    b = buckets_for(Tier.FREE, Kind.MEAL, NOW)
    for _ in range(3):
        assert fs.consume(uid, b, "2026-10").allowed
    res = fs.consume(uid, b, "2026-10")
    assert not res.allowed and res.blocked.kind is Kind.MEAL
    user = fs.db.collection("users").document(uid).get().to_dict()
    assert user["ai_usage"] == {"month": "2026-10", "meal_n": 3}
    fs.refund(uid, b, "2026-10")
    assert fs.consume(uid, b, "2026-10").allowed


def test_tier_from_subscription_mirror(fs, uid):
    assert fs.tier(uid, NOW) is Tier.FREE
    fs.db.collection("subscriptions").document(uid).set({"active": True})
    assert fs.tier(uid, NOW) is Tier.PRO


def test_idempotency_records(fs, uid):
    assert fs.idem_begin(uid, "meal", "key-00000001")
    assert not fs.idem_begin(uid, "meal", "key-00000001")
    assert fs.idem_get(uid, "meal", "key-00000001") is None
    fs.idem_put(uid, "meal", "key-00000001", {"kcal": 1})
    assert fs.idem_get(uid, "meal", "key-00000001") == {"kcal": 1}
    assert fs.idem_begin(uid, "meal", "key-00000002")
    fs.idem_abort(uid, "meal", "key-00000002")
    assert fs.idem_begin(uid, "meal", "key-00000002")


def test_consume_reserves_spend_atomically(fs, uid):
    b = buckets_for(Tier.PRO, Kind.CHAT, NOW)
    fs.add_spend(uid, "2026-10", 1.45)
    assert fs.consume(uid, b, "2026-10", reserve_usd=0.03, spend_cap=1.50).allowed
    res = fs.consume(uid, b, "2026-10", reserve_usd=0.03, spend_cap=1.50)
    assert not res.allowed and res.spend_blocked
    assert fs.spend(uid, "2026-10") == pytest.approx(1.48)


def test_spend_ledger(fs, uid):
    fs.add_spend(uid, "2026-10", 0.25)
    fs.add_spend(uid, "2026-10", 0.5)
    assert fs.spend(uid, "2026-10") == pytest.approx(0.75)


def test_rate_limit(fs, uid):
    assert all(fs.rate_hit(f"t_{uid}", 3600, 3, NOW) for _ in range(3))
    assert not fs.rate_hit(f"t_{uid}", 3600, 3, NOW)


def test_promo_redeem_transaction(fs, uid):
    h = f"hash-{uuid.uuid4().hex}"
    fs.db.collection("promo_codes").document(h).set(
        {"uses": 0, "uses_max": 1, "tier": "pro", "grant_days": 30, "revoked": False,
         "expires_at": NOW + timedelta(days=10)})
    grant = fs.promo_redeem(uid, h, NOW)
    assert grant.tier == "pro"
    assert fs.tier(uid, NOW) is Tier.PRO
    user = fs.db.collection("users").document(uid).get().to_dict()
    assert user["entitlement"]["promo"] is True
    assert "pro" not in user["entitlement"]  # derived from promo_expires_at client-side
    with pytest.raises(PromoError) as e:
        fs.promo_redeem(uid, h, NOW)
    assert e.value.code == "exhausted"
    with pytest.raises(PromoError) as e:
        fs.promo_redeem(uid, "missing", NOW)
    assert e.value.code == "not_found"


def test_plans_are_versioned(fs, uid):
    assert fs.save_plan(uid, {"source": "ai"}) == 1
    assert fs.save_plan(uid, {"source": "ai"}) == 2


def test_profile_and_reports(fs, uid):
    assert fs.profile(uid) is None
    fs.db.collection("users").document(uid).set({
        "goal": {"type": "lose_fat"}, "level": "beginner", "equipment": ["dumbbells"],
        "days_per_week": 3, "mins": 30, "injuries": [], "profile": {"sex": "male"}})
    assert fs.profile(uid)["goal"] == "lose_fat"
    fs.save_checkin_report(uid, "c1", {"summary": "x"}, "done")
    snap = fs.db.collection("users").document(uid).collection("checkins").document("c1").get()
    assert snap.to_dict()["ai_status"] == "done"


def test_prompt_pins(fs):
    fs.set_prompt_pin("coach", "v1")
    assert fs.prompt_pins()["coach"] == "v1"
