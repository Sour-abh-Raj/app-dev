"""Versioned prompts (prompts/vN/<route>.md). The live version per route comes
from the admin pin in Firestore (config/prompts), defaulting to v1."""

from __future__ import annotations

import time
from functools import lru_cache
from pathlib import Path

from .store import Store

PROMPTS_DIR = Path(__file__).resolve().parents[1] / "prompts"
DEFAULT_VERSION = "v1"
_PIN_TTL_S = 60.0
_pins: tuple[float, dict[str, str]] = (0.0, {})


def available_versions(route: str) -> list[str]:
    return sorted(p.parent.name for p in PROMPTS_DIR.glob(f"v*/{route}.md"))


@lru_cache(maxsize=64)
def load(route: str, version: str) -> str:
    path = PROMPTS_DIR / version / f"{route}.md"
    return path.read_text().strip()


def pinned_version(store: Store, route: str) -> str:
    global _pins
    now = time.monotonic()
    if now - _pins[0] > _PIN_TTL_S:
        try:
            _pins = (now, store.prompt_pins())
        except Exception:  # pins are an optimisation; fall back to the default
            _pins = (now, {})
    version = _pins[1].get(route, DEFAULT_VERSION)
    return version if version in available_versions(route) else DEFAULT_VERSION


def invalidate_pins() -> None:
    global _pins
    _pins = (0.0, {})
