"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { FieldValue, getFirestore } = require("firebase-admin/firestore");
const {
  applyMatchingMetricEvent,
  filterCompatibleRides,
  rankRideRecommendations,
} = require("./matching");

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
  const driverCategory = profile.get("vehicleCategory") || "STANDARD";
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
    .limit(100)
    .get();
  const candidates = openRides.docs.map((ride) => {
    try {
      return {
        id: ride.id,
        pickup: parsePoint(ride.get("pickup")?.location),
        vehicleCategory: ride.get("vehicleCategory") || "ANY",
      };
    } catch {
      return null;
    }
  }).filter(Boolean);
  if (candidates.length === 0) return { recommendations: [] };
  const compatibleCandidates = filterCompatibleRides(candidates, driverCategory).slice(0, 20);
  if (compatibleCandidates.length === 0) return { recommendations: [] };

  const response = await fetch("https://routes.googleapis.com/directions/v2:computeRouteMatrix", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": googleMapsApiKey.value(),
      "X-Goog-FieldMask": "originIndex,destinationIndex,duration,distanceMeters,status,condition",
    },
    body: JSON.stringify({
      origins: [{ waypoint: { location: { latLng: origin } } }],
      destinations: compatibleCandidates.map(({ pickup }) => ({ waypoint: { location: { latLng: pickup } } })),
      travelMode: "DRIVE",
      routingPreference: "TRAFFIC_AWARE",
    }),
  });
  if (!response.ok) throw new HttpsError("unavailable", "Ride pickup routes are temporarily unavailable");

  const matrix = await response.json();
  return {
    recommendations: rankRideRecommendations(
      compatibleCandidates,
      Array.isArray(matrix) ? matrix : [],
      profile.get("matchingMetrics") ?? {},
    ),
  };
});

exports.acceptRide = onCall({ secrets: [googleMapsApiKey] }, async (request) => {
  requireAuthentication(request);
  const driverId = request.auth.uid;
  if (request.data?.driverId !== driverId) throw new HttpsError("permission-denied", "Driver identity does not match the signed-in user");
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || rideId.length === 0) throw new HttpsError("invalid-argument", "A ride ID is required");

  const db = getFirestore();
  const profileRef = db.collection("users").doc(driverId);
  const driverRef = db.collection("drivers").doc(driverId);
  const rideRef = db.collection("rides").doc(rideId);
  const [profile, driver, ride] = await Promise.all([profileRef.get(), driverRef.get(), rideRef.get()]);
  assertAvailableDriver(profile, driver);
  if (!ride.exists || ride.get("status") !== "SEARCHING") {
    throw new HttpsError("failed-precondition", "Ride is no longer available");
  }
  if (filterCompatibleRides(
    [{ vehicleCategory: ride.get("vehicleCategory") || "ANY" }],
    profile.get("vehicleCategory") || "STANDARD",
  ).length === 0) {
    throw new HttpsError("failed-precondition", "Ride requires a different vehicle category");
  }

  const pickup = parsePoint(ride.get("pickup")?.location);
  const pickupEtaSeconds = await getTrafficAwareEta(parsePoint(driver.get("location")), pickup);
  await db.runTransaction(async (transaction) => {
    const [currentRide, currentProfile, currentDriver] = await Promise.all([
      transaction.get(rideRef),
      transaction.get(profileRef),
      transaction.get(driverRef),
    ]);
    assertAvailableDriver(currentProfile, currentDriver);
    if (!currentRide.exists || currentRide.get("status") !== "SEARCHING") {
      throw new HttpsError("failed-precondition", "Ride is no longer available");
    }
    if (filterCompatibleRides(
      [{ vehicleCategory: currentRide.get("vehicleCategory") || "ANY" }],
      currentProfile.get("vehicleCategory") || "STANDARD",
    ).length === 0) {
      throw new HttpsError("failed-precondition", "Ride requires a different vehicle category");
    }
    transaction.update(rideRef, {
      driverId,
      driverName: currentProfile.get("displayName") || "",
      status: "ACCEPTED",
      pickupEtaSeconds,
      acceptedAt: FieldValue.serverTimestamp(),
    });
  });
  return { accepted: true, pickupEtaSeconds };
});

