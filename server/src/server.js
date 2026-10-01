import express from "express";
import { connect as connectHTTP2 } from "node:http2";
import { rateLimit } from "express-rate-limit";
import pg from "pg";
import Stripe from "stripe";
import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT } from "jose";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { readConfig } from "./config.js";
import { calculateRideFare, isValidLocation } from "./validation.js";

const config = readConfig();
const { Pool } = pg;
const pool = new Pool({ connectionString: config.databaseUrl, ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined });
const stripe = new Stripe(config.stripeSecretKey);
const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
const sessionKey = new TextEncoder().encode(config.sessionSecret);
const app = express();
let cachedAPNSToken;
let cachedAPNSTokenCreatedAt = 0;

async function getAPNSToken() {
  const now = Date.now();
  if (cachedAPNSToken && now - cachedAPNSTokenCreatedAt < 50 * 60_000) return cachedAPNSToken;
  const signingKey = await importPKCS8(config.apns.privateKey, "ES256");
  cachedAPNSToken = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.apns.keyId })
    .setIssuer(config.apns.teamId)
    .setIssuedAt(now / 1000)
    .sign(signingKey);
  cachedAPNSTokenCreatedAt = now;
  return cachedAPNSToken;
}

async function sendAPNSNotification(deviceToken, title, body, rideId) {
  if (!config.apns) return;
  const authorization = `bearer ${await getAPNSToken()}`;
  const session = connectHTTP2(`https://${config.apns.host}`);
  try {
    await new Promise((resolve, reject) => {
      session.once("connect", resolve);
      session.once("error", reject);
    });
    const request = session.request({
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization,
      "apns-topic": config.appleBundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    });
    const response = await new Promise((resolve, reject) => {
      let status;
      let responseBody = "";
      request.on("response", (headers) => { status = headers[":status"]; });
      request.setEncoding("utf8");
      request.on("data", (chunk) => { responseBody += chunk; });
      request.on("end", () => resolve({ status, body: responseBody }));
      request.on("error", reject);
      request.setTimeout(10_000, () => request.destroy(new Error("APNs request timed out.")));
      request.end(JSON.stringify({
        aps: { alert: { title, body }, sound: "default" },
        rideId,
      }));
    });
    if (response.status === 410) {
      await pool.query("DELETE FROM notification_devices WHERE device_token = $1", [deviceToken]);
    } else if (response.status < 200 || response.status >= 300) {
      throw new Error(`APNs returned ${response.status}: ${response.body}`);
    }
  } finally {
    session.close();
  }
}

