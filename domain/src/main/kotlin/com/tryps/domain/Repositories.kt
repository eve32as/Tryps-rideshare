package com.tryps.domain

import com.tryps.model.GeoPoint
import com.tryps.model.Place
import com.tryps.model.Ride
import com.tryps.model.RideQuote
import com.tryps.model.RidePass
import com.tryps.model.RidePaymentMethod
import com.tryps.model.TransitOption
import com.tryps.model.RideStatus
import com.tryps.model.UserProfile
import com.tryps.model.UserRole
import com.tryps.model.VehicleCategory
import kotlinx.coroutines.flow.Flow

interface AccountRepository {
    val currentUser: Flow<UserProfile?>
    suspend fun signIn(email: String, password: String)
    suspend fun register(name: String, email: String, password: String, role: UserRole, vehicleCategory: VehicleCategory)
    suspend fun signOut()
}

interface RideRepository {
    suspend fun searchPlaces(query: String, near: GeoPoint?): List<Place>
    suspend fun transitOptions(pickup: Place, destination: Place): List<TransitOption>
    fun observeActiveRide(userId: String, role: UserRole): Flow<Ride?>
    fun observeHistory(userId: String, role: UserRole): Flow<List<Ride>>
    fun observeRidePasses(riderId: String): Flow<List<RidePass>>
    fun observeOpenRides(driverId: String, vehicleCategory: VehicleCategory): Flow<List<Ride>>
    suspend fun quote(pickup: Place, destination: Place): RideQuote
    suspend fun request(
        rider: UserProfile,
        pickup: Place,
        destination: Place,
        quote: RideQuote,
        vehicleCategory: VehicleCategory,
        paymentMethod: RidePaymentMethod,
        splitParticipantEmails: List<String>,
        ridePassId: String?,
    )
    suspend fun confirmCashPayment(rideId: String, driverId: String)
    suspend fun reportSafetyAlert(rideId: String, userId: String, location: GeoPoint)
    suspend fun resolveSafetyAlert(rideId: String, userId: String)
    suspend fun accept(rideId: String, driver: UserProfile)
    suspend fun updateStatus(rideId: String, status: RideStatus)
    suspend fun updateDriverLocation(
        driverId: String,
        location: GeoPoint,
        available: Boolean,
        activeRideId: String? = null,
    )
    suspend fun cancel(rideId: String, userId: String)
    suspend fun rate(rideId: String, rating: Int)
}
