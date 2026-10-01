import express from "express";
import pg from "pg";
import Stripe from "stripe";
import { createRemoteJWKSet, jwtVerify, SignJWT } from "jose";
import { createHash, randomUUID } from "node:crypto";
import { readConfig } from "./config.js";
import { getRidePrice, isValidLocation } from "./validation.js";

const config = readConfig();
const { Pool } = pg;
const pool = new Pool({ connectionString: config.databaseUrl, ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined });
const stripe = new Stripe(config.stripeSecretKey);
const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
const sessionKey = new TextEncoder().encode(config.sessionSecret);
const app = express();

app.disable("x-powered-by");

app.post("/v1/webhooks/stripe", express.raw({ type: "application/json", limit: "1mb" }), async (req, res) => {
  let event;
  try {
    event = stripe.webhooks.constructEvent(
      req.body,
      req.header("stripe-signature"),
      config.stripeWebhookSecret,
    );
  } catch {
    return res.status(400).json({ error: "Invalid webhook signature." });
  }

  try {
    if (event.type === "payment_intent.succeeded") {
      const intent = event.data.object;
      if (intent.metadata?.rideId) {
        await pool.query(
          "UPDATE rides SET status = 'confirmed' WHERE id = $1 AND payment_intent_id = $2 AND status = 'awaiting_payment'",
          [intent.metadata.rideId, intent.id],
        );
      }
    } else if (event.type === "payment_intent.canceled") {
      const intent = event.data.object;
      const result = await pool.query(
        "UPDATE rides SET status = 'cancelled' WHERE id = $1 AND payment_intent_id = $2 AND status = 'awaiting_payment' RETURNING driver_user_id",
        [intent.metadata?.rideId, intent.id],
      );
      if (result.rowCount) {
        await pool.query(
          `UPDATE drivers SET available = true
           WHERE user_id = $1
             AND NOT EXISTS (
               SELECT 1 FROM rides WHERE driver_user_id = $1 AND status IN ('awaiting_payment', 'confirmed')
             )`,
          [result.rows[0].driver_user_id],
        );
      }
    }
    return res.json({ received: true });
  } catch (error) {
    console.error("Stripe webhook processing failed:", error);
    return res.status(500).json({ error: "Webhook processing failed." });
  }
});

app.use(express.json({ limit: "16kb", type: "application/json" }));

function asyncRoute(handler) {
  return (req, res, next) => Promise.resolve(handler(req, res, next)).catch(next);
}

function validText(value, maxLength = 200) {
  return typeof value === "string" && value.trim().length > 0 && value.length <= maxLength;
}

function validateLocationPair(body) {
  return isValidLocation(body?.pickup) && isValidLocation(body?.destination);
}

async function authenticate(req, res, next) {
  const authHeader = req.header("authorization") ?? "";
  const [scheme, token, ...extra] = authHeader.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !token || extra.length > 0) {
    return res.status(401).json({ error: "Authentication required." });
  }
  try {
    const { payload } = await jwtVerify(token, sessionKey, {
      issuer: "tryps-rideshare-api",
      audience: "tryps-rideshare-app",
      algorithms: ["HS256"],
    });
    if (typeof payload.sub !== "string" || !["rider", "driver"].includes(payload.role)) {
      return res.status(401).json({ error: "Invalid session." });
    }
    req.user = { id: payload.sub, role: payload.role };
    return next();
  } catch {
    return res.status(401).json({ error: "Invalid or expired session." });
  }
}

function requireRole(role) {
  return (req, res, next) => {
    if (req.user.role !== role) return res.status(403).json({ error: "This action is not available for this account." });
    return next();
  };
}

app.get("/v1/health", (_req, res) => res.json({ status: "ok" }));

app.post("/v1/auth/apple", asyncRoute(async (req, res) => {
  const identityToken = req.body?.identityToken;
  const nonce = req.body?.nonce;
  const role = req.body?.role;
  if (!validText(identityToken, 10000) || !validText(nonce, 128) || nonce.length < 16 ||
      !["rider", "driver"].includes(role)) {
    return res.status(400).json({ error: "A valid Apple identity token, nonce, and account role are required." });
  }

  let claims;
  try {
    ({ payload: claims } = await jwtVerify(identityToken, appleKeys, {
      issuer: "https://appleid.apple.com",
      audience: config.appleBundleId,
      algorithms: ["RS256"],
    }));
  } catch {
    return res.status(401).json({ error: "Apple sign-in could not be verified." });
  }

  if (typeof claims.sub !== "string" || claims.sub.length > 255 ||
      claims.nonce !== createHash("sha256").update(nonce).digest("hex")) {
    return res.status(401).json({ error: "Apple sign-in did not provide a valid account." });
  }

  const inserted = await pool.query(
    "INSERT INTO app_users (id, role) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
    [claims.sub, role],
  );
  const account = await pool.query("SELECT role FROM app_users WHERE id = $1", [claims.sub]);
  if (!account.rowCount || account.rows[0].role !== role) {
    return res.status(409).json({ error: "This Apple account is already registered with a different role." });
  }
  if (inserted.rowCount && role === "driver") {
    return res.status(201).json({ sessionToken: await createSession(claims.sub, role), needsDriverOnboarding: true });
  }

  return res.status(inserted.rowCount ? 201 : 200).json({
    sessionToken: await createSession(claims.sub, role),
    needsDriverOnboarding: role === "driver",
  });
}));

