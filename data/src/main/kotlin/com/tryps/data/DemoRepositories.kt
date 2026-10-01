package com.tryps.data

import com.tryps.domain.AccountRepository
import com.tryps.domain.RideRepository
import com.tryps.model.GeoPoint
import com.tryps.model.Place
import com.tryps.model.Ride
import com.tryps.model.RideQuote
import com.tryps.model.RideStatus
import com.tryps.model.UserProfile
import com.tryps.model.UserRole
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map

class DemoAccountRepository : AccountRepository {
    private val user = MutableStateFlow<UserProfile?>(null)
    override val currentUser: Flow<UserProfile?> = user

    override suspend fun signIn(email: String, password: String) {
        val role = if (email.startsWith("driver", ignoreCase = true)) UserRole.DRIVER else UserRole.RIDER
        user.value = UserProfile("demo-$role", email.substringBefore("@").replaceFirstChar(Char::uppercase), email, role = role, vehicle = if (role == UserRole.DRIVER) "Silver EV · TRYPS" else "")
    }

    override suspend fun register(name: String, email: String, password: String, role: UserRole) {
        user.value = UserProfile("demo-${UUID.randomUUID()}", name, email, role = role)
    }

    override suspend fun signOut() {
        user.value = null
    }
}

class DemoRideRepository : RideRepository {
    private val rides = MutableStateFlow<List<Ride>>(emptyList())
    private val locations = MutableStateFlow<Map<String, GeoPoint>>(emptyMap())
    private val samplePlaces = listOf(
        Place("Downtown", "Market Street", GeoPoint(37.7749, -122.4194)),
        Place("Airport", "San Francisco International Airport", GeoPoint(37.6213, -122.3790)),
        Place("Waterfront", "Embarcadero", GeoPoint(37.7955, -122.3937)),
        Place("Central Station", "4th and King Street", GeoPoint(37.7764, -122.3943)),
    )

    override suspend fun searchPlaces(query: String, near: GeoPoint?): List<Place> =
        samplePlaces.filter { it.name.contains(query, true) || it.address.contains(query, true) }

    override fun observeActiveRide(userId: String, role: UserRole): Flow<Ride?> =
        combine(rides, locations) { current, driverLocations ->
            current.firstOrNull {
                (if (role == UserRole.RIDER) it.riderId == userId else it.driverId == userId) &&
                    it.status !in setOf(RideStatus.COMPLETED, RideStatus.CANCELLED)
            }?.let { ride -> ride.copy(driverLocation = ride.driverId?.let(driverLocations::get)) }
        }

    override fun observeHistory(userId: String, role: UserRole): Flow<List<Ride>> =
        rides.map { current ->
            current.filter {
                (if (role == UserRole.RIDER) it.riderId == userId else it.driverId == userId) &&
                    it.status in setOf(RideStatus.COMPLETED, RideStatus.CANCELLED)
            }
        }

    override fun observeOpenRides(driverId: String): Flow<List<Ride>> =
        combine(rides, locations) { current, driverLocations ->
            val location = driverLocations[driverId]
            val openRides = current.filter { it.status == RideStatus.SEARCHING }
            if (location == null) {
                openRides.sortedBy(Ride::createdAtEpochMillis)
            } else {
                openRides.map { ride ->
                    val distance = approximateDistance(location, ride.pickup.location)
                    ride.copy(pickupEtaSeconds = (distance / 8.0).toInt())
                }.sortedBy { it.pickupEtaSeconds }
            }
        }

    override suspend fun quote(pickup: Place, destination: Place): RideQuote {
        val distance = approximateDistance(pickup.location, destination.location).coerceAtLeast(1_000)
        return RideQuote(350 + distance / 100 * 18, distanceMeters = distance, durationSeconds = distance / 9)
    }

    override suspend fun request(rider: UserProfile, pickup: Place, destination: Place, quote: RideQuote) {
        rides.value = listOf(
            Ride(
                id = UUID.randomUUID().toString(),
                riderId = rider.id,
                pickup = pickup,
                destination = destination,
                quote = quote,
                createdAtEpochMillis = System.currentTimeMillis(),
                riderName = rider.displayName,
            ),
        ) + rides.value
    }

    override suspend fun accept(rideId: String, driver: UserProfile) = update(rideId) {
        it.copy(driverId = driver.id, driverName = driver.displayName, status = RideStatus.ACCEPTED)
    }

    override suspend fun updateStatus(rideId: String, status: RideStatus) = update(rideId) { it.copy(status = status) }

    override suspend fun updateDriverLocation(driverId: String, location: GeoPoint, available: Boolean) {
        locations.value = locations.value + (driverId to location)
    }

    override suspend fun cancel(rideId: String) = updateStatus(rideId, RideStatus.CANCELLED)

    override suspend fun rate(rideId: String, rating: Int) = update(rideId) { it.copy(rating = rating.coerceIn(1, 5)) }

    private fun update(id: String, transform: (Ride) -> Ride) {
        rides.value = rides.value.map { if (it.id == id) transform(it) else it }
    }

    private fun approximateDistance(a: GeoPoint, b: GeoPoint): Int {
        val latitudeMeters = (a.latitude - b.latitude) * 111_000
        val longitudeMeters = (a.longitude - b.longitude) * 85_000
        return kotlin.math.sqrt(latitudeMeters * latitudeMeters + longitudeMeters * longitudeMeters).toInt()
    }
}
