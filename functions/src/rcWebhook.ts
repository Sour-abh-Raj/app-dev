import { timingSafeEqual } from "node:crypto";

import { FieldValue } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

import { db, mirrorFromDoc, pushToUser } from "./common";
import { RcEvent, applyRcEvent, entitlementOf, resolveUid } from "./subscriptions";

export function authorized(header: string | undefined, secret: string): boolean {
  if (!secret || !header) return false;
  const a = Buffer.from(header.replace(/^Bearer\s+/i, ""));
  const b = Buffer.from(secret);
  return a.length === b.length && timingSafeEqual(a, b);
}

export interface WebhookResult {
  status: number;
  body: Record<string, unknown>;
}

/**
 * RevenueCat → Firestore mirror. Idempotent per event id; events older than
 * the mirror are recorded but do not change state (O3).
 */
export async function handleRcWebhook(
  authHeader: string | undefined,
  payload: unknown,
  secret: string,
  now = new Date(),
): Promise<WebhookResult> {
  if (!authorized(authHeader, secret)) return { status: 401, body: { error: "unauthorized" } };
  const event = (payload as { event?: RcEvent } | undefined)?.event;
  if (!event?.id || !event.type || typeof event.event_timestamp_ms !== "number") {
    return { status: 400, body: { error: "malformed" } };
  }
  const uid = resolveUid(event);
  if (!uid) return { status: 200, body: { ok: true, skipped: "anonymous" } };

  const fs = db();
  const eventRef = fs.collection("webhook_events").doc(event.id);
  const subRef = fs.collection("subscriptions").doc(uid);
  const userRef = fs.collection("users").doc(uid);

  const applied = await fs.runTransaction(async (tx) => {
    const [seen, subSnap] = await Promise.all([tx.get(eventRef), tx.get(subRef)]);
    if (seen.exists) return null;
    const prev = mirrorFromDoc(subSnap.data());
    const res = applyRcEvent(prev, event, now);
    tx.set(eventRef, {
      type: event.type,
      uid,
      lifecycle: res.lifecycle,
      stale: res.stale,
      environment: event.environment ?? null,
      received_at: FieldValue.serverTimestamp(),
    });
    if (!res.stale && res.lifecycle !== "ignored") {
      tx.set(subRef, { ...res.next, updated_at: FieldValue.serverTimestamp() }, { merge: true });
      tx.set(
        userRef,
        {
          entitlement: entitlementOf(res.next, now),
          winback: res.next.winback ?? null,
        },
        { merge: true },
      );
    }
    return res;
  });

  if (!applied) return { status: 200, body: { ok: true, duplicate: true } };
  if (applied.stale) logger.warn("rc_webhook_stale", { uid, type: event.type, id: event.id });
  logger.info("rc_webhook", { uid, type: event.type, lifecycle: applied.lifecycle });
  if (applied.push) {
    try {
      await pushToUser(uid, applied.push);
    } catch (e) {
      // A failed push must not make RevenueCat redeliver a state change we already applied.
      logger.error("push_failed", { uid, kind: applied.push, err: String(e) });
    }
  }
  return { status: 200, body: { ok: true, lifecycle: applied.lifecycle } };
}
