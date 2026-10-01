import test from "node:test";
import assert from "node:assert/strict";
import { readConfig } from "../src/config.js";
import { getRidePrice, isValidLocation } from "../src/validation.js";

const validEnvironment = {
  DATABASE_URL: "postgres://localhost/tryps",
  APPLE_BUNDLE_ID: "com.tryps.rideshare",
  SESSION_SECRET: "a".repeat(32),
  STRIPE_SECRET_KEY: "sk_test_placeholder",
  STRIPE_WEBHOOK_SECRET: "whsec_placeholder",
  STRIPE_CONNECT_COUNTRY: "US",
  DRIVER_ONBOARDING_RETURN_URL: "https://tryps.app/return",
  DRIVER_ONBOARDING_REFRESH_URL: "https://tryps.app/refresh",
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

test("only allows server-priced ride types", () => {
  const prices = { "tryps-go": 1250, "tryps-comfort": 1820 };
  assert.equal(getRidePrice("tryps-go", prices), 1250);
  assert.equal(getRidePrice("not-a-ride", prices), undefined);
});