async function notifyUser(userId, title, body, rideId) {
  if (!config.apns) return;
  try {
    const result = await pool.query("SELECT device_token FROM notification_devices WHERE user_id = $1", [userId]);
    await Promise.all(result.rows.map(({ device_token: deviceToken }) =>
      sendAPNSNotification(deviceToken, title, body, rideId)
        .catch((error) => console.error("Could not send APNs notification:", error))));
  } catch (error) {
    console.error("Could not look up APNs devices:", error);
  }
}

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
        const confirmed = await pool.query(
          `UPDATE rides SET status = 'confirmed'
           WHERE id = $1 AND payment_intent_id = $2 AND status = 'awaiting_payment'
           RETURNING rider_user_id, driver_user_id`,
          [intent.metadata.rideId, intent.id],
        );
        if (confirmed.rowCount) {
          const { rider_user_id: riderId, driver_user_id: driverId } = confirmed.rows[0];
          await Promise.all([
            notifyUser(riderId, "Ride confirmed", "Your payment is complete and your ride is confirmed.", intent.metadata.rideId),
            notifyUser(driverId, "Ride confirmed", "Payment is complete. Your assigned ride is confirmed.", intent.metadata.rideId),
          ]);
        }
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
               SELECT 1 FROM rides WHERE driver_user_id = $1 AND status IN ('awaiting_payment', 'confirmed', 'refund_pending')
             )`,
          [result.rows[0].driver_user_id],
        );
        await notifyUser(result.rows[0].driver_user_id, "Ride reservation released", "The rider's pending payment was canceled.", intent.metadata?.rideId);
      }
    } else if (event.type === "refund.updated" || event.type === "refund.failed") {
      const refund = event.data.object;
      const rideId = refund.metadata?.rideId;
      if (rideId && refund.status === "succeeded") {
        const finalized = await finalizeRideRefund(rideId, refund.id);
        if (finalized) {
          await Promise.all([
            notifyUser(finalized.riderId, "Ride canceled", "Your full refund has been processed by Stripe.", rideId),
            notifyUser(finalized.driverId, "Ride canceled", "The rider canceled this ride.", rideId),
          ]);
        }
      } else if (rideId && refund.status === "failed") {
        const failed = await pool.query(
          `UPDATE rides SET status = 'confirmed', refund_id = NULL
           WHERE id = $1 AND status = 'refund_pending' AND (refund_id IS NULL OR refund_id = $2)
           RETURNING rider_user_id`,
          [rideId, refund.id],
        );
        if (failed.rowCount) {
          await notifyUser(failed.rows[0].rider_user_id, "Refund could not be completed", "Your ride remains confirmed. Contact support if you still need help.", rideId);
        }
      }
    }
    return res.json({ received: true });
  } catch (error) {
    console.error("Stripe webhook processing failed:", error);
    return res.status(500).json({ error: "Webhook processing failed." });
  }
});

const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 120,
  standardHeaders: true,
  legacyHeaders: false,
});
const signInLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 10,
  standardHeaders: true,
  legacyHeaders: false,
});
app.use("/v1", apiLimiter);
app.use("/v1/auth/apple", signInLimiter);
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

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  })[character]);
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

app.put("/v1/notifications/device", authenticate, asyncRoute(async (req, res) => {
  const token = req.body?.deviceToken;
  if (typeof token !== "string" || !/^[a-fA-F0-9]{64}$/.test(token)) {
    return res.status(400).json({ error: "A valid APNs device token is required." });
  }
  await pool.query(
    `INSERT INTO notification_devices (user_id, device_token, updated_at)
     VALUES ($1, $2, now())
     ON CONFLICT (device_token) DO UPDATE SET user_id = EXCLUDED.user_id, updated_at = now()`,
    [req.user.id, token.toLowerCase()],
  );
  await pool.query(
    `DELETE FROM notification_devices
     WHERE user_id = $1 AND device_token NOT IN (
       SELECT device_token FROM notification_devices
       WHERE user_id = $1 ORDER BY updated_at DESC LIMIT 10
     )`,
    [req.user.id],
  );
  return res.json({ registered: true });
}));

app.delete("/v1/notifications/device", authenticate, asyncRoute(async (req, res) => {
  const token = req.body?.deviceToken;
  if (typeof token !== "string" || !/^[a-fA-F0-9]{64}$/.test(token)) {
    return res.status(400).json({ error: "A valid APNs device token is required." });
  }
  await pool.query(
    "DELETE FROM notification_devices WHERE user_id = $1 AND device_token = $2",
    [req.user.id, token.toLowerCase()],
  );
  return res.json({ unregistered: true });
}));

app.post("/v1/fare-estimate", asyncRoute(async (req, res) => {
  const { pickup, destination, rideType } = req.body ?? {};
  if (!validateLocationPair(req.body)) {
    return res.status(400).json({ error: "Valid pickup and destination are required." });
  }
  const estimate = calculateRideFare(pickup, destination, rideType, config.farePricing);
  if (!estimate) return res.status(400).json({ error: "This ride type or trip distance is not supported." });
  return res.json({ ...estimate, currency: config.currency });
}));

app.get("/v1/shared-trips/:token", asyncRoute(async (req, res) => {
  const token = req.params.token;
  if (typeof token !== "string" || !/^[A-Za-z0-9_-]{40,60}$/.test(token)) {
    return res.status(404).json({ error: "Shared trip not found." });
  }
  const tokenHash = createHash("sha256").update(token).digest("hex");
  const result = await pool.query(
    `SELECT r.id, r.pickup_label AS pickup, r.destination_label AS destination,
            r.status, r.scheduled_at AS "scheduledAt", r.created_at AS "createdAt",
            ST_Y(d.location::geometry) AS "driverLatitude",
            ST_X(d.location::geometry) AS "driverLongitude"
     FROM rides r
     LEFT JOIN drivers d ON d.user_id = r.driver_user_id
     WHERE r.share_token_hash = $1
       AND r.status <> 'cancelled'
       AND COALESCE(r.completed_at, r.scheduled_at, r.created_at) > now() - interval '24 hours'`,
    [tokenHash],
  );
  if (!result.rowCount) return res.status(404).json({ error: "Shared trip not found or expired." });
  if (req.get("accept")?.includes("text/html") && req.accepts("html")) {
    const trip = result.rows[0];
    const driverLink = Number.isFinite(trip.driverLatitude) && Number.isFinite(trip.driverLongitude)
      ? `<p><a href="https://maps.apple.com/?ll=${trip.driverLatitude},${trip.driverLongitude}&amp;q=Driver">View driver's latest location</a></p>`
      : "";
    res.set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline';");
    res.set("Referrer-Policy", "no-referrer");
    return res.type("html").send(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="15"><title>Shared Tryps ride</title>
<style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;background:#f4f6f2;color:#18312a;margin:0;padding:24px}
main{max-width:520px;margin:8vh auto;background:white;padding:28px;border-radius:20px;box-shadow:0 8px 30px #18312a12}
h1{font-size:24px}.status{color:#28705f;font-weight:700}p{line-height:1.5}a{color:#28705f}</style></head>
<body><main><h1>Tryps ride</h1><p class="status">${escapeHtml(trip.status.replaceAll("_", " "))}</p>
<p><strong>Pickup:</strong> ${escapeHtml(trip.pickup)}</p><p><strong>Destination:</strong> ${escapeHtml(trip.destination)}</p>
${trip.scheduledAt ? `<p><strong>Scheduled:</strong> ${escapeHtml(new Date(trip.scheduledAt).toLocaleString())}</p>` : ""}
${driverLink}<p>This page refreshes every 15 seconds with the latest trip status.</p></main></body></html>`);
  }
  return res.json(result.rows[0]);
}));

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
    return res.status(201).json({ sessionToken: await createSession(claims.sub, role), role, needsDriverOnboarding: true });
  }

  return res.status(inserted.rowCount ? 201 : 200).json({
    sessionToken: await createSession(claims.sub, role),
    role,
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

app.get("/v1/driver/profile", authenticate, requireRole("driver"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT stripe_account_id, available,
            updated_at > now() - ($2::double precision * interval '1 second') AS heartbeat_fresh
     FROM drivers WHERE user_id = $1`,
    [req.user.id, config.driverHeartbeatTimeoutSeconds],
  );
  if (!result.rowCount) return res.json({ onboardingComplete: false, available: false });
  if (result.rows[0].available && !result.rows[0].heartbeat_fresh) {
    await pool.query("UPDATE drivers SET available = false WHERE user_id = $1", [req.user.id]);
  }
  const account = await stripe.accounts.retrieve(result.rows[0].stripe_account_id);
  return res.json({
    onboardingComplete: Boolean(account.details_submitted && account.payouts_enabled),
    available: result.rows[0].available && result.rows[0].heartbeat_fresh,
  });
}));

