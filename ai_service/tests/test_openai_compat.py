from __future__ import annotations

import json

import httpx
import pytest

from app.ai_schemas import MealOut
from app.config import Settings
from app.providers import make_provider
from app.providers.base import AiError, Image
from app.providers.mock import MockProvider
from app.providers.openai_compat import OpenAICompatProvider

MEAL = {"name": "Oats", "kcal": 350, "protein_g": 12, "carbs_g": 60, "fat_g": 7,
        "confidence": 0.8, "is_food": True}


def _ok(content, finish="stop", **extra):
    return httpx.Response(200, json={
        "model": "vendor/alias", "usage": {"prompt_tokens": 1200, "completion_tokens": 300},
        "choices": [{"finish_reason": finish, "message": {"role": "assistant",
                                                          "content": content, **extra}}]})


def _provider(handler, **kw):
    seen = {}

    def wrap(req: httpx.Request):
        seen["req"] = req
        seen["body"] = json.loads(req.content)
        return handler(req)

    p = OpenAICompatProvider(base_url="https://openrouter.ai/api/v1/", api_key="sk-test",
                             client=httpx.Client(transport=httpx.MockTransport(wrap)),
                             extra_headers={"X-Title": "Forme AI"}, **kw)
    return p, seen


def _call(p, images=()):
    return p.complete(route="meal", model="openai/gpt-4o-mini", system="sys", text="oats",
                      images=list(images), schema=MealOut, effort="low", max_tokens=2000)


def test_request_shape_json_schema_and_images():
    p, seen = _provider(lambda r: _ok(json.dumps(MEAL)))
    out, usage = _call(p, [Image("image/jpeg", "AAAA", "Meal photo")])
    assert out.kcal == 350
    assert (usage.model, usage.input_tokens, usage.output_tokens) == ("openai/gpt-4o-mini", 1200, 300)
    req, body = seen["req"], seen["body"]
    assert str(req.url) == "https://openrouter.ai/api/v1/chat/completions"
    assert req.headers["authorization"] == "Bearer sk-test"
    assert req.headers["x-title"] == "Forme AI"
    assert body["model"] == "openai/gpt-4o-mini" and body["max_tokens"] == 2000
    assert body["response_format"]["type"] == "json_schema"
    assert body["response_format"]["json_schema"]["name"] == "MealOut"
    parts = body["messages"][1]["content"]
    assert [x["type"] for x in parts] == ["text", "image_url", "text"]
    assert parts[1]["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_text_only_sends_plain_string():
    p, seen = _provider(lambda r: _ok(json.dumps(MEAL)))
    _call(p)
    assert seen["body"]["messages"][1]["content"] == "oats"


@pytest.mark.parametrize("mode,fmt", [("json_object", {"type": "json_object"}), ("prompt", None)])
def test_weaker_json_modes_put_schema_in_prompt_and_tolerate_fences(mode, fmt):
    p, seen = _provider(lambda r: _ok("```json\n" + json.dumps(MEAL) + "\n```"), json_mode=mode)
    out, _ = _call(p)
    assert out.name == "Oats"
    assert seen["body"].get("response_format") == fmt
    assert "JSON Schema" in seen["body"]["messages"][0]["content"]


def test_json_wrapped_in_prose_is_recovered():
    p, _ = _provider(lambda r: _ok("Sure! " + json.dumps(MEAL) + " Hope that helps."),
                     json_mode="prompt")
    assert _call(p)[0].fat_g == 7


def test_content_parts_list():
    p, _ = _provider(lambda r: _ok([{"type": "text", "text": json.dumps(MEAL)}]))
    assert _call(p)[0].kcal == 350


@pytest.mark.parametrize("resp,transient", [
    (lambda r: httpx.Response(429, json={}), True),
    (lambda r: httpx.Response(503, text="busy"), True),
    (lambda r: httpx.Response(401, json={}), False),
    (lambda r: httpx.Response(404, json={}), False),
    (lambda r: httpx.Response(400, json={"error": "bad"}), False),
    (lambda r: _ok(json.dumps(MEAL), finish="length"), True),
    (lambda r: _ok(None, refusal="no"), False),
    (lambda r: _ok("not json at all"), True),
    (lambda r: _ok(json.dumps({**MEAL, "kcal": -5})), True),  # fails schema validation
    (lambda r: _ok(""), True),
    (lambda r: httpx.Response(200, json={"choices": []}), True),
])
def test_errors_map_to_aierror(resp, transient):
    p, _ = _provider(resp)
    with pytest.raises(AiError) as e:
        _call(p)
    assert e.value.transient is transient


def test_network_errors_are_transient():
    def boom(req):
        raise httpx.ConnectError("down")

    p, _ = _provider(boom)
    with pytest.raises(AiError) as e:
        _call(p)
    assert e.value.transient


def test_bad_json_mode_rejected():
    with pytest.raises(ValueError):
        OpenAICompatProvider(base_url="x", api_key="k", json_mode="yaml")


# ---------- factory ----------

def _settings(**kw) -> Settings:
    base = dict(provider="openai_compat", ai_api_key="k", model_default="gpt-4o-mini",
                ai_base_url="https://api.openai.com/v1")
    return Settings(**{**base, **kw})


def test_factory_builds_openai_compat_with_headers():
    p = make_provider(_settings(ai_extra_headers=("HTTP-Referer=https://forme.ai", "X-Title=Forme")))
    assert isinstance(p, OpenAICompatProvider)
    assert p.headers["HTTP-Referer"] == "https://forme.ai"


def test_factory_requires_key_and_model():
    with pytest.raises(RuntimeError, match="AI_API_KEY"):
        make_provider(_settings(ai_api_key=""))
    with pytest.raises(RuntimeError, match="AI_MODEL_DEFAULT"):
        make_provider(_settings(model_default="mock"))
    # A local server (Ollama/vLLM) needs no key.
    assert make_provider(_settings(ai_api_key="", ai_base_url="http://localhost:11434/v1"))


def test_factory_other_providers():
    assert isinstance(make_provider(_settings(provider="mock")), MockProvider)
    with pytest.raises(RuntimeError, match="Unknown AI_PROVIDER"):
        make_provider(_settings(provider="nope"))


def test_unknown_model_uses_configured_prices(monkeypatch):
    from app import caps
    from app.config import reset_settings

    monkeypatch.setenv("AI_PRICE_INPUT_PER_MTOK", "0.15")
    monkeypatch.setenv("AI_PRICE_OUTPUT_PER_MTOK", "0.60")
    reset_settings()
    try:
        assert caps.cost_usd("gpt-4o-mini", 1_000_000, 1_000_000) == pytest.approx(0.75)
    finally:
        reset_settings()
