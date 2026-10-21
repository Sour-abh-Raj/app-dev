"""Claude provider. The API key is read by the SDK from ANTHROPIC_API_KEY, which
Cloud Run injects from Secret Manager — it never reaches the client app."""

from __future__ import annotations

from typing import Any

import anthropic

from .base import AiError, Effort, Image, T, Usage

# Server-side refusal fallback: a policy decline is re-run on Anthropic's
# recommended fallback model inside the same call.
_FALLBACK_BETA = "server-side-fallback-2026-07-01"


class ClaudeProvider:
    def __init__(self, timeout_s: float = 60.0) -> None:
        # The SDK retries 408/409/429/5xx itself; keep one retry so the
        # 60s route timeout still holds.
        self.client = anthropic.Anthropic(timeout=timeout_s, max_retries=1)

    def complete(
        self,
        *,
        route: str,
        model: str,
        system: str,
        text: str,
        images: list[Image],
        schema: type[T],
        effort: Effort,
        max_tokens: int,
        context: dict[str, Any] | None = None,
    ) -> tuple[T, Usage]:
        content: list[dict[str, Any]] = []
        for img in images:
            if img.label:
                content.append({"type": "text", "text": img.label})
            content.append({
                "type": "image",
                "source": {"type": "base64", "media_type": img.media_type, "data": img.b64},
            })
        content.append({"type": "text", "text": text})
        try:
            resp = self.client.beta.messages.parse(
                model=model,
                max_tokens=max_tokens,
                betas=[_FALLBACK_BETA],
                fallbacks="default",
                output_config={"effort": effort},
                # The system prompt is frozen per prompt version, so it caches.
                system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
                messages=[{"role": "user", "content": content}],
                output_format=schema,
            )
        except anthropic.BadRequestError as e:
            raise AiError(f"{route}: bad request ({e.message})", transient=False) from e
        except (anthropic.AuthenticationError, anthropic.PermissionDeniedError,
                anthropic.NotFoundError) as e:
            raise AiError(f"{route}: provider config error ({e.status_code})",
                          transient=False) from e
        except anthropic.RateLimitError as e:
            raise AiError(f"{route}: provider rate limited", transient=True) from e
        except anthropic.APIStatusError as e:
            raise AiError(f"{route}: provider error {e.status_code}",
                          transient=e.status_code >= 500) from e
        except anthropic.APIConnectionError as e:
            raise AiError(f"{route}: provider unreachable", transient=True) from e
        except ValueError as e:  # schema validation of the parsed output
            raise AiError(f"{route}: invalid model output ({e})", transient=True) from e

        u = resp.usage
        # Cache writes bill at 1.25x input and reads at 0.1x; fold them into an
        # input-token equivalent for the spend ledger.
        eff_input = (u.input_tokens + 1.25 * (u.cache_creation_input_tokens or 0)
                     + 0.1 * (u.cache_read_input_tokens or 0))
        usage = Usage(model=resp.model, input_tokens=int(eff_input),
                      output_tokens=u.output_tokens)
        if resp.stop_reason == "refusal":
            raise AiError(f"{route}: declined by model", transient=False)
        if resp.stop_reason == "max_tokens" or resp.parsed_output is None:
            raise AiError(f"{route}: incomplete model output", transient=True)
        return resp.parsed_output, usage
