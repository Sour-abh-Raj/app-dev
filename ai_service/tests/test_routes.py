from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.providers.base import AiError
from app.store import is_pro

from .conftest import ONBOARDING, jpeg_b64


# ---------- auth ----------

def test_routes_require_auth(env):
    r = env.client.post("/v1/meal/analyze", json={"text": "toast"})
    assert r.status_code == 401
    assert r.headers["x-request-id"]


def test_request_id_is_echoed(env):
    r = env.post("/v1/meal/analyze", {"text": "toast"}, **{"X-Request-Id": "abc123"})
    assert r.headers["x-request-id"] == "abc123"


# ---------- plan ----------

def test_plan_generate_returns_valid_plan_and_versions(env):
    r = env.post("/v1/plan/generate", {"onboarding": ONBOARDING}, idem="plan-key-0001")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["version"] == 1 and body["source"] == "ai"
    assert len(body["mesocycle"]["weeks"]) == 4
    assert all(len(w["sessions"]) == 3 for w in body["mesocycle"]["weeks"])


def test_plan_generate_free_is_one_lifetime(env):
    assert env.post("/v1/plan/generate", {"onboarding": ONBOARDING}).status_code == 200
    r = env.post("/v1/plan/generate", {"onboarding": ONBOARDING})
    assert r.status_code == 429
    body = r.json()
    assert body["error"] == "cap_reached" and body["cap"] == "plan_generate"
    assert body["paywall"].startswith("forme://paywall")
    assert int(r.headers["Retry-After"]) == body["retry_after"]


def test_plan_ai_failure_applies_template_and_refunds(env):
    env.provider.fail_next = AiError("boom")
    r = env.post("/v1/plan/generate", {"onboarding": ONBOARDING})
    assert r.status_code == 200
    assert r.json()["source"] == "template" and r.json()["queued"] is True
    # refunded: the free lifetime generate is still available
    assert env.post("/v1/plan/generate", {"onboarding": ONBOARDING}).status_code == 200


def test_plan_regenerate_pro_only(env):
    env.store.users["u1"] = {"onboarding": ONBOARDING}
    body = {"uid": "u1", "week": 2, "adherence": {"planned_sessions": 3, "completed_sessions": 2}}
    assert env.post("/v1/plan/regenerate", body).status_code == 429
    env.make_pro()
    r = env.post("/v1/plan/regenerate", body)
    assert r.status_code == 200 and r.json()["week_index"] == 2


def test_plan_regenerate_rejects_other_uid(env):
    body = {"uid": "someone-else", "week": 2,
            "adherence": {"planned_sessions": 3, "completed_sessions": 2}}
    assert env.post("/v1/plan/regenerate", body).status_code == 403


# ---------- idempotency (O7) ----------

def test_idempotent_replay_does_not_double_charge(env):
    env.make_pro()
    a = env.post("/v1/meal/analyze", {"text": "oats"}, idem="meal-key-0001")
    b = env.post("/v1/meal/analyze", {"text": "oats"}, idem="meal-key-0001")
    assert a.status_code == b.status_code == 200 and a.json() == b.json()
    assert len(env.provider.calls) == 1
    assert env.store.users["u1"]["ai_usage"]["meal_n"] == 1


def test_bad_idempotency_key(env):
    assert env.post("/v1/meal/analyze", {"text": "x"}, idem="bad key!").status_code == 400


# ---------- meals ----------

def test_meal_free_cap_three_per_day(env):
    for i in range(3):
        assert env.post("/v1/meal/analyze", {"text": f"meal {i}"}).status_code == 200
    r = env.post("/v1/meal/analyze", {"text": "meal 4"})
    assert r.status_code == 429 and r.json()["cap"] == "meal"
    assert r.json()["paywall"].endswith("placement=cap_meal")


def test_meal_photo_is_downscaled(env):
    r = env.post("/v1/meal/analyze", {"photo_b64": jpeg_b64(w=3000, h=2000)})
    assert r.status_code == 200
    body = r.json()
    assert {"kcal", "P", "C", "F", "confidence", "model"} <= set(body)


def test_meal_requires_input(env):
    assert env.post("/v1/meal/analyze", {}).status_code == 422


def test_meal_bad_image(env):
    r = env.post("/v1/meal/analyze", {"photo_b64": "bm90IGFuIGltYWdl"})
    assert r.status_code == 422 and r.json()["error"] == "bad_image"


