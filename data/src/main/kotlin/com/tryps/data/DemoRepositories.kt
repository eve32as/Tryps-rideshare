package com.tryps.data

import com.tryps.domain.AccountRepository
import com.tryps.domain.RideRepository
import com.tryps.model.GeoPoint
import com.tryps.model.Place
import com.tryps.model.Ride
import com.tryps.model.RidePass
import com.tryps.model.RidePayment
import com.tryps.model.RidePaymentMethod
import com.tryps.model.RidePaymentShare
import com.tryps.model.RidePaymentStatus
import com.tryps.model.RideQuote
import com.tryps.model.RideStatus
import com.tryps.model.UserProfile
import com.tryps.model.UserRole
import com.tryps.model.VehicleCategory
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map

class DemoAccountRepository : AccountRepository {
    private val user = MutableStateFlow<UserProfile?>(null)
    override val currentUser: Flow<UserProfile?> = user

    override suspend fun signIn(email: String, password: String) {
        val role = if (email.startsWith("driver", ignoreCase = true)) UserRole.DRIVER else UserRole.RIDER
        user.value = UserProfile("demo-$role", email.substringBefore("@").replaceFirstChar(Char::uppercase), email, role = role, vehicle = if (role == UserRole.DRIVER) "Silver EV · TRYPS" else "")
    }

    override suspend fun register(name: String, email: String, password: String, role: UserRole, vehicleCategory: VehicleCategory) {
        user.value = UserProfile("demo-${UUID.randomUUID()}", name, email, role = role, vehicleCategory = vehicleCategory)
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
                (if (role == UserRole.RIDER) it.riderId == userId || it.payment.splits.any { share -> share.payerId == userId }
                else it.driverId == userId) &&
                    it.status !in setOf(RideStatus.COMPLETED, RideStatus.CANCELLED)
            }?.let { ride -> ride.copy(driverLocation = ride.driverId?.let(driverLocations::get)) }
        }

    override fun observeHistory(userId: String, role: UserRole): Flow<List<Ride>> =
        rides.map { current ->
            current.filter {
                (if (role == UserRole.RIDER) it.riderId == userId || it.payment.splits.any { share -> share.payerId == userId }
                else it.driverId == userId) &&
                    it.status in setOf(RideStatus.COMPLETED, RideStatus.CANCELLED)
            }
        }

    override fun observeRidePasses(riderId: String): Flow<List<RidePass>> = flowOf(emptyList())

    override fun observeOpenRides(driverId: String, vehicleCategory: VehicleCategory): Flow<List<Ride>> =
        combine(rides, locations) { current, driverLocations ->
            val location = driverLocations[driverId]
            val openRides = current.filter {
                it.status == RideStatus.SEARCHING &&
                    (it.vehicleCategory == VehicleCategory.ANY ||
                        vehicleCategory == VehicleCategory.ANY ||
                        it.vehicleCategory == vehicleCategory)
            }
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

    override suspend fun request(
        rider: UserProfile,
        pickup: Place,
        destination: Place,
        quote: RideQuote,
        vehicleCategory: VehicleCategory,
        paymentMethod: RidePaymentMethod,
        splitParticipantEmails: List<String>,
        ridePassId: String?,
    ) {
        require(paymentMethod != RidePaymentMethod.RIDE_PASS || ridePassId != null) {
            "Ride passes are not available in demo mode"
        }
        require(splitParticipantEmails.size <= 4) { "A split can include at most four other riders" }
        require(paymentMethod == RidePaymentMethod.CASH || splitParticipantEmails.isEmpty()) {
            "Split payments currently require cash"
        }
        val payment = when (paymentMethod) {
            RidePaymentMethod.CASH -> {
                val payerIds = listOf(rider.id) + splitParticipantEmails.map(String::trim)
                val baseShare = quote.amountCents / payerIds.size
                val remainder = quote.amountCents % payerIds.size
                RidePayment(
                    method = paymentMethod,
                    status = RidePaymentStatus.PENDING,
                    amountCents = quote.amountCents,
                    splits = payerIds.mapIndexed { index, payerId ->
                        RidePaymentShare(payerId, payerId, baseShare + if (index < remainder) 1 else 0)
                    },
                )
            }
            RidePaymentMethod.SIMULATED_CARD -> RidePayment(
                method = paymentMethod,
                status = RidePaymentStatus.SIMULATED,
                amountCents = quote.amountCents,
            )
            RidePaymentMethod.RIDE_PASS -> error("Ride passes are not available in demo mode")
        }
        rides.value = listOf(
            Ride(
                id = UUID.randomUUID().toString(),
                riderId = rider.id,
                pickup = pickup,
                destination = destination,
                quote = quote,
                createdAtEpochMillis = System.currentTimeMillis(),
                riderName = rider.displayName,
                vehicleCategory = vehicleCategory,
                payment = payment,
            ),
        ) + rides.value
    }

    override suspend fun accept(rideId: String, driver: UserProfile) = update(rideId) {
        it.copy(driverId = driver.id, driverName = driver.displayName, status = RideStatus.ACCEPTED)
    }

    override suspend fun updateStatus(rideId: String, status: RideStatus) = update(rideId) { it.copy(status = status) }

    override suspend fun confirmCashPayment(rideId: String, driverId: String) = update(rideId) { ride ->
        require(ride.driverId == driverId && ride.status == RideStatus.COMPLETED)
        require(ride.payment.method == RidePaymentMethod.CASH && ride.payment.status == RidePaymentStatus.PENDING)
        ride.copy(
            payment = ride.payment.copy(
                status = RidePaymentStatus.RECEIVED,
                splits = ride.payment.splits.map { it.copy(status = RidePaymentStatus.RECEIVED) },
            ),
        )
    }

    override suspend fun updateDriverLocation(driverId: String, location: GeoPoint, available: Boolean) {
        locations.value = locations.value + (driverId to location)
    }

    override suspend fun cancel(rideId: String, userId: String) = updateStatus(rideId, RideStatus.CANCELLED)

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
