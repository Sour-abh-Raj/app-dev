import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import {
  RulesTestEnvironment,
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, serverTimestamp, setDoc, updateDoc, Timestamp } from "firebase/firestore";
import { ref, uploadBytes, getBytes } from "firebase/storage";
import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";

let env: RulesTestEnvironment;
const root = resolve(__dirname, "../../../firebase");

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: "forme-rules-test",
    firestore: { rules: readFileSync(`${root}/firestore.rules`, "utf8"), host: "127.0.0.1", port: 8080 },
    storage: { rules: readFileSync(`${root}/storage.rules`, "utf8"), host: "127.0.0.1", port: 9199 },
  });
});
afterAll(async () => env?.cleanup());
beforeEach(async () => {
  await env.clearFirestore();
});

const alice = () => env.authenticatedContext("alice").firestore();
const bob = () => env.authenticatedContext("bob").firestore();

describe("firestore rules", () => {
  it("owner can create and read their profile; others cannot", async () => {
    await assertSucceeds(setDoc(doc(alice(), "users/alice"), { level: "beginner" }));
    await assertSucceeds(getDoc(doc(alice(), "users/alice")));
    await assertFails(getDoc(doc(bob(), "users/alice")));
    await assertFails(setDoc(doc(bob(), "users/alice"), { level: "x" }));
    await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), "users/alice")));
  });

  it("clients cannot grant themselves pro or reset usage", async () => {
    await assertFails(setDoc(doc(alice(), "users/alice"), { entitlement: { pro: true } }));
    await assertSucceeds(setDoc(doc(alice(), "users/alice"), { level: "beginner" }));
    await assertFails(updateDoc(doc(alice(), "users/alice"), { "entitlement.pro": true }));
    await assertFails(updateDoc(doc(alice(), "users/alice"), { ai_usage: {} }));
    await assertFails(updateDoc(doc(alice(), "users/alice"), { deleted_at: null }));
    await assertSucceeds(updateDoc(doc(alice(), "users/alice"), { fcm_tokens: ["t1"] }));
  });

  it("photo consent must be adult", async () => {
    await assertFails(setDoc(doc(alice(), "users/alice"), { photo_consent: { adult: false } }));
  });

  it("deleted accounts are read-only", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "users/alice"), { deleted_at: Timestamp.now() });
    });
    await assertFails(updateDoc(doc(alice(), "users/alice"), { level: "x" }));
    await assertFails(
      setDoc(doc(alice(), "users/alice/workouts/w1"), { sets: [], volume_kg: 0 }),
    );
  });

  it("workouts: owner only, bounded sets", async () => {
    await assertSucceeds(setDoc(doc(alice(), "users/alice/workouts/w1"), { sets: [], volume_kg: 0 }));
    await assertFails(setDoc(doc(bob(), "users/alice/workouts/w2"), { sets: [], volume_kg: 0 }));
    await assertFails(setDoc(doc(alice(), "users/alice/workouts/w3"), { sets: "nope" }));
  });

  it("check-ins: client cannot write the AI report", async () => {
    const c = doc(alice(), "users/alice/checkins/c1");
    await assertSucceeds(setDoc(c, { week_index: 1, photos: [] }));
    await assertFails(updateDoc(c, { ai_report: { summary: "fake" } }));
    await assertFails(setDoc(doc(alice(), "users/alice/checkins/c2"), { photos: [], ai_status: "done" }));
  });

  it("plans: client may only write template plans", async () => {
    await assertSucceeds(setDoc(doc(alice(), "users/alice/plans/p1"), { source: "template" }));
    await assertFails(setDoc(doc(alice(), "users/alice/plans/p2"), { source: "ai" }));
  });

  it("meals need a timestamp", async () => {
    await assertSucceeds(setDoc(doc(alice(), "users/alice/meals/m1"), { logged_at: serverTimestamp() }));
    await assertFails(setDoc(doc(alice(), "users/alice/meals/m2"), { logged_at: "today" }));
  });

  it("server-only collections are closed", async () => {
    for (const p of ["promo_codes/x", "promo_redemptions/x", "ai_cache/x", "config/prompts",
                     "rate_limits/x", "webhook_events/x", "users/alice/ai_jobs/x"]) {
      await assertFails(getDoc(doc(alice(), p)));
      await assertFails(setDoc(doc(alice(), p), { a: 1 }));
    }
    await assertFails(setDoc(doc(alice(), "subscriptions/alice"), { active: true }));
    await assertSucceeds(getDoc(doc(alice(), "subscriptions/alice")));
    await assertFails(getDoc(doc(bob(), "subscriptions/alice")));
    await assertFails(setDoc(doc(alice(), "users/alice/usage/x"), { n: 0 }));
  });

  it("exercises are readable by signed-in users only", async () => {
    await assertSucceeds(getDoc(doc(alice(), "exercises/goblet_squat")));
    await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), "exercises/goblet_squat")));
    await assertFails(setDoc(doc(alice(), "exercises/x"), { a: 1 }));
  });
});

describe("storage rules", () => {
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
  const meta = { contentType: "image/jpeg" };
  const st = (uid: string) => env.authenticatedContext(uid).storage();

  it("owner can upload and read progress photos; nobody else", async () => {
    await assertSucceeds(uploadBytes(ref(st("alice"), "progress-photos/alice/c1/front.jpg"), jpeg, meta));
    await assertSucceeds(getBytes(ref(st("alice"), "progress-photos/alice/c1/front.jpg")));
    await assertFails(getBytes(ref(st("bob"), "progress-photos/alice/c1/front.jpg")));
    await assertFails(uploadBytes(ref(st("bob"), "progress-photos/alice/c1/side.jpg"), jpeg, meta));
    await assertFails(getBytes(ref(env.unauthenticatedContext().storage(), "progress-photos/alice/c1/front.jpg")));
  });

  it("only jpeg front/side/back originals", async () => {
    await assertFails(uploadBytes(ref(st("alice"), "progress-photos/alice/c1/front.png"), jpeg, { contentType: "image/png" }));
    await assertFails(uploadBytes(ref(st("alice"), "progress-photos/alice/c1/front_thumb.jpg"), jpeg, meta));
    await assertFails(uploadBytes(ref(st("alice"), "progress-photos/alice/c1/front.jpg"), jpeg, { contentType: "text/plain" }));
  });

  it("previews are server-written", async () => {
    await assertFails(uploadBytes(ref(st("alice"), "previews/alice/p.jpg"), jpeg, meta));
  });

  it("meals owner-only", async () => {
    await assertSucceeds(uploadBytes(ref(st("alice"), "meals/alice/m1.jpg"), jpeg, meta));
    await assertFails(uploadBytes(ref(st("bob"), "meals/alice/m2.jpg"), jpeg, meta));
  });
});
