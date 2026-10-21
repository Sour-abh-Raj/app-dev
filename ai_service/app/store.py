"""Persistence behind the AI service. `MemoryStore` backs tests and offline dev;
`FirestoreStore` is production. Both implement the same atomic operations."""

from __future__ import annotations

import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Protocol

from .caps import Bucket, Kind, Tier


@dataclass
class ConsumeResult:
    allowed: bool
    blocked: Bucket | None = None
    spend_blocked: bool = False


class StoreBusy(Exception):
    """Contention or a transient backend error; safe for the client to retry.
    The request is denied (fail closed), never let through uncounted."""


class PromoError(Exception):
    """Raised with a stable machine code: not_found, revoked, expired, exhausted,
    already_redeemed."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


@dataclass
class PromoGrant:
    tier: str
    expires_at: datetime


def is_pro(sub: dict[str, Any] | None, now: datetime) -> bool:
    if not sub:
        return False
    if sub.get("active"):
        return True
    grace = sub.get("grace_until")
    if grace and _as_dt(grace) > now:
        return True  # billing-issue grace keeps Pro while the store retries
    promo = sub.get("promo") or {}
    exp = promo.get("expires_at")
    return bool(exp and _as_dt(exp) > now)


def _as_dt(v: Any) -> datetime:
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    return datetime.fromisoformat(str(v).replace("Z", "+00:00"))


class Store(Protocol):
    def tier(self, uid: str, now: datetime) -> Tier: ...
    def user_tz(self, uid: str) -> str | None: ...
    def consume(self, uid: str, buckets: list[Bucket], month: str,
                reserve_usd: float = 0.0, spend_cap: float = float("inf")) -> ConsumeResult:
        """Atomically: check every bucket and the spend ceiling, then count the
        call and reserve its worst-case cost. All or nothing."""
        ...
    def refund(self, uid: str, buckets: list[Bucket], month: str) -> None: ...
    def spend(self, uid: str, month: str) -> float: ...
    def add_spend(self, uid: str, month: str, usd: float) -> None: ...
    def idem_get(self, uid: str, route: str, key: str) -> dict | None: ...
    def idem_begin(self, uid: str, route: str, key: str) -> bool: ...
    def idem_put(self, uid: str, route: str, key: str, response: dict) -> None: ...
    def idem_abort(self, uid: str, route: str, key: str) -> None: ...
    def cache_get(self, h: str) -> dict | None: ...
    def cache_put(self, h: str, value: dict) -> None: ...
    def rate_hit(self, key: str, window_s: int, max_hits: int, now: datetime) -> bool: ...
    def promo_redeem(self, uid: str, code_hash: str, now: datetime) -> PromoGrant: ...
    def promo_audit(self, uid: str, code_hash: str, result: str, now: datetime) -> None: ...
    def prompt_pins(self) -> dict[str, str]: ...
    def set_prompt_pin(self, route: str, version: str) -> None: ...
    def save_checkin_report(self, uid: str, checkin_id: str, report: dict | None,
                            status: str) -> None: ...
    def save_plan(self, uid: str, plan: dict) -> int: ...
    def profile(self, uid: str) -> dict | None: ...


# Map usage kinds to the client-visible users/{uid}.ai_usage counters.
USAGE_FIELD = {
    Kind.PHOTO: "photo_n",
    Kind.MEAL: "meal_n",
    Kind.CHAT: "chat_n",
    Kind.RENDER: "renders_n",
}


class MemoryStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.subs: dict[str, dict] = {}
        self.users: dict[str, dict] = {}
        self.counters: dict[tuple[str, str], int] = {}
        self.spend_: dict[tuple[str, str], float] = {}
        self.idem: dict[tuple[str, str, str], dict | None] = {}
        self.cache: dict[str, dict] = {}
        self.rates: dict[str, list[datetime]] = {}
        self.promos: dict[str, dict] = {}
        self.redemptions: list[dict] = []
        self.pins: dict[str, str] = {}
        self.checkins: dict[tuple[str, str], dict] = {}
        self.plans: dict[str, list[dict]] = {}

    def tier(self, uid: str, now: datetime) -> Tier:
        return Tier.PRO if is_pro(self.subs.get(uid), now) else Tier.FREE

    def user_tz(self, uid: str) -> str | None:
        return self.users.get(uid, {}).get("timezone")

    def consume(self, uid: str, buckets: list[Bucket], month: str,
                reserve_usd: float = 0.0, spend_cap: float = float("inf")) -> ConsumeResult:
        with self._lock:
            for b in buckets:
                if self.counters.get((uid, b.key), 0) >= b.max:
                    return ConsumeResult(False, b)
            cur = self.spend_.get((uid, month), 0.0)
            if reserve_usd and cur + reserve_usd > spend_cap + 1e-9:
                return ConsumeResult(False, spend_blocked=True)
            self.spend_[(uid, month)] = cur + reserve_usd
            for b in buckets:
                self.counters[(uid, b.key)] = self.counters.get((uid, b.key), 0) + 1
            if buckets and buckets[0].kind in USAGE_FIELD:
                u = self.users.setdefault(uid, {}).setdefault("ai_usage", {})
                if u.get("month") != month:
                    u.clear()
                    u["month"] = month
                f = USAGE_FIELD[buckets[0].kind]
                u[f] = u.get(f, 0) + 1
            return ConsumeResult(True)

    def refund(self, uid: str, buckets: list[Bucket], month: str) -> None:
        with self._lock:
            for b in buckets:
                k = (uid, b.key)
                self.counters[k] = max(0, self.counters.get(k, 0) - 1)
            if buckets and buckets[0].kind in USAGE_FIELD:
                u = self.users.setdefault(uid, {}).setdefault("ai_usage", {})
                f = USAGE_FIELD[buckets[0].kind]
                if u.get("month") == month:
                    u[f] = max(0, u.get(f, 0) - 1)

    def spend(self, uid: str, month: str) -> float:
        return self.spend_.get((uid, month), 0.0)

    def add_spend(self, uid: str, month: str, usd: float) -> None:
        with self._lock:
            self.spend_[(uid, month)] = self.spend_.get((uid, month), 0.0) + usd

    def idem_get(self, uid: str, route: str, key: str) -> dict | None:
        return self.idem.get((uid, route, key))

    def idem_begin(self, uid: str, route: str, key: str) -> bool:
        with self._lock:
            if (uid, route, key) in self.idem:
                return False
            self.idem[(uid, route, key)] = None
            return True

    def idem_put(self, uid: str, route: str, key: str, response: dict) -> None:
        self.idem[(uid, route, key)] = response

    def idem_abort(self, uid: str, route: str, key: str) -> None:
        self.idem.pop((uid, route, key), None)

    def cache_get(self, h: str) -> dict | None:
        return self.cache.get(h)

    def cache_put(self, h: str, value: dict) -> None:
        self.cache[h] = value

    def rate_hit(self, key: str, window_s: int, max_hits: int, now: datetime) -> bool:
        with self._lock:
            hits = [t for t in self.rates.get(key, []) if t > now - timedelta(seconds=window_s)]
            if len(hits) >= max_hits:
                self.rates[key] = hits
                return False
            hits.append(now)
            self.rates[key] = hits
            return True

    def promo_redeem(self, uid: str, code_hash: str, now: datetime) -> PromoGrant:
        with self._lock:
            p = self.promos.get(code_hash)
            grant = _check_promo(p, uid, code_hash, now, self._already(uid, code_hash))
            p["uses"] = p.get("uses", 0) + 1
            sub = self.subs.setdefault(uid, {})
            sub["promo"] = {"tier": grant.tier, "expires_at": grant.expires_at,
                            "code_hash": code_hash}
            return grant

    def _already(self, uid: str, code_hash: str) -> bool:
        return any(r["uid"] == uid and r["code_hash"] == code_hash and r["result"] == "granted"
                   for r in self.redemptions)

    def promo_audit(self, uid: str, code_hash: str, result: str, now: datetime) -> None:
        self.redemptions.append({"uid": uid, "code_hash": code_hash, "ts": now, "result": result})

    def prompt_pins(self) -> dict[str, str]:
        return dict(self.pins)

    def set_prompt_pin(self, route: str, version: str) -> None:
        self.pins[route] = version

    def save_checkin_report(self, uid: str, checkin_id: str, report: dict | None,
                            status: str) -> None:
        self.checkins[(uid, checkin_id)] = {"ai_report": report, "ai_status": status}

    def save_plan(self, uid: str, plan: dict) -> int:
        plans = self.plans.setdefault(uid, [])
        plans.append(plan)
        return len(plans)

    def profile(self, uid: str) -> dict | None:
        return self.users.get(uid, {}).get("onboarding")


def _check_promo(p: dict | None, uid: str, code_hash: str, now: datetime,
                 already: bool) -> PromoGrant:
    if not p:
        raise PromoError("not_found")
    if p.get("revoked"):
        raise PromoError("revoked")
    if p.get("expires_at") and _as_dt(p["expires_at"]) <= now:
        raise PromoError("expired")
    if p.get("uses", 0) >= p.get("uses_max", 0):
        raise PromoError("exhausted")
    if already:
        raise PromoError("already_redeemed")
    days = int(p.get("grant_days", 30))
    return PromoGrant(tier=p.get("tier", "pro"), expires_at=now + timedelta(days=days))


class FirestoreStore:
    """Production store. Counters live in users/{uid}/usage/{bucket}; every
    multi-document change runs in a Firestore transaction.

    A burst from one user would make those transactions fight over the same
    documents, so per-user work is first serialised in-process (lock stripes);
    transactions still guarantee correctness across instances, and any
    residual contention surfaces as StoreBusy (→ 503 + Retry-After)."""

    _STRIPES = 256
    _TX_ATTEMPTS = 10

    def __init__(self) -> None:
        from google.cloud import firestore  # imported lazily: optional in tests

        self._fs = firestore
        self.db = firestore.Client()
        self._locks = [threading.Lock() for _ in range(self._STRIPES)]

    def _lock(self, key: str) -> threading.Lock:
        return self._locks[hash(key) % self._STRIPES]

    def _run_tx(self, key: str, fn):
        from google.api_core import exceptions as gexc

        with self._lock(key):
            try:
                return fn(self.db.transaction(max_attempts=self._TX_ATTEMPTS))
            except (ValueError, gexc.Aborted, gexc.DeadlineExceeded,
                    gexc.ServiceUnavailable) as e:
                if isinstance(e, ValueError) and "transaction" not in str(e).lower():
                    raise
                raise StoreBusy(str(e)) from e

    def _user(self, uid: str):
        return self.db.collection("users").document(uid)

    def tier(self, uid: str, now: datetime) -> Tier:
        snap = self.db.collection("subscriptions").document(uid).get()
        return Tier.PRO if is_pro(snap.to_dict() if snap.exists else None, now) else Tier.FREE

    def user_tz(self, uid: str) -> str | None:
        snap = self._user(uid).get(["timezone"])
        return (snap.to_dict() or {}).get("timezone") if snap.exists else None

    def consume(self, uid: str, buckets: list[Bucket], month: str,
                reserve_usd: float = 0.0, spend_cap: float = float("inf")) -> ConsumeResult:
        fs = self._fs
        usage = self._user(uid).collection("usage")
        refs = [usage.document(b.key.replace("|", "_")) for b in buckets]
        spend_ref = usage.document(f"spend_{month}")
        user_ref = self._user(uid)

        @fs.transactional
        def run(tx) -> ConsumeResult:
            snaps = list(tx.get_all(refs + [spend_ref])) if refs else [spend_ref.get(
                transaction=tx)]
            by_id = {s.id: s for s in snaps}
            for b, r in zip(buckets, refs):
                s = by_id.get(r.id)
                n = (s.to_dict() or {}).get("n", 0) if s is not None and s.exists else 0
                if n >= b.max:
                    return ConsumeResult(False, b)
            sp = by_id.get(spend_ref.id)
            cur = float((sp.to_dict() or {}).get("usd", 0.0)) if sp is not None and sp.exists else 0.0
            if reserve_usd and cur + reserve_usd > spend_cap + 1e-9:
                return ConsumeResult(False, spend_blocked=True)
            for r in refs:
                tx.set(r, {"n": fs.Increment(1)}, merge=True)
            if reserve_usd:
                tx.set(spend_ref, {"usd": cur + reserve_usd}, merge=True)
            return ConsumeResult(True)

        res = self._run_tx(f"usage:{uid}", run)
        if res.allowed and buckets and buckets[0].kind in USAGE_FIELD:
            self._mirror_usage(user_ref, buckets[0].kind, month, +1)
        return res

    def _mirror_usage(self, user_ref, kind: Kind, month: str, delta: int) -> None:
        """Client-visible users/{uid}.ai_usage (display only; the usage/ docs
        are the enforced counters). Best effort, outside the hot transaction."""
        fs = self._fs
        f = USAGE_FIELD[kind]
        try:
            snap = user_ref.get(["ai_usage"])
            usage = ((snap.to_dict() or {}).get("ai_usage") or {}) if snap.exists else {}
            if usage.get("month") != month:
                user_ref.set({"ai_usage": {"month": month, f: max(0, delta)}}, merge=True)
            else:
                user_ref.set({"ai_usage": {f: fs.Increment(delta)}}, merge=True)
        except Exception:  # display mirror only; never fail the request on it
            pass

    def refund(self, uid: str, buckets: list[Bucket], month: str) -> None:
        with self._lock(f"usage:{uid}"):
            batch = self.db.batch()
            for b in buckets:
                ref = self._user(uid).collection("usage").document(b.key.replace("|", "_"))
                batch.set(ref, {"n": self._fs.Increment(-1)}, merge=True)
            batch.commit()
        if buckets and buckets[0].kind in USAGE_FIELD:
            self._mirror_usage(self._user(uid), buckets[0].kind, month, -1)

    def spend(self, uid: str, month: str) -> float:
        snap = self._user(uid).collection("usage").document(f"spend_{month}").get()
        return float((snap.to_dict() or {}).get("usd", 0.0)) if snap.exists else 0.0

    def add_spend(self, uid: str, month: str, usd: float) -> None:
        with self._lock(f"usage:{uid}"):
            self._user(uid).collection("usage").document(f"spend_{month}").set(
                {"usd": self._fs.Increment(usd)}, merge=True)

    def _idem_ref(self, uid: str, route: str, key: str):
        return self._user(uid).collection("ai_jobs").document(f"{route}_{key}")

    def idem_get(self, uid: str, route: str, key: str) -> dict | None:
        snap = self._idem_ref(uid, route, key).get()
        return (snap.to_dict() or {}).get("response") if snap.exists else None

    def idem_begin(self, uid: str, route: str, key: str) -> bool:
        from google.api_core.exceptions import AlreadyExists

        try:
            self._idem_ref(uid, route, key).create(
                {"state": "running", "ts": self._fs.SERVER_TIMESTAMP})
            return True
        except AlreadyExists:
            return False

    def idem_put(self, uid: str, route: str, key: str, response: dict) -> None:
        self._idem_ref(uid, route, key).set(
            {"state": "done", "response": response, "ts": self._fs.SERVER_TIMESTAMP})

    def idem_abort(self, uid: str, route: str, key: str) -> None:
        self._idem_ref(uid, route, key).delete()

    def cache_get(self, h: str) -> dict | None:
        snap = self.db.collection("ai_cache").document(h).get()
        return (snap.to_dict() or {}).get("value") if snap.exists else None

    def cache_put(self, h: str, value: dict) -> None:
        self.db.collection("ai_cache").document(h).set(
            {"value": value, "ts": self._fs.SERVER_TIMESTAMP})

    def rate_hit(self, key: str, window_s: int, max_hits: int, now: datetime) -> bool:
        fs = self._fs
        slot = int(now.timestamp()) // window_s
        ref = self.db.collection("rate_limits").document(f"{key}_{slot}")

        @fs.transactional
        def run(tx) -> bool:
            snap = ref.get(transaction=tx)
            n = (snap.to_dict() or {}).get("n", 0) if snap.exists else 0
            if n >= max_hits:
                return False
            tx.set(ref, {"n": n + 1, "expire_at": now + timedelta(seconds=2 * window_s)})
            return True

        return self._run_tx(f"rate:{key}", run)

    def promo_redeem(self, uid: str, code_hash: str, now: datetime) -> PromoGrant:
        fs = self._fs
        code_ref = self.db.collection("promo_codes").document(code_hash)
        mark_ref = code_ref.collection("redeemers").document(uid)
        sub_ref = self.db.collection("subscriptions").document(uid)

        @fs.transactional
        def run(tx) -> PromoGrant:
            snap = code_ref.get(transaction=tx)
            already = mark_ref.get(transaction=tx).exists
            grant = _check_promo(snap.to_dict() if snap.exists else None, uid, code_hash,
                                 now, already)
            tx.update(code_ref, {"uses": fs.Increment(1)})
            tx.set(mark_ref, {"ts": now})
            tx.set(sub_ref, {"promo": {"tier": grant.tier, "expires_at": grant.expires_at,
                                       "code_hash": code_hash}}, merge=True)
            # Client-visible mirror (merge keeps the RevenueCat-owned fields).
            # No sticky `pro: true` here: clients derive promo access from the
            # expiry, so it lapses on time without another write.
            tx.set(self._user(uid), {"entitlement": {"promo": True,
                                                     "promo_expires_at": grant.expires_at}},
                   merge=True)
            return grant

        return self._run_tx(f"promo:{code_hash}", run)

    def promo_audit(self, uid: str, code_hash: str, result: str, now: datetime) -> None:
        self.db.collection("promo_redemptions").add(
            {"uid": uid, "code_hash": code_hash, "ts": now, "result": result})

    def prompt_pins(self) -> dict[str, str]:
        snap = self.db.collection("config").document("prompts").get()
        return dict(snap.to_dict() or {}) if snap.exists else {}

    def set_prompt_pin(self, route: str, version: str) -> None:
        self.db.collection("config").document("prompts").set({route: version}, merge=True)

    def save_checkin_report(self, uid: str, checkin_id: str, report: dict | None,
                            status: str) -> None:
        self._user(uid).collection("checkins").document(checkin_id).set(
            {"ai_report": report, "ai_status": status,
             "updated_at": self._fs.SERVER_TIMESTAMP}, merge=True)

    def save_plan(self, uid: str, plan: dict) -> int:
        fs = self._fs
        user_ref = self._user(uid)

        @fs.transactional
        def run(tx) -> int:
            snap = user_ref.get(transaction=tx)
            version = int((snap.to_dict() or {}).get("plan_version", 0)) + 1 if snap.exists else 1
            plan_ref = user_ref.collection("plans").document(f"v{version}")
            tx.set(plan_ref, {**plan, "version": version, "created_at": fs.SERVER_TIMESTAMP})
            tx.set(user_ref, {"plan_version": version}, merge=True)
            return version

        return self._run_tx(f"plan:{uid}", run)

    def profile(self, uid: str) -> dict | None:
        snap = self._user(uid).get()
        if not snap.exists:
            return None
        d = snap.to_dict() or {}
        if not d.get("goal"):
            return None
        prof = d.get("profile") or {}
        return {
            "goal": (d.get("goal") or {}).get("type"),
            "level": d.get("level"),
            "equipment": d.get("equipment") or ["bodyweight"],
            "days_per_week": d.get("days_per_week"),
            "mins": d.get("mins"),
            "injuries": d.get("injuries") or [],
            "sex": prof.get("sex"),
            "height_cm": prof.get("height_cm"),
        }


_store: Store | None = None
_store_lock = threading.Lock()


def get_store() -> Store:
    """Process-wide singleton. Guarded: concurrent first requests must share
    one store (and so one set of per-user lock stripes)."""
    global _store
    if _store is None:
        with _store_lock:
            if _store is None:
                from .config import get_settings

                _store = (FirestoreStore() if get_settings().store == "firestore"
                          else MemoryStore())
    return _store


def set_store(s: Store | None) -> None:
    global _store
    _store = s
