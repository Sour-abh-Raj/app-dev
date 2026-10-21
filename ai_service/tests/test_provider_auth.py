from __future__ import annotations

from types import SimpleNamespace

import anthropic
import httpx2
import pytest
from fastapi import HTTPException

from app import auth
from app.ai_schemas import MealOut
from app.providers.base import AiError, Image
from app.providers.claude import ClaudeProvider

MEAL = MealOut(name="Oats", kcal=350, protein_g=12, carbs_g=60, fat_g=7, confidence=0.8,
               is_food=True)


def _resp(stop="end_turn", parsed=MEAL):
    usage = SimpleNamespace(input_tokens=1000, output_tokens=200, cache_creation_input_tokens=400,
                            cache_read_input_tokens=1000)
    return SimpleNamespace(model="claude-opus-5-5", usage=usage, stop_reason=stop,
                           parsed_output=parsed)


def _provider(parse):
    p = ClaudeProvider.__new__(ClaudeProvider)
    p.client = SimpleNamespace(beta=SimpleNamespace(messages=SimpleNamespace(parse=parse)))
    return p


def _call(p):
    return p.complete(route="meal", model="claude-opus-5-5", system="sys", text="oats",
                      images=[Image("image/jpeg", "AAAA", "Meal photo")], schema=MealOut,
                      effort="low", max_tokens=2000)


def test_request_shape_and_usage():
    seen = {}

    def parse(**kw):
        seen.update(kw)
        return _resp()

    out, usage = _call(_provider(parse))
    assert out.kcal == 350
    assert usage.input_tokens == 1000 + 500 + 100 and usage.output_tokens == 200
    assert seen["fallbacks"] == "default"
    assert seen["betas"] == ["server-side-fallback-2026-07-01"]
    assert seen["output_config"] == {"effort": "low"}
    assert seen["output_format"] is MealOut
    assert seen["system"][0]["cache_control"] == {"type": "ephemeral"}
    content = seen["messages"][0]["content"]
    assert [c["type"] for c in content] == ["text", "image", "text"]


@pytest.mark.parametrize("stop", ["refusal", "max_tokens"])
def test_bad_stop_reasons_raise(stop):
    with pytest.raises(AiError):
        _call(_provider(lambda **kw: _resp(stop=stop)))


def _status_error(cls, code):
    req = httpx2.Request("POST", "https://api.anthropic.com/v1/messages")
    return cls("err", response=httpx2.Response(code, request=req), body=None)


@pytest.mark.parametrize("exc,transient", [
    (lambda: _status_error(anthropic.BadRequestError, 400), False),
    (lambda: _status_error(anthropic.AuthenticationError, 401), False),
    (lambda: _status_error(anthropic.RateLimitError, 429), True),
    (lambda: _status_error(anthropic.InternalServerError, 500), True),
    (lambda: anthropic.APIConnectionError(
        request=httpx2.Request("POST", "https://api.anthropic.com")), True),
    (lambda: ValueError("schema"), True),
])
def test_errors_map_to_aierror(exc, transient):
    def parse(**kw):
        raise exc()

    with pytest.raises(AiError) as ei:
        _call(_provider(parse))
    assert ei.value.transient is transient


# ---------- auth ----------

@pytest.mark.anyio
async def test_current_uid_rejects_missing_and_bad_tokens(monkeypatch):
    req = SimpleNamespace(state=SimpleNamespace())
    with pytest.raises(HTTPException) as e:
        await auth.current_uid(req, None)
    assert e.value.status_code == 401

    import firebase_admin.auth as fb_auth

    monkeypatch.setattr(auth, "_firebase_app", lambda: None)

    def bad(token, app=None):
        raise ValueError("bad")

    monkeypatch.setattr(fb_auth, "verify_id_token", bad)
    with pytest.raises(HTTPException) as e:
        await auth.current_uid(req, "Bearer xyz")
    assert e.value.status_code == 401

    monkeypatch.setattr(fb_auth, "verify_id_token", lambda t, app=None: {"uid": "abc"})
    assert await auth.current_uid(req, "Bearer good") == "abc"
    assert req.state.uid == "abc"


@pytest.mark.anyio
async def test_admin_disabled_without_allowlist():
    with pytest.raises(HTTPException) as e:
        await auth.admin_principal("Bearer x")
    assert e.value.status_code == 403
