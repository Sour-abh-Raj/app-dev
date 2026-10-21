# Exit bar — status

**Overall: NOT-DONE.** Everything that can be built and proven without real store accounts, signing identities, devices or an Anthropic key is built and tested. The open items need those things, and each one has a named next step.

Environment limits during this build: no Firebase, RevenueCat, App Store Connect or Play Console credentials; no macOS (so no iOS build); no physical devices; no `ANTHROPIC_API_KEY`. The cloud container's network policy also blocked `dl.google.com`, so the Android SDK couldn't be installed and no APK was built here. CI builds the debug APK (Ubuntu) and the iOS app (macOS, no codesign) on every push.

| # | Exit criterion | Status | Evidence / what's missing |
|---|---|---|---|
| 1 | Sandbox purchase → trial → cancel → restore on iOS **and** Android | **NOT-DONE** | Built: RevenueCat-only purchase path (`purchases_service.dart`), paywall with placements/offerings, restore, manage/cancel (`cancel_tap`), the webhook state machine for every event including billing grace and winback, and the client entitlement merge with a 7-day offline cache. Tested: 16 unit tests on the webhook state machine; 6 emulator tests on the webhook → Firestore mirror covering purchase → trial → cancel → expire, billing issue, idempotency and out-of-order events; widget tests for paywall purchase, restore visibility, trial-requires-photos, the `trial_started_with_photos` / `winback_accepted` / `trial_end_paywall_shown` events, and fake-store purchase. **Missing:** RevenueCat projects, store products, sandbox testers and a run on 2 devices. Steps are in README §3 and §5. |
| 2 | All code types redeem correctly, incl. expired/revoked errors | **PARTIAL** | Server staff/test codes: **DONE**. Unit tests cover `granted`, `not_found`, `revoked`, `expired`, `exhausted`, `already_redeemed`, `rate_limited`, malformed input and auth-required. The Firestore emulator test covers the atomic redemption transaction. Every attempt is audited and the grant is mirrored to RevenueCat and Firestore. Store-native codes (Apple offer codes, Play promo codes): the redemption UI is built and deep-links to the store sheet/page, but **NOT-DONE** — this needs codes created in App Store Connect and Play Console and a device run. |
| 3 | Airplane log → force-kill → relaunch → reconnect loses zero data | **DONE (automated, data layer)** · on-device run pending | `app/test/data/sync_test.dart › EXIT BAR 3` runs the scenario: offline workout plus meal, Hive boxes closed mid-session (the "kill"), reopened, then online. It asserts zero loss and an empty outbox. Every mutation is flushed to Hive and the outbox **before** the UI acks. Still worth repeating by hand on a device during dogfood. |
| 4 | Every AI cap returns 429 + paywall link under load; spend holds | **DONE (emulators, mock model)** | `tool/load_test_caps.py` runs the real service (Firestore store, Firebase Auth emulator tokens, 2 workers) against concurrent bursts. Free tier: meal 25 → 3×200 + 22×429; chat 25 → 5 + 20; render 10 → 0 + 10; plan generation 12 → 1 + 11. Pro: meal 40 → 15 + 25. Pro near the ceiling: 30 concurrent chats stayed at **$1.436 ≤ $1.50**. Every 429 carries `cap`, `retry_after`, `Retry-After` and the `forme://paywall` link. The run produced 0 errors. The load test caught real defects, now fixed: hot-document transaction contention was returning 500s; the store singleton raced on first use; spend was check-then-act, so concurrent calls could overshoot. Not yet repeated against live Claude (needs a key). |
| 5 | Clean install on TestFlight + Play internal for the 2-day dogfood | **NOT-DONE** | Fastlane `ios beta` / `android beta` lanes, flavors, release signing hooks and CI builds are ready. **Missing:** Apple Developer / App Store Connect API key, `match` repo, Play service account, upload keystore, Firebase config per flavor. |
| 6 | Dogfood completes (onboard, trial, 2 workouts, 1 simulated check-in → AI report, crash-free ≥99.5%) | **NOT-DONE** | Blocked by #5. In-app support is ready: debug-only time controls (simulate the day-7 check-in, simulate trial expiry), Crashlytics from build one, demo mode for a credential-free walkthrough. |

## Operatives O1–O12

| Operative | Status | Where |
|---|---|---|
| O1 offline-first, outbox before UI ack | ✓ | `data/local/local_store.dart` (flush on every put), `data/repo.dart`, `data/sync/outbox.dart` |
| O2 drain on reconnect + app start, backoff + jitter, transient vs permanent, failures surfaced | ✓ | `data/sync/sync_engine.dart`, `app/app.dart` (start/resume/reconnect), shell banner + Settings → Sync (retry) |
| O3 last-write-wins on server timestamps, conflicts logged | ✓ | `data/sync/pull.dart` (`server_updated_at`, pending local edits win, `sync_conflict` event); webhook ignores stale events |
| O4 no unbounded queries, composite indexes, rules tested in emulator | ✓ | `functions/src/common.ts › forEachPage`, `firebase/firestore.indexes.json`, 14 rules tests |
| O5 version-keyed cache, AI responses cached by request hash, vision ≤1024 px | ✓ | exercise seed `version`; `guard.request_hash` + `ai_cache`; `images.normalize`, `PhotoService.visionMaxEdge` |
| O6 every AI route capped → 429 + retry_after + paywall; ≤$1.50/payer/mo | ✓ | `caps.py` (test asserts no uncapped kind), `guard.py` (atomic cap + spend reservation), load test |
| O7 resumable uploads, idempotency keys, force-kill loses nothing | ✓ (see notes) | `Idempotency-Key` on every AI call (check-in id = key); outbox retries uploads to deterministic paths. Uploads use the Firebase SDK's resumable `putFile`; a kill restarts that file's upload from zero (no cross-process resume). |
| O8 secrets + promo logic server-side; redemption auth + rate-limit + audit | ✓ | `promo.py`, `store.promo_redeem`, `/v1/promo/redeem`; no codes or secrets in the app |
| O9 Crashlytics + Analytics from build one; mandatory events | ✓ | `app/bootstrap.dart`, `services/analytics.dart` |
| O10 money paths built + sandbox-tested before polish | **built ✓ / sandbox ✗** | See exit bar #1–2 |
| O11 debug-only time controls, compiled out of release | ✓ | `/debug` route only when `!kReleaseMode`; `Clock`/`DebugFlags` ignore offsets in release |
| O12 README, known issues, conflicts | ✓ | this folder |

## Performance targets (not yet measurable here)
- Cold start under 2.5 s on a mid-tier Android
- Upload ≤15 s on 4G
- Report p95 under 90 s
- Crash-free ≥99.5%

These need devices and real traffic. The design supports them:
- RevenueCat and Remote Config start off the critical path.
- Photos are capped at 2048 px for storage and 1024 px for vision.
- The report screen has a 90-second budget, then shows "queued" instead of spinning.
