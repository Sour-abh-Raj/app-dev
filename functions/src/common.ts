import { getApps, initializeApp } from "firebase-admin/app";
import { Firestore, Query, QueryDocumentSnapshot, Timestamp, getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions";

import { SubMirror } from "./subscriptions";

if (!getApps().length) initializeApp();

export const db = (): Firestore => getFirestore();

/** O4: never read an unbounded query; walk it in cursor pages. */
export async function forEachPage(
  q: Query,
  pageSize: number,
  fn: (doc: QueryDocumentSnapshot) => Promise<void>,
  maxPages = 200,
): Promise<number> {
  let n = 0;
  let cursor: QueryDocumentSnapshot | undefined;
  for (let page = 0; page < maxPages; page++) {
    const snap = await (cursor ? q.startAfter(cursor) : q).limit(pageSize).get();
    for (const d of snap.docs) {
      await fn(d);
      n++;
    }
    if (snap.size < pageSize) break;
    cursor = snap.docs[snap.docs.length - 1];
  }
  return n;
}

const DATE_FIELDS = ["renews_at", "grace_until", "expired_at"] as const;

export function mirrorFromDoc(data: FirebaseFirestore.DocumentData | undefined): SubMirror | null {
  if (!data) return null;
  const out: Record<string, unknown> = { ...data };
  for (const f of DATE_FIELDS) out[f] = toDate(data[f]);
  if (data.winback) out.winback = { ...data.winback, until: toDate(data.winback.until) };
  if (data.promo) out.promo = { ...data.promo, expires_at: toDate(data.promo.expires_at) };
  return out as unknown as SubMirror;
}

export function toDate(v: unknown): Date | null {
  if (!v) return null;
  if (v instanceof Timestamp) return v.toDate();
  if (v instanceof Date) return v;
  if (typeof v === "string" || typeof v === "number") return new Date(v);
  return null;
}

export type PushKind = "fix_payment" | "winback" | "trial_d3" | "trial_d1" | "checkin";

// Copy follows the brand voice: encouraging, never shaming.
export const PUSH_COPY: Record<PushKind, { title: string; body: string; link: string }> = {
  fix_payment: {
    title: "Payment didn't go through",
    body: "Update your payment method to keep your plan adapting.",
    link: "forme://settings/subscription",
  },
  winback: {
    title: "Your progress is saved",
    body: "Come back to Pro — 50% off your first year of Annual.",
    link: "forme://paywall?placement=winback",
  },
  trial_d3: {
    title: "Your morph is ready — keep it",
    body: "3 days left in your trial. See how far you've come.",
    link: "forme://progress",
  },
  trial_d1: {
    title: "Your morph is ready — keep it",
    body: "Your trial ends tomorrow. Keep your AI reports and timeline.",
    link: "forme://paywall?placement=trial_end",
  },
  checkin: {
    title: "Sunday check-in",
    body: "3 photos + weight + 60 seconds. See yourself changing.",
    link: "forme://checkin",
  },
};

export async function pushToUser(uid: string, kind: PushKind): Promise<number> {
  const ref = db().collection("users").doc(uid);
  const snap = await ref.get();
  const tokens: string[] = (snap.get("fcm_tokens") as string[] | undefined) ?? [];
  if (!tokens.length || snap.get("deleted_at")) return 0;
  const copy = PUSH_COPY[kind];
  const res = await getMessaging().sendEachForMulticast({
    tokens,
    notification: { title: copy.title, body: copy.body },
    data: { link: copy.link, kind },
  });
  const dead = res.responses
    .map((r, i) => (!r.success && isDeadToken(r.error?.code) ? tokens[i] : null))
    .filter((t): t is string => !!t);
  if (dead.length) {
    await ref.update({ fcm_tokens: tokens.filter((t) => !dead.includes(t)) });
  }
  logger.info("push", { uid, kind, sent: res.successCount, dead: dead.length });
  return res.successCount;
}

function isDeadToken(code?: string): boolean {
  return (
    code === "messaging/registration-token-not-registered" ||
    code === "messaging/invalid-registration-token"
  );
}
