import test from "node:test";
import assert from "node:assert/strict";
import { readConfig } from "../src/config.js";
import { calculateRideFare, isValidLocation } from "../src/validation.js";

const validEnvironment = {
  DATABASE_URL: "postgres://localhost/tryps",
  APPLE_BUNDLE_ID: "com.tryps.rideshare",
  SESSION_SECRET: "a".repeat(32),
  STRIPE_SECRET_KEY: "sk_test_placeholder",
  STRIPE_WEBHOOK_SECRET: "whsec_placeholder",
  STRIPE_CONNECT_COUNTRY: "US",
  DRIVER_ONBOARDING_RETURN_URL: "https://tryps.app/return",
  DRIVER_ONBOARDING_REFRESH_URL: "https://tryps.app/refresh",
  TRIP_SHARE_BASE_URL: "https://tryps.app/trip",
  PLATFORM_FEE_BPS: "2000",
};

test("requires a sufficiently strong session signing secret", () => {
  assert.throws(
    () => readConfig({ ...validEnvironment, SESSION_SECRET: "short" }),
    /at least 32 bytes/,
  );
});

test("validates the platform fee and port", () => {
  assert.throws(
    () => readConfig({ ...validEnvironment, PLATFORM_FEE_BPS: "5001" }),
    /between 0 and 5000/,
  );
  assert.throws(
    () => readConfig({ ...validEnvironment, PORT: "70000" }),
    /valid TCP port/,
  );
});

test("supports only the USD sample fares", () => {
  assert.throws(
    () => readConfig({ ...validEnvironment, STRIPE_CURRENCY: "jpy" }),
    /USD only/,
  );
  assert.equal(readConfig(validEnvironment).currency, "usd");
});

test("rejects placeholder or insecure driver onboarding URLs", () => {
  assert.throws(
    () => readConfig({
      ...validEnvironment,
      DRIVER_ONBOARDING_RETURN_URL: "http://tryps.app/return",
    }),
    /real HTTPS URL/,
  );
  assert.throws(
    () => readConfig({
      ...validEnvironment,
      DRIVER_ONBOARDING_REFRESH_URL: "https://tryps.invalid/refresh",
    }),
    /real HTTPS URL/,
  );
  assert.throws(
    () => readConfig({ ...validEnvironment, TRIP_SHARE_BASE_URL: "http://tryps.app/trip" }),
    /real HTTPS URL/,
  );
});

test("accepts valid pickup coordinates and rejects out-of-range values", () => {
  assert.equal(isValidLocation({
    label: "City Hall",
    latitude: 37.7793,
    longitude: -122.4193,
  }), true);
  assert.equal(isValidLocation({
    label: "Invalid",
    latitude: 91,
    longitude: 0,
  }), false);
  assert.equal(isValidLocation({
    label: "",
    latitude: 37,
    longitude: -122,
  }), false);
});

test("calculates server-side estimated fares and rejects unsupported ride types or distances", () => {
  const pricing = {
    baseCents: 300,
    perKmCents: 150,
    minimumCents: 500,
    distanceMultiplier: 1.35,
    rideTypeMultipliers: { "tryps-go": 1, "tryps-comfort": 1.4, "tryps-xl": 1.8 },
  };
  const pickup = { latitude: 37.7793, longitude: -122.4193 };
  const destination = { latitude: 37.7893, longitude: -122.4193 };
  const estimate = calculateRideFare(pickup, destination, "tryps-go", pricing);
  assert.ok(estimate.amountCents > pricing.minimumCents);
  assert.ok(estimate.estimatedDistanceKm > 1);
  assert.equal(estimate.amountCents, estimate.baseFareCents + estimate.distanceChargeCents);
  assert.equal(estimate.distanceChargeCents, Math.round(estimate.estimatedDistanceKm * estimate.perKmCents));
  assert.equal(estimate.minimumApplied, false);
  assert.equal(
    calculateRideFare(pickup, destination, "tryps-xl", pricing).amountCents,
    Math.round(estimate.amountCents * 1.8),
  );
  const minimumFare = calculateRideFare(
    pickup,
    pickup,
    "tryps-go",
    { ...pricing, minimumCents: 1000 },
  );
  assert.equal(minimumFare.amountCents, 1000);
  assert.equal(minimumFare.minimumApplied, true);
  assert.equal(calculateRideFare(pickup, destination, "unknown", pricing), undefined);
  assert.equal(calculateRideFare(pickup, { latitude: 0, longitude: 0 }, "tryps-go", pricing), undefined);
  assert.equal(calculateRideFare(pickup, destination, "toString", pricing), undefined);
});

test("validates fare configuration and optional APNs settings", () => {
  assert.throws(
    () => readConfig({ ...validEnvironment, FARE_PER_KM_CENTS: "-1" }),
    /positive cent amounts/,
  );
  assert.throws(
    () => readConfig({ ...validEnvironment, APNS_KEY_ID: "key-id" }),
    /Configure all APNS_KEY_ID/,
  );
  assert.throws(
    () => readConfig({
      ...validEnvironment,
      APNS_KEY_ID: "key-id",
      APNS_TEAM_ID: "team-id",
      APNS_PRIVATE_KEY: "key",
      APNS_HOST: "example.com",
    }),
    /Apple production or sandbox/,
  );
});
