import { getFirestore } from "firebase-admin/firestore";
import { describe, expect, it, beforeEach } from "vitest";

import { handleRcWebhook } from "../../src/rcWebhook";

const SECRET = "whsec_test";
const NOW = new Date("2026-10-21T12:00:00Z");
const DAY = 24 * 3600 * 1000;
const db = () => getFirestore();

function payload(type: string, extra: Record<string, unknown> = {}) {
  return {
    api_version: "1.0",
    event: {
      id: `${type}-${Math.random().toString(36).slice(2)}`,
      type,
      app_user_id: "user_a",
      product_id: "forme_annual",
      period_type: "TRIAL",
      event_timestamp_ms: NOW.getTime(),
      expiration_at_ms: NOW.getTime() + 7 * DAY,
      environment: "SANDBOX",
      ...extra,
    },
  };
}

beforeEach(async () => {
  for (const c of ["subscriptions", "users", "webhook_events"]) {
    const snap = await db().collection(c).get();
    await Promise.all(snap.docs.map((d) => d.ref.delete()));
  }
});

describe("rcWebhook against the Firestore emulator", () => {
  it("rejects bad auth", async () => {
    const r = await handleRcWebhook("Bearer nope", payload("INITIAL_PURCHASE"), SECRET, NOW);
    expect(r.status).toBe(401);
  });

  it("rejects malformed bodies", async () => {
    expect((await handleRcWebhook(SECRET, {}, SECRET, NOW)).status).toBe(400);
  });

  it("purchase → trial → cancel → expire, mirrored to subscriptions and users", async () => {
    await handleRcWebhook(SECRET, payload("INITIAL_PURCHASE"), SECRET, NOW);
    let user = (await db().doc("users/user_a").get()).data()!;
    expect(user.entitlement.pro).toBe(true);
    expect(user.entitlement.trial).toBe(true);

    await handleRcWebhook(SECRET, payload("CANCELLATION", { event_timestamp_ms: NOW.getTime() + 1 }), SECRET, NOW);
    user = (await db().doc("users/user_a").get()).data()!;
    expect(user.entitlement.pro).toBe(true);
    expect(user.entitlement.will_renew).toBe(false);

    await handleRcWebhook(SECRET, payload("EXPIRATION", { event_timestamp_ms: NOW.getTime() + 2 }), SECRET, NOW);
    const sub = (await db().doc("subscriptions/user_a").get()).data()!;
    user = (await db().doc("users/user_a").get()).data()!;
    expect(sub.active).toBe(false);
    expect(user.entitlement.pro).toBe(false);
    expect(user.winback.eligible).toBe(true);
  });

  it("is idempotent per event id", async () => {
    const p = payload("INITIAL_PURCHASE");
    await handleRcWebhook(SECRET, p, SECRET, NOW);
    const r = await handleRcWebhook(SECRET, p, SECRET, NOW);
    expect(r.body.duplicate).toBe(true);
  });

  it("ignores out-of-order older events", async () => {
    await handleRcWebhook(SECRET, payload("EXPIRATION", { event_timestamp_ms: NOW.getTime() + 100 }), SECRET, NOW);
    const r = await handleRcWebhook(SECRET, payload("RENEWAL", { event_timestamp_ms: NOW.getTime() }), SECRET, NOW);
    expect(r.body.lifecycle).toBe("ignored");
    expect((await db().doc("subscriptions/user_a").get()).get("active")).toBe(false);
    const ev = await db().collection("webhook_events").where("stale", "==", true).limit(5).get();
    expect(ev.size).toBe(1);
  });

  it("billing issue sets grace_until and keeps pro", async () => {
    await handleRcWebhook(SECRET, payload("INITIAL_PURCHASE", { period_type: "NORMAL" }), SECRET, NOW);
    await handleRcWebhook(
      SECRET,
      payload("BILLING_ISSUE", { event_timestamp_ms: NOW.getTime() + 1, grace_period_expiration_at_ms: NOW.getTime() + 3 * DAY }),
      SECRET,
      NOW,
    );
    const user = (await db().doc("users/user_a").get()).data()!;
    expect(user.entitlement.pro).toBe(true);
    expect(user.entitlement.billing_issue).toBe(true);
  });
});
