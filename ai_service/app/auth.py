"""Firebase ID-token auth for app routes; Google service-account OIDC for admin."""

from __future__ import annotations

from fastapi import Header, HTTPException, Request

from .config import get_settings


def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, detail={"error": "unauthenticated"})
    return authorization.split(" ", 1)[1].strip()


def _firebase_app():
    import firebase_admin

    try:
        return firebase_admin.get_app()
    except ValueError:
        return firebase_admin.initialize_app()


async def current_uid(request: Request, authorization: str | None = Header(None)) -> str:
    """Verifies the Firebase ID token (honours FIREBASE_AUTH_EMULATOR_HOST in dev)."""
    token = _bearer(authorization)
    from firebase_admin import auth as fb_auth

    try:
        decoded = fb_auth.verify_id_token(token, app=_firebase_app())
    except Exception as e:  # any verification failure is a 401, never a 500
        raise HTTPException(401, detail={"error": "invalid_token"}) from e
    if decoded.get("deleted"):
        raise HTTPException(403, detail={"error": "account_deleted"})
    request.state.uid = decoded["uid"]
    return decoded["uid"]


async def admin_principal(authorization: str | None = Header(None)) -> str:
    """Only allow-listed Google service accounts may call /v1/admin/*."""
    token = _bearer(authorization)
    s = get_settings()
    if not s.admin_service_accounts or not s.admin_audience:
        raise HTTPException(403, detail={"error": "admin_disabled"})
    from google.auth.transport import requests as g_requests
    from google.oauth2 import id_token

    try:
        claims = id_token.verify_oauth2_token(token, g_requests.Request(), s.admin_audience)
    except Exception as e:
        raise HTTPException(401, detail={"error": "invalid_token"}) from e
    email = claims.get("email", "")
    if not claims.get("email_verified") or email not in s.admin_service_accounts:
        raise HTTPException(403, detail={"error": "forbidden"})
    return email
