from __future__ import annotations

import pytest

from app import images, plan_engine, prompts, redflag
from app.models import Onboarding
from app.store import MemoryStore

from .conftest import ONBOARDING, jpeg_bytes


# ---------- plan engine ----------

def test_catalog_has_60_exercises_with_valid_substitutions():
    cat = plan_engine.catalog()
    assert len(cat) == 60
    for e in cat.values():
        assert all(s in cat for s in e["substitutions"]), e["id"]
        assert len(e["cues"]) >= 2


@pytest.mark.parametrize("days", [2, 3, 4, 5, 6])
@pytest.mark.parametrize("equipment", [["bodyweight"], ["dumbbells", "bench"],
                                       ["barbell", "bench", "dumbbells", "cable", "machine"]])
def test_template_plan_valid_for_all_splits(days, equipment):
    ob = Onboarding.model_validate({**ONBOARDING, "days_per_week": days, "equipment": equipment})
    plan = plan_engine.template_plan(ob)
    assert plan_engine.validate_plan(plan, ob) == []
    assert len(plan.weeks) == 4


def test_template_respects_injuries():
    ob = Onboarding.model_validate({**ONBOARDING, "injuries": ["knee", "shoulder"]})
    plan = plan_engine.template_plan(ob)
    cat = plan_engine.catalog()
    for w in plan.weeks:
        for s in w.sessions:
            for e in s.exercises:
                assert not {"knee", "shoulder"} & set(cat[e.ex_id]["contraindications"])


def test_template_deload_week():
    ob = Onboarding.model_validate(ONBOARDING)
    plan = plan_engine.template_plan(ob)
    w1, w2, w4 = plan.weeks[0], plan.weeks[1], plan.weeks[3]
    assert w2.sessions[0].exercises[0].sets == w1.sessions[0].exercises[0].sets + 1
    assert w4.sessions[0].exercises[1].sets == w1.sessions[0].exercises[1].sets - 1


def test_session_length_scales_with_minutes():
    short = plan_engine.template_plan(Onboarding.model_validate({**ONBOARDING, "mins": 20}))
    long = plan_engine.template_plan(Onboarding.model_validate({**ONBOARDING, "mins": 75,
                                                                "equipment": ["dumbbells",
                                                                              "bench", "cable"]}))
    assert len(short.weeks[0].sessions[0].exercises) == 4
    assert len(long.weeks[0].sessions[0].exercises) == 7


def test_validate_plan_flags_bad_ai_output():
    ob = Onboarding.model_validate(ONBOARDING)
    plan = plan_engine.template_plan(ob)
    bad = plan.model_copy(deep=True)
    bad.weeks[0].sessions[0].exercises[0].ex_id = "back_squat"  # needs a barbell
    bad.weeks[1].sessions[0].exercises[0].ex_id = "made_up"
    errs = plan_engine.validate_plan(bad, ob)
    assert any("back_squat" in e for e in errs) and any("made_up" in e for e in errs)


def test_nutrition_targets():
    ob = Onboarding.model_validate(ONBOARDING)
    kcal, protein = plan_engine.nutrition_targets(ob)
    assert 1500 < kcal < 2600 and protein == 164
    assert plan_engine.nutrition_targets(
        Onboarding.model_validate({**ONBOARDING, "weight_kg": None})) == (None, None)


# ---------- images ----------

def test_normalize_downscales_and_strips():
    img = images.normalize(jpeg_bytes(3000, 1000))
    from PIL import Image
    import base64
    import io
    im = Image.open(io.BytesIO(base64.b64decode(img.b64)))
    assert max(im.size) == 1024 and im.getexif() == {}


def test_normalize_rejects_garbage():
    with pytest.raises(images.BadImage):
        images.normalize(b"not an image")


@pytest.mark.parametrize("path,ok", [
    ("progress-photos/u1/c1/front.jpg", True),
    ("progress-photos/u2/c1/front.jpg", False),
    ("progress-photos/u1/../u2/front.jpg", False),
    ("meals/u1/x.jpg", False),
    ("progress-photos/u1", False),
])
def test_owned_path(path, ok):
    assert images.owned_path("u1", path, "progress-photos") is ok


# ---------- red flags ----------

@pytest.mark.parametrize("text,cat", [
    ("I have chest pain on the treadmill", "cardiac"),
    ("Felt a sharp pain in my knee", "injury"),
    ("should I eat 800 calories a day", "eating_disorder"),
    ("best steroid cycle?", "peds"),
    ("I want to kill myself", "self_harm"),
])
def test_redflags(text, cat):
    flag = redflag.check_inbound(text)
    assert flag is not None and flag.category == cat


def test_no_false_positive_on_normal_question():
    assert redflag.check_inbound("How many sets of squats should I do?") is None


def test_unsafe_outbound():
    assert redflag.unsafe_outbound("Try eating 900 kcal a day")
    assert not redflag.unsafe_outbound("Aim for about 2200 kcal a day")


# ---------- prompts ----------

def test_prompts_exist_for_every_route():
    for route in ("plan", "checkin", "meal", "coach", "preview"):
        assert prompts.load(route, "v1")


def test_pin_falls_back_when_version_missing():
    prompts.invalidate_pins()
    s = MemoryStore()
    s.set_prompt_pin("coach", "v99")
    assert prompts.pinned_version(s, "coach") == "v1"
    prompts.invalidate_pins()
