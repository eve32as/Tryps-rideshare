"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { FieldValue, Timestamp, getFirestore } = require("firebase-admin/firestore");
const {
  applyMatchingMetricEvent,
  filterCompatibleRides,
  isValidDriverCategory,
  rankRideRecommendations,
} = require("./matching");
const { calculateSurgeMultiplier, distanceMeters } = require("./pricing");
const { allocateEqualShares, isRidePassUsable, validatePaymentRequest } = require("./payments");

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
  const db = getFirestore();
  const userId = request.auth.uid;
  const profile = await db.collection("users").doc(userId).get();
  if (profile.get("role") !== "RIDER") throw new HttpsError("permission-denied", "Only riders can request fare quotes");
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
  if (!Number.isSafeInteger(durationSeconds) || durationSeconds < 0 ||
      !Number.isSafeInteger(distanceMeters) || distanceMeters < 0) {
    throw new HttpsError("unavailable", "The route provider returned invalid trip details");
  }
  const baseAmountCents = Math.max(
    rateCard.minimumCents,
    rateCard.baseCents +
      Math.ceil(distanceMeters / 1000 * rateCard.perKilometerCents) +
      Math.ceil(durationSeconds / 60 * rateCard.perMinuteCents),
  );
  const nearbyCounts = await getNearbyRideCounts(db, pickup);
  const surgeMultiplier = calculateSurgeMultiplier(nearbyCounts.demandCount, nearbyCounts.availableDriverCount);
  const amountCents = Math.ceil(baseAmountCents * surgeMultiplier);
  const quoteRef = db.collection("users").doc(userId).collection("rideQuotes").doc();
  await quoteRef.set({
    userId,
    pickup,
    destination,
    amountCents,
    baseAmountCents,
    surgeMultiplier,
    demandCount: nearbyCounts.demandCount,
    availableDriverCount: nearbyCounts.availableDriverCount,
    currency: "USD",
    distanceMeters,
    durationSeconds,
    rateVersion: rateCard.version,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt: Timestamp.fromMillis(Date.now() + 5 * 60 * 1000),
  });
  return {
    quoteId: quoteRef.id,
    amountCents,
    baseAmountCents,
    surgeMultiplier,
    demandCount: nearbyCounts.demandCount,
    availableDriverCount: nearbyCounts.availableDriverCount,
    currency: "USD",
    distanceMeters,
    durationSeconds,
    rateVersion: rateCard.version,
  };
});

