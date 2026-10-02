"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { canResolveSafetyAlert, canTriggerSafetyAlert } = require("../safety");

const ride = {
  riderId: "rider-1",
  driverId: "driver-1",
  status: "IN_PROGRESS",
};

test("only active ride participants can trigger a new SOS alert", () => {
  assert.equal(canTriggerSafetyAlert(ride, "rider-1"), true);
  assert.equal(canTriggerSafetyAlert(ride, "driver-1"), true);
  assert.equal(canTriggerSafetyAlert(ride, "stranger"), false);
  assert.equal(canTriggerSafetyAlert({ ...ride, status: "COMPLETED" }, "rider-1"), false);
  assert.equal(canTriggerSafetyAlert({ ...ride, safetyAlert: { status: "ACTIVE" } }, "rider-1"), false);
  assert.equal(canTriggerSafetyAlert({ ...ride, safetyAlert: { status: "RESOLVED" } }, "rider-1"), true);
});

test("only ride participants can resolve an active SOS alert", () => {
  const active = { ...ride, safetyAlert: { status: "ACTIVE" } };
  assert.equal(canResolveSafetyAlert(active, "rider-1"), true);
  assert.equal(canResolveSafetyAlert(active, "stranger"), false);
  assert.equal(canResolveSafetyAlert(ride, "rider-1"), false);
});
