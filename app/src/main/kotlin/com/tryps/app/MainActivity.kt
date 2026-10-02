package com.tryps.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.location.Location
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.tryps.model.GeoPoint
import com.tryps.model.RideStatus
import com.tryps.model.UserRole
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val applicationContainer get() = application as TrypsApplication
    private val locationClient by lazy { LocationServices.getFusedLocationProviderClient(this) }
    private val viewModel by viewModels<MainViewModel> {
        MainViewModel.Factory(applicationContainer.accountRepository, applicationContainer.rideRepository)
    }
    private var locationCallback: LocationCallback? = null
    private val permissionRequest = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { permissions ->
        if (permissions[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
            permissions[Manifest.permission.ACCESS_COARSE_LOCATION] == true
        ) loadLastLocation()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { TrypsApp(viewModel, applicationContainer.isDemoMode) }
        requestPermissions()
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                try {
                    viewModel.state
                        .map { state ->
                            val activeRide = state.activeRide?.status in setOf(
                                RideStatus.ACCEPTED,
                                RideStatus.DRIVER_ARRIVING,
                                RideStatus.IN_PROGRESS,
                            )
                            activeRide || state.user?.role == UserRole.DRIVER && state.isAvailable
                        }
                        .distinctUntilChanged()
                        .collect { shouldTrack ->
                            if (shouldTrack) startLocationUpdates() else stopLocationUpdates()
                        }
                } finally {
                    stopLocationUpdates()
                }
            }
        }
    }

    private fun requestPermissions() {
        val permissions = buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        }
        permissionRequest.launch(permissions.toTypedArray())
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun loadLastLocation() {
        if (!hasLocationPermission()) return
        locationClient.lastLocation.addOnSuccessListener { location ->
            location?.let { viewModel.updateLocation(GeoPoint(it.latitude, it.longitude)) }
        }
    }

    private fun startLocationUpdates() {
        if (locationCallback != null || !hasLocationPermission()) return
        val callback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.locations.forEach(::publishLocation)
            }
        }
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, LOCATION_INTERVAL_MILLIS)
            .setMinUpdateIntervalMillis(MIN_LOCATION_INTERVAL_MILLIS)
            .setMinUpdateDistanceMeters(MIN_LOCATION_DISTANCE_METERS)
            .setMaxUpdateDelayMillis(MAX_LOCATION_BATCH_DELAY_MILLIS)
            .build()
        locationCallback = callback
        try {
            locationClient.requestLocationUpdates(request, callback, mainLooper)
                .addOnFailureListener {
                    if (locationCallback === callback) {
                        locationCallback = null
                        viewModel.reportLocationUnavailable()
                    }
                    locationClient.removeLocationUpdates(callback)
                }
        } catch (_: SecurityException) {
            locationCallback = null
            viewModel.reportLocationUnavailable()
        }
    }

    private fun publishLocation(location: Location) {
        if (location.hasAccuracy() && location.accuracy > MAX_ACCEPTED_ACCURACY_METERS) return
        viewModel.updateLocation(GeoPoint(location.latitude, location.longitude))
    }

    private fun stopLocationUpdates() {
        locationCallback?.let(locationClient::removeLocationUpdates)
        locationCallback = null
    }

    private companion object {
        const val LOCATION_INTERVAL_MILLIS = 10_000L
        const val MIN_LOCATION_INTERVAL_MILLIS = 5_000L
        const val MIN_LOCATION_DISTANCE_METERS = 20f
        const val MAX_LOCATION_BATCH_DELAY_MILLIS = 15_000L
        const val MAX_ACCEPTED_ACCURACY_METERS = 200f
    }
}
