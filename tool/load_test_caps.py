"""Exit bar 4: every AI cap returns 429 + retry_after + paywall link under
concurrent load, and the per-user spend ceiling holds.

Runs the real service (Firestore store, Firebase ID-token auth) against the
Auth + Firestore emulators with the deterministic mock provider:

  firebase emulators:exec --only auth,firestore --project forme-load \
    "ai_service/.venv/bin/python tool/load_test_caps.py"
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import sys
import time
from collections import Counter

import httpx

PROJECT = os.environ.get("GCLOUD_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT") or "forme-load"
AUTH = os.environ.get("FIREBASE_AUTH_EMULATOR_HOST", "127.0.0.1:9099")
PORT = 18765
BASE = f"http://127.0.0.1:{PORT}"


def start_service() -> subprocess.Popen:
    env = {**os.environ, "AI_PROVIDER": "mock", "STORE": "firestore", "PROMO_PEPPER": "load",
           "MOCK_USAGE_MODEL": "claude-opus-5-5",  # bill realistic costs
           "GOOGLE_CLOUD_PROJECT": PROJECT, "FIREBASE_AUTH_EMULATOR_HOST": AUTH}
    p = subprocess.Popen([sys.executable, "-m", "uvicorn", "app.main:app", "--port", str(PORT),
                          "--workers", "2", "--log-level", "warning"], cwd="ai_service", env=env)
    for _ in range(60):
        try:
            if httpx.get(f"{BASE}/healthz", timeout=1).status_code == 200:
                return p
        except httpx.HTTPError:
            time.sleep(0.25)
    p.kill()
    raise SystemExit("service did not start")


def user_token(email: str) -> str:
    r = httpx.post(f"http://{AUTH}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake",
                   json={"email": email, "password": "password123", "returnSecureToken": True})
    r.raise_for_status()
    return r.json()["idToken"]


async def burst(token: str, path: str, bodies: list[dict]) -> list[httpx.Response]:
    h = {"Authorization": f"Bearer {token}"}
    async with httpx.AsyncClient(base_url=BASE, timeout=60) as c:
        return await asyncio.gather(*(c.post(path, json=b, headers=h) for b in bodies))


def uid_of(token: str) -> str:
    r = httpx.post(f"http://{AUTH}/identitytoolkit.googleapis.com/v1/accounts:lookup?key=fake",
                   json={"idToken": token})
    return r.json()["users"][0]["localId"]


def make_pro(uid: str, spend_usd: float = 0.0) -> None:
    from datetime import datetime, timezone

    from google.cloud import firestore

    db = firestore.Client(project=PROJECT)
    db.collection("subscriptions").document(uid).set({"active": True})
    if spend_usd:
        month = datetime.now(timezone.utc).strftime("%Y-%m")
        db.collection("users").document(uid).collection("usage").document(
            f"spend_{month}").set({"usd": spend_usd})


def spend_of(uid: str) -> float:
    from datetime import datetime, timezone

    from google.cloud import firestore

    month = datetime.now(timezone.utc).strftime("%Y-%m")
    snap = firestore.Client(project=PROJECT).collection("users").document(uid).collection(
        "usage").document(f"spend_{month}").get()
    return float((snap.to_dict() or {}).get("usd", 0.0))


def check(name: str, resps: list[httpx.Response], allowed: int, cap: str) -> bool:
    codes = Counter(r.status_code for r in resps)
    capped = [r for r in resps if r.status_code == 429]
    ok = codes[200] == allowed and len(capped) == len(resps) - allowed
    for r in capped:
        j = r.json()
        ok &= (j.get("error") == "cap_reached" and j.get("cap") == cap
               and j.get("paywall", "").startswith("forme://paywall")
               and int(r.headers.get("retry-after", "0")) > 0 and j.get("retry_after", 0) > 0)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {dict(codes)} (expected {allowed}×200)")
    return ok


def main() -> int:
    svc = start_service()
    results = []
    try:
        t = user_token("free-meal@load.test")
        # 25 concurrent meal scans, free tier: exactly 3 succeed.
        results.append(check("free meal cap (3/day)", asyncio.run(
            burst(t, "/v1/meal/analyze", [{"text": f"meal {i}"} for i in range(25)])), 3, "meal"))
        t = user_token("free-chat@load.test")
        msgs = [{"messages": [{"role": "user", "content": f"tip {i}?"}]} for i in range(25)]
        results.append(check("free chat cap (5 total)", asyncio.run(
            burst(t, "/v1/coach/chat", msgs)), 5, "chat"))
        t = user_token("free-photo@load.test")
        body = {"photo": "progress-photos/x/c/front.jpg", "goal": "lean"}
        r = asyncio.run(burst(t, "/v1/preview/render", [body] * 10))
        # Foreign photo path → 403 before any cap; use own uid path instead.
        print(f"INFO  render with foreign path: {Counter(x.status_code for x in r)}")
        uid = uid_of(t)
        body = {"photo": f"progress-photos/{uid}/c/front.jpg", "goal": "lean"}
        results.append(check("free render (not included)", asyncio.run(
            burst(t, "/v1/preview/render", [body] * 10)), 0, "render"))
        t = user_token("free-plan@load.test")
        ob = {"onboarding": {"goal": "lose_fat", "level": "beginner", "equipment": ["dumbbells"],
                             "days_per_week": 3, "mins": 30}}
        results.append(check("free plan generate (1 lifetime)", asyncio.run(
            burst(t, "/v1/plan/generate", [ob] * 12)), 1, "plan_generate"))
        # Pro: 40 concurrent meal scans → exactly 15 (daily Pro cap).
        t = user_token("pro-meal@load.test")
        make_pro(uid_of(t))
        results.append(check("pro meal cap (15/day)", asyncio.run(
            burst(t, "/v1/meal/analyze", [{"text": f"pro meal {i}"} for i in range(40)])),
            15, "meal"))
        # Pro near the $1.50 ceiling: 30 concurrent chats must not overshoot it.
        t = user_token("pro-spend@load.test")
        uid = uid_of(t)
        make_pro(uid, spend_usd=1.40)
        msgs = [{"messages": [{"role": "user", "content": f"q{i}"}]} for i in range(30)]
        r = asyncio.run(burst(t, "/v1/coach/chat", msgs))
        ok = all(x.status_code in (200, 429) for x in r)
        capped = [x.json() for x in r if x.status_code == 429]
        ok &= bool(capped) and all(c["cap"] == "spend" and c["paywall"] for c in capped)
        spent = spend_of(uid)
        ok &= spent <= 1.50 + 1e-9
        print(f"{'PASS' if ok else 'FAIL'}  pro spend ceiling: "
              f"{dict(Counter(x.status_code for x in r))}, spend ${spent:.4f} ≤ $1.50")
        results.append(ok)
    finally:
        svc.terminate()
        svc.wait(timeout=10)
    print("ALL PASS" if all(results) else "FAILURES")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
