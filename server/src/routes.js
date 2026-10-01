const routesEndpoint = "https://routes.googleapis.com/directions/v2:computeRoutes";

export class RouteProviderError extends Error {
  constructor() {
    super("Driving route lookup failed.");
    this.name = "RouteProviderError";
  }
}

export async function getDrivingDistanceMeters(pickup, destination, apiKey, fetchImpl = fetch) {
  let response;
  try {
    response = await fetchImpl(routesEndpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": apiKey,
        "X-Goog-FieldMask": "routes.distanceMeters",
      },
      body: JSON.stringify({
        origin: { location: { latLng: { latitude: pickup.latitude, longitude: pickup.longitude } } },
        destination: { location: { latLng: { latitude: destination.latitude, longitude: destination.longitude } } },
        travelMode: "DRIVE",
        routingPreference: "TRAFFIC_UNAWARE",
      }),
      signal: AbortSignal.timeout(8_000),
    });
  } catch {
    throw new RouteProviderError();
  }

  if (!response.ok) throw new RouteProviderError();

  let result;
  try {
    result = await response.json();
  } catch {
    throw new RouteProviderError();
  }
  const distanceMeters = result?.routes?.[0]?.distanceMeters;
  if (!Number.isSafeInteger(distanceMeters) || distanceMeters <= 0) {
    throw new RouteProviderError();
  }
  return distanceMeters;
}
