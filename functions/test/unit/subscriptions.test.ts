import { describe, expect, it } from "vitest";

import {
  RcEvent,
  applyRcEvent,
  dueNudge,
  emptyMirror,
  entitlementOf,
  isPro,
  resolveUid,
} from "../../src/subscriptions";
import { authorized } from "../../src/rcWebhook";
import { codeHash, normalizeCode } from "../../src/scripts/seed";

const NOW = new Date("2026-10-21T12:00:00Z");
const DAY = 24 * 3600 * 1000;

function ev(type: string, extra: Partial<RcEvent> = {}): RcEvent {
  return {
    id: `${type}-${Math.random()}`,
    type,
    app_user_id: "uid1",
    product_id: "forme_annual",
    event_timestamp_ms: NOW.getTime(),
    expiration_at_ms: NOW.getTime() + 7 * DAY,
    environment: "SANDBOX",
    ...extra,
  };
}

describe("applyRcEvent — money paths", () => {
  it("trial start → active trial", () => {
    const r = applyRcEvent(null, ev("INITIAL_PURCHASE", { period_type: "TRIAL" }), NOW);
    expect(r.lifecycle).toBe("trial_started");
    expect(r.next.active && r.next.trial).toBe(true);
    expect(isPro(r.next, NOW)).toBe(true);
  });

  it("spec spelling TRIAL_STARTED is accepted", () => {
    const r = applyRcEvent(null, ev("TRIAL_STARTED"), NOW);
    expect(r.lifecycle).toBe("trial_started");
    expect(r.next.trial).toBe(true);
  });

  it("trial → renewal is a conversion", () => {
    const t = applyRcEvent(null, ev("INITIAL_PURCHASE", { period_type: "TRIAL" }), NOW).next;
    const r = applyRcEvent(t, ev("RENEWAL", { event_timestamp_ms: NOW.getTime() + 1 }), NOW);
    expect(r.lifecycle).toBe("conversion");
    expect(r.next.trial).toBe(false);
    const again = applyRcEvent(r.next, ev("RENEWAL", { event_timestamp_ms: NOW.getTime() + 2 }), NOW);
    expect(again.lifecycle).toBe("renewal");
  });

  it("cancel keeps access until expiration", () => {
    const t = applyRcEvent(null, ev("INITIAL_PURCHASE", { period_type: "TRIAL" }), NOW).next;
    const c = applyRcEvent(t, ev("CANCELLATION", { period_type: "TRIAL", event_timestamp_ms: NOW.getTime() + 1 }), NOW);
    expect(c.lifecycle).toBe("trial_cancelled");
    expect(c.next.will_renew).toBe(false);
    expect(isPro(c.next, NOW)).toBe(true);
    const x = applyRcEvent(c.next, ev("EXPIRATION", { period_type: "TRIAL", event_timestamp_ms: NOW.getTime() + 2 }), NOW);
    expect(x.lifecycle).toBe("trial_expired");
    expect(isPro(x.next, NOW)).toBe(false);
    expect(x.push).toBe("winback");
    expect(x.next.winback?.eligible).toBe(true);
    expect(x.next.winback!.until.getTime() - NOW.getTime()).toBe(14 * DAY);
  });

  it("uncancellation restores auto-renew", () => {
    const p = applyRcEvent(null, ev("INITIAL_PURCHASE"), NOW).next;
    const c = applyRcEvent(p, ev("CANCELLATION", { event_timestamp_ms: NOW.getTime() + 1 }), NOW).next;
    const u = applyRcEvent(c, ev("UNCANCELLATION", { event_timestamp_ms: NOW.getTime() + 2 }), NOW);
    expect(u.next.will_renew).toBe(true);
  });

  it("billing issue with store grace keeps pro and asks to fix payment", () => {
    const p = applyRcEvent(null, ev("INITIAL_PURCHASE"), NOW).next;
    const b = applyRcEvent(
      p,
      ev("BILLING_ISSUE", { event_timestamp_ms: NOW.getTime() + 1, grace_period_expiration_at_ms: NOW.getTime() + 6 * DAY }),
      NOW,
    );
    expect(b.push).toBe("fix_payment");
    expect(b.next.billing_issue).toBe(true);
    expect(isPro(b.next, NOW)).toBe(true);
    expect(entitlementOf(b.next, NOW).billing_issue).toBe(true);
    expect(isPro(b.next, new Date(NOW.getTime() + 7 * DAY))).toBe(true); // active until EXPIRATION arrives
  });

  it("billing issue without grace lapses access", () => {
    const p = applyRcEvent(null, ev("INITIAL_PURCHASE"), NOW).next;
    const b = applyRcEvent(p, ev("BILLING_ISSUE", { event_timestamp_ms: NOW.getTime() + 1, grace_period_expiration_at_ms: null }), NOW);
    expect(isPro(b.next, NOW)).toBe(false);
  });

  it("renewal clears billing issue", () => {
    const p = applyRcEvent(null, ev("INITIAL_PURCHASE"), NOW).next;
    const b = applyRcEvent(p, ev("BILLING_ISSUE", { event_timestamp_ms: NOW.getTime() + 1, grace_period_expiration_at_ms: NOW.getTime() + DAY }), NOW).next;
    const r = applyRcEvent(b, ev("RENEWAL", { event_timestamp_ms: NOW.getTime() + 2 }), NOW).next;
    expect(r.billing_issue).toBe(false);
    expect(r.grace_until).toBeNull();
  });

  it("stale events do not overwrite newer state (LWW)", () => {
    const p = applyRcEvent(null, ev("EXPIRATION", { event_timestamp_ms: NOW.getTime() + 10 }), NOW).next;
    const r = applyRcEvent(p, ev("RENEWAL", { event_timestamp_ms: NOW.getTime() }), NOW);
    expect(r.stale).toBe(true);
    expect(r.next.active).toBe(false);
  });

  it("TEST / TRANSFER are acknowledged without change", () => {
    expect(applyRcEvent(null, ev("TEST"), NOW).lifecycle).toBe("ignored");
    expect(applyRcEvent(null, ev("TRANSFER"), NOW).lifecycle).toBe("ignored");
  });

  it("product change", () => {
    const p = applyRcEvent(null, ev("INITIAL_PURCHASE"), NOW).next;
    const r = applyRcEvent(p, ev("PRODUCT_CHANGE", { new_product_id: "forme_monthly", event_timestamp_ms: NOW.getTime() + 1 }), NOW);
    expect(r.next.product_id).toBe("forme_monthly");
  });
});

