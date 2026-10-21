"""Image access and normalisation. O5: every vision input is ≤1024 px."""

from __future__ import annotations

import base64
import io
from typing import Protocol

from PIL import Image as PILImage, UnidentifiedImageError

from .providers.base import Image

MAX_EDGE = 1024
MAX_BYTES = 8 * 1024 * 1024


class BadImage(ValueError):
    pass


def normalize(raw: bytes, label: str = "") -> Image:
    """Decode, strip metadata (EXIF/GPS), downscale to ≤1024 px, re-encode JPEG."""
    if len(raw) > MAX_BYTES:
        raise BadImage("image too large")
    try:
        im = PILImage.open(io.BytesIO(raw))
        im.load()
    except (UnidentifiedImageError, OSError) as e:
        raise BadImage("not an image") from e
    im = im.convert("RGB")
    im.thumbnail((MAX_EDGE, MAX_EDGE))
    out = io.BytesIO()
    im.save(out, format="JPEG", quality=85)
    return Image(media_type="image/jpeg", b64=base64.b64encode(out.getvalue()).decode(),
                 label=label)


def from_b64(b64: str, label: str = "") -> Image:
    try:
        raw = base64.b64decode(b64, validate=True)
    except ValueError as e:
        raise BadImage("invalid base64") from e
    return normalize(raw, label)


def owned_path(uid: str, path: str, root: str) -> bool:
    """Photos must live under <root>/<uid>/ — users can only analyse their own."""
    parts = path.split("/")
    return (len(parts) >= 3 and parts[0] == root and parts[1] == uid
            and ".." not in parts and all(parts))


class ImageLoader(Protocol):
    def load(self, path: str) -> bytes: ...


class GcsLoader:
    def __init__(self, bucket: str) -> None:
        from google.cloud import storage

        self.bucket = storage.Client().bucket(bucket)

    def load(self, path: str) -> bytes:
        # Prefer the pre-made 1024px variant written by the upload pipeline.
        if path.endswith(".jpg"):
            variant = self.bucket.blob(path[:-4] + "_1024.jpg")
            if variant.exists():
                return variant.download_as_bytes()
        return self.bucket.blob(path).download_as_bytes()


class MemoryLoader:
    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}

    def load(self, path: str) -> bytes:
        if path not in self.files:
            raise FileNotFoundError(path)
        return self.files[path]
