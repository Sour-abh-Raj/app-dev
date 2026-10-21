"""Runtime settings. Every secret comes from the environment (Secret Manager on
Cloud Run); nothing sensitive is hardcoded here."""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _csv(name: str) -> tuple[str, ...]:
    raw = os.environ.get(name, "")
    return tuple(x.strip() for x in raw.split(",") if x.strip())


@dataclass(frozen=True)
class Settings:
    env: str = field(default_factory=lambda: os.environ.get("FORME_ENV", "dev"))
    # "claude" in staging/prod; "mock" for tests, CI and offline dev.
    provider: str = field(default_factory=lambda: os.environ.get("AI_PROVIDER", "mock"))
    # Per-route model ids; all default to the current Opus. Change via env only.
    model_default: str = field(
        default_factory=lambda: os.environ.get("AI_MODEL_DEFAULT", "claude-opus-5-5")
    )
    model_meal: str = field(default_factory=lambda: os.environ.get("AI_MODEL_MEAL", ""))
    model_chat: str = field(default_factory=lambda: os.environ.get("AI_MODEL_CHAT", ""))
    store: str = field(default_factory=lambda: os.environ.get("STORE", "memory"))
    storage_bucket: str = field(default_factory=lambda: os.environ.get("STORAGE_BUCKET", ""))
    # HMAC pepper for promo code hashing (Secret Manager: PROMO_PEPPER).
    promo_pepper: str = field(default_factory=lambda: os.environ.get("PROMO_PEPPER", ""))
    revenuecat_secret: str = field(
        default_factory=lambda: os.environ.get("REVENUECAT_SECRET_KEY", "")
    )
    admin_service_accounts: tuple[str, ...] = field(
        default_factory=lambda: _csv("ADMIN_SERVICE_ACCOUNTS")
    )
    admin_audience: str = field(default_factory=lambda: os.environ.get("ADMIN_AUDIENCE", ""))
    request_timeout_s: float = 60.0
    # O6: hard monthly AI spend ceiling per user, in USD.
    spend_cap_pro_usd: float = field(
        default_factory=lambda: float(os.environ.get("SPEND_CAP_PRO_USD", "1.50"))
    )
    spend_cap_free_usd: float = field(
        default_factory=lambda: float(os.environ.get("SPEND_CAP_FREE_USD", "0.25"))
    )
    paywall_link: str = "forme://paywall"

    def model_for(self, route: str) -> str:
        override = {"meal": self.model_meal, "chat": self.model_chat}.get(route, "")
        return override or self.model_default


_settings: Settings | None = None


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = Settings()
    return _settings


def reset_settings(s: Settings | None = None) -> None:
    global _settings
    _settings = s
