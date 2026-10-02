"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { parseTransitOptions } = require("../transit");

const busRoute = {
  duration: "1800s",
  distanceMeters: 8_200,
  legs: [{
    steps: [
      { travelMode: "WALK", staticDuration: "120s", distanceMeters: 150 },
      {
        travelMode: "TRANSIT",
        staticDuration: "900s",
        distanceMeters: 7_000,
        navigationInstruction: { instructions: "Take the 38 bus" },
        transitDetails: {
          departureTime: "2026-10-02T03:10:00Z",
          arrivalTime: "2026-10-02T03:25:00Z",
          stopDetails: {
            departureStop: { name: "A" },
            arrivalStop: { name: "B" },
          },
          transitLine: {
            name: "Geary Blvd",
            nameShort: "38",
            agencies: [{ name: "Muni" }],
            vehicle: { type: "BUS" },
          },
        },
      },
    ],
  }],
};

test("parses and ranks valid transit itineraries with sanitized step details", () => {
  const options = parseTransitOptions([
    { duration: "2400s", distanceMeters: 9_000, legs: [{ steps: [{ travelMode: "WALK" }] }] },
    busRoute,
    { duration: "bad", distanceMeters: 5, legs: [{ steps: [{ travelMode: "WALK" }] }] },
  ]);
  assert.equal(options.length, 1);
  assert.equal(options[0].durationSeconds, 1_800);
  assert.equal(options[0].walkingDurationSeconds, 120);
  assert.deepEqual(options[0].steps[1], {
    mode: "TRANSIT",
    instruction: "Take the 38 bus",
    lineName: "38",
    agencyName: "Muni",
    vehicleType: "BUS",
    departureStop: "A",
    arrivalStop: "B",
    departureTime: "2026-10-02T03:10:00Z",
    arrivalTime: "2026-10-02T03:25:00Z",
    durationSeconds: 900,
    distanceMeters: 7_000,
  });
});

test("rejects malformed routes, non-transit itineraries, and invalid limits", () => {
  assert.deepEqual(parseTransitOptions(null), []);
  assert.deepEqual(parseTransitOptions([{
    duration: "30s",
    distanceMeters: 100,
    legs: [{ steps: [{ travelMode: "DRIVE" }] }],
  }]), []);
  assert.deepEqual(parseTransitOptions([busRoute], 0), []);
  assert.deepEqual(parseTransitOptions([{ ...busRoute, distanceMeters: -1 }]), []);
  assert.deepEqual(parseTransitOptions([{ ...busRoute, legs: [{ steps: [null] }] }]), []);
  assert.equal(parseTransitOptions([busRoute, busRoute, busRoute, busRoute]).length, 3);
});
