package com.tryps.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.tryps.domain.AccountRepository
import com.tryps.domain.RideRepository
import com.tryps.domain.RideValidation
import com.tryps.model.GeoPoint
import com.tryps.model.Place
import com.tryps.model.Ride
import com.tryps.model.RideQuote
import com.tryps.model.RideStatus
import com.tryps.model.UserProfile
import com.tryps.model.UserRole
import com.tryps.model.VehicleCategory
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class MainUiState(
    val user: UserProfile? = null,
    val activeRide: Ride? = null,
    val openRides: List<Ride> = emptyList(),
    val history: List<Ride> = emptyList(),
    val pickup: Place? = null,
    val destination: Place? = null,
    val suggestions: List<Place> = emptyList(),
    val quote: RideQuote? = null,
    val currentLocation: GeoPoint? = null,
    val isAvailable: Boolean = false,
    val isBusy: Boolean = false,
    val error: String? = null,
    val requestedVehicleCategory: VehicleCategory = VehicleCategory.STANDARD,
)

class MainViewModel(
    private val accounts: AccountRepository,
    private val rides: RideRepository,
) : ViewModel() {
    private val mutableState = MutableStateFlow(MainUiState())
    val state: StateFlow<MainUiState> = mutableState.asStateFlow()
    private var userDataJob: Job? = null
    private var searchJob: Job? = null

    init {
        viewModelScope.launch {
            accounts.currentUser.catch { showError(it) }.collectLatest { user ->
                mutableState.update { MainUiState(user = user, currentLocation = it.currentLocation) }
                observeUserData(user)
            }
        }
    }

    fun signIn(email: String, password: String) {
        RideValidation.loginError(email, password)?.let { return showError(it) }
        action { accounts.signIn(email, password) }
    }

    fun register(name: String, email: String, password: String, role: UserRole, vehicleCategory: VehicleCategory) {
        if (name.isBlank()) return showError("Enter your name")
        RideValidation.loginError(email, password)?.let { return showError(it) }
        action { accounts.register(name, email, password, role, vehicleCategory) }
    }

    fun signOut() = action { accounts.signOut() }

    fun updateLocation(location: GeoPoint) {
        mutableState.update { it.copy(currentLocation = location) }
        val snapshot = state.value
        if (snapshot.user?.role == UserRole.DRIVER && snapshot.isAvailable) {
            action(showProgress = false) { rides.updateDriverLocation(snapshot.user.id, location, true) }
        }
    }

    fun useCurrentLocationForPickup() {
        val location = state.value.currentLocation ?: return showError("Current location is unavailable")
        mutableState.update { it.copy(pickup = Place("Current location", "GPS location", location), quote = null) }
    }

    fun searchPlaces(query: String) {
        searchJob?.cancel()
        if (query.length < 2) {
            mutableState.update { it.copy(suggestions = emptyList()) }
            return
        }
        searchJob = viewModelScope.launch {
            delay(250)
            runCatching { rides.searchPlaces(query, state.value.currentLocation) }
                .onSuccess { results -> mutableState.update { it.copy(suggestions = results) } }
                .onFailure { showError(it) }
        }
    }

    fun selectPlace(place: Place, pickup: Boolean) {
        mutableState.update {
            if (pickup) it.copy(pickup = place, suggestions = emptyList(), quote = null)
            else it.copy(destination = place, suggestions = emptyList(), quote = null)
        }
    }

    fun getQuote() {
        val snapshot = state.value
        RideValidation.routeError(snapshot.pickup, snapshot.destination)?.let { return showError(it) }
        action {
            val quote = rides.quote(requireNotNull(snapshot.pickup), requireNotNull(snapshot.destination))
            mutableState.update { it.copy(quote = quote) }
        }
    }

    fun requestRide() {
        val snapshot = state.value
        val user = snapshot.user ?: return
        val pickup = snapshot.pickup ?: return
        val destination = snapshot.destination ?: return
        val quote = snapshot.quote ?: return
        action { rides.request(user, pickup, destination, quote, snapshot.requestedVehicleCategory) }
    }

    fun selectVehicleCategory(category: VehicleCategory) {
        mutableState.update { it.copy(requestedVehicleCategory = category) }
    }

    fun acceptRide(rideId: String) {
        val driver = state.value.user ?: return
        action { rides.accept(rideId, driver) }
    }

    fun cancelRide() {
        val user = state.value.user ?: return
        state.value.activeRide?.let { ride -> action { rides.cancel(ride.id, user.id) } }
    }

    fun advanceRide() {
        val ride = state.value.activeRide ?: return
        val next = when (ride.status) {
            RideStatus.ACCEPTED -> RideStatus.DRIVER_ARRIVING
            RideStatus.DRIVER_ARRIVING -> RideStatus.IN_PROGRESS
            RideStatus.IN_PROGRESS -> RideStatus.COMPLETED
            else -> return
        }
        action { rides.updateStatus(ride.id, next) }
    }

    fun setAvailable(available: Boolean) {
        mutableState.update { it.copy(isAvailable = available) }
        val snapshot = state.value
        val driver = snapshot.user ?: return
        val location = snapshot.currentLocation ?: return
        action(showProgress = false) { rides.updateDriverLocation(driver.id, location, available) }
    }

    fun rate(rideId: String, rating: Int) = action { rides.rate(rideId, rating) }

    fun clearError() = mutableState.update { it.copy(error = null) }

    private fun observeUserData(user: UserProfile?) {
        userDataJob?.cancel()
        if (user == null) return
        userDataJob = viewModelScope.launch {
            launch {
                rides.observeActiveRide(user.id, user.role).catch { showError(it) }.collect { active ->
                    mutableState.update { it.copy(activeRide = active) }
                }
            }
            launch {
                rides.observeHistory(user.id, user.role).catch { showError(it) }.collect { history ->
                    mutableState.update { it.copy(history = history) }
                }
            }
            if (user.role == UserRole.DRIVER) launch {
                rides.observeOpenRides(user.id, user.vehicleCategory).catch { showError(it) }.collect { open ->
                    mutableState.update { it.copy(openRides = open) }
                }
            }
        }
    }

    private fun action(showProgress: Boolean = true, block: suspend () -> Unit) {
        viewModelScope.launch {
            if (showProgress) mutableState.update { it.copy(isBusy = true, error = null) }
            runCatching { block() }.onFailure { showError(it) }
            if (showProgress) mutableState.update { it.copy(isBusy = false) }
        }
    }

    private fun showError(error: Throwable) = showError(error.message ?: "Something went wrong")
    private fun showError(message: String) = mutableState.update { it.copy(error = message, isBusy = false) }

    class Factory(
        private val accounts: AccountRepository,
        private val rides: RideRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            MainViewModel(accounts, rides) as T
    }
}
