import test from "node:test";
import assert from "node:assert/strict";
import { getDrivingDistanceMeters, RouteProviderError } from "../src/routes.js";

const pickup = { latitude: 37.7793, longitude: -122.4193 };
const destination = { latitude: 37.7893, longitude: -122.4193 };

test("requests a driving route with server-only credentials and returns meters", async () => {
  let request;
  const distance = await getDrivingDistanceMeters(pickup, destination, "server-key", async (url, options) => {
    request = { url, options };
    return new Response(JSON.stringify({ routes: [{ distanceMeters: 2345 }] }), { status: 200 });
  });

  assert.equal(distance, 2345);
  assert.equal(request.url, "https://routes.googleapis.com/directions/v2:computeRoutes");
  assert.equal(request.options.headers["X-Goog-Api-Key"], "server-key");
  assert.equal(request.options.headers["X-Goog-FieldMask"], "routes.distanceMeters");
  assert.deepEqual(JSON.parse(request.options.body), {
    origin: { location: { latLng: pickup } },
    destination: { location: { latLng: destination } },
    travelMode: "DRIVE",
    routingPreference: "TRAFFIC_UNAWARE",
  });
});

test("fails closed for route provider errors, empty routes, and invalid distances", async () => {
  await assert.rejects(
    getDrivingDistanceMeters(pickup, destination, "server-key", async () => {
      throw new Error("network failure");
    }),
    RouteProviderError,
  );
  await assert.rejects(
    getDrivingDistanceMeters(pickup, destination, "server-key", async () =>
      new Response("{}", { status: 503 })),
    RouteProviderError,
  );
  await assert.rejects(
    getDrivingDistanceMeters(pickup, destination, "server-key", async () =>
      new Response(JSON.stringify({ routes: [{ distanceMeters: "10" }] }), { status: 200 })),
    RouteProviderError,
  );
});
