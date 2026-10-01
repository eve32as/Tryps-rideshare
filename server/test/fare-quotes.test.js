import test from "node:test";
import assert from "node:assert/strict";
import { createFareQuote, verifyFareQuote } from "../src/fare-quotes.js";

const signingKey = new TextEncoder().encode("test-signing-secret-with-at-least-32-bytes");
const pickup = { label: "Pickup", latitude: 37.7793, longitude: -122.4193 };
const destination = { label: "Destination", latitude: 37.7893, longitude: -122.4193 };
const pricing = {
  baseCents: 300,
  perKmCents: 150,
  minimumCents: 500,
  rideTypeMultipliers: { "tryps-go": 1, "tryps-xl": 1.8 },
};
const now = Date.parse("2026-01-01T12:00:00Z");

test("creates a signed quote that verifies for its exact trip and fare", async () => {
  const quote = await createFareQuote({
    pickup,
    destination,
    rideType: "tryps-go",
    routeDistanceMeters: 2_000,
    pricing,
    currency: "usd",
    signingKey,
    now,
  });
  const fare = await verifyFareQuote({
    token: quote.fareQuoteToken,
    pickup,
    destination,
    rideType: "tryps-go",
    signingKey,
    now: now + 1_000,
  });

  assert.equal(quote.amountCents, 600);
  assert.equal(quote.estimatedDistanceKm, 2);
  assert.equal(fare.amountCents, quote.amountCents);
  assert.equal(quote.expiresAt, "2026-01-01T12:10:00.000Z");
});

test("rejects expired, altered, or mismatched fare quote tokens", async () => {
  const quote = await createFareQuote({
    pickup,
    destination,
    rideType: "tryps-go",
    routeDistanceMeters: 2_000,
    pricing,
    currency: "usd",
    signingKey,
    now,
  });
  const verify = (options = {}) => verifyFareQuote({
    token: quote.fareQuoteToken,
    pickup,
    destination,
    rideType: "tryps-go",
    signingKey,
    now: now + 1_000,
    ...options,
  });

  assert.equal(await verify({ now: now + 601_000 }), undefined);
  assert.equal(await verify({ pickup: { ...pickup, latitude: 37.78 } }), undefined);
  assert.equal(await verify({ rideType: "tryps-xl" }), undefined);
  assert.equal(await verify({ signingKey: new TextEncoder().encode("wrong-signing-secret-with-at-least-32-bytes") }), undefined);
  assert.equal(await verify({ token: "not-a-token" }), undefined);
});
