"use strict";

function parseTransitOptions(routes, limit = 3) {
  if (!Array.isArray(routes) || !Number.isSafeInteger(limit) || limit < 1) return [];
  return routes.slice(0, Math.min(limit, 3)).map((route) => {
    const durationSeconds = parseDuration(route?.duration);
    const distanceMeters = route?.distanceMeters;
    if (durationSeconds === null || !Number.isSafeInteger(distanceMeters) || distanceMeters < 0) return null;

    const steps = (Array.isArray(route.legs) ? route.legs : [])
      .flatMap((leg) => Array.isArray(leg?.steps) ? leg.steps : [])
      .filter((step) => step && typeof step === "object")
      .map((step) => {
      const transit = step.transitDetails;
      const stopDetails = transit?.stopDetails ?? {};
      const line = transit?.transitLine ?? {};
      const agency = Array.isArray(line.agencies) ? line.agencies[0] : null;
      return {
        mode: step.travelMode === "WALK" ? "WALK" : transit ? "TRANSIT" : "OTHER",
        instruction: boundedText(step.navigationInstruction?.instructions, 180),
        lineName: boundedText(line.nameShort || line.name, 80),
        agencyName: boundedText(agency?.name, 80),
        vehicleType: boundedText(line.vehicle?.type, 40),
        departureStop: boundedText(stopDetails.departureStop?.name, 100),
        arrivalStop: boundedText(stopDetails.arrivalStop?.name, 100),
        departureTime: validIsoTime(transit?.departureTime),
        arrivalTime: validIsoTime(transit?.arrivalTime),
        durationSeconds: parseDuration(step.staticDuration) ?? 0,
        distanceMeters: Number.isSafeInteger(step.distanceMeters) && step.distanceMeters >= 0
          ? step.distanceMeters
          : 0,
      };
      }).filter((step) => step.mode !== "OTHER");
    if (!steps.some((step) => step.mode === "TRANSIT")) return null;
    return {
      durationSeconds,
      distanceMeters,
      walkingDurationSeconds: steps
        .filter((step) => step.mode === "WALK")
        .reduce((sum, step) => sum + step.durationSeconds, 0),
      steps,
    };
  }).filter(Boolean).sort((first, second) => first.durationSeconds - second.durationSeconds);
}

function parseDuration(value) {
  if (typeof value !== "string") return null;
  const match = /^(\d+)s$/.exec(value);
  if (!match) return null;
  const seconds = Number(match[1]);
  return Number.isSafeInteger(seconds) ? seconds : null;
}

function boundedText(value, maxLength) {
  return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

function validIsoTime(value) {
  return typeof value === "string" && Number.isFinite(Date.parse(value)) ? value : "";
}

module.exports = { parseTransitOptions };