async function createSession(userId, role) {
  return new SignJWT({ role })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer("tryps-rideshare-api")
    .setAudience("tryps-rideshare-app")
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(sessionKey);
}

app.post("/v1/driver/connect-onboarding", authenticate, requireRole("driver"), asyncRoute(async (req, res) => {
  const existing = await pool.query("SELECT stripe_account_id FROM drivers WHERE user_id = $1", [req.user.id]);
  let accountId = existing.rows[0]?.stripe_account_id;
  if (!accountId) {
    const account = await stripe.accounts.create(
      {
        type: "express",
        country: config.stripeConnectCountry,
        capabilities: { transfers: { requested: true } },
        metadata: { trypsUserId: req.user.id },
      },
      { idempotencyKey: `driver-account-${req.user.id}` },
    );
    accountId = account.id;
    await pool.query(
      "INSERT INTO drivers (user_id, stripe_account_id) VALUES ($1, $2) ON CONFLICT (user_id) DO NOTHING",
      [req.user.id, accountId],
    );
    const stored = await pool.query("SELECT stripe_account_id FROM drivers WHERE user_id = $1", [req.user.id]);
    accountId = stored.rows[0].stripe_account_id;
  }

  const link = await stripe.accountLinks.create({
    account: accountId,
    refresh_url: config.driverOnboardingRefreshUrl,
    return_url: config.driverOnboardingReturnUrl,
    type: "account_onboarding",
  });
  return res.json({ onboardingUrl: link.url });
}));

app.put("/v1/driver/location", authenticate, requireRole("driver"), asyncRoute(async (req, res) => {
  const { latitude, longitude } = req.body ?? {};
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90 ||
      !Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
    return res.status(400).json({ error: "A valid driver location is required." });
  }
  const result = await pool.query(
    `UPDATE drivers SET location = ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography, updated_at = now()
     WHERE user_id = $1 RETURNING user_id`,
    [req.user.id, longitude, latitude],
  );
  if (!result.rowCount) return res.status(409).json({ error: "Complete driver payment onboarding first." });
  return res.json({ updated: true });
}));

app.patch("/v1/driver/availability", authenticate, requireRole("driver"), asyncRoute(async (req, res) => {
  if (typeof req.body?.available !== "boolean") {
    return res.status(400).json({ error: "The available field must be true or false." });
  }
  const driver = await pool.query("SELECT stripe_account_id FROM drivers WHERE user_id = $1", [req.user.id]);
  if (!driver.rowCount) return res.status(409).json({ error: "Complete driver payment onboarding first." });
  if (req.body.available) {
    const account = await stripe.accounts.retrieve(driver.rows[0].stripe_account_id);
    if (!account.details_submitted || !account.payouts_enabled) {
      return res.status(409).json({ error: "Complete Stripe verification before going online." });
    }
  }
  await pool.query(
    "UPDATE drivers SET available = $2, updated_at = now() WHERE user_id = $1",
    [req.user.id, req.body.available],
  );
  return res.json({ available: req.body.available });
}));

