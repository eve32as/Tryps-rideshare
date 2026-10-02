package com.tryps.data

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.functions.FirebaseFunctions
import com.tryps.domain.AccountRepository
import com.tryps.domain.RideRepository
import com.tryps.model.DriverMatchingMetrics
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
import com.tryps.model.RideSafetyAlert
import com.tryps.model.TransitOption
import com.tryps.model.TransitStep
import com.tryps.model.UserProfile
import com.tryps.model.UserRole
import com.tryps.model.VehicleCategory
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.tasks.await

class FirebaseAccountRepository(
    private val auth: FirebaseAuth,
    private val firestore: FirebaseFirestore,
) : AccountRepository {
    override val currentUser: Flow<UserProfile?> = callbackFlow {
        var profileListener: ListenerRegistration? = null
        val listener = FirebaseAuth.AuthStateListener { source ->
            profileListener?.remove()
            profileListener = null
            val firebaseUser = source.currentUser
            if (firebaseUser == null) {
                trySend(null)
            } else {
                profileListener = firestore.collection("users").document(firebaseUser.uid)
                    .addSnapshotListener { snapshot, error ->
                        if (error != null) close(error)
                        else if (snapshot?.exists() == true) trySend(snapshot.toProfile(firebaseUser.email.orEmpty()))
                    }
            }
        }
        auth.addAuthStateListener(listener)
        awaitClose {
            profileListener?.remove()
            auth.removeAuthStateListener(listener)
        }
    }

    override suspend fun signIn(email: String, password: String) {
        auth.signInWithEmailAndPassword(email.trim(), password).await()
    }

    override suspend fun register(
        name: String,
        email: String,
        password: String,
        role: UserRole,
        vehicleCategory: VehicleCategory,
    ) {
        val user = auth.createUserWithEmailAndPassword(email.trim(), password).await().user
            ?: error("Firebase did not create an account")
        firestore.collection("users").document(user.uid).set(
            mapOf(
                "displayName" to name.trim(),
                "email" to email.trim(),
                "role" to role.name,
                "rating" to 5.0,
                "vehicleCategory" to vehicleCategory.name,
                "createdAt" to FieldValue.serverTimestamp(),
            ),
        ).await()
    }

    override suspend fun signOut() = auth.signOut()
}

