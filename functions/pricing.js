"use strict";

const EARTH_RADIUS_METERS = 6_371_000;

function calculateSurgeMultiplier(demandCount, availableDriverCount) {
  const demand = validCount(demandCount);
  const drivers = validCount(availableDriverCount);
  if (demand >= 4 && demand >= 2 * Math.max(drivers, 1)) return 1.5;
  if (demand >= 2 && demand > drivers) return 1.25;
  return 1;
}

function distanceMeters(first, second) {
  const lat1 = first.latitude * Math.PI / 180;
  const lat2 = second.latitude * Math.PI / 180;
  const latitudeDelta = lat2 - lat1;
  const longitudeDelta = (second.longitude - first.longitude) * Math.PI / 180;
  const haversine = Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(longitudeDelta / 2) ** 2;
  return 2 * EARTH_RADIUS_METERS * Math.asin(Math.sqrt(Math.min(1, haversine)));
}

function validCount(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

module.exports = { calculateSurgeMultiplier, distanceMeters };