exports.requestRide = onCall(async (request) => {
  requireAuthentication(request);
  const userId = request.auth.uid;
  const quoteId = request.data?.quoteId;
  const vehicleCategory = request.data?.vehicleCategory;
  let paymentRequest;
  try {
    paymentRequest = validatePaymentRequest(
      request.data?.paymentMethod ?? "SIMULATED_CARD",
      request.data?.splitParticipantEmails ?? [],
      request.data?.ridePassId ?? null,
    );
  } catch (error) {
    throw new HttpsError("invalid-argument", error.message);
  }
  if (typeof quoteId !== "string" || !quoteId || !isValidRequestedCategory(vehicleCategory)) {
    throw new HttpsError("invalid-argument", "A valid fare quote and vehicle category are required");
  }
  const db = getFirestore();
  const profileRef = db.collection("users").doc(userId);
  const quoteRef = profileRef.collection("rideQuotes").doc(quoteId);
  const passRef = paymentRequest.passId
    ? profileRef.collection("ridePasses").doc(paymentRequest.passId)
    : null;
  const splitParticipants = await Promise.all(paymentRequest.participantEmails.map(async (email) => {
    const matches = await db.collection("users").where("emailLower", "==", email).limit(2).get();
    const matchingProfile = matches.docs.find((document) =>
      document.id !== userId && document.get("role") === "RIDER" &&
      String(document.get("email") ?? "").trim().toLowerCase() === email);
    if (!matchingProfile) throw new HttpsError("not-found", `No rider account found for ${email}`);
    return { ref: matchingProfile.ref, email };
  }));
  const splitPayerRefs = splitParticipants.map(({ ref }) => ref);
  const rideRef = db.collection("rides").doc();
  await db.runTransaction(async (transaction) => {
    const reads = [
      transaction.get(profileRef),
      transaction.get(quoteRef),
      ...splitPayerRefs.map((ref) => transaction.get(ref)),
    ];
    if (passRef) reads.push(transaction.get(passRef));
    const snapshots = await Promise.all(reads);
    const [profile, quote] = snapshots;
    if (!profile.exists || profile.get("role") !== "RIDER") {
      throw new HttpsError("permission-denied", "Only riders can request rides");
    }
    if (!quote.exists || quote.get("userId") !== userId || quote.get("usedAt")) {
      throw new HttpsError("failed-precondition", "Fare quote is invalid or has already been used");
    }
    const expiresAt = quote.get("expiresAt");
    if (!expiresAt || expiresAt.toMillis() <= Date.now()) {
      throw new HttpsError("failed-precondition", "Fare quote has expired; request a new quote");
    }
    const resolvedPayers = splitParticipants.map(({ email }, index) => {
      const payer = snapshots[index + 2];
      if (!payer.exists || payer.get("role") !== "RIDER" ||
          String(payer.get("email") ?? "").trim().toLowerCase() !== email) {
        throw new HttpsError("failed-precondition", "A split participant account changed; review the split");
      }
      return { id: payer.id, name: payer.get("displayName") || "" };
    });
    const fareCents = quote.get("amountCents");
    let payment;
    if (paymentRequest.method === "RIDE_PASS") {
      const pass = snapshots[snapshots.length - 1];
      const expiresAtMillis = pass.get("expiresAt")?.toMillis?.();
      if (!pass.exists || pass.get("ownerId") !== userId ||
          !isRidePassUsable({ remainingRides: pass.get("remainingRides"), expiresAtMillis }, Date.now())) {
        throw new HttpsError("failed-precondition", "This ride pass is expired or has no rides remaining");
      }
      const remainingRides = pass.get("remainingRides") - 1;
      transaction.update(passRef, {
        remainingRides,
        status: remainingRides === 0 ? "EXHAUSTED" : "ACTIVE",
        lastUsedAt: FieldValue.serverTimestamp(),
      });
      payment = {
        method: "RIDE_PASS",
        status: "COVERED_BY_PASS",
        amountCents: 0,
        coveredFareCents: fareCents,
        passId: paymentRequest.passId,
        splits: [],
      };
    } else if (paymentRequest.method === "CASH") {
      const payers = [{ id: userId, name: profile.get("displayName") || "" }, ...resolvedPayers];
      const allocatedShares = allocateEqualShares(fareCents, payers.map(({ id }) => id));
      payment = {
        method: "CASH",
        status: "PENDING",
        amountCents: fareCents,
        payerIds: payers.map(({ id }) => id),
        splits: allocatedShares.map((share, index) => ({
          ...share,
          payerName: payers[index].name,
          status: "PENDING",
        })),
      };
    } else {
      payment = {
        method: "SIMULATED_CARD",
        status: "SIMULATED",
        amountCents: fareCents,
        splits: [],
      };
    }
    transaction.create(rideRef, {
      riderId: userId,
      riderName: profile.get("displayName") || "",
      pickup: quote.get("pickup"),
      destination: quote.get("destination"),
      quote: {
        amountCents: quote.get("amountCents"),
        baseAmountCents: quote.get("baseAmountCents"),
        surgeMultiplier: quote.get("surgeMultiplier"),
        demandCount: quote.get("demandCount"),
        availableDriverCount: quote.get("availableDriverCount"),
        currency: quote.get("currency"),
        distanceMeters: quote.get("distanceMeters"),
        durationSeconds: quote.get("durationSeconds"),
      },
      vehicleCategory,
      payment,
      status: "SEARCHING",
      createdAt: FieldValue.serverTimestamp(),
      createdAtEpochMillis: Date.now(),
    });
    transaction.update(quoteRef, { usedAt: FieldValue.serverTimestamp() });
  });
  return { rideId: rideRef.id };
});

exports.confirmCashPayment = onCall(async (request) => {
  requireAuthentication(request);
  const driverId = request.auth.uid;
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || !rideId) throw new HttpsError("invalid-argument", "A ride ID is required");
  const rideRef = getFirestore().collection("rides").doc(rideId);
  await getFirestore().runTransaction(async (transaction) => {
    const ride = await transaction.get(rideRef);
    if (!ride.exists || ride.get("driverId") !== driverId) {
      throw new HttpsError("permission-denied", "Only the assigned driver can confirm cash");
    }
    const payment = ride.get("payment");
    if (ride.get("status") !== "COMPLETED" || payment?.method !== "CASH" || payment.status !== "PENDING") {
      throw new HttpsError("failed-precondition", "Cash can only be confirmed once after the ride is complete");
    }
    transaction.update(rideRef, {
      "payment.status": "RECEIVED",
      "payment.confirmedBy": driverId,
      "payment.confirmedAt": FieldValue.serverTimestamp(),
      "payment.splits": (payment.splits ?? []).map((share) => ({ ...share, status: "RECEIVED" })),
    });
  });
  return { received: true };
});

