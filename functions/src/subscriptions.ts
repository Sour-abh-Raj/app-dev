/**
 * Pure RevenueCat event → subscription-mirror logic. No I/O here, so every
 * money-path transition is unit-tested.
 */

export type RcEventType =
  | "INITIAL_PURCHASE"
  | "RENEWAL"
  | "PRODUCT_CHANGE"
  | "UNCANCELLATION"
  | "CANCELLATION"
  | "BILLING_ISSUE"
  | "EXPIRATION"
  | "SUBSCRIPTION_PAUSED"
  | "TRANSFER"
  | "TEST"
  // The spec names these trial events; RevenueCat itself reports trials as the
  // events above with period_type=TRIAL. Accept both spellings.
  | "TRIAL_STARTED"
  | "TRIAL_CANCELLED"
  | "TRIAL_EXPIRED";

export interface RcEvent {
  id: string;
  type: RcEventType | string;
  app_user_id: string;
  original_app_user_id?: string;
  aliases?: string[];
  product_id?: string;
  new_product_id?: string;
  period_type?: "TRIAL" | "INTRO" | "NORMAL" | "PROMOTIONAL" | string;
  expiration_at_ms?: number | null;
  event_timestamp_ms: number;
  grace_period_expiration_at_ms?: number | null;
  environment?: "SANDBOX" | "PRODUCTION" | string;
  presented_offering_id?: string | null;
  cancel_reason?: string;
}

export interface SubMirror {
  rc_user_id: string;
  active: boolean;
  product_id: string | null;
  period_type: string | null;
  trial: boolean;
  renews_at: Date | null;
  will_renew: boolean;
  billing_issue: boolean;
  grace_until: Date | null;
  expired_at: Date | null;
  environment: string | null;
  last_webhook_ts: number;
  winback?: { eligible: boolean; offering: string; until: Date } | null;
  nudged_d3?: boolean;
  nudged_d1?: boolean;
  promo?: { tier: string; expires_at: Date } | null;
}

/** Analytics-facing lifecycle name for each applied event (logged + pushed). */
export type Lifecycle =
  | "trial_started"
  | "purchase"
  | "conversion"
  | "renewal"
  | "trial_cancelled"
  | "cancelled"
  | "uncancelled"
  | "billing_issue"
  | "trial_expired"
  | "expired"
  | "product_change"
  | "ignored";

export interface Applied {
  next: SubMirror;
  lifecycle: Lifecycle;
  /** Push to send to the user, if any. */
  push: "fix_payment" | "winback" | null;
  /** True when the event was older than the mirror (O3: last-write-wins). */
  stale: boolean;
}

export const WINBACK_WINDOW_DAYS = 14;
const DAY_MS = 24 * 3600 * 1000;

/** Firebase uid for an event; anonymous RevenueCat ids are not ours to mirror. */
export function resolveUid(e: RcEvent): string | null {
  const ids = [e.app_user_id, e.original_app_user_id, ...(e.aliases ?? [])].filter(
    (x): x is string => !!x,
  );
  return ids.find((x) => !x.startsWith("$RCAnonymousID")) ?? null;
}

export function emptyMirror(uid: string): SubMirror {
  return {
    rc_user_id: uid,
    active: false,
    product_id: null,
    period_type: null,
    trial: false,
    renews_at: null,
    will_renew: false,
    billing_issue: false,
    grace_until: null,
    expired_at: null,
    environment: null,
    last_webhook_ts: 0,
    winback: null,
    nudged_d3: false,
    nudged_d1: false,
  };
}

function normalizeType(e: RcEvent): { type: string; trial: boolean } {
  switch (e.type) {
    case "TRIAL_STARTED":
      return { type: "INITIAL_PURCHASE", trial: true };
    case "TRIAL_CANCELLED":
      return { type: "CANCELLATION", trial: true };
    case "TRIAL_EXPIRED":
      return { type: "EXPIRATION", trial: true };
    default:
      return { type: e.type, trial: e.period_type === "TRIAL" };
  }
}

const ms = (v: number | null | undefined): Date | null => (v ? new Date(v) : null);

