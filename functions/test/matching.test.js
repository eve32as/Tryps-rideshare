"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { filterCompatibleRides, rankRideRecommendations } = require("../matching");

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
