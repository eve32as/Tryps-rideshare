export function isCoordinate(value) {
  return Number.isFinite(value) && value >= -180 && value <= 180;
}

export function isValidLocation(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    isCoordinate(value.longitude) &&
    value.longitude >= -180 &&
    value.longitude <= 180 &&
    isCoordinate(value.latitude) &&
    value.latitude >= -90 &&
    value.latitude <= 90 &&
    typeof value.label === "string" &&
    value.label.trim().length > 0 &&
    value.label.length <= 200
  );
}

export function calculateRideFare(routeDistanceMeters, rideType, pricing) {
  const rideTypeMultiplier = Object.hasOwn(pricing.rideTypeMultipliers, rideType)
    ? pricing.rideTypeMultipliers[rideType]
    : undefined;
  if (rideTypeMultiplier === undefined || !Number.isFinite(routeDistanceMeters) || routeDistanceMeters <= 0) {
    return undefined;
  }
  const routeDistanceKm = routeDistanceMeters / 1000;
  if (routeDistanceKm > 500) return undefined;
  const estimatedDistanceKm = Math.max(0.1, Math.round(routeDistanceKm * 10) / 10);
  const distanceChargeCents = Math.round(estimatedDistanceKm * pricing.perKmCents);
  const subtotalCents = pricing.baseCents + distanceChargeCents;
  const multipliedFareCents = Math.round(subtotalCents * rideTypeMultiplier);
  const amountCents = Math.max(pricing.minimumCents, multipliedFareCents);
  return {
    amountCents,
    estimatedDistanceKm,
    baseFareCents: pricing.baseCents,
    distanceChargeCents,
    subtotalCents,
    multipliedFareCents,
    perKmCents: pricing.perKmCents,
    rideTypeMultiplier,
    minimumFareCents: pricing.minimumCents,
    minimumApplied: amountCents > multipliedFareCents,
  };
}
