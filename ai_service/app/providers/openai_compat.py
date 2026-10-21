"""Provider for any OpenAI-compatible Chat Completions API: OpenAI, OpenRouter,
Together, Groq, Mistral, DeepSeek, Fireworks, a self-hosted Ollama/vLLM, …

Configured entirely by env (AI_BASE_URL, AI_API_KEY, AI_MODEL_*, AI_JSON_MODE).
The key stays server-side; the app never sees it. Output is always validated
against the Pydantic schema here, whatever the vendor promises."""

from __future__ import annotations

import json
import re
from typing import Any

import httpx

from .base import AiError, Effort, Image, T, Usage

_FENCE = re.compile(r"^\s*```(?:json)?\s*(.*?)\s*```\s*$", re.S)


def _extract_json(text: str) -> Any:
    m = _FENCE.match(text)
    if m:
        text = m.group(1)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Some models wrap the object in prose; take the outermost {...}.
        start, end = text.find("{"), text.rfind("}")
        if start == -1 or end <= start:
            raise
        return json.loads(text[start:end + 1])


class OpenAICompatProvider:
    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        json_mode: str = "json_schema",
        extra_headers: dict[str, str] | None = None,
        timeout_s: float = 60.0,
        client: httpx.Client | None = None,
    ) -> None:
        if json_mode not in ("json_schema", "json_object", "prompt"):
            raise ValueError(f"AI_JSON_MODE must be json_schema|json_object|prompt, not {json_mode!r}")
        self.base_url = base_url.rstrip("/")
        self.json_mode = json_mode
        self.http = client or httpx.Client(timeout=timeout_s)
        self.headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
                        **(extra_headers or {})}

    def _body(self, *, model: str, system: str, text: str, images: list[Image],
              schema: type[T], max_tokens: int) -> dict[str, Any]:
        json_schema = schema.model_json_schema()
        if self.json_mode != "json_schema":
            # Without schema-constrained decoding, put the contract in the prompt.
            system = (f"{system}\n\nRespond with ONLY a JSON object (no prose, no code fences) "
                      f"that validates against this JSON Schema:\n{json.dumps(json_schema)}")
        content: list[dict[str, Any]] = []
        for img in images:
            if img.label:
                content.append({"type": "text", "text": img.label})
            content.append({"type": "image_url",
                            "image_url": {"url": f"data:{img.media_type};base64,{img.b64}"}})
        content.append({"type": "text", "text": text})
        body: dict[str, Any] = {
            "model": model,
            "max_tokens": max_tokens,
            "messages": [
                {"role": "system", "content": system},
                # Plain string when there are no images: widest compatibility.
                {"role": "user", "content": content if images else text},
            ],
        }
        if self.json_mode == "json_schema":
            # strict=False: vendors differ on which schema keywords strict mode
            # accepts; the schema still guides decoding and we validate below.
            body["response_format"] = {"type": "json_schema", "json_schema": {
                "name": schema.__name__, "schema": json_schema, "strict": False}}
        elif self.json_mode == "json_object":
            body["response_format"] = {"type": "json_object"}
        return body

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
        body = self._body(model=model, system=system, text=text, images=images, schema=schema,
                          max_tokens=max_tokens)
        try:
            r = self.http.post(f"{self.base_url}/chat/completions", json=body,
                               headers=self.headers)
        except httpx.TimeoutException as e:
            raise AiError(f"{route}: provider timed out", transient=True) from e
        except httpx.HTTPError as e:
            raise AiError(f"{route}: provider unreachable", transient=True) from e

        if r.status_code == 429 or r.status_code >= 500:
            raise AiError(f"{route}: provider error {r.status_code}", transient=True)
        if r.status_code in (401, 403, 404):
            raise AiError(f"{route}: provider config error ({r.status_code})", transient=False)
        if r.status_code >= 400:
            raise AiError(f"{route}: bad request ({r.status_code}: {r.text[:200]})",
                          transient=False)

        try:
            data = r.json()
            choice = data["choices"][0]
            msg = choice["message"]
        except (ValueError, KeyError, IndexError, TypeError) as e:
            raise AiError(f"{route}: malformed provider response", transient=True) from e

        u = data.get("usage") or {}
        # Spend is recorded under the requested model id (what the price table
        # and AI_PRICE_* env refer to), not the vendor's echoed alias.
        usage = Usage(model=model, input_tokens=int(u.get("prompt_tokens") or 0),
                      output_tokens=int(u.get("completion_tokens") or 0))

        if msg.get("refusal"):
            raise AiError(f"{route}: declined by model", transient=False)
        if choice.get("finish_reason") == "length":
            raise AiError(f"{route}: incomplete model output", transient=True)
        raw = msg.get("content")
        if isinstance(raw, list):  # some vendors return content parts
            raw = "".join(p.get("text", "") for p in raw if isinstance(p, dict))
        if not raw:
            raise AiError(f"{route}: empty model output", transient=True)
        try:
            return schema.model_validate(_extract_json(raw)), usage
        except ValueError as e:  # JSONDecodeError and ValidationError are ValueErrors
            raise AiError(f"{route}: invalid model output ({str(e)[:200]})", transient=True) from e
