"use strict";

const { randomUUID } = require("node:crypto");
const { initializeApp } = require("firebase-admin/app");
const { FieldValue, Timestamp, getFirestore } = require("firebase-admin/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { geohashForLocation, geohashQueryBounds } = require("geofire-common");
const { defineSecret, defineString } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const Stripe = require("stripe");

const {
  RIDE_TYPES,
  aggregateDemandHeatmap,
  calculateQuote,
  calculateDemandSurgeMultiplier,
  canTransitionRide,
  filterNearbyDemandZones,
  isFreshDriverLocation,
  isWithinServiceArea,
  matchesRidePreferences,
  normalizeDriverRidePreferences,
  normalizeRidePreferences,
  rankNearbyDrivers,
  riderVisibleDriverProfile,
  validCoordinate,
} = require("./domain");
const { RouteLookupError, getDrivingRoute } = require("./routes");

initializeApp();
const db = getFirestore();
const REGION = "us-central1";
const DRIVER_MATCH_RADIUS_KM = 15;
const SURGE_SUPPLY_RADIUS_KM = 5;
const ACTIVE_RIDE_STATUSES = ["driver_assigned", "en_route", "arrived", "in_progress"];
const GOOGLE_ROUTES_API_KEY = defineSecret("GOOGLE_ROUTES_API_KEY");
const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");
const STRIPE_PUBLISHABLE_KEY = defineString("STRIPE_PUBLISHABLE_KEY", { default: "" });

function authenticatedUser(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in to continue.");
  return request.auth.uid;
}

function getStripe() {
  const key = STRIPE_SECRET_KEY.value();
  if (!key) throw new HttpsError("failed-precondition", "Payments are not configured.");
  return new Stripe(key);
}

function requireDriver(request) {
  const uid = authenticatedUser(request);
  if (request.auth.token.driver !== true) {
    throw new HttpsError("permission-denied", "An approved driver account is required.");
  }
  return uid;
}

function requireAdmin(request) {
  const uid = authenticatedUser(request);
  if (request.auth.token.admin !== true) {
    throw new HttpsError("permission-denied", "Administrator access is required.");
  }
  return uid;
}

async function getLocalDemandAndSupply(pickup, preferences = {}) {
  const demandZone = geohashForLocation([pickup.latitude, pickup.longitude]).slice(0, 5);
  const demandQuery = db.collection("rides")
    .where("demandZone", "==", demandZone)
    .where("status", "in", ["searching_driver", "dispatching", "offered"])
    .get();
  const bounds = geohashQueryBounds(
    [pickup.latitude, pickup.longitude],
    SURGE_SUPPLY_RADIUS_KM * 1000
  );
  const supplyQueries = bounds.map(([start, end]) => db.collection("drivers")
    .where("available", "==", true)
    .orderBy("geohash")
    .startAt(start)
    .endAt(end)
    .get());
  const [demandSnapshot, ...supplySnapshots] = await Promise.all([demandQuery, ...supplyQueries]);
  const driversById = new Map();
  for (const snapshot of supplySnapshots) {
    for (const document of snapshot.docs) driversById.set(document.id, document);
  }
  const now = Date.now();
  const supplyCount = rankNearbyDrivers(
    [...driversById.values()].map((document) => {
      const data = document.data();
      return {
        uid: document.id,
        available: data.available,
        verified: data.verified,
        acceptsWomenAndMinorsRides: data.acceptsWomenAndMinorsRides,
        ecoFriendlyVehicle: data.ecoFriendlyVehicle,
        location: data.location,
        locationUpdatedAtMillis: data.locationUpdatedAt?.toMillis(),
      };
    }),
    pickup,
    SURGE_SUPPLY_RADIUS_KM,
    now,
    preferences,
    Number.MAX_SAFE_INTEGER
  ).length;
  return { demandZone, demandCount: demandSnapshot.size, supplyCount };
}

async function createDriverOffers(rideId, ride) {
  const bounds = geohashQueryBounds(
    [ride.pickup.latitude, ride.pickup.longitude],
    DRIVER_MATCH_RADIUS_KM * 1000
  );
  const driverSnapshots = await Promise.all(bounds.map(([start, end]) =>
    db.collection("drivers")
      .where("available", "==", true)
      .orderBy("geohash")
      .startAt(start)
      .endAt(end)
      .get()
  ));
  const driverDocuments = new Map();
  for (const snapshot of driverSnapshots) {
    for (const document of snapshot.docs) driverDocuments.set(document.id, document);
  }
  const now = Date.now();
  const rideRef = db.collection("rides").doc(rideId);
  const currentRide = await rideRef.get();
  if (!currentRide.exists || currentRide.data().status !== "dispatching") return;
  const previouslyOffered = new Set(currentRide.data().driverOfferAttemptedUids ?? []);
  const currentDrivers = [...driverDocuments.values()].map((document) => {
    const data = document.data();
    return {
      uid: document.id,
      ref: document.ref,
      available: data.available,
      verified: data.verified,
      acceptsWomenAndMinorsRides: data.acceptsWomenAndMinorsRides,
      ecoFriendlyVehicle: data.ecoFriendlyVehicle,
      location: data.location,
      locationUpdatedAtMillis: data.locationUpdatedAt?.toMillis(),
    };
  }).filter((driver) => !previouslyOffered.has(driver.uid));
  const candidates = rankNearbyDrivers(
    currentDrivers,
    ride.pickup,
    DRIVER_MATCH_RADIUS_KM,
    now,
    ride.preferences
  ).filter((candidate) => !previouslyOffered.has(candidate.uid));

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(rideRef);
    if (!snapshot.exists || snapshot.data().status !== "dispatching" ||
        snapshot.data().paymentStatus !== "succeeded") return;

    const latestDrivers = await Promise.all(
      candidates.map((candidate) => transaction.get(candidate.ref))
    );
    const latestAttemptedDrivers = new Set(snapshot.data().driverOfferAttemptedUids ?? []);
    const eligibleCandidates = rankNearbyDrivers(
      latestDrivers.map((document) => {
        const data = document.data() ?? {};
        return {
          uid: document.id,
          ref: document.ref,
          available: document.exists && data.available,
          verified: document.exists && data.verified,
          acceptsWomenAndMinorsRides: data.acceptsWomenAndMinorsRides,
          ecoFriendlyVehicle: data.ecoFriendlyVehicle,
          location: data.location,
          locationUpdatedAtMillis: data.locationUpdatedAt?.toMillis(),
        };
      }).filter((driver) => !latestAttemptedDrivers.has(driver.uid)),
      ride.pickup,
      DRIVER_MATCH_RADIUS_KM,
      Date.now(),
      snapshot.data().preferences
    );

    if (eligibleCandidates.length === 0) {
      const preferences = snapshot.data().preferences ?? {};
      transaction.update(rideRef, {
        status: "searching_driver",
        driverOfferAttemptedUids: [],
        dispatchMessage: preferences.womanDriverForWomenAndMinors || preferences.ecoFriendlyVehicle
          ? "No nearby drivers currently meet your selected preferences. We’ll keep looking."
          : "No nearby drivers are available yet.",
        updatedAt: FieldValue.serverTimestamp(),
      });
      return;
    }

    const expiresAt = Timestamp.fromMillis(Date.now() + 60_000);
    for (const candidate of eligibleCandidates) {
      transaction.set(candidate.ref.collection("offers").doc(rideId), {
        rideId,
        status: "pending",
        pickup: ride.pickup,
        dropOff: ride.dropOff,
        rideType: ride.rideType,
        preferences: ride.preferences ?? {},
        expiresAt,
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.update(rideRef, {
      status: "offered",
      offerCount: eligibleCandidates.length,
      offeredDriverUids: eligibleCandidates.map((candidate) => candidate.uid),
      driverOfferAttemptedUids: FieldValue.arrayUnion(
        ...eligibleCandidates.map((candidate) => candidate.uid)
      ),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

exports.createRideQuote = onCall({
  region: REGION,
  secrets: [GOOGLE_ROUTES_API_KEY],
}, async (request) => {
  const uid = authenticatedUser(request);
  const pickup = request.data?.pickup;
  const dropOff = request.data?.dropOff;
  const rideTypes = request.data?.rideTypes;
  if (!validCoordinate(pickup) || !validCoordinate(dropOff)) {
    throw new HttpsError("invalid-argument", "Choose valid pickup and drop-off locations.");
  }
  if (!isWithinServiceArea(pickup) || !isWithinServiceArea(dropOff)) {
    throw new HttpsError(
      "out-of-range",
      "Pickup and drop-off must be within the San Francisco service area."
    );
  }
  if (!Array.isArray(rideTypes) || rideTypes.length === 0 || rideTypes.length > 3 ||
      new Set(rideTypes).size !== rideTypes.length ||
      rideTypes.some((rideType) => typeof rideType !== "string" ||
        !Object.hasOwn(RIDE_TYPES, rideType))) {
    throw new HttpsError("invalid-argument", "Choose valid ride options.");
  }

  let route;
  try {
    route = await getDrivingRoute(
      pickup,
      dropOff,
      GOOGLE_ROUTES_API_KEY.value()
    );
  } catch (error) {
    logger.warn("Driving route lookup failed", { error: error.message });
    throw new HttpsError(
      "unavailable",
      "A driving route is unavailable right now. Check the locations and try again."
    );
  }

  let market;
  try {
    market = await getLocalDemandAndSupply(pickup);
  } catch (error) {
    logger.warn("Local demand and supply lookup failed", { error: error.message });
    throw new HttpsError(
      "unavailable",
      "Current ride prices are unavailable. Please try again."
    );
  }
  const surgeMultiplier = calculateDemandSurgeMultiplier(
    market.demandCount,
    market.supplyCount
  );
  const quotes = rideTypes.map((rideType) => {
    let fare;
    try {
      fare = calculateQuote(pickup, dropOff, rideType, route.distanceMeters, surgeMultiplier);
    } catch (error) {
      throw new HttpsError("invalid-argument", error.message);
    }
    return {
      quoteId: randomUUID(),
      demandZone: market.demandZone,
      demandCount: market.demandCount,
      supplyCount: market.supplyCount,
      ...fare,
      estimatedDurationSeconds: route.durationSeconds,
    };
  });
  const batch = db.batch();
  const expiresAt = Timestamp.fromMillis(Date.now() + 5 * 60_000);
  for (const quote of quotes) {
    batch.set(db.collection("rideQuotes").doc(quote.quoteId), {
      uid,
      pickup,
      dropOff,
      ...quote,
      status: "available",
      createdAt: FieldValue.serverTimestamp(),
      expiresAt,
    });
  }
  await batch.commit();
  return {
    quotes: quotes.map((quote) => ({ ...quote, expiresAt: expiresAt.toMillis() })),
  };
});

exports.createRideBooking = onCall({ region: REGION }, async (request) => {
  const uid = authenticatedUser(request);
  const quoteId = request.data?.quoteId;
  const preferences = request.data?.preferences;
  if (typeof quoteId !== "string" || quoteId.length > 100) {
    throw new HttpsError("invalid-argument", "A valid quote is required.");
  }
  let normalizedPreferences;
  try {
    normalizedPreferences = normalizeRidePreferences(preferences);
  } catch {
    throw new HttpsError("invalid-argument", "Choose valid ride preferences.");
  }

  const quoteRef = db.collection("rideQuotes").doc(quoteId);
  const rideRef = db.collection("rides").doc();
  await db.runTransaction(async (transaction) => {
    const quoteSnapshot = await transaction.get(quoteRef);
    if (!quoteSnapshot.exists) throw new HttpsError("not-found", "The ride quote expired.");
    const quote = quoteSnapshot.data();
    if (quote.uid !== uid || quote.status !== "available") {
      throw new HttpsError("permission-denied", "This quote cannot be used.");
    }
    if (!isWithinServiceArea(quote.pickup) || !isWithinServiceArea(quote.dropOff)) {
      throw new HttpsError("failed-precondition", "This quote is outside the current service area.");
    }
    if (quote.expiresAt.toMillis() <= Date.now()) {
      throw new HttpsError("deadline-exceeded", "The ride quote expired. Request a new quote.");
    }
    if (quote.pricingVersion !== 3 ||
        !Number.isSafeInteger(quote.routeDistanceMeters) ||
        !Number.isSafeInteger(quote.estimatedDurationSeconds) ||
        typeof quote.demandZone !== "string" ||
        ![1, 1.25, 1.5].includes(quote.surgeMultiplier) ||
        !Number.isSafeInteger(quote.surgeAdjustmentCents)) {
      throw new HttpsError("failed-precondition", "This quote uses outdated pricing. Request a new quote.");
    }

    transaction.create(rideRef, {
      riderUid: uid,
      driverUid: null,
      quoteId,
      demandZone: quote.demandZone,
      pickup: quote.pickup,
      dropOff: quote.dropOff,
      rideType: quote.rideType,
      preferences: normalizedPreferences,
      rideLabel: quote.rideLabel,
      pricingVersion: quote.pricingVersion,
      distanceKm: quote.distanceKm,
      routeDistanceMeters: quote.routeDistanceMeters,
      estimatedDurationSeconds: quote.estimatedDurationSeconds,
      baseFareCents: quote.baseFareCents,
      distanceFareCents: quote.distanceFareCents,
      surgeMultiplier: quote.surgeMultiplier,
      surgeAdjustmentCents: quote.surgeAdjustmentCents,
      bookingFeeCents: quote.bookingFeeCents,
      minimumFareAdjustmentCents: quote.minimumFareAdjustmentCents,
      amountCents: quote.amountCents,
      currency: quote.currency,
      status: "awaiting_payment",
      paymentStatus: "unpaid",
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.update(quoteRef, { status: "consumed", rideId: rideRef.id });
  });
  return { rideId: rideRef.id };
});

exports.createRidePaymentIntent = onCall({
  region: REGION,
  secrets: [STRIPE_SECRET_KEY],
}, async (request) => {
  const uid = authenticatedUser(request);
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || rideId.length > 100) {
    throw new HttpsError("invalid-argument", "A valid booking is required.");
  }

  const rideRef = db.collection("rides").doc(rideId);
  const snapshot = await rideRef.get();
  if (!snapshot.exists || snapshot.data().riderUid !== uid) {
    throw new HttpsError("not-found", "Booking not found.");
  }
  const ride = snapshot.data();
  if (ride.status !== "awaiting_payment" || !["unpaid", "failed"].includes(ride.paymentStatus)) {
    throw new HttpsError("failed-precondition", "This booking is not awaiting payment.");
  }
  if (!Number.isSafeInteger(ride.amountCents) || ride.amountCents < 100) {
    throw new HttpsError("failed-precondition", "The booking amount is invalid.");
  }

  const publishableKey = STRIPE_PUBLISHABLE_KEY.value();
  if (!publishableKey) {
    throw new HttpsError("failed-precondition", "Payments are not fully configured.");
  }
  const stripe = getStripe();
  let intent;
  try {
    intent = ride.paymentIntentId
      ? await stripe.paymentIntents.retrieve(ride.paymentIntentId)
      : await stripe.paymentIntents.create({
        amount: ride.amountCents,
        currency: ride.currency,
        automatic_payment_methods: { enabled: true },
        metadata: { rideId, riderUid: uid },
      }, { idempotencyKey: `ride-payment-${rideId}` });
  } catch (error) {
    logger.error("Stripe PaymentIntent creation failed", { rideId, error: error.message });
    throw new HttpsError("internal", "Could not start payment. Please try again.");
  }
  if (intent.metadata?.rideId !== rideId ||
      intent.amount !== ride.amountCents ||
      intent.currency !== ride.currency) {
    throw new HttpsError("failed-precondition", "The payment does not match this booking.");
  }
  if (!["requires_payment_method", "requires_action", "requires_confirmation"].includes(intent.status)) {
    throw new HttpsError(
      "failed-precondition",
      intent.status === "succeeded"
        ? "Payment is already processing. Wait for your ride status to update."
        : "This payment can no longer be retried. Cancel the booking and request a new ride."
    );
  }

  if (!ride.paymentIntentId) {
    await db.runTransaction(async (transaction) => {
      const current = await transaction.get(rideRef);
      if (!current.exists || current.data().riderUid !== uid) {
        throw new HttpsError("not-found", "Booking not found.");
      }
      const currentRide = current.data();
      if (currentRide.status !== "awaiting_payment" ||
          !["unpaid", "failed"].includes(currentRide.paymentStatus) ||
          (currentRide.paymentIntentId && currentRide.paymentIntentId !== intent.id)) {
        throw new HttpsError("failed-precondition", "This booking is no longer awaiting payment.");
      }
      transaction.update(rideRef, {
        paymentIntentId: intent.id,
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }
  return { clientSecret: intent.client_secret, publishableKey };
});

exports.cancelRideBooking = onCall({
  region: REGION,
  secrets: [STRIPE_SECRET_KEY],
}, async (request) => {
  const uid = authenticatedUser(request);
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string") throw new HttpsError("invalid-argument", "A booking ID is required.");
  const rideRef = db.collection("rides").doc(rideId);
  let paymentIntentId;
  let paymentStatus;

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(rideRef);
    if (!snapshot.exists || snapshot.data().riderUid !== uid) {
      throw new HttpsError("not-found", "Booking not found.");
    }
    const ride = snapshot.data();
    if (ride.status === "cancelled" && ride.paymentStatus === "refund_pending") {
      paymentIntentId = ride.paymentIntentId;
      paymentStatus = ride.paymentStatus;
      return;
    }
    if (["in_progress", "completed", "cancelled"].includes(ride.status)) {
      throw new HttpsError("failed-precondition", "This ride can no longer be cancelled.");
    }
    paymentIntentId = ride.paymentIntentId;
    paymentStatus = ride.paymentStatus;
    const offerRefs = (ride.offeredDriverUids ?? [])
      .map((driverUid) => db.collection("drivers").doc(driverUid).collection("offers").doc(rideId));
    const reads = await Promise.all([
      ...offerRefs.map((ref) => transaction.get(ref)),
      ...(ride.driverUid ? [transaction.get(db.collection("drivers").doc(ride.driverUid))] : []),
    ]);
    transaction.update(rideRef, {
      status: "cancelled",
      paymentStatus: paymentStatus === "succeeded" ? "refund_pending" : paymentStatus,
      driverLocation: FieldValue.delete(),
      driverLocationUpdatedAt: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    reads.slice(0, offerRefs.length).forEach((offer) => {
      if (offer.exists && offer.data().status === "pending") {
        transaction.update(offer.ref, { status: "expired", updatedAt: FieldValue.serverTimestamp() });
      }
    });
    if (ride.driverUid && reads[offerRefs.length]?.exists) {
      transaction.update(reads[offerRefs.length].ref, {
        available: true,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
  });

  if (paymentIntentId && ["succeeded", "refund_pending"].includes(paymentStatus)) {
    try {
      await getStripe().refunds.create(
        { payment_intent: paymentIntentId },
        { idempotencyKey: `ride-refund-${rideId}` }
      );
      await rideRef.update({ paymentStatus: "refunded", updatedAt: FieldValue.serverTimestamp() });
    } catch (error) {
      logger.error("Ride refund failed", { rideId, error: error.message });
      throw new HttpsError("internal", "Ride cancelled, but the refund needs support review.");
    }
  } else if (paymentIntentId && paymentStatus === "unpaid") {
    try {
      await getStripe().paymentIntents.cancel(paymentIntentId, {}, {
        idempotencyKey: `ride-cancel-${rideId}`,
      });
    } catch (error) {
      logger.warn("Payment cancellation needs reconciliation", { rideId, error: error.message });
    }
  }
  return { rideId, status: "cancelled" };
});

exports.applyToDrive = onCall({ region: REGION }, async (request) => {
  const uid = authenticatedUser(request);
  const displayName = typeof request.data?.displayName === "string" ? request.data.displayName.trim() : "";
  const vehicleDescription = typeof request.data?.vehicleDescription === "string" ? request.data.vehicleDescription.trim() : "";
  const licensePlate = typeof request.data?.licensePlate === "string" ? request.data.licensePlate.trim() : "";
  let driverPreferences;
  try {
    driverPreferences = normalizeDriverRidePreferences(
      request.data?.acceptsWomenAndMinorsRides,
      request.data?.ecoFriendlyVehicle
    );
  } catch {
    throw new HttpsError("invalid-argument", "Enter valid driver preferences.");
  }
  if (
    typeof displayName !== "string" || displayName.length < 2 || displayName.length > 80 ||
    typeof vehicleDescription !== "string" || vehicleDescription.length < 2 || vehicleDescription.length > 100 ||
    typeof licensePlate !== "string" || licensePlate.length < 2 || licensePlate.length > 16
  ) {
    throw new HttpsError("invalid-argument", "Enter your name, vehicle, and license plate.");
  }

  const applicationRef = db.collection("driverApplications").doc(uid);
  await applicationRef.set({
    uid,
    displayName,
    vehicleDescription,
    licensePlate: licensePlate.toUpperCase(),
    ...driverPreferences,
    status: "pending_review",
    updatedAt: FieldValue.serverTimestamp(),
    createdAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  return { status: "pending_review" };
});

exports.approveDriverApplication = onCall({ region: REGION }, async (request) => {
  requireAdmin(request);
  const driverUid = request.data?.driverUid;
  if (typeof driverUid !== "string" || driverUid.length > 128) {
    throw new HttpsError("invalid-argument", "A valid driver account is required.");
  }
  const applicationRef = db.collection("driverApplications").doc(driverUid);
  const applicationSnapshot = await applicationRef.get();
  if (!applicationSnapshot.exists || applicationSnapshot.data().status !== "pending_review") {
    throw new HttpsError("not-found", "Pending driver application not found.");
  }
  const application = applicationSnapshot.data();
  const driverRef = db.collection("drivers").doc(driverUid);
  const existingDriver = await driverRef.get();
  if (application.preferenceReviewOnly === true) {
    if (!existingDriver.exists || existingDriver.data().verified !== true) {
      throw new HttpsError("failed-precondition", "The existing driver profile is not eligible for review.");
    }
    await driverRef.update({
      acceptsWomenAndMinorsRides: application.acceptsWomenAndMinorsRides === true,
      womenAndMinorsEligibilityApproved: application.acceptsWomenAndMinorsRides === true,
      updatedAt: FieldValue.serverTimestamp(),
    });
  } else {
    await driverRef.set({
      uid: driverUid,
      displayName: application.displayName,
      vehicleDescription: application.vehicleDescription,
      licensePlate: application.licensePlate,
      acceptsWomenAndMinorsRides: application.acceptsWomenAndMinorsRides === true,
      womenAndMinorsEligibilityApproved: application.acceptsWomenAndMinorsRides === true,
      ecoFriendlyVehicle: application.ecoFriendlyVehicle === true,
      verified: true,
      available: false,
      ...(existingDriver.data()?.location ? { location: existingDriver.data().location } : {}),
      updatedAt: FieldValue.serverTimestamp(),
    });
  }
  const user = await require("firebase-admin/auth").getAuth().getUser(driverUid);
  await require("firebase-admin/auth").getAuth().setCustomUserClaims(driverUid, {
    ...user.customClaims,
    driver: true,
  });
  await applicationRef.update({
    status: "approved",
    reviewedAt: FieldValue.serverTimestamp(),
    reviewedBy: request.auth.uid,
  });
  return { driverUid, status: "approved" };
});

exports.setDriverAvailability = onCall({ region: REGION }, async (request) => {
  const uid = requireDriver(request);
  const available = request.data?.available;
  const location = request.data?.location;
  if (typeof available !== "boolean" || (available && !validCoordinate(location))) {
    throw new HttpsError("invalid-argument", "A valid availability and location are required.");
  }
  if (available && !isWithinServiceArea(location)) {
    throw new HttpsError(
      "out-of-range",
      "Go online within the San Francisco service area."
    );
  }

  const driverRef = db.collection("drivers").doc(uid);
  const driverSnapshot = await driverRef.get();
  if (!driverSnapshot.exists || driverSnapshot.data().verified !== true) {
    throw new HttpsError("permission-denied", "Your driver profile is not approved.");
  }
  await driverRef.update({
    available,
    ...(available ? {
      location,
      geohash: geohashForLocation([location.latitude, location.longitude]),
      locationUpdatedAt: FieldValue.serverTimestamp(),
    } : {}),
    updatedAt: FieldValue.serverTimestamp(),
  });
  return { available };
});

exports.getDriverDemandHeatmap = onCall({ region: REGION }, async (request) => {
  const uid = requireDriver(request);
  const driverRef = db.collection("drivers").doc(uid);
  const now = Date.now();
  const refresh = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(driverRef);
    if (!snapshot.exists || snapshot.data().verified !== true ||
        snapshot.data().available !== true) {
      throw new HttpsError("failed-precondition", "Go online to view nearby demand.");
    }
    const driver = snapshot.data();
    const cachedZones = Array.isArray(driver.demandHeatmapZones) ? driver.demandHeatmapZones : [];
    const cachedAt = driver.demandHeatmapUpdatedAt?.toMillis();
    if (!isWithinServiceArea(driver.location) ||
        !isFreshDriverLocation(driver.locationUpdatedAt?.toMillis(), now)) {
      return { zones: [], updatedAt: now, shouldRefresh: false };
    }
    const nearbyCachedZones = filterNearbyDemandZones(cachedZones, driver.location);
    if (Number.isFinite(cachedAt) && now >= cachedAt && now - cachedAt < 5 * 60_000) {
      return { zones: nearbyCachedZones, updatedAt: cachedAt, shouldRefresh: false };
    }
    const refreshStartedAt = driver.demandHeatmapRefreshStartedAt?.toMillis();
    if (Number.isFinite(refreshStartedAt) && now >= refreshStartedAt &&
        now - refreshStartedAt < 2 * 60_000) {
      return { zones: nearbyCachedZones, updatedAt: cachedAt ?? null, shouldRefresh: false };
    }
    transaction.update(driverRef, {
      demandHeatmapRefreshStartedAt: Timestamp.fromMillis(now),
    });
    return { location: driver.location, shouldRefresh: true };
  });
  if (!refresh.shouldRefresh) {
    return { zones: refresh.zones, updatedAt: refresh.updatedAt };
  }

  try {
    const cutoff = Timestamp.fromMillis(now - 30 * 60_000);
    const activeStatuses = ["searching_driver", "dispatching", "offered"];
    const snapshots = await Promise.all(activeStatuses.map((status) =>
      db.collection("rides")
        .where("status", "==", status)
        .where("updatedAt", ">=", cutoff)
        .orderBy("updatedAt", "desc")
        .limit(100)
        .get()
    ));
    const rides = snapshots.flatMap((snapshot) => snapshot.docs.map((document) => {
      const data = document.data();
      return {
        status: data.status,
        demandZone: data.demandZone,
        updatedAtMillis: data.updatedAt?.toMillis(),
      };
    }));
    const zones = aggregateDemandHeatmap(rides, refresh.location, now);
    await driverRef.update({
      demandHeatmapZones: zones,
      demandHeatmapUpdatedAt: Timestamp.fromMillis(now),
      demandHeatmapRefreshStartedAt: FieldValue.delete(),
    });
    return { zones, updatedAt: now };
  } catch (error) {
    await driverRef.update({
      demandHeatmapRefreshStartedAt: FieldValue.delete(),
    }).catch(() => {});
    throw error;
  }
});

exports.setDriverRidePreferences = onCall({ region: REGION }, async (request) => {
  const uid = requireDriver(request);
  const acceptsWomenAndMinorsRides = request.data?.acceptsWomenAndMinorsRides;
  const ecoFriendlyVehicle = request.data?.ecoFriendlyVehicle;
  if (typeof acceptsWomenAndMinorsRides !== "boolean" ||
      typeof ecoFriendlyVehicle !== "boolean") {
    throw new HttpsError("invalid-argument", "Choose valid driver preferences.");
  }
  const driverRef = db.collection("drivers").doc(uid);
  const snapshot = await driverRef.get();
  if (!snapshot.exists || snapshot.data().verified !== true) {
    throw new HttpsError("permission-denied", "Your driver profile is not approved.");
  }
  if (acceptsWomenAndMinorsRides &&
      snapshot.data().womenAndMinorsEligibilityApproved !== true) {
    throw new HttpsError(
      "failed-precondition",
      "A manual eligibility review is required before opting in."
    );
  }
  await driverRef.update({
    acceptsWomenAndMinorsRides,
    ecoFriendlyVehicle,
    updatedAt: FieldValue.serverTimestamp(),
  });
  return { acceptsWomenAndMinorsRides, ecoFriendlyVehicle };
});

exports.requestWomenAndMinorsEligibilityReview = onCall({ region: REGION }, async (request) => {
  const uid = requireDriver(request);
  const driverRef = db.collection("drivers").doc(uid);
  const driverSnapshot = await driverRef.get();
  if (!driverSnapshot.exists || driverSnapshot.data().verified !== true) {
    throw new HttpsError("permission-denied", "Your driver profile is not approved.");
  }
  if (driverSnapshot.data().womenAndMinorsEligibilityApproved === true) {
    return { status: "approved" };
  }
  const driver = driverSnapshot.data();
  await db.collection("driverApplications").doc(uid).set({
    uid,
    displayName: driver.displayName,
    vehicleDescription: driver.vehicleDescription,
    licensePlate: driver.licensePlate,
    acceptsWomenAndMinorsRides: true,
    ecoFriendlyVehicle: driver.ecoFriendlyVehicle === true,
    preferenceReviewOnly: true,
    status: "pending_review",
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  return { status: "pending_review" };
});

exports.updateDriverLocation = onCall({ region: REGION }, async (request) => {
  const uid = requireDriver(request);
  const location = request.data?.location;
  if (!validCoordinate(location)) {
    throw new HttpsError("invalid-argument", "A valid driver location is required.");
  }

  const driverRef = db.collection("drivers").doc(uid);
  const activeRideQuery = db.collection("rides")
    .where("driverUid", "==", uid)
    .where("status", "in", ACTIVE_RIDE_STATUSES)
    .limit(10);
  const withinServiceArea = isWithinServiceArea(location);
  const transactionResult = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(driverRef);
    if (!snapshot.exists || snapshot.data().verified !== true) {
      throw new HttpsError("failed-precondition", "Go online to update your driver location.");
    }
    let activeRidesSnapshot;
    if (!snapshot.data().available) {
      activeRidesSnapshot = await transaction.get(activeRideQuery);
      if (activeRidesSnapshot.empty) {
        throw new HttpsError("failed-precondition", "Go online to update your driver location.");
      }
    }
    const lastUpdatedAt = snapshot.data().locationUpdatedAt?.toMillis();
    if (withinServiceArea && Number.isFinite(lastUpdatedAt) &&
        Date.now() - lastUpdatedAt < 10_000) {
      return { updated: false, activeRidesSnapshot };
    }
    transaction.update(driverRef, {
      location,
      geohash: geohashForLocation([location.latitude, location.longitude]),
      locationUpdatedAt: FieldValue.serverTimestamp(),
      ...(!withinServiceArea ? { available: false } : {}),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return { updated: true, activeRidesSnapshot };
  });
  if (transactionResult.updated) {
    const activeRides = transactionResult.activeRidesSnapshot ?? await activeRideQuery.get();
    await Promise.all(activeRides.docs
      .map((ride) => db.runTransaction(async (transaction) => {
        const currentRide = await transaction.get(ride.ref);
        if (!currentRide.exists ||
            currentRide.data().driverUid !== uid ||
            !ACTIVE_RIDE_STATUSES.includes(currentRide.data().status)) return;
        transaction.update(ride.ref, {
          driverLocation: location,
          driverLocationUpdatedAt: FieldValue.serverTimestamp(),
        });
      })));
  }
  return {
    updated: transactionResult.updated,
    withinServiceArea,
    available: withinServiceArea,
  };
});

exports.claimRideOffer = onCall({ region: REGION }, async (request) => {
  const uid = requireDriver(request);
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || rideId.length > 100) {
    throw new HttpsError("invalid-argument", "A valid ride offer is required.");
  }
  const driverRef = db.collection("drivers").doc(uid);
  const offerRef = driverRef.collection("offers").doc(rideId);
  const rideRef = db.collection("rides").doc(rideId);

  await db.runTransaction(async (transaction) => {
    const [driverSnapshot, offerSnapshot, rideSnapshot] = await Promise.all([
      transaction.get(driverRef),
      transaction.get(offerRef),
      transaction.get(rideRef),
    ]);
    if (!driverSnapshot.exists || driverSnapshot.data().verified !== true ||
        !driverSnapshot.data().available ||
        !isWithinServiceArea(driverSnapshot.data().location) ||
        !isFreshDriverLocation(
          driverSnapshot.data().locationUpdatedAt?.toMillis(),
          Date.now()
        )) {
      throw new HttpsError("failed-precondition", "Go online to accept ride offers.");
    }
    if (!offerSnapshot.exists || offerSnapshot.data().status !== "pending" ||
        offerSnapshot.data().expiresAt.toMillis() <= Date.now()) {
      throw new HttpsError("deadline-exceeded", "This ride offer has expired.");
    }
    if (!rideSnapshot.exists || rideSnapshot.data().status !== "offered" ||
        rideSnapshot.data().paymentStatus !== "succeeded") {
      throw new HttpsError("already-exists", "Another driver has accepted this ride.");
    }
    if (!matchesRidePreferences(driverSnapshot.data(), rideSnapshot.data().preferences)) {
      throw new HttpsError(
        "failed-precondition",
        "Your ride preferences no longer match this offer."
      );
    }
    const competingOfferRefs = (rideSnapshot.data().offeredDriverUids ?? [])
      .filter((driverUid) => driverUid !== uid)
      .map((driverUid) => db.collection("drivers").doc(driverUid).collection("offers").doc(rideId));
    const competingOffers = await Promise.all(competingOfferRefs.map((ref) => transaction.get(ref)));
    transaction.update(rideRef, {
      status: "driver_assigned",
      driverUid: uid,
      driverInfo: riderVisibleDriverProfile(driverSnapshot.data()),
      driverLocation: driverSnapshot.data().location,
      driverLocationUpdatedAt: FieldValue.serverTimestamp(),
      assignedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.update(driverRef, { available: false, updatedAt: FieldValue.serverTimestamp() });
    transaction.update(offerRef, { status: "accepted", updatedAt: FieldValue.serverTimestamp() });
    competingOffers.forEach((snapshot) => {
      if (snapshot.exists && snapshot.data().status === "pending") {
        transaction.update(snapshot.ref, { status: "expired", updatedAt: FieldValue.serverTimestamp() });
      }
    });
  });
  return { rideId, status: "driver_assigned" };
});

exports.updateRideStatus = onCall({ region: REGION }, async (request) => {
  const uid = requireDriver(request);
  const rideId = request.data?.rideId;
  const nextStatus = request.data?.status;
  if (typeof rideId !== "string" || !["en_route", "arrived", "in_progress", "completed"].includes(nextStatus)) {
    throw new HttpsError("invalid-argument", "A valid ride and trip status are required.");
  }
  const rideRef = db.collection("rides").doc(rideId);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(rideRef);
    if (!snapshot.exists || snapshot.data().driverUid !== uid) {
      throw new HttpsError("not-found", "Assigned ride not found.");
    }
    if (!canTransitionRide(snapshot.data().status, nextStatus)) {
      throw new HttpsError("failed-precondition", "That trip status transition is not allowed.");
    }
    transaction.update(rideRef, {
      status: nextStatus,
      ...(nextStatus === "completed" ? {
        driverLocation: FieldValue.delete(),
        driverLocationUpdatedAt: FieldValue.delete(),
      } : {}),
      updatedAt: FieldValue.serverTimestamp(),
      ...(nextStatus === "completed" ? { completedAt: FieldValue.serverTimestamp() } : {}),
    });
  });
  return { rideId, status: nextStatus };
});

exports.dispatchPaidRide = onDocumentUpdated({
  region: REGION,
  document: "rides/{rideId}",
}, async (event) => {
  const before = event.data?.before.data();
  const ride = event.data?.after.data();
  if (!ride || before?.paymentStatus === "succeeded" || ride.paymentStatus !== "succeeded") return;
  await createDriverOffers(event.params.rideId, ride);
});

exports.retryUnmatchedRides = onSchedule({
  region: REGION,
  schedule: "every 1 minutes",
  timeZone: "UTC",
}, async () => {
  const cutoff = Timestamp.fromMillis(Date.now() - 60_000);
  const staleRideQueries = ["searching_driver", "offered", "dispatching"].map((status) =>
    db.collection("rides")
      .where("status", "==", status)
      .where("updatedAt", "<=", cutoff)
      .orderBy("updatedAt")
      .limit(50)
      .get()
  );
  const [searchingSnapshot, offeredSnapshot, dispatchingSnapshot] = await Promise.all(staleRideQueries);
  const staleRides = [
    ...searchingSnapshot.docs.map((snapshot) => ({ snapshot, expectedStatus: "searching_driver" })),
    ...offeredSnapshot.docs.map((snapshot) => ({ snapshot, expectedStatus: "offered" })),
    ...dispatchingSnapshot.docs.map((snapshot) => ({ snapshot, expectedStatus: "dispatching" })),
  ];

  for (const { snapshot: staleSnapshot, expectedStatus } of staleRides) {
    const rideRef = staleSnapshot.ref;
    try {
      let ride;
      await db.runTransaction(async (transaction) => {
        ride = undefined;
        const currentSnapshot = await transaction.get(rideRef);
        if (!currentSnapshot.exists) return;
        const currentRide = currentSnapshot.data();
        if (currentRide.status !== expectedStatus ||
            currentRide.paymentStatus !== "succeeded" ||
            currentRide.driverUid ||
            currentRide.updatedAt.toMillis() > cutoff.toMillis()) return;

        const offerRefs = expectedStatus === "offered"
          ? (currentRide.offeredDriverUids ?? []).map((uid) =>
            db.collection("drivers").doc(uid).collection("offers").doc(rideRef.id))
          : [];
        const offers = await Promise.all(offerRefs.map((ref) => transaction.get(ref)));
        offers.forEach((offer) => {
          if (offer.exists && offer.data().status === "pending") {
            transaction.update(offer.ref, {
              status: "expired",
              updatedAt: FieldValue.serverTimestamp(),
            });
          }
        });
        transaction.update(rideRef, {
          status: "dispatching",
          updatedAt: FieldValue.serverTimestamp(),
        });
        ride = currentRide;
      });
      if (ride) await createDriverOffers(rideRef.id, ride);
    } catch (error) {
      logger.error("Ride redispatch failed", { rideId: rideRef.id, error: error.message });
    }
  }
});

exports.stripeWebhook = onRequest({
  region: REGION,
  secrets: [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET],
}, async (request, response) => {
  if (request.method !== "POST") {
    response.status(405).send("Method not allowed");
    return;
  }

  let event;
  try {
    event = getStripe().webhooks.constructEvent(
      request.rawBody,
      request.headers["stripe-signature"],
      STRIPE_WEBHOOK_SECRET.value()
    );
  } catch (error) {
    logger.warn("Rejected invalid Stripe webhook signature");
    response.status(400).send("Invalid webhook signature");
    return;
  }

  const paymentIntent = event.data.object;
  const rideId = paymentIntent.metadata?.rideId;
  if (rideId && event.type.startsWith("payment_intent.")) {
    const rideRef = db.collection("rides").doc(rideId);
    const outcome = await db.runTransaction(async (transaction) => {
      const [eventSnapshot, rideSnapshot] = await Promise.all([
        transaction.get(db.collection("stripeEvents").doc(event.id)),
        transaction.get(rideRef),
      ]);
      if (eventSnapshot.exists) return "duplicate";
      if (!rideSnapshot.exists || !rideSnapshot.data().paymentIntentId) {
        return "not-ready";
      }
      const currentRide = rideSnapshot.data();
      if (currentRide.paymentIntentId !== paymentIntent.id) {
        transaction.create(db.collection("stripeEvents").doc(event.id), {
          type: event.type,
          processedAt: FieldValue.serverTimestamp(),
        });
        return "ignored";
      }
      if (event.type === "payment_intent.succeeded" && currentRide.status === "cancelled") {
        transaction.update(rideRef, {
          paymentStatus: "refund_pending",
          updatedAt: FieldValue.serverTimestamp(),
        });
        return "refund";
      }
      if (event.type === "payment_intent.succeeded" && currentRide.status === "awaiting_payment") {
        transaction.create(db.collection("stripeEvents").doc(event.id), {
          type: event.type,
          processedAt: FieldValue.serverTimestamp(),
        });
        transaction.update(rideRef, {
          paymentStatus: "succeeded",
          status: "dispatching",
          paidAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        return "paid";
      } else if (event.type === "payment_intent.payment_failed" && currentRide.status === "awaiting_payment") {
        transaction.create(db.collection("stripeEvents").doc(event.id), {
          type: event.type,
          processedAt: FieldValue.serverTimestamp(),
        });
        transaction.update(rideRef, {
          paymentStatus: "failed",
          updatedAt: FieldValue.serverTimestamp(),
        });
      } else {
        transaction.create(db.collection("stripeEvents").doc(event.id), {
          type: event.type,
          processedAt: FieldValue.serverTimestamp(),
        });
      }
      return "processed";
    });
    if (outcome === "not-ready") {
      response.status(500).send("Booking payment state not ready; retry webhook.");
      return;
    }
    if (outcome === "refund") {
      await getStripe().refunds.create(
        { payment_intent: paymentIntent.id },
        { idempotencyKey: `ride-refund-${rideId}` }
      );
      await db.runTransaction(async (transaction) => {
        const eventRef = db.collection("stripeEvents").doc(event.id);
        const [eventSnapshot, rideSnapshot] = await Promise.all([
          transaction.get(eventRef),
          transaction.get(rideRef),
        ]);
        if (!eventSnapshot.exists) {
          transaction.create(eventRef, {
            type: event.type,
            processedAt: FieldValue.serverTimestamp(),
          });
        }
        if (rideSnapshot.exists && rideSnapshot.data().paymentStatus === "refund_pending") {
          transaction.update(rideRef, {
            paymentStatus: "refunded",
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
      });
    }
  }
  response.status(200).json({ received: true });
});
