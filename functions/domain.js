"use strict";

const RIDE_TYPES = Object.freeze({
  everyday: { label: "Everyday", baseFareCents: 250, centsPerKm: 125 },
  comfort: { label: "Comfort", baseFareCents: 400, centsPerKm: 175 },
  xl: { label: "XL", baseFareCents: 600, centsPerKm: 225 },
});

const PRICING_VERSION = 3;
const BOOKING_FEE_CENTS = 150;
const MINIMUM_FARE_CENTS = 500;
const MAX_TRIP_DISTANCE_METERS = 200_000;
const MIN_TRIP_DISTANCE_METERS = 50;
const DRIVER_LOCATION_MAX_AGE_MS = 2 * 60 * 1000;
const DRIVER_LOCATION_FUTURE_TOLERANCE_MS = 30 * 1000;
const MAX_SURGE_MULTIPLIER = 1.5;
const SERVICE_AREA_CENTER = Object.freeze({ latitude: 37.7749, longitude: -122.4194 });
const SERVICE_AREA_RADIUS_KM = 30;
const DEMAND_HEATMAP_MIN_COUNT = 3;
const DEMAND_HEATMAP_MAX_AGE_MS = 30 * 60 * 1000;
const DEMAND_HEATMAP_RADIUS_KM = 15;
const GEOHASH_ALPHABET = "0123456789bcdefghjkmnpqrstuvwxyz";

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

function isWithinServiceArea(coordinate) {
  return validCoordinate(coordinate) &&
    distanceInKilometers(SERVICE_AREA_CENTER, coordinate) <= SERVICE_AREA_RADIUS_KM;
}

function geohashCellCenter(hash) {
  if (typeof hash !== "string" || hash.length !== 5 ||
      [...hash].some((character) => !GEOHASH_ALPHABET.includes(character))) {
    return null;
  }
  let latitude = [-90, 90];
  let longitude = [-180, 180];
  let longitudeBit = true;
  for (const character of hash) {
    const value = GEOHASH_ALPHABET.indexOf(character);
    for (let bit = 4; bit >= 0; bit -= 1) {
      const interval = longitudeBit ? longitude : latitude;
      const midpoint = (interval[0] + interval[1]) / 2;
      if ((value >> bit) & 1) interval[0] = midpoint;
      else interval[1] = midpoint;
      longitudeBit = !longitudeBit;
    }
  }
  return {
    latitude: (latitude[0] + latitude[1]) / 2,
    longitude: (longitude[0] + longitude[1]) / 2,
  };
}

function aggregateDemandHeatmap(rides, driverLocation, nowMillis) {
  if (!validCoordinate(driverLocation) || !Number.isFinite(nowMillis)) return [];
  const counts = new Map();
  for (const ride of rides) {
    if (!["searching_driver", "dispatching", "offered"].includes(ride.status) ||
        !Number.isFinite(ride.updatedAtMillis) ||
        nowMillis - ride.updatedAtMillis < 0 ||
        nowMillis - ride.updatedAtMillis > DEMAND_HEATMAP_MAX_AGE_MS ||
        !geohashCellCenter(ride.demandZone)) continue;
    counts.set(ride.demandZone, (counts.get(ride.demandZone) ?? 0) + 1);
  }
  return [...counts.entries()].flatMap(([geohash, count]) => {
    const center = geohashCellCenter(geohash);
    if (count < DEMAND_HEATMAP_MIN_COUNT ||
        !isWithinServiceArea(center) ||
        distanceInKilometers(driverLocation, center) > DEMAND_HEATMAP_RADIUS_KM) return [];
    return [{
      geohash,
      ...center,
      demandBand: count <= 5 ? "3–5" : count <= 10 ? "6–10" : "11+",
    }];
  }).sort((first, second) => first.geohash.localeCompare(second.geohash));
}

