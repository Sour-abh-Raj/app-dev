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
    # Which model vendor serves the AI routes. Nothing assumes a particular one:
    #   "openai_compat" — any OpenAI-compatible Chat Completions API (OpenAI,
    #                     OpenRouter, Together, Groq, Mistral, DeepSeek, a local
    #                     Ollama/vLLM, …) via AI_BASE_URL + AI_API_KEY
    #   "anthropic"     — Claude API (ANTHROPIC_API_KEY); "claude" is an alias
    #   "mock"          — deterministic, offline (tests, CI, demo)
    provider: str = field(default_factory=lambda: os.environ.get("AI_PROVIDER", "mock"))
    # Default model for every route; per-route overrides below. Required for
    # openai_compat (the id is vendor-specific, e.g. "gpt-4o-mini" or
    # "anthropic/claude-opus-5-5" on OpenRouter).
    model_default: str = field(
        default_factory=lambda: os.environ.get("AI_MODEL_DEFAULT")
        or ("claude-opus-5-5" if os.environ.get("AI_PROVIDER") in ("anthropic", "claude")
            else "mock")
    )
    model_meal: str = field(default_factory=lambda: os.environ.get("AI_MODEL_MEAL", ""))
    model_chat: str = field(default_factory=lambda: os.environ.get("AI_MODEL_CHAT", ""))
    model_checkin: str = field(default_factory=lambda: os.environ.get("AI_MODEL_CHECKIN", ""))
    model_plan: str = field(default_factory=lambda: os.environ.get("AI_MODEL_PLAN", ""))
    # openai_compat settings. The key is a secret (Secret Manager on Cloud Run).
    ai_base_url: str = field(
        default_factory=lambda: os.environ.get("AI_BASE_URL", "https://api.openai.com/v1")
    )
    ai_api_key: str = field(default_factory=lambda: os.environ.get("AI_API_KEY", ""))
    # json_schema (default) | json_object | prompt — how structured output is
    # requested; pick the strongest one your vendor/model supports.
    ai_json_mode: str = field(default_factory=lambda: os.environ.get("AI_JSON_MODE", "json_schema"))
    # Optional extra headers, e.g. OpenRouter attribution: "HTTP-Referer=https://forme.ai,X-Title=Forme AI"
    ai_extra_headers: tuple[str, ...] = field(default_factory=lambda: _csv("AI_EXTRA_HEADERS"))
    # Spend-ledger prices (USD per 1M tokens) for models not in caps.PRICES_PER_MTOK.
    # Unknown models without these are billed at a conservative default.
    ai_price_in: float = field(
        default_factory=lambda: float(os.environ.get("AI_PRICE_INPUT_PER_MTOK", "0") or 0)
    )
    ai_price_out: float = field(
        default_factory=lambda: float(os.environ.get("AI_PRICE_OUTPUT_PER_MTOK", "0") or 0)
    )
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
        override = {"meal": self.model_meal, "chat": self.model_chat,
                    "checkin": self.model_checkin, "plan": self.model_plan}.get(route, "")
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