class FirebaseRideRepository(
    private val firestore: FirebaseFirestore,
    private val functions: FirebaseFunctions,
) : RideRepository {
    private val rides: Flow<List<Ride>> = callbackFlow {
        val listener = firestore.collection("rides").addSnapshotListener { snapshot, error ->
            if (error != null) close(error) else trySend(snapshot?.documents.orEmpty().mapNotNull(DocumentSnapshot::toRide))
        }
        awaitClose { listener.remove() }
    }

    private data class DriverDispatchState(
        val available: Boolean,
        val locationUpdateBucket: Long,
        val matchingMetrics: Map<*, *>,
    )

    override suspend fun searchPlaces(query: String, near: GeoPoint?): List<Place> {
        if (query.length < 2) return emptyList()
        val payload = mutableMapOf<String, Any>("query" to query)
        near?.let { payload["near"] = it.toMap() }
        val result = functions.getHttpsCallable("searchPlaces").call(payload).await().getData() as? Map<*, *>
        val places = result?.get("places") as? List<*> ?: return emptyList()
        return places.mapNotNull { value ->
            val map = value as? Map<*, *> ?: return@mapNotNull null
            Place(
                name = map["name"] as? String ?: return@mapNotNull null,
                address = map["address"] as? String ?: "",
                location = map["location"].toGeoPoint(),
            )
        }
    }

    override suspend fun transitOptions(pickup: Place, destination: Place): List<TransitOption> {
        val result = functions.getHttpsCallable("getTransitOptions")
            .call(mapOf("pickup" to pickup.location.toMap(), "destination" to destination.location.toMap()))
            .await()
            .getData() as? Map<*, *> ?: error("Invalid transit response")
        return (result["options"] as? List<*>).orEmpty().mapNotNull { value ->
            val option = value as? Map<*, *> ?: return@mapNotNull null
            val steps = (option["steps"] as? List<*>).orEmpty().mapNotNull { stepValue ->
                val step = stepValue as? Map<*, *> ?: return@mapNotNull null
                TransitStep(
                    mode = step["mode"] as? String ?: "",
                    instruction = step["instruction"] as? String ?: "",
                    lineName = step["lineName"] as? String ?: "",
                    agencyName = step["agencyName"] as? String ?: "",
                    vehicleType = step["vehicleType"] as? String ?: "",
                    departureStop = step["departureStop"] as? String ?: "",
                    arrivalStop = step["arrivalStop"] as? String ?: "",
                    departureTime = step["departureTime"] as? String ?: "",
                    arrivalTime = step["arrivalTime"] as? String ?: "",
                    durationSeconds = (step["durationSeconds"] as? Number)?.toInt() ?: 0,
                    distanceMeters = (step["distanceMeters"] as? Number)?.toInt() ?: 0,
                )
            }
            TransitOption(
                durationSeconds = (option["durationSeconds"] as? Number)?.toInt() ?: return@mapNotNull null,
                distanceMeters = (option["distanceMeters"] as? Number)?.toInt() ?: 0,
                walkingDurationSeconds = (option["walkingDurationSeconds"] as? Number)?.toInt() ?: 0,
                steps = steps,
            ).takeIf { steps.any { step -> step.mode == "TRANSIT" } }
        }
    }

    override fun observeActiveRide(userId: String, role: UserRole): Flow<Ride?> =
        rides.map { current ->
            current.firstOrNull {
                (if (role == UserRole.RIDER) it.riderId == userId || it.payment.splits.any { share -> share.payerId == userId }
                else it.driverId == userId) &&
                    it.status !in setOf(RideStatus.COMPLETED, RideStatus.CANCELLED)
            }
        }

    override fun observeHistory(userId: String, role: UserRole): Flow<List<Ride>> = rides.map { current ->
        current.filter {
            (if (role == UserRole.RIDER) it.riderId == userId || it.payment.splits.any { share -> share.payerId == userId }
            else it.driverId == userId) &&
                it.status in setOf(RideStatus.COMPLETED, RideStatus.CANCELLED)
        }.sortedByDescending(Ride::createdAtEpochMillis)
    }

    override fun observeRidePasses(riderId: String): Flow<List<RidePass>> = callbackFlow {
        val listener = firestore.collection("users").document(riderId).collection("ridePasses")
            .whereEqualTo("status", "ACTIVE")
            .addSnapshotListener { snapshot, error ->
                if (error != null) close(error)
                else trySend(snapshot?.documents.orEmpty().mapNotNull { pass ->
                    val remainingRides = pass.getLong("remainingRides")?.toInt() ?: return@mapNotNull null
                    val expiresAt = pass.getTimestamp("expiresAt")?.toDate()?.time ?: return@mapNotNull null
                    if (remainingRides > 0 && expiresAt > System.currentTimeMillis()) {
                        RidePass(pass.id, remainingRides, expiresAt)
                    } else {
                        null
                    }
                })
            }
        awaitClose { listener.remove() }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun observeOpenRides(driverId: String, vehicleCategory: VehicleCategory): Flow<List<Ride>> =
        combine(rides, observeDriverDispatchState(driverId)) { current, dispatchState ->
            current to dispatchState
        }
            .distinctUntilChangedBy { (current, dispatchState) ->
                current.filter { it.status == RideStatus.SEARCHING }.map(Ride::id) to dispatchState
            }
            .mapLatest { (current, dispatchState) ->
                val openRides = current.filter {
                    it.status == RideStatus.SEARCHING &&
                        (it.vehicleCategory == VehicleCategory.ANY ||
                            vehicleCategory == VehicleCategory.ANY ||
                            it.vehicleCategory == vehicleCategory)
                }
                    .sortedBy(Ride::createdAtEpochMillis)
                if (openRides.isEmpty() || !dispatchState.available) return@mapLatest openRides

                val recommendations = try {
                    val result = functions.getHttpsCallable("getRideRecommendations")
                        .call(mapOf("driverId" to driverId))
                        .await()
                        .getData() as? Map<*, *>
                    result?.get("recommendations") as? List<*> ?: emptyList<Any>()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    emptyList()
                }
                val scoreByRide = recommendations.mapNotNull { value ->
                    val recommendation = value as? Map<*, *> ?: return@mapNotNull null
                    val rideId = recommendation["rideId"] as? String ?: return@mapNotNull null
                    val eta = (recommendation["pickupEtaSeconds"] as? Number)?.toInt() ?: return@mapNotNull null
                    val score = (recommendation["matchingScoreSeconds"] as? Number)?.toInt() ?: eta
                    rideId to (eta to score)
                }.toMap()

                openRides.withIndex()
                    .sortedWith(compareBy<IndexedValue<Ride>> { scoreByRide[it.value.id]?.second ?: Int.MAX_VALUE }.thenBy { it.index })
                    .map { indexedRide ->
                        val recommendation = scoreByRide[indexedRide.value.id]
                        indexedRide.value.copy(
                            pickupEtaSeconds = recommendation?.first,
                            matchingScoreSeconds = recommendation?.second,
                        )
                    }
            }

    private fun observeDriverDispatchState(driverId: String): Flow<DriverDispatchState> = callbackFlow {
        var available = false
        var locationUpdateBucket = 0L
        var matchingMetrics: Map<*, *> = emptyMap<Any, Any>()
        fun emitState() {
            trySend(DriverDispatchState(available, locationUpdateBucket, matchingMetrics))
        }
        val driverListener = firestore.collection("drivers").document(driverId)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                } else {
                    available = snapshot?.getBoolean("available") == true
                    locationUpdateBucket = (snapshot?.getTimestamp("updatedAt")?.seconds ?: 0L) / 30
                    emitState()
                }
            }
        val profileListener = firestore.collection("users").document(driverId)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                } else {
                    matchingMetrics = snapshot?.get("matchingMetrics") as? Map<*, *> ?: emptyMap()
                    emitState()
                }
            }
        awaitClose {
            driverListener.remove()
            profileListener.remove()
        }
    }

    override suspend fun quote(pickup: Place, destination: Place): RideQuote {
        val result = functions.getHttpsCallable("getRideQuote").call(
            mapOf("pickup" to pickup.location.toMap(), "destination" to destination.location.toMap()),
        ).await().getData() as? Map<*, *> ?: error("Invalid quote response")
        return RideQuote(
            amountCents = (result["amountCents"] as Number).toInt(),
            currency = result["currency"] as? String ?: "USD",
            distanceMeters = (result["distanceMeters"] as Number).toInt(),
            durationSeconds = (result["durationSeconds"] as Number).toInt(),
            baseAmountCents = (result["baseAmountCents"] as? Number)?.toInt()
                ?: (result["amountCents"] as Number).toInt(),
            surgeMultiplier = (result["surgeMultiplier"] as? Number)?.toDouble() ?: 1.0,
            demandCount = (result["demandCount"] as? Number)?.toInt() ?: 0,
            availableDriverCount = (result["availableDriverCount"] as? Number)?.toInt() ?: 0,
            quoteId = result["quoteId"] as? String ?: error("Invalid quote response"),
            weatherCondition = result["weatherCondition"] as? String ?: "UNAVAILABLE",
            weatherDemandUpliftPercent = (result["weatherDemandUpliftPercent"] as? Number)?.toInt() ?: 0,
        )
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
        require(!quote.quoteId.isNullOrBlank()) { "A valid server quote is required to request a ride" }
        functions.getHttpsCallable("requestRide")
            .call(
                mapOf(
                    "quoteId" to quote.quoteId,
                    "vehicleCategory" to vehicleCategory.name,
                    "paymentMethod" to paymentMethod.name,
                    "splitParticipantEmails" to splitParticipantEmails,
                    "ridePassId" to ridePassId,
                ),
            )
            .await()
    }

    override suspend fun confirmCashPayment(rideId: String, driverId: String) {
        functions.getHttpsCallable("confirmCashPayment")
            .call(mapOf("rideId" to rideId, "driverId" to driverId))
            .await()
    }

    override suspend fun reportSafetyAlert(rideId: String, userId: String, location: GeoPoint) {
        functions.getHttpsCallable("reportSafetyAlert")
            .call(mapOf("rideId" to rideId, "location" to location.toMap()))
            .await()
    }

    override suspend fun resolveSafetyAlert(rideId: String, userId: String) {
        functions.getHttpsCallable("resolveSafetyAlert")
            .call(mapOf("rideId" to rideId))
            .await()
    }

    override suspend fun accept(rideId: String, driver: UserProfile) {
        functions.getHttpsCallable("acceptRide")
            .call(mapOf("rideId" to rideId, "driverId" to driver.id))
            .await()
    }

    override suspend fun updateStatus(rideId: String, status: RideStatus) {
        require(status != RideStatus.CANCELLED) { "Use cancel to record who cancelled the ride" }
        firestore.collection("rides").document(rideId).update("status", status.name).await()
    }

    override suspend fun updateDriverLocation(
        driverId: String,
        location: GeoPoint,
        available: Boolean,
        activeRideId: String?,
    ) {
        firestore.collection("drivers").document(driverId).set(
            mapOf(
                "location" to location.toMap(),
                "available" to available,
                "updatedAt" to FieldValue.serverTimestamp(),
            ),
        ).await()
        if (activeRideId != null) {
            firestore.collection("rides").document(activeRideId)
                .update("driverLocation", location.toMap())
                .await()
        }
    }

    override suspend fun cancel(rideId: String, userId: String) {
        functions.getHttpsCallable("cancelRide")
            .call(mapOf("rideId" to rideId, "userId" to userId))
            .await()
    }

    override suspend fun rate(rideId: String, rating: Int) {
        firestore.collection("rides").document(rideId).update("rating", rating.coerceIn(1, 5)).await()
    }

}

