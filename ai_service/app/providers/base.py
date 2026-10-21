from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal, Protocol, TypeVar

from pydantic import BaseModel

T = TypeVar("T", bound=BaseModel)

Effort = Literal["low", "medium", "high"]


@dataclass(frozen=True)
class Image:
    media_type: str  # "image/jpeg"
    b64: str
    label: str = ""  # shown to the model before the image, e.g. "Week 1 front"


@dataclass
class Usage:
    model: str
    input_tokens: int = 0
    output_tokens: int = 0


class AiError(Exception):
    """Any provider failure. `transient` tells callers whether a retry may help."""

    def __init__(self, msg: str, transient: bool = True):
        super().__init__(msg)
        self.transient = transient


class Provider(Protocol):
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
    ) -> tuple[T, Usage]: ...