def test_meal_ai_failure_is_503_and_refunded(env):
    env.provider.fail_next = AiError("down")
    r = env.post("/v1/meal/analyze", {"text": "eggs"})
    assert r.status_code == 503 and r.headers["Retry-After"] == "30"
    assert env.store.users["u1"]["ai_usage"]["meal_n"] == 0


def test_meal_cache_hit_skips_model(env):
    env.make_pro()
    env.post("/v1/meal/analyze", {"text": "Same Meal"})
    env.post("/v1/meal/analyze", {"text": "same meal"})
    assert len(env.provider.calls) == 1


# ---------- coach ----------

def test_chat_free_lifetime_five(env):
    msg = {"messages": [{"role": "user", "content": "How do I squat deeper?"}]}
    for _ in range(5):
        assert env.post("/v1/coach/chat", msg).status_code == 200
    assert env.post("/v1/coach/chat", msg).status_code == 429


def test_chat_red_flag_bypasses_model_and_cap(env):
    msg = {"messages": [{"role": "user", "content": "I get chest pain when I run"}]}
    r = env.post("/v1/coach/chat", msg)
    assert r.status_code == 200 and r.json()["flagged"] is True
    assert env.provider.calls == []


def test_chat_uses_last_12_messages(env):
    msgs = [{"role": "user" if i % 2 == 0 else "assistant", "content": f"m{i}"} for i in range(21)]
    assert env.post("/v1/coach/chat", {"messages": msgs}).status_code == 200


def test_chat_last_message_must_be_user(env):
    msgs = [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "yo"}]
    assert env.post("/v1/coach/chat", {"messages": msgs}).status_code == 422


# ---------- check-in ----------

def _checkin_body(env, uid="u1", cid="ck2", week=2, history=True):
    photos = env.add_photos(uid, cid)
    hist = []
    if history:
        hist = [{"week_index": 0, "weight_kg": 80.0, "photos": env.add_photos(uid, "base")}]
    return {"checkin_id": cid, "week_index": week, "weight_kg": 79.2, "photos": photos,
            "survey": {"adherence": 4, "sleep": 3, "soreness": 2, "motivation": 4},
            "history": hist}


def test_checkin_free_user_gets_paywall(env):
    r = env.post("/v1/checkin/analyze", _checkin_body(env))
    assert r.status_code == 429 and r.json()["cap"] == "photo"


def test_checkin_report_for_pro(env):
    env.make_pro()
    r = env.post("/v1/checkin/analyze", _checkin_body(env))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "done" and body["morph_ready"] is True
    metrics = {d["metric"]: d for d in body["ai_report"]["deltas"]}
    assert metrics["weight_kg"]["from"] == 80.0 and metrics["weight_kg"]["to"] == 79.2
    assert all(0 <= d["confidence"] <= 1 for d in metrics.values())
    assert env.provider.calls[-1]["images"] == 5  # baseline front+side + current 3
    assert env.store.checkins[("u1", "ck2")]["ai_status"] == "done"


def test_checkin_is_idempotent_per_checkin_id(env):
    env.make_pro()
    body = _checkin_body(env)
    env.post("/v1/checkin/analyze", body)
    env.post("/v1/checkin/analyze", body)
    assert len(env.provider.calls) == 1


def test_checkin_rejects_foreign_photos(env):
    env.make_pro()
    body = _checkin_body(env)
    body["photos"][0]["path"] = "progress-photos/other/ck/front.jpg"
    assert env.post("/v1/checkin/analyze", body).status_code == 403


def test_checkin_requires_three_angles(env):
    env.make_pro()
    body = _checkin_body(env)
    body["photos"][2]["angle"] = "front"
    assert env.post("/v1/checkin/analyze", body).status_code == 422


def test_checkin_missing_upload_is_409_and_retryable(env):
    env.make_pro()
    body = _checkin_body(env)
    del env.loader.files[body["photos"][0]["path"]]
    r = env.post("/v1/checkin/analyze", body)
    assert r.status_code == 409 and r.json()["error"] == "upload_incomplete"
    env.add_photos("u1", "ck2")
    assert env.post("/v1/checkin/analyze", body).status_code == 200


