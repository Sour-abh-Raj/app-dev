/**
 * Deploy-time seeding. Usage (after `npm run build`):
 *   node lib/scripts/seed.js exercises
 *   FORME_TEAM_CODE=... PROMO_PEPPER=... node lib/scripts/seed.js team-code [uses_max] [days]
 *   FORME_TEAM_CODE=... PROMO_PEPPER=... node lib/scripts/seed.js revoke
 * The plaintext code is read from the environment (Secret Manager in CI) and
 * only its HMAC is stored — never hardcode a code in the app or the repo.
 */
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { Timestamp } from "firebase-admin/firestore";

import { db } from "../common";

export function normalizeCode(code: string): string {
  const c = code.replace(/\s+/g, "").toUpperCase();
  if (!/^[A-Z0-9-]{4,40}$/.test(c)) throw new Error("code must be 4-40 chars of A-Z, 0-9, -");
  return c;
}

/** Must match ai_service/app/promo.py code_hash(). */
export function codeHash(code: string, pepper: string): string {
  if (!pepper) throw new Error("PROMO_PEPPER is required");
  return createHmac("sha256", pepper).update(normalizeCode(code)).digest("hex");
}

async function seedExercises(): Promise<void> {
  const path = resolve(__dirname, "../../../seed/exercises.json");
  const data = JSON.parse(readFileSync(path, "utf8")) as {
    version: number;
    exercises: { id: string }[];
  };
  const batch = db().batch();
  for (const e of data.exercises) {
    batch.set(db().collection("exercises").doc(e.id), { ...e, seed_version: data.version });
  }
  batch.set(db().collection("config").doc("exercises"), { version: data.version });
  await batch.commit();
  console.log(`seeded ${data.exercises.length} exercises (v${data.version})`);
}

async function seedTeamCode(usesMax: number, days: number): Promise<void> {
  const h = codeHash(process.env.FORME_TEAM_CODE ?? "", process.env.PROMO_PEPPER ?? "");
  await db()
    .collection("promo_codes")
    .doc(h)
    .set(
      {
        uses_max: usesMax,
        uses: 0,
        tier: "pro",
        grant_days: 30,
        revoked: false,
        label: "team",
        expires_at: Timestamp.fromDate(new Date(Date.now() + days * 24 * 3600 * 1000)),
      },
      { merge: true },
    );
  console.log(`team code seeded (hash ${h.slice(0, 8)}…, uses_max ${usesMax}, ${days}d)`);
}

async function revokeTeamCode(): Promise<void> {
  const h = codeHash(process.env.FORME_TEAM_CODE ?? "", process.env.PROMO_PEPPER ?? "");
  await db().collection("promo_codes").doc(h).update({ revoked: true });
  console.log(`revoked ${h.slice(0, 8)}…`);
}

if (require.main === module) {
  const [cmd, a, b] = process.argv.slice(2);
  const run =
    cmd === "exercises"
      ? seedExercises()
      : cmd === "team-code"
        ? seedTeamCode(Number(a ?? 25), Number(b ?? 90))
        : cmd === "revoke"
          ? revokeTeamCode()
          : Promise.reject(new Error("usage: seed.js exercises|team-code|revoke"));
  run.catch((e) => {
    console.error(String(e));
    process.exit(1);
  });
}
