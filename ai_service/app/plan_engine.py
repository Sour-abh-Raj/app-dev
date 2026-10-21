"""Deterministic template planner. Used when the model fails ("template applied")
and to validate AI plans against the exercise library. The Flutter app ships
the same algorithm (lib/features/plan/plan_engine.dart) for offline use; keep
the two in step."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

from .models import Mesocycle, Onboarding, PlanSession, PlanWeek, SessionExercise

SEED = Path(__file__).resolve().parents[2] / "seed" / "exercises.json"
SEED_FALLBACK = Path(__file__).resolve().parents[1] / "seed" / "exercises.json"

LEVEL_MAX_DIFFICULTY = {"beginner": 1, "intermediate": 2, "advanced": 3}

# Movement slots per session template, in priority order.
TEMPLATES: dict[str, list[str]] = {
    "full_a": ["quads", "chest", "back", "hamstrings", "shoulders", "core", "biceps"],
    "full_b": ["hamstrings", "back", "chest", "quads", "rear_delts", "core", "triceps"],
    "upper": ["chest", "back", "shoulders", "back", "triceps", "biceps", "rear_delts"],
    "lower": ["quads", "hamstrings", "glutes", "quads", "calves", "core", "hamstrings"],
    "push": ["chest", "shoulders", "chest", "triceps", "shoulders", "core", "triceps"],
    "pull": ["back", "back", "rear_delts", "biceps", "back", "core", "biceps"],
    "legs": ["quads", "hamstrings", "glutes", "quads", "calves", "core", "hamstrings"],
}
SPLITS: dict[int, list[str]] = {
    2: ["full_a", "full_b"],
    3: ["full_a", "full_b", "full_a"],
    4: ["upper", "lower", "upper", "lower"],
    5: ["push", "pull", "legs", "upper", "lower"],
    6: ["push", "pull", "legs", "push", "pull", "legs"],
}
# Training-day indexes (0 = Monday) per frequency.
DAYS: dict[int, list[int]] = {
    2: [0, 3], 3: [0, 2, 4], 4: [0, 1, 3, 4], 5: [0, 1, 2, 4, 5], 6: [0, 1, 2, 3, 4, 5],
}
NAMES = {"full_a": "Full-body A", "full_b": "Full-body B", "upper": "Upper", "lower": "Lower",
         "push": "Push", "pull": "Pull", "legs": "Legs"}

# (sets, reps, rest_s) per goal; time-based exercises use seconds instead.
DOSE = {
    "strength": (4, "5", 150),
    "build_muscle": (3, "8-12", 90),
    "recomp": (3, "8-10", 75),
    "lose_fat": (3, "10-15", 60),
    "tone_up": (3, "10-15", 60),
}


@lru_cache(maxsize=1)
def catalog() -> dict[str, dict]:
    path = SEED if SEED.exists() else SEED_FALLBACK
    data = json.loads(path.read_text())
    return {e["id"]: e for e in data["exercises"]}


def slots_for_minutes(mins: int) -> int:
    if mins < 30:
        return 4
    if mins < 45:
        return 5
    if mins <= 60:
        return 6
    return 7


def available(ex: dict, equipment: set[str], injuries: set[str], max_diff: int) -> bool:
    needs = {e for e in ex["equipment"] if e != "bodyweight"}
    return (needs <= equipment and not (set(ex["contraindications"]) & injuries)
            and ex["difficulty"] <= max_diff)


def pick(muscle: str, used: set[str], equipment: set[str], injuries: set[str],
         max_diff: int) -> dict | None:
    cands = [e for e in catalog().values()
             if e["muscle"] == muscle and e["id"] not in used
             and available(e, equipment, injuries, max_diff)]
    # Hardest allowed first (most stimulus for the level), then loadable over
    # bodyweight, then a stable id order.
    cands.sort(key=lambda e: (-e["difficulty"],
                              -len([q for q in e["equipment"] if q != "bodyweight"]), e["id"]))
    return cands[0] if cands else None


def template_plan(ob: Onboarding) -> Mesocycle:
    equipment = set(ob.equipment) - {"bodyweight"}
    injuries = set(ob.injuries)
    max_diff = LEVEL_MAX_DIFFICULTY[ob.level]
    sets, reps, rest = DOSE[ob.goal]
    n_slots = slots_for_minutes(ob.mins)

    base_sessions: list[PlanSession] = []
    for day, tmpl in zip(DAYS[ob.days_per_week], SPLITS[ob.days_per_week]):
        used: set[str] = set()
        exercises: list[SessionExercise] = []
        # Second pass fills slots the first pass could not (level/equipment limits).
        for muscle in TEMPLATES[tmpl] * 2:
            if len(exercises) >= n_slots:
                break
            ex = pick(muscle, used, equipment, injuries, max_diff)
            if ex is None:
                continue
            used.add(ex["id"])
            timed = ex["kind"] == "time"
            exercises.append(SessionExercise(
                ex_id=ex["id"], sets=3 if timed else sets,
                reps="30s" if timed else reps, load_kg=None, rest_s=60 if timed else rest))
        if not exercises:  # pathological equipment/injury combo: fall back to safe core work
            exercises = [SessionExercise(ex_id="dead_bug", sets=3, reps="10", rest_s=45),
                         SessionExercise(ex_id="glute_bridge", sets=3, reps="12", rest_s=45)]
        base_sessions.append(PlanSession(day_index=day, name=NAMES[tmpl], est_mins=ob.mins,
                                         exercises=exercises))

    weeks: list[PlanWeek] = []
    for w in range(1, 5):
        sessions = []
        for s in base_sessions:
            exs = []
            for i, e in enumerate(s.exercises):
                delta = 0
                if w in (2, 3) and i == 0:
                    delta = 1  # progressive overload on the main lift
                if w == 4:
                    delta = -1  # deload
                exs.append(e.model_copy(update={"sets": max(1, e.sets + delta)}))
            sessions.append(s.model_copy(update={"exercises": exs}))
        weeks.append(PlanWeek(week_index=w, sessions=sessions))

    kcal, protein = nutrition_targets(ob)
    return Mesocycle(name=f"{NAMES[SPLITS[ob.days_per_week][0]]} · {ob.days_per_week}x/week",
                     weeks=weeks, kcal_target=kcal, protein_g=protein,
                     notes="Starter template. Week 4 is a deload.")


def nutrition_targets(ob: Onboarding) -> tuple[int | None, int | None]:
    if not (ob.weight_kg and ob.height_cm):
        return None, None
    # Mifflin-St Jeor with a neutral constant when sex is unknown; age assumed 30.
    s = {"male": 5, "female": -161}.get(ob.sex or "", -78)
    bmr = 10 * ob.weight_kg + 6.25 * ob.height_cm - 5 * 30 + s
    tdee = bmr * (1.2 + 0.075 * ob.days_per_week)
    adj = {"lose_fat": -0.2, "tone_up": -0.1, "recomp": -0.05, "build_muscle": 0.1,
           "strength": 0.05}[ob.goal]
    kcal = int(round(max(1200, tdee * (1 + adj)) / 10) * 10)
    protein = int(round(ob.weight_kg * (2.0 if ob.goal != "strength" else 1.8)))
    return kcal, min(protein, 300)


def validate_plan(plan: Mesocycle, ob: Onboarding) -> list[str]:
    """Problems that make an AI plan unusable for this user; empty = OK."""
    cat = catalog()
    equipment = set(ob.equipment) - {"bodyweight"}
    injuries = set(ob.injuries)
    errors: list[str] = []
    for w in plan.weeks:
        for s in w.sessions:
            for e in s.exercises:
                ex = cat.get(e.ex_id)
                if ex is None:
                    errors.append(f"unknown exercise {e.ex_id}")
                elif not available(ex, equipment, injuries, 3):
                    errors.append(f"{e.ex_id} not allowed for equipment/injuries")
        if len(w.sessions) != ob.days_per_week:
            errors.append(f"week {w.week_index}: {len(w.sessions)} sessions, "
                          f"expected {ob.days_per_week}")
    return errors