exports.cancelRide = onCall(async (request) => {
  requireAuthentication(request);
  const userId = request.auth.uid;
  if (request.data?.userId !== userId) throw new HttpsError("permission-denied", "User identity does not match the signed-in user");
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || rideId.length === 0) throw new HttpsError("invalid-argument", "A ride ID is required");
  const rideRef = getFirestore().collection("rides").doc(rideId);
  await getFirestore().runTransaction(async (transaction) => {
    const ride = await transaction.get(rideRef);
    if (!ride.exists || ![ride.get("riderId"), ride.get("driverId")].includes(userId)) {
      throw new HttpsError("permission-denied", "Only ride participants can cancel this ride");
    }
    if (["COMPLETED", "CANCELLED", "IN_PROGRESS"].includes(ride.get("status"))) {
      throw new HttpsError("failed-precondition", "This ride can no longer be cancelled");
    }
    transaction.update(rideRef, { status: "CANCELLED", cancelledBy: userId });
  });
  return { cancelled: true };
});

exports.trackDriverMatchingMetrics = onDocumentUpdated("rides/{rideId}", async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  const driverId = after?.driverId;
  if (!before || !after || typeof driverId !== "string") return;

  const metricEvents = [];
  if (before.status !== "CANCELLED" && after.status === "CANCELLED" && after.cancelledBy === driverId) {
    metricEvents.push({ type: "cancellation" });
  }
  if (before.status !== "COMPLETED" && after.status === "COMPLETED") {
    metricEvents.push({ type: "completion" });
  }
  if (before.status !== "IN_PROGRESS" && after.status === "IN_PROGRESS" &&
      Number.isFinite(after.pickupEtaSeconds) && after.acceptedAt?.toMillis) {
    const elapsedSeconds = Math.max(0, (Date.now() - after.acceptedAt.toMillis()) / 1000);
    metricEvents.push({
      type: "etaError",
      errorSeconds: Math.abs(elapsedSeconds - after.pickupEtaSeconds),
    });
  }
  if (metricEvents.length === 0) return;

  const db = getFirestore();
  const profileRef = db.collection("users").doc(driverId);
  await Promise.all(metricEvents.map(async (metricEvent) => {
    const eventRef = db.collection("driverMatchingEvents")
      .doc(`${event.params.rideId}_${metricEvent.type}`);
    await db.runTransaction(async (transaction) => {
      const [processed, profile] = await Promise.all([
        transaction.get(eventRef),
        transaction.get(profileRef),
      ]);
      if (processed.exists || !profile.exists || profile.get("role") !== "DRIVER") return;
      const updatedMetrics = applyMatchingMetricEvent(profile.get("matchingMetrics") ?? {}, metricEvent);
      transaction.update(profileRef, { matchingMetrics: updatedMetrics });
      transaction.create(eventRef, {
        rideId: event.params.rideId,
        driverId,
        type: metricEvent.type,
        createdAt: FieldValue.serverTimestamp(),
      });
    });
  }));
});

function assertAvailableDriver(profile, driver) {
  if (!profile.exists || profile.get("role") !== "DRIVER") {
    throw new HttpsError("permission-denied", "Only drivers can accept rides");
  }
  if (!driver.exists || driver.get("available") !== true) {
    throw new HttpsError("failed-precondition", "Go online to accept rides");
  }
  const updatedAt = driver.get("updatedAt");
  if (!updatedAt || Date.now() - updatedAt.toMillis() > 120_000) {
    throw new HttpsError("failed-precondition", "Update your location before accepting a ride");
  }
}

async function getTrafficAwareEta(origin, destination) {
  const response = await fetch("https://routes.googleapis.com/directions/v2:computeRouteMatrix", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": googleMapsApiKey.value(),
      "X-Goog-FieldMask": "destinationIndex,duration,status,condition",
    },
    body: JSON.stringify({
      origins: [{ waypoint: { location: { latLng: origin } } }],
      destinations: [{ waypoint: { location: { latLng: destination } } }],
      travelMode: "DRIVE",
      routingPreference: "TRAFFIC_AWARE",
    }),
  });
  if (!response.ok) throw new HttpsError("unavailable", "A pickup route could not be calculated");
  const route = (await response.json())[0];
  const eta = Number.parseInt(route?.duration, 10);
  if (route?.condition !== "ROUTE_EXISTS" || route.status?.code > 0 || !Number.isFinite(eta) || eta < 0) {
    throw new HttpsError("not-found", "No driving route to this pickup was found");
  }
  return eta;
}

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