private fun DocumentSnapshot.toProfile(fallbackEmail: String) = UserProfile(
    id = id,
    displayName = getString("displayName").orEmpty(),
    email = getString("email") ?: fallbackEmail,
    phone = getString("phone").orEmpty(),
    role = enumValueOrDefault(getString("role"), UserRole.RIDER),
    vehicle = getString("vehicle").orEmpty(),
    rating = getDouble("rating") ?: 5.0,
    vehicleCategory = enumValueOrDefault(
        getString("vehicleCategory"),
        if (enumValueOrDefault(getString("role"), UserRole.RIDER) == UserRole.DRIVER) VehicleCategory.STANDARD else VehicleCategory.ANY,
    ),
    matchingMetrics = (get("matchingMetrics") as? Map<*, *>)?.let { metrics ->
        DriverMatchingMetrics(
            cancellationCount = (metrics["cancellationCount"] as? Number)?.toInt() ?: 0,
            completedRideCount = (metrics["completedRideCount"] as? Number)?.toInt() ?: 0,
            etaSampleCount = (metrics["etaSampleCount"] as? Number)?.toInt() ?: 0,
            averageEtaErrorSeconds = (metrics["averageEtaErrorSeconds"] as? Number)?.toDouble() ?: 0.0,
        )
    } ?: DriverMatchingMetrics(),
)

