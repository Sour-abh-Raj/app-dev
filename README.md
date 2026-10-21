# Forme AI — Iteration 1

> “See yourself changing.” An AI personal trainer that watches weekly progress
> photos and adapts the plan.

This repo holds the whole iteration-1 prototype. Status against the exit bar is in
[`docs/EXIT_BAR.md`](docs/EXIT_BAR.md); read it first. Also see
[`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md) and the conflicts log in
[`docs/CONFLICTS.md`](docs/CONFLICTS.md).

| Path | What |
|---|---|
| `app/` | Flutter 3.47 app: Riverpod, go_router, Hive offline outbox, RevenueCat, Firebase, ML Kit Pose, `health` |
| `ai_service/` | FastAPI AI service for Cloud Run (Claude API, server-side keys), with caps, spend ceiling, idempotency, promo redemption and versioned prompts |
| `functions/` | Firebase Functions (TypeScript): RevenueCat webhook mirror, trial nudges, check-in reminders, account purge, photo variants, seeding |
| `firebase/` | Firestore and Storage security rules, plus composite indexes |
| `seed/exercises.json` | The 60-exercise library shared by app and server (CI checks that the app copy matches) |
| `tool/` | Coverage gate, seed-sync check, concurrent cap load test |
| `.github/workflows/ci.yml` | CI: analyze, format, tests, coverage gate, Android and iOS debug builds, AI service, Functions, emulator suites |
| `app/fastlane/` | Beta lanes (TestFlight and Play internal track). The P5 release lanes are locked |

## Architecture in one picture

```
Flutter app ── Hive (offline truth) ── Outbox ──► SyncEngine ──► Firestore / Storage
     │                                     │  (backoff+jitter, transient vs permanent,
     │                                     │   permanent failures surfaced, LWW pull)
     ├── RevenueCat SDK (only purchase path) ──► stores ──► RC webhook ──► Functions rcWebhook
     │                                                          └─► subscriptions/{uid} + users/{uid}.entitlement
     └── HTTPS + Firebase ID token + Idempotency-Key ──► FastAPI (Cloud Run)
                                                          ├─ caps + spend reservation (1 atomic Firestore tx)
                                                          ├─ response cache, prompt pins (prompts/vN)
                                                          └─ Claude API (server-side key) ── mock provider in tests
```

## Run it locally (no accounts needed)

```bash
# 1) Flutter app in offline demo mode (debug only, all backends faked)
cd app && flutter pub get
flutter run --flavor dev --dart-define-from-file=config/demo.json
#   Debug tools (welcome screen → "Debug tools", or Settings) give you:
#   simulate the day-7 check-in, simulate trial expiry, a fake trial with 2 days left, drain the outbox.

# 2) AI service with the deterministic mock provider
cd ai_service && python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
AI_PROVIDER=mock STORE=memory PROMO_PEPPER=dev .venv/bin/uvicorn app.main:app --reload

# 3) Everything against the Firebase emulators
npm i -g firebase-tools@14
firebase emulators:start --only auth,firestore,storage,functions
#   then run the app with USE_EMULATORS=true (config/example.json) and the AI
#   service with STORE=firestore FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099
```

## Tests

| Suite | Command | Current |
|---|---|---|
| Flutter (unit + widget) | `cd app && flutter test --coverage && python3 ../tool/coverage_gate.py coverage/lcov.info 80` | 84 tests, **91.5%** logic/validator coverage |
| AI service | `cd ai_service && .venv/bin/pytest --cov=app` | 102 tests, 84% |
| Functions unit | `cd functions && npm test` | 16 tests |
| Rules + webhook (emulator) | `firebase emulators:exec --only firestore,storage "npm --prefix functions run test:emulator"` | 20 tests |
| Firestore store (emulator) | `firebase emulators:exec --only firestore "cd ai_service && .venv/bin/pytest -m emulator"` | 10 tests |
| Cap load test (exit bar 4) | `firebase emulators:exec --only auth,firestore "ai_service/.venv/bin/python tool/load_test_caps.py"` | all scenarios pass |
| Prompt evals | `cd ai_service && AI_PROVIDER=claude .venv/bin/python -m evals.run_evals --live` | **not run yet:** needs `ANTHROPIC_API_KEY` |

## Setup for real (dev → staging → prod)

### 1. Firebase (one project per environment: `forme-dev`, `forme-staging`, `forme-prod`)
1. Create the projects. Enable Auth (Apple, Google, Email/Password), Firestore (native), Storage, FCM, Crashlytics, Analytics and Remote Config.
2. Register the apps: iOS `ai.forme.app` (`.dev`, `.staging` for the other envs) and Android `ai.forme.app` (with the same suffixes).
3. Put the public client values into `app/config/<flavor>.json`, copied from `config/example.json`. The file is gitignored.
4. Deploy rules, indexes and functions:
   ```bash
   firebase use dev
   firebase functions:secrets:set RC_WEBHOOK_AUTH        # any long random string; also set it in RevenueCat
   firebase functions:secrets:set REVENUECAT_SECRET_KEY  # RC secret API key (promo mirror, account purge)
   firebase deploy --only firestore,storage,functions
   ```
5. Seed the exercises and the revocable team code. The code comes from your shell or CI secrets and is never committed:
   ```bash
   cd functions && npm run build
   node lib/scripts/seed.js exercises
   FORME_TEAM_CODE=<code> PROMO_PEPPER=<same pepper as the AI service> node lib/scripts/seed.js team-code 25 90
   # revoke later:  FORME_TEAM_CODE=<code> PROMO_PEPPER=… node lib/scripts/seed.js revoke
   ```
6. Upload a placeholder render to `previews/_placeholder/v1.jpg`. This is the D5 stub image.

### 2. AI service (Cloud Run)
```bash
gcloud secrets create anthropic-api-key --data-file=-     # Claude API key — server only
gcloud secrets create promo-pepper --data-file=-          # long random string
gcloud secrets create revenuecat-secret-key --data-file=-
docker build -f ai_service/Dockerfile -t REGION-docker.pkg.dev/PROJECT/forme/forme-ai:TAG .
docker push …
# edit ai_service/service.yaml (PROJECT_ID, REGION, TAG, ADMIN_* values), then:
gcloud run services replace ai_service/service.yaml --region REGION
```
`service.yaml` follows the spec: min 1 and max 20 instances, 2 CPU / 4 GiB, concurrency 10, 60 s timeout, secrets from Secret Manager. The model defaults to `claude-opus-5-5` on every route, with per-route overrides through `AI_MODEL_MEAL` / `AI_MODEL_CHAT`. The Claude client opts into server-side refusal fallback (`fallbacks: "default"`).

To pin a prompt version (service account only):
`POST /v1/admin/prompt-pin {"route":"coach","version":"v2"}` using a Google OIDC token for an account listed in `ADMIN_SERVICE_ACCOUNTS`. Run the live evals before pinning.

### 3. RevenueCat (projects `forme-dev`, `forme-prod`)
- Apps: iOS `ai.forme.app` and Android `ai.forme.app`. Put the public SDK keys into `config/<flavor>.json` as `RC_IOS_KEY` / `RC_ANDROID_KEY`.
- Entitlement: `pro`. Products:

  | Product | Price | Trial |
  |---|---|---|
  | `forme_weekly` | $4.99/wk | 3-day |
  | `forme_monthly` | $12.99/mo | 7-day |
  | `forme_annual` | $79.99/yr | 7-day |

- Offerings (ids must match `Placement.offeringId`):
  - `onboarding`: annual (default) + monthly, with trials
  - `settings`: all three
  - `winback`: annual with 50% off year 1 (Android: Play offer tagged for winback; iOS: see promos below)
  - `weekly_entry`: weekly only. Route price-sensitive geos here with the Remote Config key `weekly_entry_geos`
- Webhook: `https://REGION-PROJECT.cloudfunctions.net/rcWebhook`, with the Authorization header set to the `RC_WEBHOOK_AUTH` value. Send a test event from the dashboard first. Verify it in staging (exit bar).
- RevenueCat app user id = Firebase uid (`Purchases.logIn(uid)` on every sign-in).

### 4. Promos
- **Store-native.** No single cross-platform code exists:
  - iOS: create custom offer codes (e.g. `FORME-LAUNCH`) in App Store Connect. The Redeem screen opens Apple's redemption sheet.
  - Android: create Play promo codes in Play Console. These only grant free trials. The Redeem screen deep-links to `play.google.com/redeem`.
  - Winback on iOS: put the comeback offer code into Remote Config `winback_offer_code`. The winback paywall shows a "Redeem 50% off" button. No code ships in the binary.
- **Staff/test codes** are server-side only (`promo_codes`, `POST /v1/promo/redeem`). Codes are stored as HMAC hashes and redemption is auth-required, rate-limited (5/h per user, 20/h per IP) and audited in `promo_redemptions`. A grant mirrors into RevenueCat as a promotional `pro` entitlement and into Firestore.

### 5. Sandbox testers
- **iOS:** App Store Connect → Users and Access → Sandbox → add testers. On the device: Settings → App Store → Sandbox Account. Trials renew fast in sandbox (a 7-day trial lasts about 3 minutes).
- **Android:** Play Console → Settings → License testing → add Gmail accounts. Add the same accounts to the internal testing track.
- The RevenueCat dashboard shows sandbox events. The webhook stores `environment` on every event.

### 6. Builds and release lanes
```bash
cd app && bundle install
# Beta (dogfood): TestFlight internal + Play internal track
ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_CONTENT=<base64 p8> MATCH_PASSWORD=… bundle exec fastlane ios beta flavor:prod
PLAY_JSON_KEY_PATH=… bundle exec fastlane android beta flavor:prod
# P5 release lanes exist but refuse to run until FORME_RELEASE_APPROVED=yes (after dogfood sign-off).
```
Android release signing reads `android/key.properties` (gitignored). Flavors are `dev`, `staging` and `prod` (applicationId suffixes `.dev` / `.staging`). iOS uses one scheme; the bundle id comes from `FORME_BUNDLE_ID` (xcconfig default, overridden by the lane). Set the Google Sign-In ids in `ios/Flutter/*.xcconfig`, then enable these capabilities in Xcode once: Sign in with Apple, HealthKit, Push.

## Product rules implemented (quick reference)

| | Free forever | Pro (incl. trial, billing grace, promo) | Grace mode (expired) |
|---|---|---|---|
| Logger, PR graphs, photo capture, streaks, reminders | ✓ | ✓ | ✓ (data never locked) |
| AI meal scans | 3/day | 15/day, 150/mo | 3/day |
| Coach messages | 5 total | 20/month | 5 total |
| Plan | 1 starter plan (never re-plans) | adaptive weekly re-plans (6/mo) | starter plan kept |
| AI photo reports, timeline/morph | — (manual side-by-side) | ✓ (6 reports/mo) | — |
| Future-physique render | — | 1/month (iteration-1 stub) | — |
| Spend ceiling | $0.25/mo | **$1.50/mo** (atomic reservation) | $0.25/mo |

Every AI route is capped. A breach returns `429` with `Retry-After`, `retry_after` and `paywall: forme://paywall?placement=cap_<cap>`. The app turns that into an inline, non-blocking upsell and logs `cap_hit_<cap>`.

Mandatory analytics events (O9): `trial_started_with_photos`, `conversion_event_reached` (the first AI check-in report renders), `trial_end_paywall_shown`, `cancel_tap`, `winback_accepted`, `cap_hit_*`. To apply the kill rule (a variant with trial→paid <30% over 7 days), compare `trial_started_with_photos` against `purchase_completed` and RevenueCat conversions, broken down by the `paywall_variant` Remote Config key.

## Guidebook
No Software Engineering Guidebook was supplied, so operatives O1–O12 served as the binding standard. [`docs/EXIT_BAR.md`](docs/EXIT_BAR.md) maps each operative to code and tests.
