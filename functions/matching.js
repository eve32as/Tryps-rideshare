"use strict";

function rankRideRecommendations(candidates, matrix, metrics = {}) {
  const etaByDestination = new Map();
  for (const route of matrix) {
    if (!route || typeof route !== "object") continue;
    if (route.condition !== "ROUTE_EXISTS" || route.status?.code > 0) continue;
    const eta = Number.parseInt(route.duration, 10);
    if (!Number.isInteger(route.destinationIndex) || !Number.isFinite(eta) || eta < 0) continue;
    etaByDestination.set(route.destinationIndex, {
      pickupEtaSeconds: eta,
      pickupDistanceMeters: Number.isFinite(route.distanceMeters) ? route.distanceMeters : null,
    });
  }

  const reliabilityPenaltySeconds = calculateReliabilityPenalty(metrics);
  return candidates.map((candidate, index) => {
    const route = etaByDestination.get(index);
    return route ? {
      rideId: candidate.id,
      ...route,
      reliabilityPenaltySeconds,
      matchingScoreSeconds: route.pickupEtaSeconds + reliabilityPenaltySeconds,
    } : null;
  }).filter(Boolean).sort((a, b) =>
    a.matchingScoreSeconds - b.matchingScoreSeconds ||
    a.pickupEtaSeconds - b.pickupEtaSeconds ||
    a.rideId.localeCompare(b.rideId));
}

function filterCompatibleRides(candidates, driverCategory) {
  const category = normalizeCategory(driverCategory) ?? "STANDARD";
  return candidates.filter(({ vehicleCategory }) => {
    const requestedCategory = vehicleCategory == null ? "ANY" : normalizeCategory(vehicleCategory);
    if (!requestedCategory) return false;
    return requestedCategory === "ANY" || category === "ANY" || requestedCategory === category;
  });
}

function isValidDriverCategory(category) {
  return ["STANDARD", "XL", "ACCESSIBLE", "LUXURY"].includes(category);
}

function calculateReliabilityPenalty(metrics = {}) {
  const cancelled = nonNegativeCount(metrics.cancellationCount);
  const completed = nonNegativeCount(metrics.completedRideCount);
  const etaSamples = nonNegativeCount(metrics.etaSampleCount);
  const averageEtaError = finiteNonNegative(metrics.averageEtaErrorSeconds);
  const cancellationRate = (cancelled + 1) / (cancelled + completed + 10);
  const etaPenalty = etaSamples >= 3 ? Math.min(averageEtaError, 600) * 0.5 : 0;
  return Math.round(Math.min(900, cancellationRate * 600 + etaPenalty));
}

function applyMatchingMetricEvent(metrics = {}, event) {
  const updated = {
    cancellationCount: nonNegativeCount(metrics.cancellationCount),
    completedRideCount: nonNegativeCount(metrics.completedRideCount),
    etaSampleCount: nonNegativeCount(metrics.etaSampleCount),
    averageEtaErrorSeconds: finiteNonNegative(metrics.averageEtaErrorSeconds),
  };
  if (event.type === "cancellation") {
    updated.cancellationCount += 1;
  } else if (event.type === "completion") {
    updated.completedRideCount += 1;
  } else if (event.type === "etaError" && Number.isFinite(event.errorSeconds) && event.errorSeconds >= 0) {
    updated.averageEtaErrorSeconds =
      (updated.averageEtaErrorSeconds * updated.etaSampleCount + event.errorSeconds) /
      (updated.etaSampleCount + 1);
    updated.etaSampleCount += 1;
  }
  return updated;
}

function nonNegativeCount(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function finiteNonNegative(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0;
}

function normalizeCategory(value) {
  const categories = new Set(["ANY", "STANDARD", "XL", "ACCESSIBLE", "LUXURY"]);
  return typeof value === "string" && categories.has(value) ? value : null;
}

module.exports = {
  applyMatchingMetricEvent,
  calculateReliabilityPenalty,
  filterCompatibleRides,
  isValidDriverCategory,
  rankRideRecommendations,
};
