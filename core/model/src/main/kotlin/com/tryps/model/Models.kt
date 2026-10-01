package com.tryps.model

enum class UserRole { RIDER, DRIVER }

enum class VehicleCategory { ANY, STANDARD, XL, ACCESSIBLE, LUXURY }

enum class RideStatus {
    SEARCHING, ACCEPTED, DRIVER_ARRIVING, IN_PROGRESS, COMPLETED, CANCELLED
}

data class GeoPoint(
    val latitude: Double = 0.0,
    val longitude: Double = 0.0,
)

data class Place(
    val name: String = "",
    val address: String = "",
    val location: GeoPoint = GeoPoint(),
)

data class UserProfile(
    val id: String = "",
    val displayName: String = "",
    val email: String = "",
    val phone: String = "",
    val role: UserRole = UserRole.RIDER,
    val vehicle: String = "",
    val rating: Double = 5.0,
    val vehicleCategory: VehicleCategory = VehicleCategory.STANDARD,
    val matchingMetrics: DriverMatchingMetrics = DriverMatchingMetrics(),
)

data class DriverMatchingMetrics(
    val cancellationCount: Int = 0,
    val completedRideCount: Int = 0,
    val etaSampleCount: Int = 0,
    val averageEtaErrorSeconds: Double = 0.0,
)

data class RideQuote(
    val amountCents: Int = 0,
    val currency: String = "USD",
    val distanceMeters: Int = 0,
    val durationSeconds: Int = 0,
    val baseAmountCents: Int = amountCents,
    val surgeMultiplier: Double = 1.0,
    val demandCount: Int = 0,
    val availableDriverCount: Int = 0,
    val quoteId: String? = null,
)

data class Ride(
    val id: String = "",
    val riderId: String = "",
    val driverId: String? = null,
    val pickup: Place = Place(),
    val destination: Place = Place(),
    val quote: RideQuote = RideQuote(),
    val status: RideStatus = RideStatus.SEARCHING,
    val createdAtEpochMillis: Long = 0,
    val riderName: String = "",
    val driverName: String = "",
    val driverLocation: GeoPoint? = null,
    val rating: Int? = null,
    val pickupEtaSeconds: Int? = null,
    val vehicleCategory: VehicleCategory = VehicleCategory.ANY,
    val matchingScoreSeconds: Int? = null,
)