export function applyRcEvent(prev: SubMirror | null, e: RcEvent, now: Date): Applied {
  const uid = resolveUid(e) ?? e.app_user_id;
  const base = prev ?? emptyMirror(uid);
  if (e.event_timestamp_ms < base.last_webhook_ts) {
    return { next: base, lifecycle: "ignored", push: null, stale: true };
  }
  const n: SubMirror = { ...base, last_webhook_ts: e.event_timestamp_ms };
  n.environment = e.environment ?? n.environment;
  const { type, trial } = normalizeType(e);
  let lifecycle: Lifecycle = "ignored";
  let push: Applied["push"] = null;

  switch (type) {
    case "INITIAL_PURCHASE":
      Object.assign(n, {
        active: true,
        trial,
        product_id: e.product_id ?? n.product_id,
        period_type: trial ? "TRIAL" : (e.period_type ?? "NORMAL"),
        renews_at: ms(e.expiration_at_ms),
        will_renew: true,
        billing_issue: false,
        grace_until: null,
        expired_at: null,
        winback: null,
        nudged_d3: false,
        nudged_d1: false,
      });
      lifecycle = trial ? "trial_started" : "purchase";
      break;
    case "RENEWAL":
      lifecycle = base.trial ? "conversion" : "renewal";
      Object.assign(n, {
        active: true,
        trial: false,
        period_type: e.period_type ?? "NORMAL",
        product_id: e.product_id ?? n.product_id,
        renews_at: ms(e.expiration_at_ms),
        will_renew: true,
        billing_issue: false,
        grace_until: null,
        expired_at: null,
        winback: null,
      });
      break;
    case "PRODUCT_CHANGE":
      n.product_id = e.new_product_id ?? e.product_id ?? n.product_id;
      lifecycle = "product_change";
      break;
    case "UNCANCELLATION":
      n.will_renew = true;
      lifecycle = "uncancelled";
      break;
    case "CANCELLATION":
      // Auto-renew turned off; access continues until EXPIRATION.
      n.will_renew = false;
      lifecycle = trial ? "trial_cancelled" : "cancelled";
      break;
    case "BILLING_ISSUE":
      n.billing_issue = true;
      n.grace_until = ms(e.grace_period_expiration_at_ms);
      // Without a store grace period the subscription is effectively lapsed.
      n.active = !!(n.grace_until && n.grace_until > now);
      lifecycle = "billing_issue";
      push = "fix_payment";
      break;
    case "EXPIRATION":
      Object.assign(n, {
        active: false,
        trial: false,
        will_renew: false,
        billing_issue: false,
        grace_until: null,
        expired_at: now,
        winback: {
          eligible: true,
          offering: "winback",
          until: new Date(now.getTime() + WINBACK_WINDOW_DAYS * DAY_MS),
        },
      });
      lifecycle = trial ? "trial_expired" : "expired";
      push = "winback";
      break;
    default:
      // TEST, TRANSFER, SUBSCRIPTION_PAUSED: acknowledged, no state change.
      return { next: base, lifecycle: "ignored", push: null, stale: false };
  }
  return { next: n, lifecycle, push, stale: false };
}

/** Same rule as the AI service's is_pro(): active, billing grace, or promo. */
export function isPro(s: SubMirror | null, now: Date): boolean {
  if (!s) return false;
  if (s.active) return true;
  if (s.grace_until && s.grace_until > now) return true;
  return !!(s.promo?.expires_at && s.promo.expires_at > now);
}

/** Client-visible users/{uid}.entitlement. */
export function entitlementOf(s: SubMirror, now: Date) {
  return {
    pro: isPro(s, now),
    expires_at: s.renews_at ?? s.promo?.expires_at ?? null,
    product_id: s.product_id,
    trial: s.trial,
    billing_issue: s.billing_issue,
    grace_until: s.grace_until,
    will_renew: s.will_renew,
  };
}

export type NudgeKind = "d3" | "d1";

/** Which trial-end nudge (if any) is due now. D-3 fires inside the last 72h, D-1 inside 24h. */
export function dueNudge(s: SubMirror, now: Date): NudgeKind | null {
  if (!s.trial || !s.active || !s.renews_at) return null;
  const left = s.renews_at.getTime() - now.getTime();
  if (left <= 0) return null;
  if (left <= DAY_MS && !s.nudged_d1) return "d1";
  if (left <= 3 * DAY_MS && !s.nudged_d3 && left > DAY_MS) return "d3";
  return null;
}
