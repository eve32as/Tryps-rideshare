"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { geohashForLocation, geohashQueryBounds } = require("geofire-common");

const {
  calculateQuote,
  calculateDemandSurgeMultiplier,
  aggregateDemandHeatmap,
  canTransitionRide,
  distanceInKilometers,
  isFreshDriverLocation,
  isWithinServiceArea,
  geohashCellCenter,
  matchesRidePreferences,
  normalizeDriverRidePreferences,
  normalizeRidePreferences,
  rankNearbyDrivers,
  validCoordinate,
} = require("./domain");

test("validates coordinates and rejects values outside geographic bounds", () => {
  assert.equal(validCoordinate({ latitude: 37.7, longitude: -122.4 }), true);
  assert.equal(validCoordinate({ latitude: 91, longitude: 0 }), false);
  assert.equal(validCoordinate({ latitude: 0, longitude: Infinity }), false);
  assert.equal(validCoordinate(null), false);
});

test("enforces the configured San Francisco service-area geofence", () => {
  assert.equal(isWithinServiceArea({ latitude: 37.7749, longitude: -122.4194 }), true);
  assert.equal(isWithinServiceArea({ latitude: 37.6213, longitude: -122.3790 }), true);
  assert.equal(isWithinServiceArea({ latitude: 38.5816, longitude: -121.4944 }), false);
  assert.equal(isWithinServiceArea({ latitude: 91, longitude: 0 }), false);
});

test("aggregates only recent coarse demand zones above the privacy threshold", () => {
  const now = 1_800_000_000_000;
  const driverLocation = { latitude: 37.7749, longitude: -122.4194 };
  const nearbyZone = geohashForLocation([driverLocation.latitude, driverLocation.longitude]).slice(0, 5);
  const twoRequestZone = geohashForLocation([37.79, -122.40]).slice(0, 5);
  const rides = [
    ...Array.from({ length: 3 }, () => ({
      status: "searching_driver",
      demandZone: nearbyZone,
      updatedAtMillis: now - 60_000,
    })),
    ...Array.from({ length: 2 }, () => ({
      status: "offered",
      demandZone: twoRequestZone,
      updatedAtMillis: now - 60_000,
    })),
    {
      status: "dispatching",
      demandZone: nearbyZone,
      updatedAtMillis: now - 31 * 60_000,
    },
    {
      status: "completed",
      demandZone: nearbyZone,
      updatedAtMillis: now,
    },
  ];
  const zones = aggregateDemandHeatmap(rides, driverLocation, now);
  assert.equal(zones.length, 1);
  assert.equal(zones[0].geohash, nearbyZone);
  assert.equal(zones[0].demandBand, "3–5");
  assert.ok(Math.abs(zones[0].latitude - driverLocation.latitude) < 0.1);
  assert.ok(Math.abs(zones[0].longitude - driverLocation.longitude) < 0.1);
  assert.equal(geohashCellCenter("invalid"), null);
});

test("calculates a server-owned fare quote for a supported ride", () => {
  const quote = calculateQuote(
    { latitude: 37.7749, longitude: -122.4194 },
    { latitude: 37.784, longitude: -122.409 },
    "everyday",
    2_500
  );
  assert.equal(quote.rideType, "everyday");
  assert.equal(quote.currency, "usd");
  assert.equal(quote.pricingVersion, 3);
  assert.equal(quote.routeDistanceMeters, 2_500);
  assert.equal(quote.distanceKm, 2.5);
  assert.equal(
    quote.amountCents,
    quote.baseFareCents + quote.distanceFareCents +
    quote.surgeAdjustmentCents + quote.bookingFeeCents + quote.minimumFareAdjustmentCents
  );
  assert.equal(quote.amountCents, 713);
  assert.equal(quote.baseFareCents, 250);
  assert.equal(quote.distanceFareCents, 313);
  assert.equal(quote.surgeMultiplier, 1);
  assert.equal(quote.surgeAdjustmentCents, 0);
  assert.equal(quote.bookingFeeCents, 150);
  assert.equal(quote.minimumFareAdjustmentCents, 0);
  assert.throws(
    () => calculateQuote({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 0 }, "everyday", 0),
    RangeError
  );
  assert.throws(
    () => calculateQuote({ latitude: 0, longitude: 0 }, { latitude: 1, longitude: 1 }, "luxury", 1000),
    TypeError
  );
  assert.throws(
    () => calculateQuote({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 2 }, "everyday", 200_001),
    RangeError
  );
  assert.throws(
    () => calculateQuote({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 1 }, "everyday", 150.5),
    RangeError
  );
  const minimumFare = calculateQuote(
    { latitude: 37.7749, longitude: -122.4194 },
    { latitude: 37.7755, longitude: -122.4194 },
    "everyday",
    200
  );
  assert.equal(minimumFare.amountCents, 500);
  assert.equal(minimumFare.minimumFareAdjustmentCents, 75);
  const surgeFare = calculateQuote(
    { latitude: 37.7749, longitude: -122.4194 },
    { latitude: 37.784, longitude: -122.409 },
    "everyday",
    2_500,
    1.5
  );
  assert.equal(surgeFare.surgeAdjustmentCents, 282);
  assert.equal(surgeFare.amountCents, 995);
  assert.throws(
    () => calculateQuote({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 1 }, "everyday", 1000, 2),
    RangeError
  );
  assert.equal(
    calculateQuote({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 1 }, "comfort", 10_000).amountCents,
    2_300
  );
  assert.equal(
    calculateQuote({ latitude: 0, longitude: 0 }, { latitude: 0, longitude: 1 }, "xl", 10_000).amountCents,
    3_000
  );
});

