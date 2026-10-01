"use strict";

const RIDE_TYPES = Object.freeze({
  everyday: { label: "Everyday", baseCents: 800, centsPerKm: 180 },
  comfort: { label: "Comfort", baseCents: 1200, centsPerKm: 240 },
  xl: { label: "XL", baseCents: 1600, centsPerKm: 300 },
});

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
  return 6371 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function calculateQuote(pickup, dropOff, rideType) {
  if (!validCoordinate(pickup) || !validCoordinate(dropOff)) {
    throw new TypeError("Pickup and drop-off must be valid coordinates.");
  }
  const type = RIDE_TYPES[rideType];
  if (!type) throw new TypeError("Unsupported ride type.");

  const distanceKm = distanceInKilometers(pickup, dropOff);
  if (distanceKm < 0.05 || distanceKm > 200) {
    throw new RangeError("The trip distance is outside the supported range.");
  }
  const amountCents = Math.ceil((type.baseCents + type.centsPerKm * distanceKm) / 50) * 50;
  return {
    rideType,
    rideLabel: type.label,
    distanceKm: Math.round(distanceKm * 10) / 10,
    amountCents,
    currency: "usd",
  };
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
  validCoordinate,
};
