from __future__ import annotations

import base64
import io
import os

import pytest
from fastapi import Header, HTTPException, Request
from fastapi.testclient import TestClient
from PIL import Image

os.environ.setdefault("AI_PROVIDER", "mock")
os.environ.setdefault("STORE", "memory")
os.environ.setdefault("PROMO_PEPPER", "test-pepper")

from app import prompts  # noqa: E402
from app.auth import current_uid  # noqa: E402
from app.config import reset_settings  # noqa: E402
from app.images import MemoryLoader  # noqa: E402
from app.main import create_app  # noqa: E402
from app.providers.mock import MockProvider  # noqa: E402
from app.store import MemoryStore, set_store  # noqa: E402


async def fake_uid(request: Request, authorization: str | None = Header(None)) -> str:
    if not authorization or not authorization.startswith("Bearer test:"):
        raise HTTPException(401, detail={"error": "unauthenticated"})
    uid = authorization.split(":", 1)[1]
    request.state.uid = uid
    return uid


def jpeg_bytes(w: int = 2000, h: int = 1500, color=(120, 140, 160)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, format="JPEG")
    return buf.getvalue()


def jpeg_b64(**kw) -> str:
    return base64.b64encode(jpeg_bytes(**kw)).decode()


class Env:
    def __init__(self) -> None:
        reset_settings()
        prompts.invalidate_pins()
        self.store = MemoryStore()
        set_store(self.store)
        self.provider = MockProvider()
        self.loader = MemoryLoader()
        from app import main as main_mod

        main_mod._burst.rates.clear()  # per-instance burst limiter is module state
        app = create_app()
        app.state.provider = self.provider
        app.state.loader = self.loader
        app.dependency_overrides[current_uid] = fake_uid
        self.app = app
        self.client = TestClient(app)

    def post(self, path: str, json: dict, uid: str = "u1", idem: str | None = None, **headers):
        h = {"Authorization": f"Bearer test:{uid}", **headers}
        if idem:
            h["Idempotency-Key"] = idem
        return self.client.post(path, json=json, headers=h)

    def make_pro(self, uid: str = "u1") -> None:
        self.store.subs[uid] = {"active": True}

    def add_photos(self, uid: str, checkin: str) -> list[dict]:
        refs = []
        for angle in ("front", "side", "back"):
            path = f"progress-photos/{uid}/{checkin}/{angle}.jpg"
            self.loader.files[path] = jpeg_bytes()
            refs.append({"angle": angle, "path": path})
        return refs


@pytest.fixture
def env() -> Env:
    e = Env()
    yield e
    set_store(None)
    reset_settings()


ONBOARDING = {
    "goal": "lose_fat", "level": "beginner", "equipment": ["dumbbells"],
    "days_per_week": 3, "mins": 30, "injuries": [], "sex": "male",
    "height_cm": 178, "weight_kg": 82,
}