app.post("/v1/rides", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const { pickup, destination, rideType } = req.body ?? {};
  const amountCents = getRidePrice(rideType, config.ridePrices);
  if (!validateLocationPair(req.body) || amountCents === undefined) {
    return res.status(400).json({ error: "Valid pickup, destination, and ride type are required." });
  }

  const rideId = randomUUID();
  const client = await pool.connect();
  let transactionOpen = false;
  let paymentIntentId;
  try {
    await client.query("BEGIN");
    transactionOpen = true;
    const candidates = await client.query(
      `SELECT user_id, stripe_account_id
       FROM drivers
       WHERE available = true
         AND location IS NOT NULL
         AND ST_DWithin(
           location,
           ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography,
           $3
         )
       ORDER BY location <-> ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography
       LIMIT 1
       FOR UPDATE SKIP LOCKED`,
      [pickup.longitude, pickup.latitude, config.matchingRadiusMeters],
    );
    const driver = candidates.rows[0];
    if (!driver) {
      await client.query("ROLLBACK");
      transactionOpen = false;
      return res.status(409).json({ error: "No available drivers nearby. Please try again shortly." });
    }

    const account = await stripe.accounts.retrieve(driver.stripe_account_id);
    if (!account.details_submitted || !account.payouts_enabled) {
      await client.query("UPDATE drivers SET available = false WHERE user_id = $1", [driver.user_id]);
      await client.query("COMMIT");
      transactionOpen = false;
      return res.status(409).json({ error: "A nearby driver is finishing payment verification. Please try again." });
    }

    const applicationFeeAmount = Math.floor(amountCents * config.applicationFeeBasisPoints / 10000);
    const paymentIntent = await stripe.paymentIntents.create(
      {
        amount: amountCents,
        currency: config.currency,
        automatic_payment_methods: { enabled: true },
        application_fee_amount: applicationFeeAmount,
        transfer_data: { destination: driver.stripe_account_id },
        metadata: { rideId },
      },
      { idempotencyKey: `ride-payment-${rideId}` },
    );
    paymentIntentId = paymentIntent.id;

    await client.query(
      `INSERT INTO rides (
        id, rider_user_id, driver_user_id, pickup_label, pickup, destination_label, destination,
        ride_type, amount_cents, currency, payment_intent_id, status
      ) VALUES (
        $1, $2, $3, $4, ST_SetSRID(ST_MakePoint($5, $6), 4326)::geography,
        $7, ST_SetSRID(ST_MakePoint($8, $9), 4326)::geography, $10, $11, $12, $13, 'awaiting_payment'
      )`,
      [
        rideId, req.user.id, driver.user_id, pickup.label.trim(), pickup.longitude, pickup.latitude,
        destination.label.trim(), destination.longitude, destination.latitude,
        rideType, amountCents, config.currency, paymentIntent.id,
      ],
    );
    await client.query("UPDATE drivers SET available = false, updated_at = now() WHERE user_id = $1", [driver.user_id]);
    await client.query("COMMIT");
    transactionOpen = false;

    return res.status(201).json({
      rideId,
      status: "awaiting_payment",
      paymentIntentClientSecret: paymentIntent.client_secret,
      amountCents,
      currency: config.currency,
    });
  } catch (error) {
    if (transactionOpen) await client.query("ROLLBACK").catch(() => {});
    if (paymentIntentId) {
      await stripe.paymentIntents.cancel(paymentIntentId).catch((cancelError) => {
        console.error("Could not cancel an unclaimed payment intent:", cancelError);
      });
    }
    throw error;
  } finally {
    client.release();
  }
}));

app.delete("/v1/rides/:rideId", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT payment_intent_id FROM rides
     WHERE id = $1 AND rider_user_id = $2 AND status = 'awaiting_payment'`,
    [req.params.rideId, req.user.id],
  );
  if (!result.rowCount) return res.status(404).json({ error: "Pending ride not found." });
  try {
    await stripe.paymentIntents.cancel(result.rows[0].payment_intent_id);
  } catch {
    const current = await stripe.paymentIntents.retrieve(result.rows[0].payment_intent_id);
    if (current.status !== "canceled") {
      return res.status(409).json({ error: "This payment is already processing and cannot be canceled." });
    }
  }
  const cancelled = await pool.query(
    `UPDATE rides SET status = 'cancelled'
     WHERE id = $1 AND rider_user_id = $2 AND status = 'awaiting_payment'
     RETURNING driver_user_id`,
    [req.params.rideId, req.user.id],
  );
  if (cancelled.rowCount) {
    await pool.query(
      `UPDATE drivers SET available = true
       WHERE user_id = $1
         AND NOT EXISTS (
           SELECT 1 FROM rides WHERE driver_user_id = $1 AND status IN ('awaiting_payment', 'confirmed')
         )`,
      [cancelled.rows[0].driver_user_id],
    );
  }
  return res.json({ cancelled: cancelled.rowCount > 0 });
}));

app.get("/v1/rides/:rideId", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT id, pickup_label AS pickup, destination_label AS destination, ride_type AS "rideType",
            amount_cents AS "amountCents", currency, status, created_at AS "createdAt"
     FROM rides WHERE id = $1 AND rider_user_id = $2`,
    [req.params.rideId, req.user.id],
  );
  if (!result.rowCount) return res.status(404).json({ error: "Ride not found." });
  return res.json(result.rows[0]);
}));

app.use((error, _req, res, _next) => {
  console.error("API request failed:", error);
  if (res.headersSent) return;
  return res.status(500).json({ error: "The request could not be completed." });
});

const server = app.listen(config.port, () => {
  console.log(`Tryps API listening on port ${config.port}.`);
});

async function shutdown() {
  server.close();
  await pool.end();
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