app.post("/v1/driver/heartbeat", authenticate, requireRole("driver"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    `UPDATE drivers SET updated_at = now()
     WHERE user_id = $1
       AND available = true
       AND updated_at > now() - ($2::double precision * interval '1 second')
     RETURNING user_id`,
    [req.user.id, config.driverHeartbeatTimeoutSeconds],
  );
  return res.json({ available: result.rowCount > 0 });
}));

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
    `UPDATE drivers
     SET location = ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography,
         location_updated_at = now(),
         updated_at = now()
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
  const update = await pool.query(
    `UPDATE drivers SET available = $2, updated_at = now()
     WHERE user_id = $1
       AND ($2 = false OR NOT EXISTS (
         SELECT 1 FROM rides WHERE driver_user_id = $1 AND status IN ('awaiting_payment', 'confirmed', 'refund_pending')
       ))`,
    [req.user.id, req.body.available],
  );
  if (!update.rowCount) return res.status(409).json({ error: "Finish your assigned ride before going online again." });
  return res.json({ available: req.body.available });
}));

app.get("/v1/driver/rides", authenticate, requireRole("driver"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT id, pickup_label AS pickup, destination_label AS destination, ride_type AS "rideType",
            status, created_at AS "createdAt",
            EXISTS (SELECT 1 FROM ride_ratings rr WHERE rr.ride_id = rides.id AND rr.rater_user_id = $1) AS "hasRated"
     FROM rides
     WHERE driver_user_id = $1 AND status IN ('confirmed', 'completed')
     ORDER BY (status = 'confirmed') DESC, created_at DESC
     LIMIT 50`,
    [req.user.id],
  );
  return res.json({ rides: result.rows });
}));

