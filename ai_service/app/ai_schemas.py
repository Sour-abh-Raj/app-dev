"""Shapes the model must return (structured outputs). Kept separate from the
public API models so prompt changes never leak into the wire contract."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

from .models import Mesocycle


class PlanOut(BaseModel):
    mesocycle: Mesocycle


class DeltaOut(BaseModel):
    metric: Literal["waist_cm", "body_fat_pct", "weight_kg", "shoulder_waist_ratio"]
    start: float
    end: float
    unit: str
    confidence: float = Field(ge=0, le=1)


class CheckinOut(BaseModel):
    summary: str = Field(max_length=500)
    deltas: list[DeltaOut] = Field(max_length=4)
    plan_changes: list[str] = Field(max_length=4)
    coach_note: str = Field(max_length=400)
    photos_usable: bool


class MealOut(BaseModel):
    name: str = Field(max_length=80)
    kcal: int = Field(ge=0, le=5000)
    protein_g: float = Field(ge=0, le=400)
    carbs_g: float = Field(ge=0, le=800)
    fat_g: float = Field(ge=0, le=400)
    confidence: float = Field(ge=0, le=1)
    is_food: bool


class CoachOut(BaseModel):
    reply: str = Field(max_length=1200)
    suggestions: list[str] = Field(max_length=3)
