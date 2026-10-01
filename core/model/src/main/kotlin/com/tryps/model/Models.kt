package com.tryps.model

enum class UserRole { RIDER, DRIVER }

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
)

data class RideQuote(
    val amountCents: Int = 0,
    val currency: String = "USD",
    val distanceMeters: Int = 0,
    val durationSeconds: Int = 0,
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
)
