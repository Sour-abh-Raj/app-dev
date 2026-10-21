from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app import promo

from .conftest import Env


def seed(env: Env, code: str, **fields) -> str:
    h = promo.code_hash(promo.normalize(code), "test-pepper")
    env.store.promos[h] = {"uses": 0, "uses_max": 10, "tier": "pro", "grant_days": 30,
                           "revoked": False, **fields}
    return h


def test_normalize():
    assert promo.normalize(" forme-team 01 ") == "FORME-TEAM01"
    assert promo.normalize("bad$code") is None
    assert promo.normalize("ab") is None


def test_hash_requires_pepper():
    with pytest.raises(RuntimeError):
        promo.code_hash("X", "")


def test_redeem_grants_and_audits(env):
    h = seed(env, "TEAM-2026")
    r = env.post("/v1/promo/redeem", {"code": "team-2026"})
    assert r.status_code == 200, r.text
    assert r.json()["result"] == "granted" and r.json()["tier"] == "pro"
    assert env.store.promos[h]["uses"] == 1
    assert env.store.redemptions[-1]["result"] == "granted"
    assert env.store.tier("u1", datetime.now(timezone.utc)).value == "pro"


@pytest.mark.parametrize("fields,code", [
    ({"revoked": True}, "revoked"),
    ({"expires_at": datetime.now(timezone.utc) - timedelta(days=1)}, "expired"),
    ({"uses": 10, "uses_max": 10}, "exhausted"),
])
def test_redeem_errors(env, fields, code):
    seed(env, "TEAM-ERR", **fields)
    r = env.post("/v1/promo/redeem", {"code": "TEAM-ERR"})
    assert r.status_code == 400 and r.json()["error"] == code
    assert env.store.redemptions[-1]["result"] == code


def test_redeem_unknown_and_malformed(env):
    assert env.post("/v1/promo/redeem", {"code": "NOPE-0000"}).json()["error"] == "not_found"
    assert env.post("/v1/promo/redeem", {"code": "bad$$code"}).json()["error"] == "not_found"


def test_redeem_once_per_user(env):
    seed(env, "TEAM-ONCE")
    assert env.post("/v1/promo/redeem", {"code": "TEAM-ONCE"}).status_code == 200
    r = env.post("/v1/promo/redeem", {"code": "TEAM-ONCE"})
    assert r.json()["error"] == "already_redeemed"


def test_redeem_rate_limited(env):
    codes = [env.post("/v1/promo/redeem", {"code": f"GUESS-{i:04d}"}).status_code
             for i in range(6)]
    assert codes[:5] == [400] * 5 and codes[5] == 429
    assert env.store.redemptions[-1]["result"] == "rate_limited"


def test_redeem_requires_auth(env):
    assert env.client.post("/v1/promo/redeem", json={"code": "X-1234"}).status_code == 401
