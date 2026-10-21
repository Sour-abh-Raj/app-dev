import { Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall, onRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import sharp from "sharp";

import { purgeUser, requestDeletion } from "./account";
import { db, forEachPage, mirrorFromDoc, pushToUser } from "./common";
import { handleRcWebhook } from "./rcWebhook";
import { dueNudge } from "./subscriptions";

const RC_WEBHOOK_AUTH = defineSecret("RC_WEBHOOK_AUTH");
const REVENUECAT_SECRET_KEY = defineSecret("REVENUECAT_SECRET_KEY");

export const rcWebhook = onRequest(
  { secrets: [RC_WEBHOOK_AUTH], cors: false, maxInstances: 10 },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).send();
      return;
    }
    const out = await handleRcWebhook(req.get("authorization"), req.body, RC_WEBHOOK_AUTH.value());
    res.status(out.status).json(out.body);
  },
);

/** Trial D-3 / D-1 nudges ("Your morph is ready — keep it"). Hourly. */
export const trialNudges = onSchedule("every 60 minutes", async () => {
  const now = new Date();
  const horizon = Timestamp.fromDate(new Date(now.getTime() + 72 * 3600 * 1000));
  const q = db()
    .collection("subscriptions")
    .where("trial", "==", true)
    .where("renews_at", ">", Timestamp.fromDate(now))
    .where("renews_at", "<=", horizon)
    .orderBy("renews_at");
  const sent = await forEachPage(q, 200, async (doc) => {
    const kind = dueNudge(mirrorFromDoc(doc.data())!, now);
    if (!kind) return;
    // Mark first so a crash never double-sends.
    await doc.ref.update({ [`nudged_${kind}`]: true });
    await pushToUser(doc.id, kind === "d3" ? "trial_d3" : "trial_d1");
  });
  logger.info("trial_nudges", { scanned: sent });
});

/**
 * Sunday check-in reminder. The app stores `checkin_reminder_slot` as the UTC
 * "weekday-hour" of the user's chosen local reminder time.
 */
export const checkinReminders = onSchedule("every 60 minutes", async () => {
  const now = new Date();
  const slot = `${now.getUTCDay()}-${String(now.getUTCHours()).padStart(2, "0")}`;
  const q = db().collection("users").where("checkin_reminder_slot", "==", slot).orderBy("__name__");
  await forEachPage(q, 300, async (doc) => {
    await pushToUser(doc.id, "checkin");
  });
});

/** Purge accounts flagged for deletion. Hourly, so every purge lands ≤24h. */
export const purgeDeletedUsers = onSchedule(
  { schedule: "every 60 minutes", secrets: [REVENUECAT_SECRET_KEY], timeoutSeconds: 540 },
  async () => {
    const q = db()
      .collection("users")
      .where("deleted_at", "<=", Timestamp.now())
      .orderBy("deleted_at");
    // Purging removes the doc, so always re-read the first page.
    let total = 0;
    for (let i = 0; i < 20; i++) {
      const snap = await q.limit(50).get();
      if (snap.empty) break;
      for (const d of snap.docs) {
        try {
          await purgeUser(d.id, REVENUECAT_SECRET_KEY.value());
          total++;
        } catch (e) {
          logger.error("purge_failed", { err: String(e) });
        }
      }
      if (snap.size < 50) break;
    }
    logger.info("purge_run", { purged: total });
  },
);

export const requestAccountDeletion = onCall(
  { secrets: [REVENUECAT_SECRET_KEY] },
  async (req) => {
    const uid = req.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
    await requestDeletion(uid);
    try {
      await purgeUser(uid, REVENUECAT_SECRET_KEY.value());
      return { purged: true };
    } catch (e) {
      logger.error("immediate_purge_failed", { err: String(e) });
      return { purged: false, scheduled: true }; // the hourly job finishes it
    }
  },
);

/** progress-photos/{uid}/{checkin}/{angle}.jpg → _thumb.jpg (320px) + _1024.jpg. */
export const photoVariants = onObjectFinalized({ memory: "1GiB" }, async (event) => {
  const name = event.data.name ?? "";
  const m = name.match(/^progress-photos\/[^/]+\/[^/]+\/(front|side|back)\.jpg$/);
  if (!m) return;
  const bucket = getStorage().bucket(event.data.bucket);
  const [buf] = await bucket.file(name).download();
  const base = name.slice(0, -4);
  for (const [suffix, edge] of [["_thumb", 320], ["_1024", 1024]] as const) {
    // .rotate() applies EXIF orientation; sharp drops all metadata (incl. GPS) on output.
    const out = await sharp(buf)
      .rotate()
      .resize(edge, edge, { fit: "inside", withoutEnlargement: true })
      .jpeg({ quality: 82 })
      .toBuffer();
    await bucket.file(`${base}${suffix}.jpg`).save(out, {
      contentType: "image/jpeg",
      resumable: false,
      metadata: { cacheControl: "private, max-age=86400" },
    });
  }
});
