"use strict";

class RouteLookupError extends Error {
  constructor(message) {
    super(message);
    this.name = "RouteLookupError";
  }
}

async function getDrivingRoute(pickup, dropOff, apiKey, fetchImpl = fetch) {
  if (!apiKey) throw new RouteLookupError("Driving routes are not configured.");

  let response;
  try {
    response = await fetchImpl(
      "https://routes.googleapis.com/directions/v2:computeRoutes",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": apiKey,
          "X-Goog-FieldMask": "routes.distanceMeters,routes.duration",
        },
        body: JSON.stringify({
          origin: {
            location: {
              latLng: { latitude: pickup.latitude, longitude: pickup.longitude },
            },
          },
          destination: {
            location: {
              latLng: { latitude: dropOff.latitude, longitude: dropOff.longitude },
            },
          },
          travelMode: "DRIVE",
          routingPreference: "TRAFFIC_UNAWARE",
          computeAlternativeRoutes: false,
        }),
        signal: AbortSignal.timeout(8_000),
      }
    );
  } catch {
    throw new RouteLookupError("Driving route lookup failed.");
  }

  if (!response.ok) throw new RouteLookupError("Driving route lookup failed.");

  let result;
  try {
    result = await response.json();
  } catch {
    throw new RouteLookupError("Driving route response was invalid.");
  }

  const route = result.routes?.[0];
  const durationSeconds = typeof route?.duration === "string"
    ? Number(route.duration.replace(/s$/, ""))
    : Number.NaN;
  if (!Number.isSafeInteger(route?.distanceMeters) ||
      route.distanceMeters <= 0 ||
      !Number.isFinite(durationSeconds) ||
      durationSeconds <= 0) {
    throw new RouteLookupError("No driving route is available.");
  }

  return {
    distanceMeters: route.distanceMeters,
    durationSeconds: Math.ceil(durationSeconds),
  };
}

module.exports = { RouteLookupError, getDrivingRoute };
