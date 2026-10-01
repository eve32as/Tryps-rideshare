"use strict";

const RIDE_TYPES = Object.freeze({
  everyday: { label: "Everyday", baseFareCents: 800, centsPerKm: 180 },
  comfort: { label: "Comfort", baseFareCents: 1200, centsPerKm: 240 },
  xl: { label: "XL", baseFareCents: 1600, centsPerKm: 300 },
});

const PRICING_VERSION = 1;
const ROUTE_DISTANCE_FACTOR = 1.25;
const BOOKING_FEE_CENTS = 200;
const MINIMUM_FARE_CENTS = 1100;
const MAX_TRIP_DISTANCE_KM = 200;
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

function calculateQuote(pickup, dropOff, rideType) {
  if (!validCoordinate(pickup) || !validCoordinate(dropOff)) {
    throw new TypeError("Pickup and drop-off must be valid coordinates.");
  }
  const type = RIDE_TYPES[rideType];
  if (!type) throw new TypeError("Unsupported ride type.");

  const straightLineDistanceKm = distanceInKilometers(pickup, dropOff);
  if (straightLineDistanceKm < 0.05 ||
      straightLineDistanceKm * ROUTE_DISTANCE_FACTOR > MAX_TRIP_DISTANCE_KM) {
    throw new RangeError("The trip distance is outside the supported range.");
  }
  const distanceKm = Math.round(straightLineDistanceKm * ROUTE_DISTANCE_FACTOR * 10) / 10;
  const distanceFareCents = Math.ceil(type.centsPerKm * distanceKm);
  const fareBeforeMinimumCents = type.baseFareCents + distanceFareCents + BOOKING_FEE_CENTS;
  const minimumFareAdjustmentCents = Math.max(0, MINIMUM_FARE_CENTS - fareBeforeMinimumCents);
  return {
    rideType,
    rideLabel: type.label,
    pricingVersion: PRICING_VERSION,
    distanceKm,
    straightLineDistanceKm: Math.round(straightLineDistanceKm * 10) / 10,
    baseFareCents: type.baseFareCents,
    distanceFareCents,
    bookingFeeCents: BOOKING_FEE_CENTS,
    minimumFareAdjustmentCents,
    amountCents: fareBeforeMinimumCents + minimumFareAdjustmentCents,
    currency: "usd",
  };
}

function isFreshDriverLocation(updatedAtMillis, nowMillis, maxAgeMillis = DRIVER_LOCATION_MAX_AGE_MS) {
  return Number.isFinite(updatedAtMillis) &&
    updatedAtMillis <= nowMillis + DRIVER_LOCATION_FUTURE_TOLERANCE_MS &&
    nowMillis - updatedAtMillis <= maxAgeMillis;
}

function rankNearbyDrivers(drivers, pickup, radiusKm, nowMillis) {
  if (!validCoordinate(pickup) || !Number.isFinite(radiusKm) || radiusKm <= 0) return [];
  return drivers
    .filter((driver) => driver.available === true && driver.verified === true &&
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
  rankNearbyDrivers,
  validCoordinate,
};
