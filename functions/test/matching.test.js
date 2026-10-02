"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  applyMatchingMetricEvent,
  calculateReliabilityPenalty,
  filterCompatibleRides,
  isValidDriverCategory,
  rankRideRecommendations,
} = require("../matching");

test("ranks rides by traffic-aware pickup ETA", () => {
  const ranked = rankRideRecommendations(
    [{ id: "far" }, { id: "near" }, { id: "middle" }],
    [
      { destinationIndex: 0, condition: "ROUTE_EXISTS", duration: "480s", distanceMeters: 3200 },
      { destinationIndex: 1, condition: "ROUTE_EXISTS", duration: "120s", distanceMeters: 700 },
      { destinationIndex: 2, condition: "ROUTE_EXISTS", duration: "240s", distanceMeters: 1600 },
    ],
  );

  assert.deepEqual(ranked.map(({ rideId }) => rideId), ["near", "middle", "far"]);
  assert.equal(ranked[0].pickupEtaSeconds, 120);
  assert.equal(ranked[0].pickupDistanceMeters, 700);
});

test("omits unavailable or invalid routes and resolves ETA ties consistently", () => {
  const ranked = rankRideRecommendations(
    [{ id: "b" }, { id: "a" }, { id: "unavailable" }],
    [
      { destinationIndex: 0, condition: "ROUTE_EXISTS", duration: "90s", distanceMeters: 500 },
      { destinationIndex: 1, condition: "ROUTE_EXISTS", duration: "90s", distanceMeters: 600 },
      { destinationIndex: 2, condition: "ROUTE_NOT_FOUND", duration: "100s" },
    ],
  );

  assert.deepEqual(ranked.map(({ rideId }) => rideId), ["a", "b"]);
});

test("filters out ride categories a driver cannot serve while retaining no-preference rides", () => {
  const candidates = [
    { id: "standard", vehicleCategory: "STANDARD" },
    { id: "accessible", vehicleCategory: "ACCESSIBLE" },
    { id: "any", vehicleCategory: "ANY" },
  ];

  assert.deepEqual(
    filterCompatibleRides(candidates, "STANDARD").map(({ id }) => id),
    ["standard", "any"],
  );
  assert.deepEqual(
    filterCompatibleRides(candidates, "ACCESSIBLE").map(({ id }) => id),
    ["accessible", "any"],
  );
});

test("treats legacy ride and driver profiles as broadly compatible", () => {
  const candidates = [{ id: "legacy" }, { id: "luxury", vehicleCategory: "LUXURY" }];
  assert.deepEqual(filterCompatibleRides(candidates, undefined).map(({ id }) => id), ["legacy"]);
  assert.deepEqual(filterCompatibleRides(candidates, "ANY").map(({ id }) => id), ["legacy", "luxury"]);
});

test("does not treat unknown vehicle categories as unrestricted", () => {
  const candidates = [
    { id: "invalid", vehicleCategory: "AIRCRAFT" },
    { id: "standard", vehicleCategory: "STANDARD" },
  ];
  assert.deepEqual(filterCompatibleRides(candidates, "AIRCRAFT").map(({ id }) => id), ["standard"]);
});

test("requires drivers to register a supported non-optional vehicle category", () => {
  assert.equal(isValidDriverCategory("ACCESSIBLE"), true);
  assert.equal(isValidDriverCategory("ANY"), false);
  assert.equal(isValidDriverCategory("AIRCRAFT"), false);
});

test("updates cancellation, completion, and average ETA error history", () => {
  const metrics = applyMatchingMetricEvent({
    cancellationCount: 1,
    completedRideCount: 2,
    etaSampleCount: 2,
    averageEtaErrorSeconds: 30,
  }, { type: "etaError", errorSeconds: 90 });

  assert.deepEqual(metrics, {
    cancellationCount: 1,
    completedRideCount: 2,
    etaSampleCount: 3,
    averageEtaErrorSeconds: 50,
  });
  assert.equal(applyMatchingMetricEvent(metrics, { type: "cancellation" }).cancellationCount, 2);
  assert.equal(applyMatchingMetricEvent(metrics, { type: "completion" }).completedRideCount, 3);
});

test("incorporates cancellation and ETA accuracy history into match scoring", () => {
  const reliablePenalty = calculateReliabilityPenalty({
    cancellationCount: 0,
    completedRideCount: 30,
    etaSampleCount: 12,
    averageEtaErrorSeconds: 20,
  });
  const unreliablePenalty = calculateReliabilityPenalty({
    cancellationCount: 8,
    completedRideCount: 2,
    etaSampleCount: 12,
    averageEtaErrorSeconds: 240,
  });
  assert.ok(unreliablePenalty > reliablePenalty);

  const recommendations = rankRideRecommendations(
    [{ id: "ride" }],
    [{ destinationIndex: 0, condition: "ROUTE_EXISTS", duration: "300s", distanceMeters: 2000 }],
    { cancellationCount: 8, completedRideCount: 2, etaSampleCount: 12, averageEtaErrorSeconds: 240 },
  );
  assert.equal(recommendations[0].matchingScoreSeconds, 300 + unreliablePenalty);
});