private fun DocumentSnapshot.toRide(): Ride? = runCatching {
    Ride(
        id = id,
        riderId = getString("riderId").orEmpty(),
        driverId = getString("driverId"),
        riderName = getString("riderName").orEmpty(),
        driverName = getString("driverName").orEmpty(),
        driverLocation = get("driverLocation")?.toGeoPoint(),
        pickup = get("pickup").toPlace(),
        destination = get("destination").toPlace(),
        quote = get("quote").toQuote(),
        status = enumValueOrDefault(getString("status"), RideStatus.SEARCHING),
        createdAtEpochMillis = getLong("createdAtEpochMillis") ?: 0,
        rating = getLong("rating")?.toInt(),
        pickupEtaSeconds = getLong("pickupEtaSeconds")?.toInt(),
        vehicleCategory = getString("vehicleCategory")?.let {
            enumValueOrDefault(it, VehicleCategory.STANDARD)
        } ?: VehicleCategory.ANY,
        payment = get("payment").toRidePayment(),
        safetyAlert = get("safetyAlert").toRideSafetyAlert(),
    )
}.getOrNull()

private fun Place.toMap() = mapOf("name" to name, "address" to address, "location" to location.toMap())
private fun GeoPoint.toMap() = mapOf("latitude" to latitude, "longitude" to longitude)
private fun Any?.toPlace(): Place {
    val map = this as? Map<*, *> ?: return Place()
    return Place(map["name"] as? String ?: "", map["address"] as? String ?: "", map["location"].toGeoPoint())
}