def test_checkin_ai_failure_is_queued_and_retry_runs(env):
    env.make_pro()
    body = _checkin_body(env)
    env.provider.fail_next = AiError("timeout")
    r = env.post("/v1/checkin/analyze", body)
    assert r.status_code == 200 and r.json()["status"] == "queued"
    assert env.store.checkins[("u1", "ck2")]["ai_status"] == "queued"
    r2 = env.post("/v1/checkin/analyze", body)
    assert r2.json()["status"] == "done"


# ---------- preview stub ----------

def test_preview_quota(env):
    env.make_pro()
    body = {"photo": "progress-photos/u1/ck/front.jpg", "goal": "lean"}
    r = env.post("/v1/preview/render", body)
    assert r.status_code == 200 and r.json()["stub"] is True
    assert env.post("/v1/preview/render", body).status_code == 429


def test_preview_free_is_paywalled(env):
    r = env.post("/v1/preview/render", {"photo": "progress-photos/u1/a/front.jpg", "goal": "x"})
    assert r.status_code == 429 and r.json()["cap"] == "render"


# ---------- spend ceiling ----------

def test_spend_ceiling_blocks_before_calling(env):
    env.make_pro()
    month = datetime.now(timezone.utc).strftime("%Y-%m")
    env.store.add_spend("u1", month, 1.49)
    r = env.post("/v1/meal/analyze", {"text": "rice"})
    assert r.status_code == 429 and r.json()["cap"] == "spend"
    assert env.provider.calls == []
    assert env.store.users.get("u1", {}).get("ai_usage", {}).get("meal_n", 0) == 0  # not counted


def test_burst_limit(env):
    from app import main

    main._burst.rates.clear()
    env.make_pro()
    codes = [env.post("/v1/meal/analyze", {"text": f"m{i}"}).status_code for i in range(32)]
    assert 429 in codes


# ---------- entitlement mirror ----------

def test_is_pro_rules():
    now = datetime(2026, 10, 21, tzinfo=timezone.utc)
    assert not is_pro(None, now)
    assert is_pro({"active": True}, now)
    assert is_pro({"active": False, "grace_until": now + timedelta(days=1)}, now)
    assert not is_pro({"active": False, "grace_until": now - timedelta(days=1)}, now)
    assert is_pro({"promo": {"expires_at": (now + timedelta(days=3)).isoformat()}}, now)


def test_expired_user_keeps_free_allowances(env):
    env.store.subs["u1"] = {"active": False, "grace_until": "2020-01-01T00:00:00Z"}
    assert env.post("/v1/meal/analyze", {"text": "toast"}).status_code == 200
    r = env.post("/v1/checkin/analyze", _checkin_body(env))
    assert r.status_code == 429


# ---------- spend reservation (O6 under concurrency) ----------

def test_reservation_is_atomic_under_threads():
    import threading

    from app.store import MemoryStore

    s = MemoryStore()
    s.add_spend("u", "2026-10", 1.40)
    wins = []
    barrier = threading.Barrier(50)

    def go():
        barrier.wait()
        wins.append(s.consume("u", [], "2026-10", reserve_usd=0.03, spend_cap=1.50).allowed)

    threads = [threading.Thread(target=go) for _ in range(50)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sum(wins) == 3
    assert s.spend("u", "2026-10") <= 1.50 + 1e-9


def test_spend_reconciles_to_actual_cost(env, monkeypatch):
    from app.caps import cost_usd

    monkeypatch.setenv("MOCK_USAGE_MODEL", "claude-opus-5-5")
    env.make_pro()
    month = datetime.now(timezone.utc).strftime("%Y-%m")
    assert env.post("/v1/meal/analyze", {"text": "rice"}).status_code == 200
    assert env.store.spend("u1", month) == pytest.approx(cost_usd("claude-opus-5-5", 1000, 400))
    # Failure releases the reservation; cache hits cost nothing.
    env.provider.fail_next = AiError("down")
    env.post("/v1/meal/analyze", {"text": "pasta"})
    env.post("/v1/meal/analyze", {"text": "rice"})
    assert env.store.spend("u1", month) == pytest.approx(cost_usd("claude-opus-5-5", 1000, 400))


def test_render_stub_costs_nothing(env):
    env.make_pro()
    month = datetime.now(timezone.utc).strftime("%Y-%m")
    env.post("/v1/preview/render", {"photo": "progress-photos/u1/c/front.jpg", "goal": "x"})
    assert env.store.spend("u1", month) == 0
