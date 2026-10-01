"use strict";

const { applicationDefault, initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");

async function main() {
  const uid = process.argv[2];
  if (!uid || uid.length > 128) {
    throw new Error("Usage: node functions/scripts/grant-admin.js FIREBASE_AUTH_UID");
  }
  initializeApp({ credential: applicationDefault() });
  const auth = getAuth();
  const user = await auth.getUser(uid);
  await auth.setCustomUserClaims(uid, { ...user.customClaims, admin: true });
  console.log(`Administrator claim granted to ${uid}.`);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
