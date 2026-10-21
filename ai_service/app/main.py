"""Forme AI service (FastAPI on Cloud Run). All routes are POST JSON, Firebase-ID
authenticated, capped (O6), idempotent (O7) and request-id logged."""

from __future__ import annotations

import hashlib
import json
import logging
import time
import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from . import images, plan_engine, promo, prompts, redflag
from .ai_schemas import CheckinOut, CoachOut, MealOut, PlanOut
from .auth import admin_principal, current_uid
from .caps import Kind
from .config import Settings, get_settings
from .guard import CapExceeded, Gate, InProgress, request_hash
from .models import (AiReport, CheckinAnalyzeRequest, CheckinAnalyzeResponse, CoachChatRequest,
                     CoachChatResponse, Delta, MealAi, MealAnalyzeRequest, Mesocycle, Onboarding,
                     PlanGenerateRequest, PlanRegenerateRequest, PlanResponse, PromoRedeemRequest,
                     PromoRedeemResponse, PromptPinRequest, PreviewRenderRequest,
                     PreviewRenderResponse)
from .providers.base import AiError, Image, Provider
from .store import MemoryStore, PromoError, Store, StoreBusy, get_store

log = logging.getLogger("forme.api")
logging.basicConfig(level=logging.INFO, format="%(message)s")

PHOTO_ROOT = "progress-photos"
PREVIEW_PLACEHOLDER = "previews/_placeholder/v1.jpg"
BURST_PER_MIN = 30


def create_app() -> FastAPI:
    app = FastAPI(title="Forme AI service", version="1.0.0", docs_url=None, redoc_url=None)
    app.state.provider = None
    app.state.loader = None

    @app.middleware("http")
    async def request_id_mw(request: Request, call_next):
        rid = request.headers.get("x-request-id") or uuid.uuid4().hex
        request.state.rid = rid
        request.state.uid = None
        t0 = time.perf_counter()
        status = 500
        try:
            resp = await call_next(request)
            status = resp.status_code
            resp.headers["x-request-id"] = rid
            return resp
        finally:
            log.info(json.dumps({"rid": rid, "path": request.url.path, "status": status,
                                 "uid": request.state.uid,
                                 "ms": round((time.perf_counter() - t0) * 1000)}))

    @app.exception_handler(CapExceeded)
    async def cap_handler(request: Request, exc: CapExceeded):
        s = get_settings()
        return JSONResponse(status_code=429, headers={"Retry-After": str(exc.retry_after)},
                            content={"error": "cap_reached", "cap": exc.cap, "tier": exc.tier.value,
                                     "retry_after": exc.retry_after,
                                     "paywall": f"{s.paywall_link}?placement=cap_{exc.cap}"})

    @app.exception_handler(StoreBusy)
    async def busy_handler(request: Request, exc: StoreBusy):
        log.warning(json.dumps({"rid": getattr(request.state, "rid", None), "store_busy": str(exc)}))
        return JSONResponse(status_code=503, headers={"Retry-After": "2"},
                            content={"error": "busy", "retry_after": 2})

    @app.exception_handler(InProgress)
    async def inprogress_handler(request: Request, exc: InProgress):
        return JSONResponse(status_code=409, headers={"Retry-After": "5"},
                            content={"error": "in_progress", "retry_after": 5})

    @app.exception_handler(RequestValidationError)
    async def validation_handler(request: Request, exc: RequestValidationError):
        return JSONResponse(status_code=422, content={
            "error": "invalid_request",
            "details": [{"loc": list(e["loc"]), "msg": e["msg"]} for e in exc.errors()]})

    @app.exception_handler(HTTPException)
    async def http_handler(request: Request, exc: HTTPException):
        content = exc.detail if isinstance(exc.detail, dict) else {"error": str(exc.detail)}
        return JSONResponse(status_code=exc.status_code, content=content,
                            headers=getattr(exc, "headers", None))

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"ok": "true"}

    _register_routes(app)
    return app


# ---------- dependencies ----------


def store_dep() -> Store:
    return get_store()