app.post("/v1/driver/rides/:rideId/complete", authenticate, requireRole("driver"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    `UPDATE rides SET status = 'completed', completed_at = now()
     WHERE id = $1 AND driver_user_id = $2 AND status = 'confirmed'
     RETURNING id, rider_user_id`,
    [req.params.rideId, req.user.id],
  );
  if (!result.rowCount) return res.status(404).json({ error: "Active ride not found." });
  await pool.query(
    "UPDATE drivers SET available = true, updated_at = now() WHERE user_id = $1",
    [req.user.id],
  );
  await notifyUser(result.rows[0].rider_user_id, "Ride completed", "Your driver marked the ride complete.", result.rows[0].id);
  return res.json({ completed: true });
}));

app.post("/v1/rides", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const { pickup, destination, rideType, scheduledAt } = req.body ?? {};
  if (!validateLocationPair(req.body)) {
    return res.status(400).json({ error: "Valid pickup, destination, and ride type are required." });
  }
  const fare = calculateRideFare(pickup, destination, rideType, config.farePricing);
  if (!fare) return res.status(400).json({ error: "This ride type or trip distance is not supported." });
  const { amountCents } = fare;

  const rideId = randomUUID();
  const shareToken = randomBytes(32).toString("base64url");
  const shareTokenHash = createHash("sha256").update(shareToken).digest("hex");
  const shareUrl = `${config.tripShareBaseUrl}/${shareToken}`;
  const requestedPickupTime = scheduledAt == null ? null : new Date(scheduledAt);
  if (scheduledAt != null && (
    typeof scheduledAt !== "string" ||
    Number.isNaN(requestedPickupTime.getTime()) ||
    requestedPickupTime.getTime() < Date.now() + 15 * 60_000 ||
    requestedPickupTime.getTime() > Date.now() + 30 * 24 * 60 * 60_000
  )) {
    return res.status(400).json({ error: "Scheduled pickups must be 15 minutes to 30 days in the future." });
  }

  if (requestedPickupTime) {
    await pool.query(
      `INSERT INTO rides (
        id, rider_user_id, pickup_label, pickup, destination_label, destination,
        ride_type, amount_cents, currency, status, scheduled_at, share_token_hash
      ) VALUES (
        $1, $2, $3, ST_SetSRID(ST_MakePoint($4, $5), 4326)::geography,
        $6, ST_SetSRID(ST_MakePoint($7, $8), 4326)::geography, $9, $10, $11, 'scheduled', $12, $13
      )`,
      [
        rideId, req.user.id, pickup.label.trim(), pickup.longitude, pickup.latitude,
        destination.label.trim(), destination.longitude, destination.latitude,
        rideType, amountCents, config.currency, requestedPickupTime.toISOString(), shareTokenHash,
      ],
    );
    return res.status(201).json({
      rideId,
      status: "scheduled",
      scheduledAt: requestedPickupTime.toISOString(),
      amountCents,
      currency: config.currency,
      shareUrl,
    });
  }

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
         AND location_updated_at > now() - ($4::double precision * interval '1 second')
         AND ST_DWithin(
           location,
           ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography,
           $3
         )
       ORDER BY location <-> ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography
       LIMIT 1
       FOR UPDATE SKIP LOCKED`,
      [pickup.longitude, pickup.latitude, config.matchingRadiusMeters, config.driverHeartbeatTimeoutSeconds],
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
        ride_type, amount_cents, currency, payment_intent_id, status, payment_created_at, share_token_hash
      ) VALUES (
        $1, $2, $3, $4, ST_SetSRID(ST_MakePoint($5, $6), 4326)::geography,
        $7, ST_SetSRID(ST_MakePoint($8, $9), 4326)::geography, $10, $11, $12, $13, 'awaiting_payment', now(), $14
      )`,
      [
        rideId, req.user.id, driver.user_id, pickup.label.trim(), pickup.longitude, pickup.latitude,
        destination.label.trim(), destination.longitude, destination.latitude,
        rideType, amountCents, config.currency, paymentIntent.id, shareTokenHash,
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
      shareUrl,
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
  const scheduledCancellation = await pool.query(
    `UPDATE rides SET status = 'cancelled'
     WHERE id = $1 AND rider_user_id = $2 AND status = 'scheduled'
     RETURNING id`,
    [req.params.rideId, req.user.id],
  );
  if (scheduledCancellation.rowCount) return res.json({ cancelled: true });

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
           SELECT 1 FROM rides WHERE driver_user_id = $1 AND status IN ('awaiting_payment', 'confirmed', 'refund_pending')
         )`,
      [cancelled.rows[0].driver_user_id],
    );
  }
  return res.json({ cancelled: cancelled.rowCount > 0 });
}));

async function finalizeRideRefund(rideId, refundId) {
  const client = await pool.connect();
  let transactionOpen = false;
  try {
    await client.query("BEGIN");
    transactionOpen = true;
    const result = await client.query(
      `UPDATE rides
       SET status = 'cancelled', refunded_at = COALESCE(refunded_at, now()), refund_id = $2
       WHERE id = $1 AND status = 'refund_pending' AND (refund_id IS NULL OR refund_id = $2)
       RETURNING rider_user_id, driver_user_id`,
      [rideId, refundId],
    );
    if (!result.rowCount) {
      await client.query("ROLLBACK");
      transactionOpen = false;
      return null;
    }
    const { rider_user_id: riderId, driver_user_id: driverId } = result.rows[0];
    await client.query(
      `UPDATE drivers SET available = true, updated_at = now()
       WHERE user_id = $1
         AND NOT EXISTS (
           SELECT 1 FROM rides
           WHERE driver_user_id = $1 AND status IN ('awaiting_payment', 'confirmed', 'refund_pending')
         )`,
      [driverId],
    );
    await client.query("COMMIT");
    transactionOpen = false;
    return { riderId, driverId };
  } catch (error) {
    if (transactionOpen) await client.query("ROLLBACK").catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

app.post("/v1/rides/:rideId/refund", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const client = await pool.connect();
  let transactionOpen = false;
  let ride;
  try {
    await client.query("BEGIN");
    transactionOpen = true;
    const result = await client.query(
      `SELECT payment_intent_id, status, driver_user_id, refund_id
       FROM rides WHERE id = $1 AND rider_user_id = $2 FOR UPDATE`,
      [req.params.rideId, req.user.id],
    );
    if (!result.rowCount) {
      await client.query("ROLLBACK");
      transactionOpen = false;
      return res.status(404).json({ error: "Ride not found." });
    }
    ride = result.rows[0];
    if (ride.status === "cancelled" && ride.refund_id) {
      await client.query("ROLLBACK");
      transactionOpen = false;
      return res.json({ cancelled: true, refunded: true, refundId: ride.refund_id });
    }
    if (ride.status === "confirmed") {
      await client.query(
        "UPDATE rides SET status = 'refund_pending' WHERE id = $1 AND status = 'confirmed'",
        [req.params.rideId],
      );
    } else if (ride.status !== "refund_pending") {
      await client.query("ROLLBACK");
      transactionOpen = false;
      return res.status(409).json({ error: "Only confirmed, uncompleted rides can be canceled for a full refund." });
    }
    await client.query("COMMIT");
    transactionOpen = false;

    const refund = await stripe.refunds.create(
      {
        payment_intent: ride.payment_intent_id,
        reason: "requested_by_customer",
        reverse_transfer: true,
        refund_application_fee: true,
        metadata: { rideId: req.params.rideId },
      },
      { idempotencyKey: `ride-refund-${req.params.rideId}` },
    );
    await pool.query(
      `UPDATE rides SET refund_id = $2
       WHERE id = $1 AND status = 'refund_pending' AND refund_id IS NULL`,
      [req.params.rideId, refund.id],
    );
    if (refund.status !== "succeeded") {
      return res.status(202).json({ cancelled: false, refundPending: true, refundId: refund.id });
    }

    const finalized = await finalizeRideRefund(req.params.rideId, refund.id);
    if (finalized) {
      await Promise.all([
        notifyUser(finalized.riderId, "Ride canceled", "Your full refund has been processed by Stripe.", req.params.rideId),
        notifyUser(finalized.driverId, "Ride canceled", "The rider canceled this ride.", req.params.rideId),
      ]);
    }
    return res.json({ cancelled: true, refunded: true, refundId: refund.id });
  } catch (error) {
    if (transactionOpen) await client.query("ROLLBACK").catch(() => {});
    if (error.type === "StripeInvalidRequestError") {
      await pool.query(
        "UPDATE rides SET status = 'confirmed' WHERE id = $1 AND status = 'refund_pending'",
        [req.params.rideId],
      ).catch(() => {});
      return res.status(409).json({ error: "Stripe could not refund this payment. Contact support for assistance." });
    }
    if (!transactionOpen && error.type !== "StripeAPIError" && error.type !== "StripeConnectionError" &&
        error.type !== "StripeRateLimitError" && error.type !== "StripeAuthenticationError" &&
        error.type !== "StripePermissionError" && error.type !== "StripeIdempotencyError") {
      throw error;
    }
    if (!transactionOpen) {
      return res.status(202).json({ cancelled: false, refundPending: true });
    }
    throw error;
  } finally {
    client.release();
  }
}));

app.get("/v1/rides/:rideId", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT id, pickup_label AS pickup, destination_label AS destination, ride_type AS "rideType",
            amount_cents AS "amountCents", currency, status, scheduled_at AS "scheduledAt",
            created_at AS "createdAt", payment_intent_id IS NOT NULL AS "paymentReady",
            ST_Y(d.location::geometry) AS "driverLatitude",
            ST_X(d.location::geometry) AS "driverLongitude",
            EXISTS (SELECT 1 FROM ride_ratings rr WHERE rr.ride_id = rides.id AND rr.rater_user_id = $2) AS "hasRated"
     FROM rides LEFT JOIN drivers d ON d.user_id = rides.driver_user_id
     WHERE rides.id = $1 AND rider_user_id = $2`,
    [req.params.rideId, req.user.id],
  );
  if (!result.rowCount) return res.status(404).json({ error: "Ride not found." });
  const ride = result.rows[0];
  if (ride.status === "awaiting_payment" && ride.paymentReady) {
    const paymentIntent = await pool.query("SELECT payment_intent_id FROM rides WHERE id = $1", [req.params.rideId]);
    const intent = await stripe.paymentIntents.retrieve(paymentIntent.rows[0].payment_intent_id);
    ride.paymentIntentClientSecret = intent.client_secret;
  }
  return res.json(ride);
}));

