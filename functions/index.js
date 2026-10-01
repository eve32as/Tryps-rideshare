"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { rankRideRecommendations } = require("./matching");

initializeApp();
const googleMapsApiKey = defineSecret("GOOGLE_MAPS_API_KEY");
const rateCard = Object.freeze({
  version: 1,
  baseCents: 350,
  perKilometerCents: 180,
  perMinuteCents: 35,
  minimumCents: 650,
});

exports.getRideQuote = onCall({ secrets: [googleMapsApiKey] }, async (request) => {
  requireAuthentication(request);
  const pickup = parsePoint(request.data?.pickup);
  const destination = parsePoint(request.data?.destination);
  const response = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": googleMapsApiKey.value(),
      "X-Goog-FieldMask": "routes.distanceMeters,routes.duration",
    },
    body: JSON.stringify({
      origin: { location: { latLng: pickup } },
      destination: { location: { latLng: destination } },
      travelMode: "DRIVE",
      routingPreference: "TRAFFIC_AWARE",
    }),
  });
  if (!response.ok) throw new HttpsError("unavailable", "A route could not be calculated");
  const route = (await response.json()).routes?.[0];
  if (!route) throw new HttpsError("not-found", "No driving route was found");
  const durationSeconds = Number.parseInt(route.duration, 10);
  const distanceMeters = route.distanceMeters;
  const amountCents = Math.max(
    rateCard.minimumCents,
    rateCard.baseCents +
      Math.ceil(distanceMeters / 1000 * rateCard.perKilometerCents) +
      Math.ceil(durationSeconds / 60 * rateCard.perMinuteCents),
  );
  return { amountCents, currency: "USD", distanceMeters, durationSeconds, rateVersion: rateCard.version };
});

exports.searchPlaces = onCall({ secrets: [googleMapsApiKey] }, async (request) => {
  requireAuthentication(request);
  const query = request.data?.query?.trim();
  if (typeof query !== "string" || query.length < 2 || query.length > 120) {
    throw new HttpsError("invalid-argument", "Search text must contain 2 to 120 characters");
  }
  const near = request.data?.near ? parsePoint(request.data.near) : null;
  const body = { textQuery: query, maxResultCount: 5 };
  if (near) {
    body.locationBias = {
      circle: { center: near, radius: 50000 },
    };
  }
  const response = await fetch("https://places.googleapis.com/v1/places:searchText", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": googleMapsApiKey.value(),
      "X-Goog-FieldMask": "places.displayName,places.formattedAddress,places.location",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new HttpsError("unavailable", "Places search is temporarily unavailable");
  const places = (await response.json()).places ?? [];
  return {
    places: places.map((place) => ({
      name: place.displayName?.text ?? place.formattedAddress,
      address: place.formattedAddress ?? "",
      location: {
        latitude: place.location.latitude,
        longitude: place.location.longitude,
      },
    })),
  };
});

exports.getRideRecommendations = onCall({ secrets: [googleMapsApiKey] }, async (request) => {
  requireAuthentication(request);
  const driverId = request.auth.uid;
  if (request.data?.driverId !== driverId) throw new HttpsError("permission-denied", "Driver identity does not match the signed-in user");
  const db = getFirestore();
  const [profile, driver] = await Promise.all([
    db.collection("users").doc(driverId).get(),
    db.collection("drivers").doc(driverId).get(),
  ]);
  if (profile.get("role") !== "DRIVER") throw new HttpsError("permission-denied", "Only drivers can request ride recommendations");
  if (!driver.exists || driver.get("available") !== true) {
    throw new HttpsError("failed-precondition", "Go online to receive ride recommendations");
  }
  const locationUpdatedAt = driver.get("updatedAt");
  if (!locationUpdatedAt || Date.now() - locationUpdatedAt.toMillis() > 120_000) {
    throw new HttpsError("failed-precondition", "Update your location to receive ride recommendations");
  }

  const origin = parsePoint(driver.get("location"));
  const openRides = await db.collection("rides")
    .where("status", "==", "SEARCHING")
    .limit(20)
    .get();
  const candidates = openRides.docs.map((ride) => {
    try {
      return { id: ride.id, pickup: parsePoint(ride.get("pickup")?.location) };
    } catch {
      return null;
    }
  }).filter(Boolean);
  if (candidates.length === 0) return { recommendations: [] };

  const response = await fetch("https://routes.googleapis.com/directions/v2:computeRouteMatrix", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": googleMapsApiKey.value(),
      "X-Goog-FieldMask": "originIndex,destinationIndex,duration,distanceMeters,status,condition",
    },
    body: JSON.stringify({
      origins: [{ waypoint: { location: { latLng: origin } } }],
      destinations: candidates.map(({ pickup }) => ({ waypoint: { location: { latLng: pickup } } })),
      travelMode: "DRIVE",
      routingPreference: "TRAFFIC_AWARE",
    }),
  });
  if (!response.ok) throw new HttpsError("unavailable", "Ride pickup routes are temporarily unavailable");

  const matrix = await response.json();
  return {
    recommendations: rankRideRecommendations(candidates, Array.isArray(matrix) ? matrix : []),
  };
});

function requireAuthentication(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in to continue");
}

function parsePoint(value) {
  const latitude = value?.latitude;
  const longitude = value?.longitude;
  if (typeof latitude !== "number" || !Number.isFinite(latitude) || latitude < -90 || latitude > 90 ||
      typeof longitude !== "number" || !Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
    throw new HttpsError("invalid-argument", "A valid latitude and longitude are required");
  }
  return { latitude, longitude };
}