private fun Any?.toGeoPoint(): GeoPoint {
    val map = this as? Map<*, *> ?: return GeoPoint()
    return GeoPoint((map["latitude"] as? Number)?.toDouble() ?: 0.0, (map["longitude"] as? Number)?.toDouble() ?: 0.0)
}

private fun Any?.toQuote(): RideQuote {
    val map = this as? Map<*, *> ?: return RideQuote()
    return RideQuote(
        amountCents = (map["amountCents"] as? Number)?.toInt() ?: 0,
        currency = map["currency"] as? String ?: "USD",
        distanceMeters = (map["distanceMeters"] as? Number)?.toInt() ?: 0,
        durationSeconds = (map["durationSeconds"] as? Number)?.toInt() ?: 0,
        baseAmountCents = (map["baseAmountCents"] as? Number)?.toInt() ?: (map["amountCents"] as? Number)?.toInt() ?: 0,
        surgeMultiplier = (map["surgeMultiplier"] as? Number)?.toDouble() ?: 1.0,
        demandCount = (map["demandCount"] as? Number)?.toInt() ?: 0,
        availableDriverCount = (map["availableDriverCount"] as? Number)?.toInt() ?: 0,
        weatherCondition = map["weatherCondition"] as? String ?: "UNAVAILABLE",
        weatherDemandUpliftPercent = (map["weatherDemandUpliftPercent"] as? Number)?.toInt() ?: 0,
    )
}

private fun Any?.toRidePayment(): RidePayment {
    val map = this as? Map<*, *> ?: return RidePayment()
    val splits = (map["splits"] as? List<*>).orEmpty().mapNotNull { item ->
        val share = item as? Map<*, *> ?: return@mapNotNull null
        RidePaymentShare(
            payerId = share["payerId"] as? String ?: return@mapNotNull null,
            payerName = share["payerName"] as? String ?: "",
            amountCents = (share["amountCents"] as? Number)?.toInt() ?: 0,
            status = enumValueOrDefault(share["status"] as? String, RidePaymentStatus.PENDING),
        )
    }
    return RidePayment(
        method = enumValueOrDefault(map["method"] as? String, RidePaymentMethod.SIMULATED_CARD),
        status = enumValueOrDefault(map["status"] as? String, RidePaymentStatus.SIMULATED),
        amountCents = (map["amountCents"] as? Number)?.toInt() ?: 0,
        passId = map["passId"] as? String,
        splits = splits,
    )
}

private fun Any?.toRideSafetyAlert(): RideSafetyAlert? {
    val map = this as? Map<*, *> ?: return null
    val location = map["location"] as? Map<*, *> ?: return null
    return RideSafetyAlert(
        status = map["status"] as? String ?: "ACTIVE",
        triggeredBy = map["triggeredBy"] as? String ?: "",
        location = location.toGeoPoint(),
        createdAtEpochMillis = (map["createdAt"] as? com.google.firebase.Timestamp)?.toDate()?.time ?: 0,
        resolvedBy = map["resolvedBy"] as? String,
    )
}

private inline fun <reified T : Enum<T>> enumValueOrDefault(value: String?, fallback: T): T =
    enumValues<T>().firstOrNull { it.name == value } ?: fallback
