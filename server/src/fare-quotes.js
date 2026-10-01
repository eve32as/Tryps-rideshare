import { SignJWT, jwtVerify } from "jose";
import { calculateRideFare } from "./validation.js";

const quoteLifetimeSeconds = 10 * 60;

export async function createFareQuote({
  pickup,
  destination,
  rideType,
  routeDistanceMeters,
  pricing,
  currency,
  signingKey,
  now = Date.now(),
}) {
  const fare = calculateRideFare(routeDistanceMeters, rideType, pricing);
  if (!fare) return undefined;
  const issuedAt = Math.floor(now / 1000);
  const expiresAt = new Date((issuedAt + quoteLifetimeSeconds) * 1000).toISOString();
  const fareQuoteToken = await new SignJWT({
    purpose: "fare_quote",
    pickup: { latitude: pickup.latitude, longitude: pickup.longitude },
    destination: { latitude: destination.latitude, longitude: destination.longitude },
    rideType,
    fare: { ...fare, currency },
  })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt(issuedAt)
    .setExpirationTime(issuedAt + quoteLifetimeSeconds)
    .sign(signingKey);
  return { ...fare, currency, fareQuoteToken, expiresAt };
}

export async function verifyFareQuote({
  token,
  pickup,
  destination,
  rideType,
  signingKey,
  now = Date.now(),
}) {
  if (typeof token !== "string" || token.length > 4096) return undefined;
  try {
    const { payload } = await jwtVerify(token, signingKey, {
      algorithms: ["HS256"],
      currentDate: new Date(now),
    });
    const quotePickup = payload.pickup;
    const quoteDestination = payload.destination;
    const fare = payload.fare;
    if (
      payload.purpose !== "fare_quote" ||
      payload.rideType !== rideType ||
      quotePickup?.latitude !== pickup.latitude ||
      quotePickup?.longitude !== pickup.longitude ||
      quoteDestination?.latitude !== destination.latitude ||
      quoteDestination?.longitude !== destination.longitude ||
      !Number.isSafeInteger(fare?.amountCents) ||
      fare.amountCents <= 0 ||
      !Number.isFinite(fare?.estimatedDistanceKm) ||
      fare.estimatedDistanceKm < 0 ||
      typeof fare?.currency !== "string"
    ) {
      return undefined;
    }
    return fare;
  } catch {
    return undefined;
  }
}
