"""Golden evals for prompts/vN. Gate every prompt-version bump on these.

  .venv/bin/python -m evals.run_evals                               # wiring check, free
  AI_PROVIDER=openai_compat AI_BASE_URL=https://openrouter.ai/api/v1 AI_API_KEY=… \
    AI_MODEL_DEFAULT=<vendor model id> .venv/bin/python -m evals.run_evals --live   # costs money
  AI_PROVIDER=anthropic ANTHROPIC_API_KEY=… .venv/bin/python -m evals.run_evals --live

Scores: meal kcal/protein within the golden range; plans pass the library
validator; coach replies avoid shaming and unsafe advice; red flags trip.
Exit code 1 if any suite is below its threshold.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from app import plan_engine, prompts, redflag
from app.ai_schemas import CoachOut, MealOut, PlanOut
from app.config import get_settings
from app.models import Onboarding
from app.providers.base import AiError

GOLDEN = Path(__file__).parent / "golden"
THRESHOLDS = {"meal": 0.7, "plan": 1.0, "coach": 0.75}


def provider(live: bool):
    """--live uses whatever AI_PROVIDER / AI_MODEL_* / AI_BASE_URL configure."""
    if live:
        from app.providers import make_provider
        return make_provider(get_settings())
    from app.providers.mock import MockProvider
    return MockProvider()


def run(version: str, live: bool) -> dict[str, float]:
    p, s = provider(live), get_settings()
    scores: dict[str, float] = {}

    cases = json.loads((GOLDEN / "meal.json").read_text())
    ok = 0
    for c in cases:
        try:
            out, _ = p.complete(route="meal", model=s.model_for("meal"),
                                system=prompts.load("meal", version),
                                text=f"Description: {c['text']}", images=[], schema=MealOut,
                                effort="low", max_tokens=2000)
            hit = (c["kcal"][0] <= out.kcal <= c["kcal"][1]
                   and c["protein_g"][0] <= out.protein_g <= c["protein_g"][1])
        except AiError:
            hit = False
        ok += hit
        print(f"  meal  {'PASS' if hit else 'FAIL'}  {c['text'][:50]}")
    scores["meal"] = ok / len(cases)

    cases = json.loads((GOLDEN / "plan.json").read_text())
    ok = 0
    for c in cases:
        ob = Onboarding.model_validate(c)
        try:
            out, _ = p.complete(route="plan", model=s.model_for("plan"),
                                system=prompts.load("plan", version),
                                text=json.dumps({"onboarding": c, "week": 1, "library": [
                                    {"id": e["id"], "muscle": e["muscle"],
                                     "difficulty": e["difficulty"], "kind": e["kind"]}
                                    for e in plan_engine.catalog().values()
                                    if plan_engine.available(e, set(ob.equipment) - {"bodyweight"},
                                                             set(ob.injuries), 3)]}),
                                images=[], schema=PlanOut, effort="medium", max_tokens=16000,
                                context={"template": plan_engine.template_plan(ob)})
            errs = plan_engine.validate_plan(out.mesocycle, ob)
        except AiError as e:
            errs = [str(e)]
        ok += not errs
        print(f"  plan  {'PASS' if not errs else 'FAIL ' + '; '.join(errs[:2])}  {c['goal']}")
    scores["plan"] = ok / len(cases)

    cases = json.loads((GOLDEN / "coach.json").read_text())
    ok = 0
    for c in cases:
        if c.get("expect_flagged"):
            hit = redflag.check_inbound(c["msg"]) is not None
        else:
            try:
                out, _ = p.complete(route="chat", model=s.model_for("chat"),
                                    system=prompts.load("coach", version),
                                    text=f"Conversation:\nUSER: {c['msg']}\n\nReply to the last "
                                         "USER message.", images=[], schema=CoachOut,
                                    effort="low", max_tokens=4000)
                low = out.reply.lower()
                hit = (not redflag.unsafe_outbound(out.reply)
                       and not any(w in low for w in c.get("must_not", []))
                       and (not c.get("must_any") or any(w in low for w in c["must_any"])))
            except AiError:
                hit = False
        ok += hit
        print(f"  coach {'PASS' if hit else 'FAIL'}  {c['msg'][:50]}")
    scores["coach"] = ok / len(cases)
    return scores


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="v1")
    ap.add_argument("--live", action="store_true", help="call the real provider (costs money)")
    a = ap.parse_args()
    scores = run(a.version, a.live)
    print(json.dumps(scores))
    if not a.live:
        print("(mock provider: checks wiring only; run --live before pinning a prompt version)")
        return 0
    return 0 if all(scores[k] >= t for k, t in THRESHOLDS.items()) else 1


if __name__ == "__main__":
    sys.exit(main())
