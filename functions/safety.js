"use strict";

const ACTIVE_RIDE_STATUSES = new Set(["ACCEPTED", "DRIVER_ARRIVING", "IN_PROGRESS"]);

function canAccessRideSafetyAlert(ride, userId) {
  return ride && typeof userId === "string" &&
    (ride.riderId === userId || ride.driverId === userId);
}

function canTriggerSafetyAlert(ride, userId) {
  return canAccessRideSafetyAlert(ride, userId) &&
    ACTIVE_RIDE_STATUSES.has(ride.status) &&
    ride.safetyAlert?.status !== "ACTIVE";
}

function canResolveSafetyAlert(ride, userId) {
  return canAccessRideSafetyAlert(ride, userId) && ride.safetyAlert?.status === "ACTIVE";
}

module.exports = { canAccessRideSafetyAlert, canResolveSafetyAlert, canTriggerSafetyAlert };
