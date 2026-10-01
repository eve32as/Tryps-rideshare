"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  calculateQuote,
  canTransitionRide,
  distanceInKilometers,
  validCoordinate,
} = require("./domain");

test("validates coordinates and rejects values outside geographic bounds", () => {
  assert.equal(validCoordinate({ latitude: 37.7, longitude: -122.4 }), true);
  assert.equal(validCoordinate({ latitude: 91, longitude: 0 }), false);
  assert.equal(validCoordinate({ latitude: 0, longitude: Infinity }), false);
  assert.equal(validCoordinate(null), false);
});

test("calculates a server-owned fare quote for a supported ride", () => {
  const quote = calculateQuote(
    { latitude: 37.7749, longitude: -122.4194 },
    { latitude: 37.784, longitude: -122.409 },
    "everyday"
  );
  assert.equal(quote.rideType, "everyday");
  assert.equal(quote.currency, "usd");
  assert.ok(quote.amountCents > 800);
  assert.ok(quote.amountCents % 50 === 0);
  assert.throws(() => calculateQuote({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 0 }, "everyday"), RangeError);
  assert.throws(() => calculateQuote({ latitude: 0, longitude: 0 }, { latitude: 1, longitude: 1 }, "luxury"), TypeError);
});

test("distance is symmetric and driver trip statuses only move forward", () => {
  const a = { latitude: 37.7749, longitude: -122.4194 };
  const b = { latitude: 37.784, longitude: -122.409 };
  assert.ok(Math.abs(distanceInKilometers(a, b) - distanceInKilometers(b, a)) < 1e-9);
  assert.equal(canTransitionRide("en_route", "arrived"), true);
  assert.equal(canTransitionRide("driver_assigned", "en_route"), true);
  assert.equal(canTransitionRide("completed", "in_progress"), false);
  assert.equal(canTransitionRide("arrived", "completed"), false);
});
