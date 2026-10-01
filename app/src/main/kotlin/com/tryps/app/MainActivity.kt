package com.tryps.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationServices
import com.tryps.model.GeoPoint

class MainActivity : ComponentActivity() {
    private val applicationContainer get() = application as TrypsApplication
    private val viewModel by viewModels<MainViewModel> {
        MainViewModel.Factory(applicationContainer.accountRepository, applicationContainer.rideRepository)
    }
    private val permissionRequest = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { permissions ->
        if (permissions[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
            permissions[Manifest.permission.ACCESS_COARSE_LOCATION] == true
        ) loadLocation()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { TrypsApp(viewModel, applicationContainer.isDemoMode) }
        requestPermissions()
    }

    private fun requestPermissions() {
        val permissions = buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        }
        permissionRequest.launch(permissions.toTypedArray())
    }

    private fun loadLocation() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) return
        LocationServices.getFusedLocationProviderClient(this).lastLocation.addOnSuccessListener { location ->
            location?.let { viewModel.updateLocation(GeoPoint(it.latitude, it.longitude)) }
        }
    }
}