test("applies capped surge tiers from local active demand and eligible driver supply", () => {
  assert.equal(calculateDemandSurgeMultiplier(0, 0), 1);
  assert.equal(calculateDemandSurgeMultiplier(1, 0), 1);
  assert.equal(calculateDemandSurgeMultiplier(2, 2), 1.25);
  assert.equal(calculateDemandSurgeMultiplier(4, 2), 1.5);
  assert.equal(calculateDemandSurgeMultiplier(20, 1), 1.5);
  assert.throws(() => calculateDemandSurgeMultiplier(-1, 0), TypeError);
  assert.throws(() => calculateDemandSurgeMultiplier(1, 1.5), TypeError);
});

test("matches only verified, available, recently located drivers within radius", () => {
  const now = 1_800_000_000_000;
  const pickup = { latitude: 37.7749, longitude: -122.4194 };
  const drivers = [
    {
      uid: "near",
      available: true,
      verified: true,
      location: { latitude: 37.78, longitude: -122.42 },
      locationUpdatedAtMillis: now - 30_000,
    },
    {
      uid: "far",
      available: true,
      verified: true,
      location: { latitude: 38, longitude: -122.42 },
      locationUpdatedAtMillis: now,
    },
    {
      uid: "stale",
      available: true,
      verified: true,
      location: pickup,
      locationUpdatedAtMillis: now - 121_000,
    },
    {
      uid: "offline",
      available: false,
      verified: true,
      location: pickup,
      locationUpdatedAtMillis: now,
    },
    {
      uid: "unverified",
      available: true,
      verified: false,
      location: pickup,
      locationUpdatedAtMillis: now,
    },
  ];
  assert.deepEqual(
    rankNearbyDrivers(drivers, pickup, 15, now).map((driver) => driver.uid),
    ["near"]
  );
  assert.equal(isFreshDriverLocation(now + 20_000, now), true);
  assert.equal(isFreshDriverLocation(now + 31_000, now), false);
});

test("ranks fresh drivers by proximity with a small freshness penalty", () => {
  const now = 1_800_000_000_000;
  const pickup = { latitude: 37.7749, longitude: -122.4194 };
  const nearButStale = {
    uid: "near-but-stale",
    available: true,
    verified: true,
    location: { latitude: 37.7839, longitude: -122.4194 },
    locationUpdatedAtMillis: now - 120_000,
  };
  const slightlyFartherAndFresh = {
    ...nearButStale,
    uid: "farther-and-fresh",
    location: { latitude: 37.7848, longitude: -122.4194 },
    locationUpdatedAtMillis: now,
  };
  assert.deepEqual(
    rankNearbyDrivers([nearButStale, slightlyFartherAndFresh], pickup, 15, now)
      .map(({ uid }) => uid),
    ["farther-and-fresh", "near-but-stale"]
  );
});

test("matches only drivers that satisfy opted-in safety and eco preferences", () => {
  const now = 1_800_000_000_000;
  const pickup = { latitude: 37.7749, longitude: -122.4194 };
  const driver = {
    uid: "eligible",
    available: true,
    verified: true,
    acceptsWomenAndMinorsRides: true,
    ecoFriendlyVehicle: true,
    location: pickup,
    locationUpdatedAtMillis: now,
  };
  assert.deepEqual(
    rankNearbyDrivers([driver], pickup, 15, now, {
      womanDriverForWomenAndMinors: true,
      ecoFriendlyVehicle: true,
    }).map(({ uid }) => uid),
    ["eligible"]
  );
  assert.deepEqual(
    rankNearbyDrivers([{ ...driver, acceptsWomenAndMinorsRides: false }], pickup, 15, now, {
      womanDriverForWomenAndMinors: true,
    }),
    []
  );
  assert.deepEqual(
    rankNearbyDrivers([{ ...driver, ecoFriendlyVehicle: false }], pickup, 15, now, {
      ecoFriendlyVehicle: true,
    }),
    []
  );
  assert.equal(matchesRidePreferences(driver, {
    womanDriverForWomenAndMinors: true,
    ecoFriendlyVehicle: true,
  }), true);
  assert.equal(matchesRidePreferences({ ...driver, ecoFriendlyVehicle: false }, {
    ecoFriendlyVehicle: true,
  }), false);
});

test("validates rider preferences and defaults omitted preferences to standard matching", () => {
  assert.deepEqual(normalizeRidePreferences(undefined), {
    womanDriverForWomenAndMinors: false,
    ecoFriendlyVehicle: false,
  });
  assert.deepEqual(normalizeRidePreferences({ ecoFriendlyVehicle: true }), {
    womanDriverForWomenAndMinors: false,
    ecoFriendlyVehicle: true,
  });
  assert.throws(() => normalizeRidePreferences({ womanDriverForWomenAndMinors: "yes" }), TypeError);
  assert.throws(() => normalizeRidePreferences({ unknown: true }), TypeError);
});

test("defaults missing driver preferences to false for older application clients", () => {
  assert.deepEqual(normalizeDriverRidePreferences(undefined, undefined), {
    acceptsWomenAndMinorsRides: false,
    ecoFriendlyVehicle: false,
  });
  assert.deepEqual(normalizeDriverRidePreferences(true, undefined), {
    acceptsWomenAndMinorsRides: true,
    ecoFriendlyVehicle: false,
  });
  assert.throws(() => normalizeDriverRidePreferences("true", false), TypeError);
});

test("geohash search bounds include nearby drivers and exclude distant regions", () => {
  const pickup = [37.7749, -122.4194];
  const bounds = geohashQueryBounds(pickup, 15_000);
  const isInBounds = (location) => {
    const geohash = geohashForLocation(location);
    return bounds.some(([start, end]) => geohash >= start && geohash <= end);
  };
  assert.equal(isInBounds([37.78, -122.42]), true);
  assert.equal(isInBounds([38.2, -122.42]), false);
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
