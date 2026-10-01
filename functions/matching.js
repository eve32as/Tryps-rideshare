"use strict";

function rankRideRecommendations(candidates, matrix) {
  const etaByDestination = new Map();
  for (const route of matrix) {
    if (route.condition !== "ROUTE_EXISTS" || route.status?.code > 0) continue;
    const eta = Number.parseInt(route.duration, 10);
    if (!Number.isInteger(route.destinationIndex) || !Number.isFinite(eta) || eta < 0) continue;
    etaByDestination.set(route.destinationIndex, {
      pickupEtaSeconds: eta,
      pickupDistanceMeters: Number.isFinite(route.distanceMeters) ? route.distanceMeters : null,
    });
  }

  return candidates.map((candidate, index) => {
    const route = etaByDestination.get(index);
    return route ? { rideId: candidate.id, ...route } : null;
  }).filter(Boolean).sort((a, b) =>
    a.pickupEtaSeconds - b.pickupEtaSeconds || a.rideId.localeCompare(b.rideId));
}

module.exports = { rankRideRecommendations };
