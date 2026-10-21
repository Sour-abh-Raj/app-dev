# Known issues (iteration 1)

## Must fix before submission (P5)
1. **No exercise demo videos.** All 60 have `demo_video_url: ""`. D1 shows the player only when a URL exists; otherwise it shows "follow the cues". We need a content source; the seed's `version` bump ships new URLs.
2. **Progress photos don't come back on a new device.** Reports and check-in metadata sync, but the timeline reads local files. A restore should download the `_thumb` / `_1024` variants (owner-only Storage reads are already allowed).
3. **Crashlytics symbols.** Release lanes build with `--obfuscate --split-debug-info`, but no symbol/mapping upload step exists yet (`firebase crashlytics:symbols:upload`, dSYM upload).
4. **iOS has one scheme.** Flavors work via `FORME_BUNDLE_ID` (xcconfig default, Fastlane override) plus per-flavor dart-defines. Separate Xcode schemes/configurations, and HealthKit / Sign in with Apple / Push capabilities, need enabling once in Xcode.
5. **`FIREBASE_ENCODED_APP_ID` is a placeholder** in `ios/Flutter/*.xcconfig`. It's needed for the Google sign-in redirect on iOS.
6. **Not built locally for Android or iOS.** The container's network policy blocked `dl.google.com` (Android SDK), and there's no macOS. CI builds both, so check the first CI run.

## Behaviour gaps (acceptable for dogfood)
7. **One FCM token per user.** The last device wins (`fcm_tokens` is overwritten). `firebase_messaging` 17 deprecates `getToken()` in favour of FID registration; we still use the token because the Admin SDK multicast in Functions targets tokens.
8. **The check-in reminder slot has 1-hour granularity.** Half-hour time zones get the Sunday push up to 30 min early.
9. **Live pose hints aren't device-tested.** The camera-stream → ML Kit conversion (NV21 / BGRA8888) and the face-blur placement need a device pass. The hint logic itself is unit-tested.
10. **The weekly nutrition report is computed on-device** (averages vs targets), not AI-written. It's Pro-gated as specified.
11. **D5 render and the $1.99 3-pack are stubs**, as specified. The endpoint enforces quota and returns a placeholder.
12. **The burst limiter is per instance** (30 req/min/user/instance). Caps and the spend ceiling are global and atomic, so this only smooths bursts.
13. **Account deletion needs a connection.** It fails safe (nothing deleted) offline. Store subscriptions must be cancelled by the user in the store; the dialog says so.
14. **Uploads restart after a kill.** The Firebase SDK's resumable upload doesn't survive process death; the outbox re-uploads to the same path.
15. **`ai_cache` and `users/*/ai_jobs` have no TTL yet.** `rate_limits` has one. Add TTL policies before scale.
16. **App Check isn't enabled.** Recommended for Firestore/Storage and the AI service before public launch.
17. **Health sync reads weight only** (read-only, 14-day lookback).

## Dependency notes
18. `functions/`: runtime has 1 moderate advisory (`uuid` via Google libraries, not on our code path). The dev-only Firebase client used by the rules tests has a high `@grpc/grpc-js` advisory; it isn't deployed. CI fails on any **high** runtime advisory.
19. npm 10 crashes resolving the `firebase@13` dev tree; CI uses npm 11.
20. The Python SDK is pinned to `anthropic==1.17.0` (2.0 exists; upgrade deliberately).

## Cost note
Cost now depends on the vendor and model you choose. For scale, at a frontier-model price of $4 in / $20 out per million tokens:

| Call | Approx. cost |
|---|---|
| Meal | ~$0.012 |
| Check-in (5 images) | ~$0.05–0.10 |
| Chat | ~$0.01 |

On that model, a heavy Pro month can approach $1.50. Small vision models through OpenRouter or OpenAI cost 10–50× less. Whatever you pick, set `AI_PRICE_*` so the ceiling measures the real cost. The full unit-economics calculation is a tracked follow-up (see `docs/ROADMAP.md`).
