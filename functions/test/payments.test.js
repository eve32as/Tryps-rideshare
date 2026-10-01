"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { allocateEqualShares, isRidePassUsable, validatePaymentRequest } = require("../payments");

test("validates cash splits, normalizes email addresses, and rejects unsupported combinations", () => {
  assert.deepEqual(validatePaymentRequest("CASH", [" FRIEND@example.com "], null), {
    method: "CASH",
    participantEmails: ["friend@example.com"],
    passId: null,
  });
  assert.throws(() => validatePaymentRequest("SIMULATED_CARD", ["friend@example.com"], null));
  assert.throws(() => validatePaymentRequest("RIDE_PASS", [], null));
  assert.throws(() => validatePaymentRequest("CASH", ["same@example.com", "SAME@example.com"], null));
  assert.throws(() => validatePaymentRequest("CASH", ["bad"], null));
  assert.throws(() => validatePaymentRequest("CASH", Array(5).fill("a@example.com"), null));
});

test("allocates every cent across equal payer shares deterministically", () => {
  const shares = allocateEqualShares(1_001, ["rider", "friend-1", "friend-2"]);
  assert.deepEqual(shares, [
    { payerId: "rider", amountCents: 334 },
    { payerId: "friend-1", amountCents: 334 },
    { payerId: "friend-2", amountCents: 333 },
  ]);
  assert.equal(shares.reduce((sum, share) => sum + share.amountCents, 0), 1_001);
  assert.throws(() => allocateEqualShares(10, ["rider", "rider"]));
});

test("requires a ride pass to be unexpired and have remaining rides", () => {
  assert.equal(isRidePassUsable({ remainingRides: 1, expiresAtMillis: 200 }, 100), true);
  assert.equal(isRidePassUsable({ remainingRides: 0, expiresAtMillis: 200 }, 100), false);
  assert.equal(isRidePassUsable({ remainingRides: 1, expiresAtMillis: 100 }, 100), false);
});
