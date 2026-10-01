"use strict";

const RIDE_TYPES = Object.freeze({
  everyday: { label: "Everyday", baseFareCents: 250, centsPerKm: 125 },
  comfort: { label: "Comfort", baseFareCents: 400, centsPerKm: 175 },
  xl: { label: "XL", baseFareCents: 600, centsPerKm: 225 },
});

const PRICING_VERSION = 2;
const BOOKING_FEE_CENTS = 150;
const MINIMUM_FARE_CENTS = 500;
const MAX_TRIP_DISTANCE_METERS = 200_000;
const MIN_TRIP_DISTANCE_METERS = 50;
const DRIVER_LOCATION_MAX_AGE_MS = 2 * 60 * 1000;
const DRIVER_LOCATION_FUTURE_TOLERANCE_MS = 30 * 1000;

function validCoordinate(value) {
  return value !== null &&
    typeof value === "object" &&
    Number.isFinite(value.latitude) &&
    Number.isFinite(value.longitude) &&
    value.latitude >= -90 &&
    value.latitude <= 90 &&
    value.longitude >= -180 &&
    value.longitude <= 180;
}

function distanceInKilometers(first, second) {
  const radians = (degrees) => degrees * Math.PI / 180;
  const latitudeDelta = radians(second.latitude - first.latitude);
  const longitudeDelta = radians(second.longitude - first.longitude);
  const value = Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(radians(first.latitude)) *
    Math.cos(radians(second.latitude)) *
    Math.sin(longitudeDelta / 2) ** 2;
  const boundedValue = Math.min(1, Math.max(0, value));
  return 6371 * 2 * Math.atan2(Math.sqrt(boundedValue), Math.sqrt(1 - boundedValue));
}

function calculateQuote(pickup, dropOff, rideType, routeDistanceMeters) {
  if (!validCoordinate(pickup) || !validCoordinate(dropOff)) {
    throw new TypeError("Pickup and drop-off must be valid coordinates.");
  }
  const type = RIDE_TYPES[rideType];
  if (!type) throw new TypeError("Unsupported ride type.");

  if (!Number.isSafeInteger(routeDistanceMeters) ||
      routeDistanceMeters < MIN_TRIP_DISTANCE_METERS ||
      routeDistanceMeters > MAX_TRIP_DISTANCE_METERS) {
    throw new RangeError("The trip distance is outside the supported range.");
  }
  const distanceKm = routeDistanceMeters / 1000;
  const distanceFareCents = Math.ceil(type.centsPerKm * routeDistanceMeters / 1000);
  const fareBeforeMinimumCents = type.baseFareCents + distanceFareCents + BOOKING_FEE_CENTS;
  const minimumFareAdjustmentCents = Math.max(0, MINIMUM_FARE_CENTS - fareBeforeMinimumCents);
  return {
    rideType,
    rideLabel: type.label,
    pricingVersion: PRICING_VERSION,
    routeDistanceMeters,
    distanceKm: Math.round(distanceKm * 10) / 10,
    baseFareCents: type.baseFareCents,
    distanceFareCents,
    bookingFeeCents: BOOKING_FEE_CENTS,
    minimumFareAdjustmentCents,
    amountCents: fareBeforeMinimumCents + minimumFareAdjustmentCents,
    currency: "usd",
  };
}

function normalizeRidePreferences(value) {
  if (value === undefined) {
    return { womanDriverForWomenAndMinors: false, ecoFriendlyVehicle: false };
  }
  if (value === null || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).some((key) =>
        !["womanDriverForWomenAndMinors", "ecoFriendlyVehicle"].includes(key)
      ) ||
      Object.values(value).some((enabled) => typeof enabled !== "boolean")) {
    throw new TypeError("Ride preferences are invalid.");
  }
  return {
    womanDriverForWomenAndMinors: value.womanDriverForWomenAndMinors ?? false,
    ecoFriendlyVehicle: value.ecoFriendlyVehicle ?? false,
  };
}

function normalizeDriverRidePreferences(acceptsWomenAndMinorsRides, ecoFriendlyVehicle) {
  if ((acceptsWomenAndMinorsRides !== undefined &&
      typeof acceptsWomenAndMinorsRides !== "boolean") ||
      (ecoFriendlyVehicle !== undefined && typeof ecoFriendlyVehicle !== "boolean")) {
    throw new TypeError("Driver ride preferences are invalid.");
  }
  return {
    acceptsWomenAndMinorsRides: acceptsWomenAndMinorsRides === true,
    ecoFriendlyVehicle: ecoFriendlyVehicle === true,
  };
}

function isFreshDriverLocation(updatedAtMillis, nowMillis, maxAgeMillis = DRIVER_LOCATION_MAX_AGE_MS) {
  return Number.isFinite(updatedAtMillis) &&
    updatedAtMillis <= nowMillis + DRIVER_LOCATION_FUTURE_TOLERANCE_MS &&
    nowMillis - updatedAtMillis <= maxAgeMillis;
}

function matchesRidePreferences(driver, preferences = {}) {
  return (!preferences.womanDriverForWomenAndMinors ||
      driver.acceptsWomenAndMinorsRides === true) &&
    (!preferences.ecoFriendlyVehicle || driver.ecoFriendlyVehicle === true);
}

function rankNearbyDrivers(drivers, pickup, radiusKm, nowMillis, preferences = {}) {
  if (!validCoordinate(pickup) || !Number.isFinite(radiusKm) || radiusKm <= 0) return [];
  return drivers
    .filter((driver) => driver.available === true && driver.verified === true &&
      matchesRidePreferences(driver, preferences) &&
      validCoordinate(driver.location) &&
      isFreshDriverLocation(driver.locationUpdatedAtMillis, nowMillis))
    .map((driver) => ({
      ...driver,
      distanceKm: distanceInKilometers(pickup, driver.location),
    }))
    .filter((driver) => driver.distanceKm <= radiusKm)
    .sort((first, second) =>
      first.distanceKm - second.distanceKm || first.uid.localeCompare(second.uid))
    .slice(0, 10);
}

function canTransitionRide(current, next) {
  const transitions = {
    driver_assigned: ["en_route"],
    en_route: ["arrived"],
    arrived: ["in_progress"],
    in_progress: ["completed"],
  };
  return transitions[current]?.includes(next) ?? false;
}

module.exports = {
  RIDE_TYPES,
  calculateQuote,
  canTransitionRide,
  distanceInKilometers,
  isFreshDriverLocation,
  matchesRidePreferences,
  normalizeDriverRidePreferences,
  normalizeRidePreferences,
  rankNearbyDrivers,
  validCoordinate,
};