app.get("/v1/rides", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT id, pickup_label AS pickup, destination_label AS destination,
            ride_type AS "rideType", amount_cents AS "amountCents", currency, status,
            scheduled_at AS "scheduledAt", created_at AS "createdAt",
            payment_intent_id IS NOT NULL AS "paymentReady",
            ST_Y(d.location::geometry) AS "driverLatitude",
            ST_X(d.location::geometry) AS "driverLongitude",
            EXISTS (SELECT 1 FROM ride_ratings rr WHERE rr.ride_id = rides.id AND rr.rater_user_id = $1) AS "hasRated"
     FROM rides LEFT JOIN drivers d ON d.user_id = rides.driver_user_id
     WHERE rides.rider_user_id = $1
     ORDER BY COALESCE(scheduled_at, created_at) DESC
     LIMIT 100`,
    [req.user.id],
  );
  return res.json({ rides: result.rows });
}));

app.post("/v1/rides/:rideId/ratings", authenticate, asyncRoute(async (req, res) => {
  const { stars, comment = "" } = req.body ?? {};
  if (!Number.isInteger(stars) || stars < 1 || stars > 5 ||
      typeof comment !== "string" || comment.length > 500) {
    return res.status(400).json({ error: "Provide a 1–5 star rating and a comment under 500 characters." });
  }
  const ride = await pool.query(
    `SELECT rider_user_id, driver_user_id, status
     FROM rides
     WHERE id = $1 AND (rider_user_id = $2 OR driver_user_id = $2)`,
    [req.params.rideId, req.user.id],
  );
  if (!ride.rowCount) return res.status(404).json({ error: "Ride not found." });
  if (ride.rows[0].status !== "completed") {
    return res.status(409).json({ error: "Rides can only be rated after completion." });
  }
  const ratedUserId = req.user.id === ride.rows[0].rider_user_id
    ? ride.rows[0].driver_user_id
    : ride.rows[0].rider_user_id;
  try {
    await pool.query(
      `INSERT INTO ride_ratings (id, ride_id, rater_user_id, rated_user_id, stars, comment)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [randomUUID(), req.params.rideId, req.user.id, ratedUserId, stars, comment.trim()],
    );
  } catch (error) {
    if (error.code === "23505") return res.status(409).json({ error: "You have already rated this ride." });
    throw error;
  }
  return res.status(201).json({ rated: true });
}));

