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

export function getRidePrice(rideType, prices) {
  return Object.hasOwn(prices, rideType) ? prices[rideType] : undefined;
}
