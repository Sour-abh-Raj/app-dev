import { createHash } from "node:crypto";

import { getAuth } from "firebase-admin/auth";
import { FieldValue } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions";

import { db } from "./common";

export const PURGE_PREFIXES = ["progress-photos", "meals", "previews"] as const;

/** Mark the account deleted, lock sign-in, and try an immediate purge. */
export async function requestDeletion(uid: string): Promise<void> {
  await db().collection("users").doc(uid).set(
    { deleted_at: FieldValue.serverTimestamp() },
    { merge: true },
  );
  try {
    await getAuth().updateUser(uid, { disabled: true });
    await getAuth().revokeRefreshTokens(uid);
  } catch (e) {
    logger.warn("auth_lock_failed", { uid, err: String(e) });
  }
}

/**
 * Remove everything we hold for a user: Firestore tree, subscription mirror,
 * Storage photos/meals/previews, RevenueCat customer, and the auth account.
 * Safe to re-run.
 */
export async function purgeUser(uid: string, rcSecret = ""): Promise<void> {
  const fs = db();
  await fs.recursiveDelete(fs.collection("users").doc(uid));
  await fs.collection("subscriptions").doc(uid).delete();
  const bucket = getStorage().bucket();
  for (const p of PURGE_PREFIXES) {
    await bucket.deleteFiles({ prefix: `${p}/${uid}/`, force: true });
  }
  if (rcSecret) {
    const res = await fetch(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(uid)}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${rcSecret}` },
    });
    if (!res.ok && res.status !== 404) throw new Error(`revenuecat delete ${res.status}`);
  }
  try {
    await getAuth().deleteUser(uid);
  } catch (e) {
    if ((e as { code?: string }).code !== "auth/user-not-found") throw e;
  }
  // Audit without PII: a one-way hash of the uid and the purge time.
  await fs
    .collection("deletion_log")
    .doc(createHash("sha256").update(uid).digest("hex"))
    .set({ purged_at: FieldValue.serverTimestamp() });
  logger.info("user_purged");
}