describe("helpers", () => {
  it("resolveUid skips anonymous ids", () => {
    expect(resolveUid(ev("TEST", { app_user_id: "$RCAnonymousID:abc", aliases: ["uid9"] }))).toBe("uid9");
    expect(resolveUid(ev("TEST", { app_user_id: "$RCAnonymousID:abc" }))).toBeNull();
  });

  it("promo keeps pro after store expiry", () => {
    const m = { ...emptyMirror("u"), promo: { tier: "pro", expires_at: new Date(NOW.getTime() + DAY) } };
    expect(isPro(m, NOW)).toBe(true);
    expect(isPro(m, new Date(NOW.getTime() + 2 * DAY))).toBe(false);
  });

  it("dueNudge D-3 then D-1, once each", () => {
    const base = { ...emptyMirror("u"), trial: true, active: true, will_renew: true };
    expect(dueNudge({ ...base, renews_at: new Date(NOW.getTime() + 4 * DAY) }, NOW)).toBeNull();
    expect(dueNudge({ ...base, renews_at: new Date(NOW.getTime() + 2.5 * DAY) }, NOW)).toBe("d3");
    expect(dueNudge({ ...base, nudged_d3: true, renews_at: new Date(NOW.getTime() + 2.5 * DAY) }, NOW)).toBeNull();
    expect(dueNudge({ ...base, nudged_d3: true, renews_at: new Date(NOW.getTime() + 0.5 * DAY) }, NOW)).toBe("d1");
    expect(dueNudge({ ...base, nudged_d1: true, renews_at: new Date(NOW.getTime() + 0.5 * DAY) }, NOW)).toBeNull();
    expect(dueNudge({ ...base, trial: false, renews_at: new Date(NOW.getTime() + DAY / 2) }, NOW)).toBeNull();
  });

  it("webhook auth is exact and constant-time", () => {
    expect(authorized("Bearer s3cret", "s3cret")).toBe(true);
    expect(authorized("s3cret", "s3cret")).toBe(true);
    expect(authorized("s3cre", "s3cret")).toBe(false);
    expect(authorized(undefined, "s3cret")).toBe(false);
    expect(authorized("x", "")).toBe(false);
  });

  it("promo hash matches the AI service (HMAC-SHA256 of normalized code)", () => {
    expect(normalizeCode(" forme-team 01 ")).toBe("FORME-TEAM01");
    // Same vector as ai_service: hmac('test-pepper', 'TEAM-2026')
    expect(codeHash("team-2026", "test-pepper")).toBe(
      "c48835dbc3b4b75c0c7a039616e235ee63dd2b7f56ac4d4bb544dc05c16c180e",
    );
    expect(() => codeHash("X-1234", "")).toThrow();
  });
});
