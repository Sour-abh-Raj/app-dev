"""Deterministic provider for tests, CI, evals and offline development. It
returns plausible, schema-valid output derived from the request context."""

from __future__ import annotations

import hashlib
import os
from typing import Any

from ..ai_schemas import CheckinOut, CoachOut, DeltaOut, MealOut, PlanOut
from .base import AiError, Effort, Image, T, Usage


class MockProvider:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.fail_next: AiError | None = None

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
        ctx = context or {}
        self.calls.append({"route": route, "model": model, "images": len(images), "ctx": ctx})
        if self.fail_next is not None:
            err, self.fail_next = self.fail_next, None
            raise err
        # MOCK_USAGE_MODEL=claude-opus-5-5 makes load tests bill realistic costs.
        usage = Usage(model=os.environ.get("MOCK_USAGE_MODEL", "mock"),
                      input_tokens=1000 + 1500 * len(images), output_tokens=400)
        if schema is PlanOut:
            return schema(mesocycle=ctx["template"]), usage  # type: ignore[return-value]
        if schema is CheckinOut:
            return self._checkin(ctx), usage  # type: ignore[return-value]
        if schema is MealOut:
            return self._meal(text), usage  # type: ignore[return-value]
        if schema is CoachOut:
            return CoachOut(  # type: ignore[return-value]
                reply="Nice work showing up this week. Keep the next session short and "
                      "focused — quality reps beat volume when sleep is low.",
                suggestions=["Swap an exercise", "20-min catch-up?", "Protein ideas"]), usage
        raise AiError(f"mock: no canned output for {schema.__name__}", transient=False)

    @staticmethod
    def _checkin(ctx: dict[str, Any]) -> CheckinOut:
        deltas: list[DeltaOut] = []
        prev_w, cur_w = ctx.get("prev_weight"), ctx.get("weight")
        if prev_w and cur_w:
            deltas.append(DeltaOut(metric="weight_kg", start=prev_w, end=cur_w, unit="kg",
                                   confidence=0.95))
        if ctx.get("has_baseline"):
            weeks = max(1, ctx.get("weeks_since_baseline", 1))
            deltas.append(DeltaOut(metric="waist_cm", start=86.0, end=round(86.0 - 0.8 * weeks, 1),
                                   unit="cm", confidence=0.6))
            deltas.append(DeltaOut(metric="body_fat_pct", start=22.0,
                                   end=round(22.0 - 0.35 * weeks, 1), unit="%", confidence=0.5))
        return CheckinOut(
            summary="Steady week. Your midsection looks tighter in the side view and your "
                    "weight trend is moving the right way.",
            deltas=deltas,
            plan_changes=["+2.5 kg on lower-body lifts", "Protein → 140 g"],
            coach_note="Consistency is showing — keep stacking weeks like this.",
            photos_usable=True)

    @staticmethod
    def _meal(text: str) -> MealOut:
        h = int(hashlib.sha256(text.encode()).hexdigest()[:6], 16)
        kcal = 350 + h % 500
        return MealOut(name="Chicken rice bowl", kcal=kcal, protein_g=round(kcal * 0.3 / 4, 1),
                       carbs_g=round(kcal * 0.45 / 4, 1), fat_g=round(kcal * 0.25 / 9, 1),
                       confidence=0.8, is_food=True)