def provider_dep(request: Request) -> Provider:
    p = request.app.state.provider
    if p is None:
        s = get_settings()
        if s.provider == "claude":
            from .providers.claude import ClaudeProvider

            p = ClaudeProvider(timeout_s=s.request_timeout_s)
        else:
            from .providers.mock import MockProvider

            p = MockProvider()
        request.app.state.provider = p
    return p


def loader_dep(request: Request) -> images.ImageLoader:
    loader = request.app.state.loader
    if loader is None:
        s = get_settings()
        loader = images.GcsLoader(s.storage_bucket) if s.storage_bucket else images.MemoryLoader()
        request.app.state.loader = loader
    return loader


# Per-instance burst limiter (soft; the caps in the store are the hard limit).
# Kept in memory so a burst never adds a hot-document transaction.
_burst = MemoryStore()


def burst_guard(store: Store, uid: str) -> None:
    if not _burst.rate_hit(f"burst_{uid}", 60, BURST_PER_MIN, datetime.now(timezone.utc)):
        raise HTTPException(429, detail={"error": "rate_limited", "retry_after": 60},
                            headers={"Retry-After": "60"})


def _gate(store: Store, uid: str, kind: Kind, route: str, idem: str | None) -> Gate:
    burst_guard(store, uid)
    return Gate(store=store, settings=get_settings(), uid=uid, kind=kind, route=route,
                idem_key=idem).open()


def _clean_idem(key: str | None) -> str | None:
    if key is None:
        return None
    if not (8 <= len(key) <= 64) or not all(c.isalnum() or c in "-_" for c in key):
        raise HTTPException(400, detail={"error": "bad_idempotency_key"})
    return key


def _allowed_library(ob: Onboarding) -> list[dict[str, Any]]:
    equipment = set(ob.equipment) - {"bodyweight"}
    injuries = set(ob.injuries)
    return [{"id": e["id"], "muscle": e["muscle"], "difficulty": e["difficulty"],
             "kind": e["kind"], "substitutions": e["substitutions"]}
            for e in plan_engine.catalog().values()
            if plan_engine.available(e, equipment, injuries, 3)]


# ---------- routes ----------


