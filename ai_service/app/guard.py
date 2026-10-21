"""The one gate every AI call passes through: idempotency (O7), per-user caps and
the monthly spend ceiling (O6), and the response cache (O5)."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from .caps import Bucket, Kind, Period, Tier, buckets_for, cost_usd, month_key, seconds_until_reset
from .config import Settings
from .providers.base import Usage
from .store import Store

# Worst-case cost of one call, checked before calling so a user can never
# cross the ceiling by more than one request's rounding.
EST_MAX_COST_USD = {
    Kind.PLAN_GENERATE: 0.12, Kind.PLAN_REGEN: 0.12, Kind.PHOTO: 0.15,
    Kind.MEAL: 0.03, Kind.CHAT: 0.03, Kind.RENDER: 0.0,
}


class CapExceeded(Exception):
    def __init__(self, cap: str, retry_after: int, tier: Tier):
        super().__init__(cap)
        self.cap = cap
        self.retry_after = retry_after
        self.tier = tier


class InProgress(Exception):
    """Same idempotency key is still running; client should retry later."""


@dataclass
class Gate:
    store: Store
    settings: Settings
    uid: str
    kind: Kind
    route: str
    idem_key: str | None
    now: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    tier: Tier = Tier.FREE
    buckets: list[Bucket] = field(default_factory=list)
    replay: dict[str, Any] | None = None
    _consumed: bool = False
    _open: bool = False

    @property
    def month(self) -> str:
        return month_key(self.now)

    def open(self) -> "Gate":
        if self.idem_key:
            prior = self.store.idem_get(self.uid, self.route, self.idem_key)
            if prior is not None:
                self.replay = prior  # retry of a finished job: no new charge, no new write
                return self
            if not self.store.idem_begin(self.uid, self.route, self.idem_key):
                raise InProgress()
            self._open = True
        try:
            self.tier = self.store.tier(self.uid, self.now)
            tz = self.store.user_tz(self.uid)
            self.buckets = buckets_for(self.tier, self.kind, self.now, tz)
            res = self.store.consume(self.uid, self.buckets, self.month)
            if not res.allowed:
                assert res.blocked is not None
                raise CapExceeded(self.kind.value,
                                  seconds_until_reset(res.blocked.period, self.now, tz), self.tier)
            self._consumed = True
            cap = (self.settings.spend_cap_pro_usd if self.tier is Tier.PRO
                   else self.settings.spend_cap_free_usd)
            if self.store.spend(self.uid, self.month) + EST_MAX_COST_USD[self.kind] > cap:
                self.refund()
                raise CapExceeded("spend", seconds_until_reset(Period.MONTH, self.now, tz),
                                  self.tier)
        except Exception:
            self.abort()
            raise
        return self

    def charge(self, usage: Usage | None) -> None:
        if usage is not None and usage.input_tokens + usage.output_tokens > 0:
            self.store.add_spend(self.uid, self.month,
                                 cost_usd(usage.model, usage.input_tokens, usage.output_tokens))

    def refund(self) -> None:
        """Our failure must not cost the user an allowance."""
        if self._consumed:
            self.store.refund(self.uid, self.buckets, self.month)
            self._consumed = False

    def finish(self, response: dict[str, Any]) -> dict[str, Any]:
        if self._open and self.idem_key:
            self.store.idem_put(self.uid, self.route, self.idem_key, response)
            self._open = False
        return response

    def abort(self) -> None:
        """Release the idempotency key so a client retry can run again."""
        if self._open and self.idem_key:
            self.store.idem_abort(self.uid, self.route, self.idem_key)
            self._open = False


def request_hash(route: str, prompt_version: str, model: str, payload: Any) -> str:
    blob = json.dumps({"r": route, "p": prompt_version, "m": model, "x": payload},
                      sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(blob.encode()).hexdigest()
