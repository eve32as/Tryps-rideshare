"use strict";

const { randomUUID } = require("node:crypto");
const { initializeApp } = require("firebase-admin/app");
const { FieldValue, Timestamp, getFirestore } = require("firebase-admin/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { defineSecret, defineString } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const Stripe = require("stripe");

const {
  calculateQuote,
  canTransitionRide,
  distanceInKilometers,
  validCoordinate,
} = require("./domain");

initializeApp();
const db = getFirestore();
const REGION = "us-central1";
const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");
const STRIPE_PUBLISHABLE_KEY = defineString("STRIPE_PUBLISHABLE_KEY", { default: "" });
const DRIVER_SEARCH_LIMIT = 100;
const DRIVER_MATCH_RADIUS_KM = 15;

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

function parseRideType(data) {
  if (!data || typeof data.rideType !== "string") {
    throw new HttpsError("invalid-argument", "Choose a ride type.");
  }
  return data.rideType;
}

async function createDriverOffers(rideId, ride) {
  const drivers = await db.collection("drivers")
    .where("available", "==", true)
    .limit(DRIVER_SEARCH_LIMIT)
    .get();
  const candidates = drivers.docs
    .filter((driver) => driver.data().verified === true && validCoordinate(driver.data().location))
    .map((driver) => ({
      ref: driver.ref,
      uid: driver.id,
      distanceKm: distanceInKilometers(ride.pickup, driver.data().location),
    }))
    .filter((driver) => driver.distanceKm <= DRIVER_MATCH_RADIUS_KM)
    .sort((a, b) => a.distanceKm - b.distanceKm)
    .slice(0, 10);

  const rideRef = db.collection("rides").doc(rideId);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(rideRef);
    if (!snapshot.exists || snapshot.data().status !== "dispatching" ||
        snapshot.data().paymentStatus !== "succeeded") return;

    if (candidates.length === 0) {
      transaction.update(rideRef, {
        status: "searching_driver",
        dispatchMessage: "No nearby drivers are available yet.",
        updatedAt: FieldValue.serverTimestamp(),
      });
      return;
    }

    const expiresAt = Timestamp.fromMillis(Date.now() + 60_000);
    for (const candidate of candidates) {
      transaction.set(candidate.ref.collection("offers").doc(rideId), {
        rideId,
        status: "pending",
        pickup: ride.pickup,
        dropOff: ride.dropOff,
        rideType: ride.rideType,
        expiresAt,
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.update(rideRef, {
      status: "offered",
      offerCount: candidates.length,
      offeredDriverUids: candidates.map((candidate) => candidate.uid),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

exports.createRideQuote = onCall({ region: REGION }, async (request) => {
  const uid = authenticatedUser(request);
  const pickup = request.data?.pickup;
  const dropOff = request.data?.dropOff;
  let quote;
  try {
    quote = calculateQuote(pickup, dropOff, parseRideType(request.data));
  } catch (error) {
    throw new HttpsError("invalid-argument", error.message);
  }

  const quoteId = randomUUID();
  const expiresAt = Timestamp.fromMillis(Date.now() + 5 * 60_000);
  await db.collection("rideQuotes").doc(quoteId).create({
    uid,
    pickup,
    dropOff,
    ...quote,
    status: "available",
    createdAt: FieldValue.serverTimestamp(),
    expiresAt,
  });
  return { quoteId, ...quote, expiresAt: expiresAt.toMillis() };
});

exports.createRideBooking = onCall({ region: REGION }, async (request) => {
  const uid = authenticatedUser(request);
  const quoteId = request.data?.quoteId;
  if (typeof quoteId !== "string" || quoteId.length > 100) {
    throw new HttpsError("invalid-argument", "A valid quote is required.");
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
    if (quote.expiresAt.toMillis() <= Date.now()) {
      throw new HttpsError("deadline-exceeded", "The ride quote expired. Request a new quote.");
    }

    transaction.create(rideRef, {
      riderUid: uid,
      driverUid: null,
      quoteId,
      pickup: quote.pickup,
      dropOff: quote.dropOff,
      rideType: quote.rideType,
      rideLabel: quote.rideLabel,
      distanceKm: quote.distanceKm,
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

  const stripe = getStripe();
  const paymentAttempt = (ride.paymentAttempts ?? 0) + 1;
  let intent;
  try {
    intent = await stripe.paymentIntents.create({
      amount: ride.amountCents,
      currency: ride.currency,
      automatic_payment_methods: { enabled: true },
      metadata: { rideId, riderUid: uid },
    }, { idempotencyKey: `ride-payment-${rideId}-${paymentAttempt}` });
  } catch (error) {
    logger.error("Stripe PaymentIntent creation failed", { rideId, error: error.message });
    throw new HttpsError("internal", "Could not start payment. Please try again.");
  }
  await db.runTransaction(async (transaction) => {
    const current = await transaction.get(rideRef);
    if (!current.exists || current.data().riderUid !== uid) {
      throw new HttpsError("not-found", "Booking not found.");
    }
    transaction.update(rideRef, {
      paymentIntentId: intent.id,
      paymentAttempts: paymentAttempt,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
  const publishableKey = STRIPE_PUBLISHABLE_KEY.value();
  if (!publishableKey) {
    throw new HttpsError("failed-precondition", "Payments are not fully configured.");
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
  await driverRef.set({
    uid: driverUid,
    displayName: application.displayName,
    vehicleDescription: application.vehicleDescription,
    licensePlate: application.licensePlate,
    verified: true,
    available: false,
    ...(existingDriver.data()?.location ? { location: existingDriver.data().location } : {}),
    updatedAt: FieldValue.serverTimestamp(),
  });
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

  const driverRef = db.collection("drivers").doc(uid);
  const driverSnapshot = await driverRef.get();
  if (!driverSnapshot.exists || driverSnapshot.data().verified !== true) {
    throw new HttpsError("permission-denied", "Your driver profile is not approved.");
  }
  await driverRef.update({
    available,
    ...(available ? { location } : {}),
    updatedAt: FieldValue.serverTimestamp(),
  });
  return { available };
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
    if (!driverSnapshot.exists || driverSnapshot.data().verified !== true || !driverSnapshot.data().available) {
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
    const competingOfferRefs = (rideSnapshot.data().offeredDriverUids ?? [])
      .filter((driverUid) => driverUid !== uid)
      .map((driverUid) => db.collection("drivers").doc(driverUid).collection("offers").doc(rideId));
    const competingOffers = await Promise.all(competingOfferRefs.map((ref) => transaction.get(ref)));
    transaction.update(rideRef, {
      status: "driver_assigned",
      driverUid: uid,
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
