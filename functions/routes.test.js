"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { RouteLookupError, getDrivingRoute } = require("./routes");

const pickup = { latitude: 37.7749, longitude: -122.4194 };
const dropOff = { latitude: 37.784, longitude: -122.409 };

test("requests a server-owned driving route and returns measured meters and duration", async () => {
  let request;
  const route = await getDrivingRoute(pickup, dropOff, "test-key", async (url, options) => {
    request = { url, options };
    return {
      ok: true,
      json: async () => ({ routes: [{ distanceMeters: 2_537, duration: "421s" }] }),
    };
  });

  assert.deepEqual(route, { distanceMeters: 2_537, durationSeconds: 421 });
  assert.match(request.url, /routes\.googleapis\.com\/directions\/v2:computeRoutes$/);
  assert.equal(request.options.headers["X-Goog-Api-Key"], "test-key");
  assert.equal(request.options.headers["X-Goog-FieldMask"], "routes.distanceMeters,routes.duration");
  assert.deepEqual(JSON.parse(request.options.body), {
    origin: { location: { latLng: pickup } },
    destination: { location: { latLng: dropOff } },
    travelMode: "DRIVE",
    routingPreference: "TRAFFIC_UNAWARE",
    computeAlternativeRoutes: false,
  });
});

test("rejects unavailable, malformed, and unconfigured route lookups", async () => {
  await assert.rejects(
    getDrivingRoute(pickup, dropOff, "", async () => { throw new Error("must not call fetch"); }),
    RouteLookupError
  );
  await assert.rejects(
    getDrivingRoute(pickup, dropOff, "test-key", async () => ({ ok: false })),
    RouteLookupError
  );
  await assert.rejects(
    getDrivingRoute(pickup, dropOff, "test-key", async () => ({
      ok: true,
      json: async () => ({ routes: [] }),
    })),
    RouteLookupError
  );
  await assert.rejects(
    getDrivingRoute(pickup, dropOff, "test-key", async () => {
      throw new Error("network error");
    }),
    RouteLookupError
  );
});
