# Roadmap and parked decisions

## ⏰ Reminder: subscription pricing review + unit economics (requested 2026-10-21)
The tiers stay unchanged for now ($4.99/wk, $12.99/mo, $79.99/yr). Revisit them once these inputs are known:
- Real AI cost per active user per month on the chosen vendor/model (from the spend ledger in `users/*/usage/spend_*`)
- The share of users who'd bring their own AI allowance (Sign in with ChatGPT, below), and how that changes our cost per payer
- Store fees (15–30%), trial→paid, D30 retention, annual mix (the 90-day targets in the spec)
- Whether to add a cheaper "bring your own AI" tier, or keep one price and let BYO-AI users raise margin

The deliverable is a per-cohort contribution-margin model: price − store fee − AI cost − infra, by tier and by AI-funding source.

## Sign in with ChatGPT, with plan usage (researched 2026-10-21; not built)
**What it is.** OpenAI announced this at DevDay on Sep 29, 2026. Users sign in with their ChatGPT account and can optionally grant **plan usage**. The app's AI requests then count against the user's ChatGPT Plus/Pro allowance instead of our API bill. Users set weekly caps per app in ChatGPT settings. Identity and plan usage are separate grants.

**Why it matters.** For users who grant plan usage, our AI cost goes to roughly zero. That's the main lever for the pricing review above.

**Blockers.**
- Plan usage is a **limited preview**. Open-source/local apps can self-serve, but a **paid, remotely hosted app (Forme) must apply** through OpenAI's commercial interest form and be accepted.
- Only **Plus/Pro** subscribers can grant plan usage. Free ChatGPT users and users who decline still need our own AI budget.
- When a user hits their weekly cap, usage stops; it doesn't fall back to our billing. We need a clear "your ChatGPT allowance is used up" state with a fallback offer.
- OpenAI doesn't notify the app on disconnect. We detect it when a request or token refresh fails.

**Proposed design, to build once accepted:**
1. Add "Continue with ChatGPT" to O6 as an identity provider. Link it to the same Firebase user through custom-token exchange in a Function.
2. Make the optional plan-usage grant a separate, explained step: "Use my ChatGPT plan for Forme's AI".
3. Store the user's OpenAI tokens **server-side only**, encrypted (KMS), with refresh handled by the AI service.
4. Per request, the AI service picks the funding source:
   - **user's plan:** OpenAI models only. Our spend ceiling doesn't apply, but our product caps still do.
   - **our key:** the configured vendor, with caps and the ceiling as today.
   - If the plan grant fails (cap hit, revoked), fall back to our budget within the user's normal tier allowance.
5. Add analytics on the AI funding source per call, as input to the unit-economics model.

**Next step (yours):** submit OpenAI's commercial interest form for Sign in with ChatGPT with plan usage. Once OpenAI grants access and shares the integration docs, I can build the design above. The official developer docs weren't reachable from this build environment, so no protocol details have been assumed.
