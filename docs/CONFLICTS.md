# Conflicts and gaps found in the spec

## Resolved by the product owner (asked before building)

| # | Conflict | Decision |
|---|---|---|
| 1 | "AI keys server-side only", but no AI provider is named | First answer: Claude. **Revised: vendor-neutral.** Any OpenAI-compatible API (OpenAI, OpenRouter, Together, Groq, self-hosted…) or Anthropic, chosen by env; a deterministic mock for tests/CI/evals |
| 2 | Grace mode "lose ALL AI" vs the free-forever tier's 3 AI meals/day + 5 chats. This would leave expired users with less than people who never paid | **Expired = free tier.** Pro AI (re-plans, photo reports, timeline/morph) goes; free allowances stay |
| 3 | §3 puts Weekly in "onboarding/winback", but §7 offerings exclude it there | **Follow §7 exactly.** Weekly appears in `settings` and `weekly_entry`; `weekly_entry_geos` in Remote Config routes price-sensitive geos |
| 4 | Real accounts and devices are needed for several exit-bar items | **Build with emulators/mocks** and report those items NOT-DONE with steps (see EXIT_BAR.md) |

## Resolved during the build (documented, not silent)

| # | Conflict or gap | Resolution |
|---|---|---|
| 5 | O2 says "4 cards"; the clickthrough shows 5 goal chips | Spec wins: **Lose fat, Build muscle, Recomp, Get stronger**. "Tone up" was dropped from the UI; the server still accepts `tone_up` |
| 6 | The clickthrough says "photos stay encrypted on your device", but the architecture uploads photos to Storage | Used the brand-kit line, **"encrypted, never public"**, everywhere |
| 7 | §7 names `TRIAL_STARTED/CANCELLED/EXPIRED`, which aren't RevenueCat event types (RC reports trials as `INITIAL_PURCHASE/CANCELLATION/EXPIRATION` with `period_type=TRIAL`) | Derived from `period_type`. The literal names are also accepted |
| 8 | "EXPIRED-72h → nudge push" is ambiguous (72 h *after* expiry, or *before*?) | Read alongside "trial D-3/D-1 nudges": **D-3 (72 h before trial end) and D-1 pushes**. The winback push fires on expiry |
| 9 | `grace_until` (billing-issue retry, user keeps Pro) vs "grace mode" (expired, free tier) share a word | Kept both as specified. Billing grace keeps Pro and shows "fix payment"; grace mode is the expired state |
| 10 | P5 (after dogfood) lists health sync, biometric lock and the 18+ gate, but D6 must not be a stub and the data model has `photo_consent.adult` | Built basic versions now: read-only weight sync, a biometric lock toggle, and an 18+ consent checkbox at O5. Listings/rollout P5 work is not done |
| 11 | Free tier has "1 static starter plan", but O7 generates a plan with AI for everyone | Every user gets **one** AI-generated plan (lifetime cap 1 for free), with the template as fallback. Free users never get re-plans |
| 12 | "Trial requires baseline photos", but stores can't make a free trial conditional | Enforced in-app: the onboarding paywall's trial CTA stays disabled until baseline photos exist ("Take photos" shortcut) |
| 13 | "Grants mirrored promo entitlement": mirrored where? | RevenueCat **promotional entitlement** (REST) + Firestore `subscriptions/{uid}.promo` and `users/{uid}.entitlement.promo_expires_at`. Access lapses on expiry without another write |
| 14 | Pro caps aren't specified beyond chat (20/mo) and renders (1/mo), but O6 requires every route capped within $1.50 | **Chosen values (please confirm):** Pro meals 15/day and 150/mo, photo reports 6/mo, re-plans 6/mo, plan generations 3/mo. Free: plan generation 1 lifetime, $0.25/mo spend ceiling. All live in `ai_service/app/caps.py` |
| 15 | Brand says lime is "never body text" but also "deltas big + bold lime" | Lime appears only on CTAs, progress, and the numeric deltas (not body copy) |
| 16 | "Seed 60" exercises with demo videos, but no video source exists | Exactly 60 exercises with cues and substitutions; `demo_video_url` is empty (see KNOWN_ISSUES) |
| 17 | "Hive" | Used `hive` 2.2.3 as named (the `hive_ce` fork is the maintained one; switching needs your OK) |
| 18 | `conversion_event_reached` isn't defined | Defined as **the first AI check-in report rendered** (the aha moment). Logged once per install |
| 19 | Exact versions for "Flutter 3.x" | Flutter 3.47.7 (latest stable at build time). Package majors as resolved by `pub` on 2026-10-21 |
| 20 | Auth spec says Apple/Google/email; the native Google Sign-In iOS SDK can't coexist with Firebase iOS 13 (dependency conflict found in CI) | Google sign-in goes through Firebase Auth's provider flow (system browser sheet) instead of the native SDK. Same user-facing button |