exports.issueRidePass = onCall(async (request) => {
  requireAuthentication(request);
  if (request.auth.token.admin !== true) {
    throw new HttpsError("permission-denied", "Only an administrator can issue ride passes");
  }
  const ownerId = request.data?.ownerId;
  const rideCount = request.data?.rideCount;
  const validDays = request.data?.validDays;
  if (typeof ownerId !== "string" || !ownerId ||
      !Number.isSafeInteger(rideCount) || rideCount < 1 || rideCount > 50 ||
      !Number.isSafeInteger(validDays) || validDays < 1 || validDays > 365) {
    throw new HttpsError("invalid-argument", "A rider, 1–50 rides, and 1–365 validity days are required");
  }
  const db = getFirestore();
  const ownerRef = db.collection("users").doc(ownerId);
  const passRef = ownerRef.collection("ridePasses").doc();
  const expiresAt = Timestamp.fromMillis(Date.now() + validDays * 24 * 60 * 60 * 1000);
  await db.runTransaction(async (transaction) => {
    const owner = await transaction.get(ownerRef);
    if (!owner.exists || owner.get("role") !== "RIDER") {
      throw new HttpsError("not-found", "Ride passes can only be issued to rider accounts");
    }
    transaction.create(passRef, {
      ownerId,
      remainingRides: rideCount,
      totalRides: rideCount,
      status: "ACTIVE",
      expiresAt,
      createdAt: FieldValue.serverTimestamp(),
      issuedBy: request.auth.uid,
    });
  });
  return { passId: passRef.id };
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
  assertAvailableDriver(profile, driver);
  const driverCategory = profile.get("vehicleCategory") || "STANDARD";

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
        vehicleCategory: ride.get("vehicleCategory") ?? "ANY",
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
    const eventTimeMillis = Date.parse(event.time);
    const elapsedSeconds = Math.max(
      0,
      ((Number.isFinite(eventTimeMillis) ? eventTimeMillis : Date.now()) - after.acceptedAt.toMillis()) / 1000,
    );
    metricEvents.push({
      type: "etaError",
      errorSeconds: Math.abs(elapsedSeconds - after.pickupEtaSeconds),
      actualPickupElapsedSeconds: elapsedSeconds,
      predictedPickupEtaSeconds: after.pickupEtaSeconds,
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
        ...(metricEvent.type === "etaError" ? {
          actualPickupElapsedSeconds: metricEvent.actualPickupElapsedSeconds,
          predictedPickupEtaSeconds: metricEvent.predictedPickupEtaSeconds,
          errorSeconds: metricEvent.errorSeconds,
        } : {}),
        createdAt: FieldValue.serverTimestamp(),
      });
    });
  }));
});

function assertAvailableDriver(profile, driver) {
  if (!profile.exists || profile.get("role") !== "DRIVER") {
    throw new HttpsError("permission-denied", "Only drivers can accept rides");
  }
  if (!isValidDriverCategory(profile.get("vehicleCategory") || "STANDARD")) {
    throw new HttpsError("failed-precondition", "Set a supported driver vehicle category");
  }
  if (!driver.exists || driver.get("available") !== true) {
    throw new HttpsError("failed-precondition", "Go online to accept rides");
  }
  const updatedAt = driver.get("updatedAt");
  if (!updatedAt || Date.now() - updatedAt.toMillis() > 120_000) {
    throw new HttpsError("failed-precondition", "Update your location before accepting a ride");
  }
}

async function getNearbyRideCounts(db, pickup) {
  const [rideSnapshot, driverSnapshot] = await Promise.all([
    db.collection("rides").where("status", "==", "SEARCHING").limit(200).get(),
    db.collection("drivers").where("available", "==", true).limit(200).get(),
  ]);
  const now = Date.now();
  const isNearby = (location) => {
    try {
      return distanceMeters(pickup, parsePoint(location)) <= 5_000;
    } catch {
      return false;
    }
  };
  const demandCount = rideSnapshot.docs.filter((ride) => isNearby(ride.get("pickup")?.location)).length;
  const availableDriverCount = driverSnapshot.docs.filter((driver) => {
    const updatedAt = driver.get("updatedAt");
    if (!updatedAt) return false;
    const ageMillis = now - updatedAt.toMillis();
    return ageMillis >= 0 && ageMillis <= 120_000 && isNearby(driver.get("location"));
  }).length;
  return { demandCount, availableDriverCount };
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
  const matrix = await response.json();
  const route = Array.isArray(matrix) ? matrix[0] : null;
  const eta = Number.parseInt(route?.duration, 10);
  if (route?.condition !== "ROUTE_EXISTS" || route.status?.code > 0 || !Number.isFinite(eta) || eta < 0) {
    throw new HttpsError("not-found", "No driving route to this pickup was found");
  }
  return eta;
}

function isValidRequestedCategory(category) {
  return category === "ANY" || isValidDriverCategory(category);
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