def _register_routes(app: FastAPI) -> None:  # noqa: C901 — flat route table reads best

    def _plan(store: Store, provider: Provider, uid: str, gate: Gate, ob: Onboarding,
              route: str, week: int, extra: dict[str, Any]) -> dict[str, Any]:
        s = get_settings()
        pv = prompts.pinned_version(store, "plan")
        model = s.model_for("plan")
        template = plan_engine.template_plan(ob)
        payload = {"onboarding": ob.model_dump(), "week": week, **extra}
        h = request_hash(route, pv, model, payload)
        meso: Mesocycle | None = None
        source, queued = "ai", False
        cached = store.cache_get(h)
        if cached:
            meso = Mesocycle.model_validate(cached["mesocycle"])
        else:
            try:
                out, usage = provider.complete(
                    route=route, model=model, system=prompts.load("plan", pv),
                    text=json.dumps({**payload, "library": _allowed_library(ob)}),
                    images=[], schema=PlanOut, effort="medium", max_tokens=16000,
                    context={"template": template})
                gate.charge(usage)
                if plan_engine.validate_plan(out.mesocycle, ob):
                    meso, source = template, "template"
                else:
                    meso = out.mesocycle
                    store.cache_put(h, {"mesocycle": meso.model_dump()})
            except AiError as e:
                log.warning(json.dumps({"ai_error": str(e), "route": route}))
                gate.refund()
                meso, source, queued = template, "template", True
        version = store.save_plan(uid, {"week_index": week, "mesocycle_json": meso.model_dump(),
                                        "source": source, "prompt_version": pv,
                                        "adherence_snapshot": extra.get("adherence")})
        resp = PlanResponse(version=version, week_index=week, mesocycle=meso, source=source,
                            prompt_version=pv, queued=queued).model_dump()
        return gate.finish(resp)

    @app.post("/v1/plan/generate", response_model=PlanResponse)
    def plan_generate(body: PlanGenerateRequest, uid: str = Depends(current_uid),
                      store: Store = Depends(store_dep), provider: Provider = Depends(provider_dep),
                      idempotency_key: str | None = Header(None)):
        gate = _gate(store, uid, Kind.PLAN_GENERATE, "plan_generate", _clean_idem(idempotency_key))
        if gate.replay is not None:
            return gate.replay
        return _plan(store, provider, uid, gate, body.onboarding, "plan_generate", 1, {})

    @app.post("/v1/plan/regenerate", response_model=PlanResponse)
    def plan_regenerate(body: PlanRegenerateRequest, uid: str = Depends(current_uid),
                        store: Store = Depends(store_dep),
                        provider: Provider = Depends(provider_dep),
                        idempotency_key: str | None = Header(None)):
        if body.uid != uid:
            raise HTTPException(403, detail={"error": "uid_mismatch"})
        prof = store.profile(uid)
        if not prof:
            raise HTTPException(409, detail={"error": "profile_missing"})
        ob = Onboarding.model_validate({k: v for k, v in prof.items() if v is not None})
        gate = _gate(store, uid, Kind.PLAN_REGEN, "plan_regen", _clean_idem(idempotency_key))
        if gate.replay is not None:
            return gate.replay
        extra = {"adherence": body.adherence.model_dump(),
                 "survey": body.survey.model_dump() if body.survey else None,
                 "current": body.current.model_dump() if body.current else None}
        return _plan(store, provider, uid, gate, ob, "plan_regen", body.week, extra)

    @app.post("/v1/checkin/analyze", response_model=CheckinAnalyzeResponse)
    def checkin_analyze(body: CheckinAnalyzeRequest, uid: str = Depends(current_uid),
                        store: Store = Depends(store_dep),
                        provider: Provider = Depends(provider_dep),
                        loader: images.ImageLoader = Depends(loader_dep),
                        idempotency_key: str | None = Header(None)):
        all_refs = list(body.photos) + [p for h in body.history for p in h.photos]
        if not all(images.owned_path(uid, p.path, PHOTO_ROOT) for p in all_refs):
            raise HTTPException(403, detail={"error": "photo_not_owned"})
        # The check-in id doubles as the idempotency key: one report per check-in.
        key = _clean_idem(idempotency_key) or _clean_idem(f"checkin-{body.checkin_id}")
        gate = _gate(store, uid, Kind.PHOTO, "checkin", key)
        if gate.replay is not None:
            return gate.replay

        baseline = next((h for h in sorted(body.history, key=lambda h: h.week_index)
                         if h.photos), None)
        prev_weight = next((h.weight_kg for h in sorted(body.history, key=lambda h: -h.week_index)
                            if h.weight_kg), None)
        try:
            imgs: list[Image] = []
            if baseline:
                for p in baseline.photos:
                    if p.angle in ("front", "side"):
                        imgs.append(images.normalize(loader.load(p.path),
                                                     f"Week {baseline.week_index} {p.angle}"))
            for p in sorted(body.photos, key=lambda p: ["front", "side", "back"].index(p.angle)):
                imgs.append(images.normalize(loader.load(p.path),
                                             f"Week {body.week_index} {p.angle} (current)"))
        except FileNotFoundError:
            gate.refund()
            gate.abort()
            raise HTTPException(409, detail={"error": "upload_incomplete", "retry_after": 10})
        except images.BadImage as e:
            gate.refund()
            gate.abort()
            raise HTTPException(422, detail={"error": "bad_image", "msg": str(e)})

        pv = prompts.pinned_version(store, "checkin")
        s = get_settings()
        text = json.dumps({
            "week_index": body.week_index, "weight_kg": body.weight_kg,
            "previous_weight_kg": prev_weight, "survey": body.survey.model_dump(),
            "weights": [{"week": h.week_index, "kg": h.weight_kg} for h in body.history],
            "baseline_week": baseline.week_index if baseline else None})
        try:
            out, usage = provider.complete(
                route="checkin", model=s.model_for("checkin"), system=prompts.load("checkin", pv),
                text=text, images=imgs, schema=CheckinOut, effort="high", max_tokens=16000,
                context={"weight": body.weight_kg, "prev_weight": prev_weight,
                         "has_baseline": baseline is not None,
                         "weeks_since_baseline": body.week_index - (baseline.week_index
                                                                    if baseline else 0)})
            gate.charge(usage)
        except AiError as e:
            log.warning(json.dumps({"ai_error": str(e), "route": "checkin"}))
            gate.refund()
            gate.abort()  # let the client's queued retry run again with the same key
            store.save_checkin_report(uid, body.checkin_id, None, "queued")
            return CheckinAnalyzeResponse(checkin_id=body.checkin_id, ai_report=None,
                                          status="queued").model_dump(by_alias=True)

        deltas = [Delta.model_validate({"metric": d.metric, "from": d.start, "to": d.end,
                                        "unit": d.unit, "confidence": d.confidence})
                  for d in out.deltas] if out.photos_usable else [
            Delta.model_validate({"metric": d.metric, "from": d.start, "to": d.end,
                                  "unit": d.unit, "confidence": d.confidence})
            for d in out.deltas if d.metric == "weight_kg"]
        report = AiReport(summary=out.summary, deltas=deltas, plan_changes=out.plan_changes,
                          coach_note=out.coach_note, prompt_version=pv)
        report_dict = report.model_dump(by_alias=True)
        store.save_checkin_report(uid, body.checkin_id, report_dict, "done")
        resp = CheckinAnalyzeResponse(checkin_id=body.checkin_id, ai_report=report, status="done",
                                      morph_ready=baseline is not None and out.photos_usable)
        return gate.finish(resp.model_dump(by_alias=True))

    @app.post("/v1/meal/analyze", response_model=MealAi)
    def meal_analyze(body: MealAnalyzeRequest, uid: str = Depends(current_uid),
                     store: Store = Depends(store_dep), provider: Provider = Depends(provider_dep),
                     idempotency_key: str | None = Header(None)):
        img: Image | None = None
        if body.photo_b64:
            try:
                img = images.from_b64(body.photo_b64, "Meal photo")
            except images.BadImage as e:
                raise HTTPException(422, detail={"error": "bad_image", "msg": str(e)})
        gate = _gate(store, uid, Kind.MEAL, "meal", _clean_idem(idempotency_key))
        if gate.replay is not None:
            return gate.replay
        s = get_settings()
        pv = prompts.pinned_version(store, "meal")
        model = s.model_for("meal")
        h = request_hash("meal", pv, model, {
            "img": hashlib.sha256(img.b64.encode()).hexdigest() if img else None,
            "text": (body.text or "").lower()})
        cached = store.cache_get(h)
        if cached:
            return gate.finish(cached)
        try:
            out, usage = provider.complete(
                route="meal", model=model, system=prompts.load("meal", pv),
                text=f"Description: {body.text or '(none)'}", images=[img] if img else [],
                schema=MealOut, effort="low", max_tokens=2000)
            gate.charge(usage)
        except AiError as e:
            gate.refund()
            gate.abort()
            raise HTTPException(503, detail={"error": "ai_unavailable", "retry_after": 30,
                                             "transient": e.transient},
                                headers={"Retry-After": "30"})
        if not out.is_food:
            gate.refund()
            gate.abort()
            raise HTTPException(422, detail={"error": "not_food"})
        resp = MealAi(name=out.name, kcal=out.kcal, P=out.protein_g, C=out.carbs_g, F=out.fat_g,
                      confidence=out.confidence, model=usage.model).model_dump()
        store.cache_put(h, resp)
        return gate.finish(resp)

    @app.post("/v1/coach/chat", response_model=CoachChatResponse)
    def coach_chat(body: CoachChatRequest, uid: str = Depends(current_uid),
                   store: Store = Depends(store_dep), provider: Provider = Depends(provider_dep),
                   idempotency_key: str | None = Header(None)):
        flag = redflag.check_inbound(body.messages[-1].content)
        if flag:  # safe canned reply; never reaches the model, never costs a message
            return CoachChatResponse(reply=flag.reply, suggestions=[], flagged=True).model_dump()
        gate = _gate(store, uid, Kind.CHAT, "chat", _clean_idem(idempotency_key))
        if gate.replay is not None:
            return gate.replay
        s = get_settings()
        pv = prompts.pinned_version(store, "coach")
        transcript = "\n".join(f"{m.role.upper()}: {m.content}" for m in body.messages)
        try:
            out, usage = provider.complete(
                route="chat", model=s.model_for("chat"), system=prompts.load("coach", pv),
                text=f"Capsule: {body.capsule.model_dump_json()}\n\nConversation:\n{transcript}"
                     "\n\nReply to the last USER message.",
                images=[], schema=CoachOut, effort="low", max_tokens=4000)
            gate.charge(usage)
        except AiError:
            gate.refund()
            gate.abort()
            raise HTTPException(503, detail={"error": "ai_unavailable", "retry_after": 30},
                                headers={"Retry-After": "30"})
        if redflag.unsafe_outbound(out.reply):
            resp = CoachChatResponse(
                reply="Let's keep this safe and sustainable — I'd suggest checking specifics "
                      "with a doctor or registered dietitian. Want a training tip instead?",
                suggestions=["Today's workout", "Protein ideas"], flagged=True)
        else:
            resp = CoachChatResponse(reply=out.reply, suggestions=out.suggestions[:3])
        return gate.finish(resp.model_dump())

    @app.post("/v1/preview/render", response_model=PreviewRenderResponse)
    def preview_render(body: PreviewRenderRequest, uid: str = Depends(current_uid),
                       store: Store = Depends(store_dep),
                       idempotency_key: str | None = Header(None)):
        # Iteration-1 STUB: quota check + placeholder. No model is called.
        if not images.owned_path(uid, body.photo, PHOTO_ROOT):
            raise HTTPException(403, detail={"error": "photo_not_owned"})
        gate = _gate(store, uid, Kind.RENDER, "preview", _clean_idem(idempotency_key))
        if gate.replay is not None:
            return gate.replay
        pv = prompts.pinned_version(store, "preview")
        return gate.finish(PreviewRenderResponse(result_path=PREVIEW_PLACEHOLDER,
                                                 prompt_version=pv).model_dump())

    @app.post("/v1/admin/prompt-pin")
    def prompt_pin(body: PromptPinRequest, principal: str = Depends(admin_principal),
                   store: Store = Depends(store_dep)):
        if body.version not in prompts.available_versions(body.route):
            raise HTTPException(404, detail={"error": "unknown_version"})
        store.set_prompt_pin(body.route, body.version)
        prompts.invalidate_pins()
        log.info(json.dumps({"audit": "prompt_pin", "by": principal, **body.model_dump()}))
        return {"route": body.route, "version": body.version}

    @app.post("/v1/promo/redeem", response_model=PromoRedeemResponse)
    def promo_redeem(body: PromoRedeemRequest, request: Request, uid: str = Depends(current_uid),
                     store: Store = Depends(store_dep)):
        s: Settings = get_settings()
        now = datetime.now(timezone.utc)
        ip = (request.headers.get("x-forwarded-for", "").split(",")[0].strip()
              or (request.client.host if request.client else "unknown"))
        if not (store.rate_hit(f"promo_uid_{uid}", 3600, 5, now)
                and store.rate_hit(f"promo_ip_{hashlib.sha256(ip.encode()).hexdigest()[:16]}",
                                   3600, 20, now)):
            store.promo_audit(uid, "-", "rate_limited", now)
            raise HTTPException(429, detail={"error": "rate_limited", "retry_after": 3600},
                                headers={"Retry-After": "3600"})
        code = promo.normalize(body.code)
        if code is None:
            store.promo_audit(uid, "-", "malformed", now)
            raise HTTPException(400, detail={"error": "not_found"})
        h = promo.code_hash(code, s.promo_pepper)
        try:
            grant = store.promo_redeem(uid, h, now)
        except PromoError as e:
            store.promo_audit(uid, h, e.code, now)
            raise HTTPException(400, detail={"error": e.code})
        store.promo_audit(uid, h, "granted", now)
        promo.grant_revenuecat_promotional(s.revenuecat_secret, uid, grant.expires_at)
        return PromoRedeemResponse(result="granted", tier=grant.tier,
                                   expires_at=grant.expires_at.isoformat())


app = create_app()
