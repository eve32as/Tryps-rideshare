"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { calculateSurgeMultiplier, distanceMeters } = require("../pricing");

test("caps demand pricing at 1.5x and increases only when nearby demand exceeds supply", () => {
  assert.equal(calculateSurgeMultiplier(0, 0), 1);
  assert.equal(calculateSurgeMultiplier(4, 4), 1);
  assert.equal(calculateSurgeMultiplier(2, 1), 1.25);
  assert.equal(calculateSurgeMultiplier(4, 1), 1.5);
  assert.equal(calculateSurgeMultiplier(200, 0), 1.5);
});

test("treats invalid counts as zero", () => {
  assert.equal(calculateSurgeMultiplier(-1, 0), 1);
  assert.equal(calculateSurgeMultiplier(Number.MAX_SAFE_INTEGER + 1, 0), 1);
});

test("calculates geographic distance in meters", () => {
  assert.equal(distanceMeters(
    { latitude: 0, longitude: 0 },
    { latitude: 0, longitude: 0 },
  ), 0);
  const oneDegreeAtEquator = distanceMeters(
    { latitude: 0, longitude: 0 },
    { latitude: 0, longitude: 1 },
  );
  assert.ok(oneDegreeAtEquator > 111_000 && oneDegreeAtEquator < 112_000);
});