app.get("/v1/saved-places", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    `SELECT id, name, label, ST_Y(location::geometry) AS latitude, ST_X(location::geometry) AS longitude
     FROM saved_places WHERE user_id = $1 ORDER BY created_at LIMIT 50`,
    [req.user.id],
  );
  return res.json({ places: result.rows });
}));

app.post("/v1/saved-places", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const { name, location } = req.body ?? {};
  if (!validText(name, 60) || !isValidLocation(location)) {
    return res.status(400).json({ error: "Provide a name and valid place location." });
  }
  try {
    const result = await pool.query(
      `INSERT INTO saved_places (id, user_id, name, label, location)
       VALUES ($1, $2, $3, $4, ST_SetSRID(ST_MakePoint($5, $6), 4326)::geography)
       RETURNING id, name, label, ST_Y(location::geometry) AS latitude, ST_X(location::geometry) AS longitude`,
      [randomUUID(), req.user.id, name.trim(), location.label.trim(), location.longitude, location.latitude],
    );
    return res.status(201).json(result.rows[0]);
  } catch (error) {
    if (error.code === "23505") return res.status(409).json({ error: "A saved place already uses that name." });
    throw error;
  }
}));

app.delete("/v1/saved-places/:placeId", authenticate, requireRole("rider"), asyncRoute(async (req, res) => {
  const result = await pool.query(
    "DELETE FROM saved_places WHERE id = $1 AND user_id = $2 RETURNING id",
    [req.params.placeId, req.user.id],
  );
  if (!result.rowCount) return res.status(404).json({ error: "Saved place not found." });
  return res.json({ deleted: true });
}));

