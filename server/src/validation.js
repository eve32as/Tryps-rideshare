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

export function calculateRideFare(pickup, destination, rideType, pricing) {
  const rideTypeMultiplier = Object.hasOwn(pricing.rideTypeMultipliers, rideType)
    ? pricing.rideTypeMultipliers[rideType]
    : undefined;
  if (rideTypeMultiplier === undefined) return undefined;
  const radians = (degrees) => degrees * Math.PI / 180;
  const latitudeDelta = radians(destination.latitude - pickup.latitude);
  const longitudeDelta = radians(destination.longitude - pickup.longitude);
  const startLatitude = radians(pickup.latitude);
  const endLatitude = radians(destination.latitude);
  const haversine = Math.min(1, Math.max(0,
    Math.sin(latitudeDelta / 2) ** 2 +
      Math.cos(startLatitude) * Math.cos(endLatitude) * Math.sin(longitudeDelta / 2) ** 2,
  ));
  const straightLineMeters = 6_371_000 * 2 * Math.atan2(Math.sqrt(haversine), Math.sqrt(1 - haversine));
  const estimatedDistanceKm = Math.round(
    Math.max(1, straightLineMeters / 1000 * pricing.distanceMultiplier) * 10,
  ) / 10;
  if (estimatedDistanceKm > 500) return undefined;
  const distanceChargeCents = Math.round(estimatedDistanceKm * pricing.perKmCents);
  const subtotalCents = Math.round((pricing.baseCents + distanceChargeCents) * rideTypeMultiplier);
  const amountCents = Math.max(pricing.minimumCents, subtotalCents);
  return {
    amountCents,
    estimatedDistanceKm,
    baseFareCents: pricing.baseCents,
    distanceChargeCents,
    perKmCents: pricing.perKmCents,
    rideTypeMultiplier,
    minimumFareCents: pricing.minimumCents,
    minimumApplied: amountCents > subtotalCents,
  };
}