function calculateQuote(pickup, dropOff, rideType, routeDistanceMeters, surgeMultiplier = 1) {
  if (!validCoordinate(pickup) || !validCoordinate(dropOff)) {
    throw new TypeError("Pickup and drop-off must be valid coordinates.");
  }
  const type = RIDE_TYPES[rideType];
  if (!type) throw new TypeError("Unsupported ride type.");
  if (![1, 1.25, MAX_SURGE_MULTIPLIER].includes(surgeMultiplier)) {
    throw new RangeError("The demand multiplier is outside the supported range.");
  }

  if (!Number.isSafeInteger(routeDistanceMeters) ||
      routeDistanceMeters < MIN_TRIP_DISTANCE_METERS ||
      routeDistanceMeters > MAX_TRIP_DISTANCE_METERS) {
    throw new RangeError("The trip distance is outside the supported range.");
  }
  const distanceKm = routeDistanceMeters / 1000;
  const distanceFareCents = Math.ceil(type.centsPerKm * routeDistanceMeters / 1000);
  const surgeAdjustmentCents = Math.ceil(
    (type.baseFareCents + distanceFareCents) * (surgeMultiplier - 1)
  );
  const fareBeforeMinimumCents =
    type.baseFareCents + distanceFareCents + surgeAdjustmentCents + BOOKING_FEE_CENTS;
  const minimumFareAdjustmentCents = Math.max(0, MINIMUM_FARE_CENTS - fareBeforeMinimumCents);
  return {
    rideType,
    rideLabel: type.label,
    pricingVersion: PRICING_VERSION,
    routeDistanceMeters,
    distanceKm: Math.round(distanceKm * 10) / 10,
    baseFareCents: type.baseFareCents,
    distanceFareCents,
    surgeMultiplier,
    surgeAdjustmentCents,
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

function calculateDemandSurgeMultiplier(demandCount, supplyCount) {
  if (!Number.isSafeInteger(demandCount) || demandCount < 0 ||
      !Number.isSafeInteger(supplyCount) || supplyCount < 0) {
    throw new TypeError("Demand and supply counts must be non-negative integers.");
  }
  if (demandCount >= 4 && demandCount >= Math.max(1, supplyCount) * 2) return MAX_SURGE_MULTIPLIER;
  if (demandCount >= 2 && demandCount >= Math.max(1, supplyCount)) return 1.25;
  return 1;
}

function rankNearbyDrivers(drivers, pickup, radiusKm, nowMillis, preferences = {}, limit = 10) {
  if (!validCoordinate(pickup) || !Number.isFinite(radiusKm) || radiusKm <= 0) return [];
  if (!Number.isSafeInteger(limit) || limit < 0) return [];
  return drivers
    .filter((driver) => driver.available === true && driver.verified === true &&
      matchesRidePreferences(driver, preferences) &&
      validCoordinate(driver.location) &&
      isWithinServiceArea(driver.location) &&
      isFreshDriverLocation(driver.locationUpdatedAtMillis, nowMillis))
    .map((driver) => ({
      ...driver,
      distanceKm: distanceInKilometers(pickup, driver.location),
      estimatedPickupMinutes: distanceInKilometers(pickup, driver.location) / 25 * 60 +
        Math.max(0, nowMillis - driver.locationUpdatedAtMillis) / 60_000 * 0.25,
    }))
    .filter((driver) => driver.distanceKm <= radiusKm)
    .sort((first, second) =>
      first.estimatedPickupMinutes - second.estimatedPickupMinutes ||
      first.distanceKm - second.distanceKm || first.uid.localeCompare(second.uid))
    .slice(0, limit);
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
  aggregateDemandHeatmap,
  canTransitionRide,
  calculateDemandSurgeMultiplier,
  distanceInKilometers,
  isFreshDriverLocation,
  isWithinServiceArea,
  geohashCellCenter,
  matchesRidePreferences,
  normalizeDriverRidePreferences,
  normalizeRidePreferences,
  rankNearbyDrivers,
  validCoordinate,
};