async function dispatchScheduledRides() {
  const client = await pool.connect();
  let transactionOpen = false;
  let driverId;
  const matchedRides = [];
  try {
    await client.query("BEGIN");
    transactionOpen = true;
    const scheduled = await client.query(
      `SELECT id, rider_user_id, ST_X(pickup::geometry) AS longitude, ST_Y(pickup::geometry) AS latitude,
              ride_type, amount_cents, currency
       FROM rides
       WHERE status = 'scheduled'
         AND scheduled_at <= now() + ($1::double precision * interval '1 minute')
         AND scheduled_at >= now() - interval '15 minutes'
       ORDER BY scheduled_at
       LIMIT 5
       FOR UPDATE SKIP LOCKED`,
      [config.scheduledDispatchLeadMinutes],
    );
    await client.query(
      `UPDATE rides SET status = 'cancelled'
       WHERE status = 'scheduled' AND scheduled_at < now() - interval '15 minutes'`,
    );

    for (const ride of scheduled.rows) {
      const driverResult = await client.query(
        `SELECT user_id, stripe_account_id
         FROM drivers d
         WHERE available = true
           AND location IS NOT NULL
           AND location_updated_at > now() - ($4::double precision * interval '1 second')
           AND NOT EXISTS (
             SELECT 1 FROM rides r
             WHERE r.driver_user_id = d.user_id AND r.status IN ('awaiting_payment', 'confirmed', 'refund_pending')
           )
           AND ST_DWithin(
             location,
             ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography,
             $3
           )
         ORDER BY location <-> ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography
         LIMIT 1
         FOR UPDATE OF d SKIP LOCKED`,
        [
          ride.longitude,
          ride.latitude,
          config.matchingRadiusMeters,
          config.driverHeartbeatTimeoutSeconds,
        ],
      );
      const driver = driverResult.rows[0];
      if (!driver) continue;
      driverId = driver.user_id;
      const account = await stripe.accounts.retrieve(driver.stripe_account_id);
      if (!account.details_submitted || !account.payouts_enabled) {
        await client.query("UPDATE drivers SET available = false WHERE user_id = $1", [driverId]);
        driverId = undefined;
        continue;
      }

      const applicationFeeAmount = Math.floor(ride.amount_cents * config.applicationFeeBasisPoints / 10000);
      const paymentIntent = await stripe.paymentIntents.create(
        {
          amount: ride.amount_cents,
          currency: ride.currency,
          automatic_payment_methods: { enabled: true },
          application_fee_amount: applicationFeeAmount,
          transfer_data: { destination: driver.stripe_account_id },
          metadata: { rideId: ride.id },
        },
        { idempotencyKey: `ride-payment-${ride.id}` },
      );
      await client.query(
        `UPDATE rides
         SET driver_user_id = $2, payment_intent_id = $3, payment_created_at = now(), status = 'awaiting_payment'
         WHERE id = $1 AND status = 'scheduled'`,
        [ride.id, driverId, paymentIntent.id],
      );
      await client.query("UPDATE drivers SET available = false, updated_at = now() WHERE user_id = $1", [driverId]);
      matchedRides.push({ rideId: ride.id, riderId: ride.rider_user_id });
      driverId = undefined;
    }
    await client.query("COMMIT");
    transactionOpen = false;
    await Promise.all(matchedRides.map(({ rideId, riderId }) =>
      notifyUser(riderId, "Driver matched", "A driver is ready. Open Tryps Activity to complete payment.", rideId)));
  } catch (error) {
    if (transactionOpen) await client.query("ROLLBACK").catch(() => {});
    if (driverId) {
      await pool.query(
        `UPDATE drivers SET available = true
         WHERE user_id = $1
           AND NOT EXISTS (
             SELECT 1 FROM rides WHERE driver_user_id = $1 AND status IN ('awaiting_payment', 'confirmed', 'refund_pending')
           )`,
        [driverId],
      ).catch(() => {});
    }
    console.error("Could not dispatch scheduled rides:", error);
  } finally {
    client.release();
  }
}

