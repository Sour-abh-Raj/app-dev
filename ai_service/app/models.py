"""Request/response schemas for every /v1 route."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Goal = Literal["lose_fat", "build_muscle", "recomp", "strength", "tone_up"]
Level = Literal["beginner", "intermediate", "advanced"]
Angle = Literal["front", "side", "back"]


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


# ---------- plan ----------


class Onboarding(_Strict):
    goal: Goal
    level: Level
    equipment: list[str] = Field(min_length=1, max_length=12)
    days_per_week: int = Field(ge=2, le=6)
    mins: int = Field(ge=15, le=90)
    injuries: list[str] = Field(default_factory=list, max_length=10)
    injury_notes: str = Field(default="", max_length=500)
    sex: Literal["male", "female", "other"] | None = None
    height_cm: float | None = Field(default=None, ge=100, le=250)
    weight_kg: float | None = Field(default=None, ge=30, le=300)
    target_kg: float | None = Field(default=None, ge=30, le=300)


class PlanGenerateRequest(_Strict):
    onboarding: Onboarding


class SessionExercise(_Strict):
    ex_id: str
    sets: int = Field(ge=1, le=8)
    reps: str = Field(max_length=16)  # "8-10", "30s", "10/side"
    load_kg: float | None = Field(default=None, ge=0, le=400)
    rest_s: int = Field(ge=15, le=300)


class PlanSession(_Strict):
    day_index: int = Field(ge=0, le=6)
    name: str = Field(max_length=60)
    est_mins: int = Field(ge=10, le=120)
    exercises: list[SessionExercise] = Field(min_length=1, max_length=12)


class PlanWeek(_Strict):
    week_index: int = Field(ge=1, le=12)
    sessions: list[PlanSession] = Field(min_length=1, max_length=7)


class Mesocycle(_Strict):
    name: str = Field(max_length=80)
    weeks: list[PlanWeek] = Field(min_length=1, max_length=6)
    kcal_target: int | None = Field(default=None, ge=1200, le=5000)
    protein_g: int | None = Field(default=None, ge=40, le=300)
    notes: str = Field(default="", max_length=600)


class PlanResponse(BaseModel):
    version: int
    week_index: int
    mesocycle: Mesocycle
    source: Literal["ai", "template"]
    prompt_version: str
    queued: bool = False  # True => AI failed; template applied, analysis queued


class Adherence(_Strict):
    planned_sessions: int = Field(ge=0, le=14)
    completed_sessions: int = Field(ge=0, le=14)
    avg_rpe: float | None = Field(default=None, ge=1, le=10)


class Survey(_Strict):
    adherence: int = Field(ge=1, le=5)
    sleep: int = Field(ge=1, le=5)
    soreness: int = Field(ge=1, le=5)
    motivation: int = Field(ge=1, le=5)


class PlanRegenerateRequest(_Strict):
    uid: str
    week: int = Field(ge=1, le=520)
    adherence: Adherence
    survey: Survey | None = None
    current: Mesocycle | None = None


# ---------- check-in ----------


class PhotoRef(_Strict):
    angle: Angle
    path: str = Field(max_length=300)


class HistoryPoint(_Strict):
    week_index: int = Field(ge=0, le=520)
    weight_kg: float | None = Field(default=None, ge=30, le=300)
    photos: list[PhotoRef] = Field(default_factory=list, max_length=3)


class CheckinAnalyzeRequest(_Strict):
    checkin_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,60}$")
    week_index: int = Field(ge=1, le=520)
    weight_kg: float | None = Field(default=None, ge=30, le=300)
    photos: list[PhotoRef] = Field(min_length=3, max_length=3)
    survey: Survey
    history: list[HistoryPoint] = Field(default_factory=list, max_length=12)

    @field_validator("photos")
    @classmethod
    def _three_angles(cls, v: list[PhotoRef]) -> list[PhotoRef]:
        if sorted(p.angle for p in v) != ["back", "front", "side"]:
            raise ValueError("photos must be exactly one front, one side, one back")
        return v


class Delta(BaseModel):
    metric: Literal["waist_cm", "body_fat_pct", "weight_kg", "shoulder_waist_ratio"]
    from_: float = Field(alias="from")
    to: float
    unit: str
    confidence: float = Field(ge=0, le=1)

    model_config = ConfigDict(populate_by_name=True)


class AiReport(BaseModel):
    summary: str
    deltas: list[Delta]
    plan_changes: list[str]
    coach_note: str
    prompt_version: str


class CheckinAnalyzeResponse(BaseModel):
    checkin_id: str
    ai_report: AiReport | None
    status: Literal["done", "queued"]
    morph_ready: bool = False


# ---------- meal ----------


class MealAnalyzeRequest(_Strict):
    photo_b64: str | None = Field(default=None, max_length=2_000_000)
    text: str | None = Field(default=None, max_length=500)

    @field_validator("text")
    @classmethod
    def _strip(cls, v: str | None) -> str | None:
        return v.strip() if v else v

    @model_validator(mode="after")
    def _one_input(self) -> "MealAnalyzeRequest":
        if not self.photo_b64 and not self.text:
            raise ValueError("photo_b64 or text required")
        return self


class MealAi(BaseModel):
    name: str
    kcal: int = Field(ge=0, le=5000)
    P: float = Field(ge=0, le=400)
    C: float = Field(ge=0, le=800)
    F: float = Field(ge=0, le=400)
    confidence: float = Field(ge=0, le=1)
    model: str


# ---------- coach ----------


class ChatMessage(_Strict):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=2000)


class Capsule(_Strict):
    """Compact user context the client sends with each chat turn."""

    name: str = Field(default="", max_length=40)
    goal: Goal | None = None
    level: Level | None = None
    week_index: int | None = Field(default=None, ge=0, le=520)
    adherence_pct: int | None = Field(default=None, ge=0, le=100)
    injuries: list[str] = Field(default_factory=list, max_length=10)
    last_report_summary: str = Field(default="", max_length=600)


class CoachChatRequest(_Strict):
    messages: list[ChatMessage] = Field(min_length=1, max_length=40)
    capsule: Capsule = Field(default_factory=Capsule)

    @field_validator("messages")
    @classmethod
    def _last_is_user(cls, v: list[ChatMessage]) -> list[ChatMessage]:
        if v[-1].role != "user":
            raise ValueError("last message must be from the user")
        return v[-12:]  # spec: only the last 12 messages are used


class CoachChatResponse(BaseModel):
    reply: str
    suggestions: list[str]
    flagged: bool = False


# ---------- preview (stub) ----------


class PreviewRenderRequest(_Strict):
    photo: str = Field(max_length=300)  # storage path of the source photo
    goal: str = Field(max_length=200)


class PreviewRenderResponse(BaseModel):
    result_path: str
    prompt_version: str
    stub: bool = True


# ---------- promo / admin ----------


class PromoRedeemRequest(_Strict):
    code: str = Field(min_length=4, max_length=40)


class PromoRedeemResponse(BaseModel):
    result: Literal["granted"]
    tier: str
    expires_at: str


class PromptPinRequest(_Strict):
    route: Literal["plan", "checkin", "meal", "coach", "preview"]
    version: str = Field(pattern=r"^v\d+$")
