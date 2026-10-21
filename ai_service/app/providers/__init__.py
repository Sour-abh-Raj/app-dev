"""Provider factory. The vendor is a deployment choice (AI_PROVIDER), never a
code assumption."""

from __future__ import annotations

from ..config import Settings
from .base import Provider

PROVIDERS = ("openai_compat", "anthropic", "claude", "mock")


def make_provider(s: Settings) -> Provider:
    name = s.provider
    if name == "openai_compat":
        from .openai_compat import OpenAICompatProvider

        if not s.ai_api_key and "localhost" not in s.ai_base_url and "127.0.0.1" not in s.ai_base_url:
            raise RuntimeError("AI_PROVIDER=openai_compat needs AI_API_KEY")
        if not s.model_default or s.model_default == "mock":
            raise RuntimeError("AI_PROVIDER=openai_compat needs AI_MODEL_DEFAULT "
                               "(the vendor's model id)")
        headers = dict(h.split("=", 1) for h in s.ai_extra_headers if "=" in h)
        return OpenAICompatProvider(base_url=s.ai_base_url, api_key=s.ai_api_key,
                                    json_mode=s.ai_json_mode, extra_headers=headers,
                                    timeout_s=s.request_timeout_s)
    if name in ("anthropic", "claude"):
        from .claude import ClaudeProvider

        return ClaudeProvider(timeout_s=s.request_timeout_s)
    if name == "mock":
        from .mock import MockProvider

        return MockProvider()
    raise RuntimeError(f"Unknown AI_PROVIDER {name!r}; use one of {', '.join(PROVIDERS)}")