async function expireUnpaidRideReservations() {
  const client = await pool.connect();
  let transactionOpen = false;
  try {
    await client.query("BEGIN");
    transactionOpen = true;
    const expired = await client.query(
      `SELECT id, driver_user_id, payment_intent_id
       FROM rides
       WHERE status = 'awaiting_payment'
         AND payment_created_at < now() - ($1::double precision * interval '1 minute')
       ORDER BY payment_created_at
       LIMIT 20
       FOR UPDATE SKIP LOCKED`,
      [config.paymentReservationMinutes],
    );
    for (const ride of expired.rows) {
      let paymentStatus;
      try {
        const intent = await stripe.paymentIntents.cancel(ride.payment_intent_id);
        paymentStatus = intent.status;
      } catch {
        const intent = await stripe.paymentIntents.retrieve(ride.payment_intent_id);
        paymentStatus = intent.status;
      }

      if (paymentStatus === "succeeded") {
        await client.query(
          "UPDATE rides SET status = 'confirmed' WHERE id = $1 AND status = 'awaiting_payment'",
          [ride.id],
        );
        continue;
      }
      if (paymentStatus !== "canceled") continue;

      const cancelled = await client.query(
        "UPDATE rides SET status = 'cancelled' WHERE id = $1 AND status = 'awaiting_payment'",
        [ride.id],
      );
      if (cancelled.rowCount) {
        await client.query(
          `UPDATE drivers SET available = true
           WHERE user_id = $1
             AND NOT EXISTS (
               SELECT 1 FROM rides WHERE driver_user_id = $1 AND status IN ('awaiting_payment', 'confirmed', 'refund_pending')
             )`,
          [ride.driver_user_id],
        );
      }
    }
    await client.query("COMMIT");
    transactionOpen = false;
  } catch (error) {
    if (transactionOpen) await client.query("ROLLBACK").catch(() => {});
    console.error("Could not expire pending ride reservations:", error);
  } finally {
    client.release();
  }
}

const reservationCleanup = setInterval(expireUnpaidRideReservations, 60_000);
reservationCleanup.unref();
const scheduledRideDispatch = setInterval(dispatchScheduledRides, 60_000);
scheduledRideDispatch.unref();

app.use((error, _req, res, _next) => {
  console.error("API request failed:", error);
  if (res.headersSent) return;
  return res.status(500).json({ error: "The request could not be completed." });
});

const server = app.listen(config.port, () => {
  console.log(`Tryps API listening on port ${config.port}.`);
});

async function shutdown() {
  clearInterval(reservationCleanup);
  clearInterval(scheduledRideDispatch);
  server.close();
  await pool.end();
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
