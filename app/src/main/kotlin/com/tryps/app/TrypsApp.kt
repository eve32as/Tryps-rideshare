package com.tryps.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.weight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.tryps.model.GeoPoint
import com.tryps.model.Place
import com.tryps.model.Ride
import com.tryps.model.RideStatus
import com.tryps.model.UserRole
import java.text.NumberFormat
import java.util.Currency

@Composable
fun TrypsApp(viewModel: MainViewModel, demoMode: Boolean) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(state.error) {
        state.error?.let {
            snackbar.showSnackbar(it)
            viewModel.clearError()
        }
    }
    MaterialTheme {
        Surface(Modifier.fillMaxSize()) {
            Box {
                if (state.user == null) {
                    AuthScreen(demoMode, state.isBusy, viewModel)
                } else {
                    HomeScreen(state, demoMode, viewModel, snackbar)
                }
                if (state.isBusy) CircularProgressIndicator(Modifier.align(Alignment.Center))
            }
        }
    }
}

@Composable
private fun AuthScreen(demoMode: Boolean, busy: Boolean, viewModel: MainViewModel) {
    var register by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var email by remember { mutableStateOf(if (demoMode) "rider@demo.com" else "") }
    var password by remember { mutableStateOf(if (demoMode) "password" else "") }
    var role by remember { mutableStateOf(UserRole.RIDER) }
    Column(
        Modifier.fillMaxSize().padding(28.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text("Tryps", style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.Bold)
        Text("Your ride, your way", style = MaterialTheme.typography.titleMedium)
        if (demoMode) Text("Demo mode · use rider@demo.com or driver@demo.com", color = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.height(28.dp))
        if (register) OutlinedTextField(name, { name = it }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(email, { email = it }, label = { Text("Email") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(
            password,
            { password = it },
            label = { Text("Password") },
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth(),
        )
        if (register) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                UserRole.entries.forEach {
                    OutlinedButton(onClick = { role = it }, enabled = role != it) { Text(it.name.lowercase().replaceFirstChar(Char::uppercase)) }
                }
            }
        }
        Button(
            onClick = {
                if (register) viewModel.register(name, email, password, role) else viewModel.signIn(email, password)
            },
            enabled = !busy,
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
        ) { Text(if (register) "Create account" else "Sign in") }
        TextButton(onClick = { register = !register }, modifier = Modifier.align(Alignment.CenterHorizontally)) {
            Text(if (register) "Already have an account?" else "Create an account")
        }
    }
}

@Composable
private fun HomeScreen(state: MainUiState, demoMode: Boolean, viewModel: MainViewModel, snackbar: SnackbarHostState) {
    var tab by remember { mutableIntStateOf(0) }
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Tryps", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                if (demoMode) Text("DEMO", color = MaterialTheme.colorScheme.primary)
            }
        },
        bottomBar = {
            NavigationBar {
                listOf("Ride", "History", "Account").forEachIndexed { index, label ->
                    NavigationBarItem(selected = tab == index, onClick = { tab = index }, icon = { Text(if (index == 0) "●" else if (index == 1) "≡" else "☺") }, label = { Text(label) })
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when (tab) {
                0 -> if (state.user?.role == UserRole.DRIVER) DriverScreen(state, viewModel) else RiderScreen(state, viewModel)
                1 -> HistoryScreen(state, viewModel)
                else -> AccountScreen(state, viewModel)
            }
        }
    }
}

@Composable
private fun RiderScreen(state: MainUiState, viewModel: MainViewModel) {
    if (state.activeRide != null) {
        ActiveRideScreen(state.activeRide, false, viewModel)
        return
    }
    var pickupQuery by remember(state.pickup) { mutableStateOf(state.pickup?.name.orEmpty()) }
    var destinationQuery by remember(state.destination) { mutableStateOf(state.destination?.name.orEmpty()) }
    var searchTarget by remember { mutableStateOf<Boolean?>(null) }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        RouteMap(state.pickup, state.destination, state.currentLocation, Modifier.weight(1f))
        Spacer(Modifier.height(8.dp))
        PlaceField(
            "Pickup",
            pickupQuery,
            { pickupQuery = it; searchTarget = true; viewModel.searchPlaces(it) },
            if (searchTarget == true) state.suggestions else emptyList(),
            { pickupQuery = it.name; viewModel.selectPlace(it, true); searchTarget = null },
        )
        TextButton(onClick = viewModel::useCurrentLocationForPickup) { Text("Use current location") }
        PlaceField(
            "Destination",
            destinationQuery,
            { destinationQuery = it; searchTarget = false; viewModel.searchPlaces(it) },
            if (searchTarget == false) state.suggestions else emptyList(),
            { destinationQuery = it.name; viewModel.selectPlace(it, false); searchTarget = null },
        )
        if (state.quote == null) {
            Button(viewModel::getQuote, Modifier.fillMaxWidth().padding(vertical = 12.dp)) { Text("See price") }
        } else {
            Card(Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
                Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column {
                        Text("Standard ride", fontWeight = FontWeight.Bold)
                        Text("${state.quote.distanceMeters / 1000.0} km · ${state.quote.durationSeconds / 60} min")
                        Text("Simulated payment ·•••• 4242")
                    }
                    Text(money(state.quote.amountCents, state.quote.currency), style = MaterialTheme.typography.titleLarge)
                }
            }
            Button(viewModel::requestRide, Modifier.fillMaxWidth().padding(bottom = 12.dp)) { Text("Request Tryps") }
        }
    }
}

@Composable
private fun PlaceField(label: String, value: String, onChange: (String) -> Unit, suggestions: List<Place>, onSelect: (Place) -> Unit) {
    Box(Modifier.fillMaxWidth()) {
        OutlinedTextField(value, onChange, label = { Text(label) }, singleLine = true, modifier = Modifier.fillMaxWidth())
        DropdownMenu(expanded = suggestions.isNotEmpty(), onDismissRequest = {}, modifier = Modifier.fillMaxWidth()) {
            suggestions.forEach { place ->
                DropdownMenuItem(
                    text = { Column { Text(place.name, fontWeight = FontWeight.Bold); Text(place.address) } },
                    onClick = { onSelect(place) },
                )
            }
        }
    }
}

@Composable
private fun DriverScreen(state: MainUiState, viewModel: MainViewModel) {
    state.activeRide?.let {
        ActiveRideScreen(it, true, viewModel)
        return
    }
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Column {
                Text(if (state.isAvailable) "You're online" else "You're offline", style = MaterialTheme.typography.titleLarge)
                Text(if (state.currentLocation == null) "Location unavailable" else "Ready for nearby requests")
            }
            Switch(state.isAvailable, viewModel::setAvailable)
        }
        Spacer(Modifier.height(16.dp))
        Text("Nearby requests", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        if (!state.isAvailable) Text("Go online to receive requests", modifier = Modifier.padding(top = 16.dp))
        else if (state.openRides.isEmpty()) Text("Searching for riders…", modifier = Modifier.padding(top = 16.dp))
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(state.openRides, key = Ride::id) { ride ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp)) {
                        Text(ride.riderName.ifBlank { "Rider" }, fontWeight = FontWeight.Bold)
                        Text("${ride.pickup.name} → ${ride.destination.name}")
                        Text(money(ride.quote.amountCents, ride.quote.currency))
                        Button({ viewModel.acceptRide(ride.id) }, Modifier.fillMaxWidth()) { Text("Accept ride") }
                    }
                }
            }
        }
    }
}

@Composable
private fun ActiveRideScreen(ride: Ride, driver: Boolean, viewModel: MainViewModel) {
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        RouteMap(ride.pickup, ride.destination, ride.driverLocation, Modifier.weight(1f))
        Card(Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
            Column(Modifier.padding(16.dp)) {
                Text(ride.status.name.replace("_", " "), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Text("${ride.pickup.name} → ${ride.destination.name}")
                Text(if (driver) "Rider: ${ride.riderName}" else if (ride.driverName.isBlank()) "Finding your driver…" else "Driver: ${ride.driverName}")
                if (driver && ride.status != RideStatus.SEARCHING) {
                    Button(viewModel::advanceRide, Modifier.fillMaxWidth().padding(top = 8.dp)) {
                        Text(when (ride.status) {
                            RideStatus.ACCEPTED -> "Start heading to pickup"
                            RideStatus.DRIVER_ARRIVING -> "Start trip"
                            RideStatus.IN_PROGRESS -> "Complete trip"
                            else -> "Update trip"
                        })
                    }
                }
                if (ride.status != RideStatus.IN_PROGRESS) {
                    OutlinedButton(viewModel::cancelRide, Modifier.fillMaxWidth().padding(top = 8.dp)) { Text("Cancel ride") }
                }
            }
        }
    }
}

@Composable
private fun RouteMap(pickup: Place?, destination: Place?, current: GeoPoint?, modifier: Modifier = Modifier) {
    val initial = pickup?.location ?: current ?: GeoPoint(37.7749, -122.4194)
    val camera = rememberCameraPositionState()
    LaunchedEffect(initial) {
        camera.move(CameraUpdateFactory.newLatLngZoom(initial.toLatLng(), 12f))
    }
    GoogleMap(modifier = modifier.fillMaxWidth(), cameraPositionState = camera) {
        pickup?.let { Marker(MarkerState(it.location.toLatLng()), title = "Pickup", snippet = it.address) }
        destination?.let { Marker(MarkerState(it.location.toLatLng()), title = "Destination", snippet = it.address) }
        current?.let { Marker(MarkerState(it.toLatLng()), title = "Current location") }
        if (pickup != null && destination != null) {
            Polyline(listOf(pickup.location.toLatLng(), destination.location.toLatLng()), color = MaterialTheme.colorScheme.primary)
        }
    }
}

@Composable
private fun HistoryScreen(state: MainUiState, viewModel: MainViewModel) {
    if (state.history.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("No past rides yet") }
        return
    }
    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(state.history, key = Ride::id) { ride ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("${ride.pickup.name} → ${ride.destination.name}", fontWeight = FontWeight.Bold)
                    Text("${ride.status.name.lowercase().replaceFirstChar(Char::uppercase)} · ${money(ride.quote.amountCents, ride.quote.currency)}")
                    if (state.user?.role == UserRole.RIDER && ride.status == RideStatus.COMPLETED && ride.rating == null) {
                        Row { (1..5).forEach { rating -> TextButton({ viewModel.rate(ride.id, rating) }) { Text("★$rating") } } }
                    }
                }
            }
        }
    }
}

@Composable
private fun AccountScreen(state: MainUiState, viewModel: MainViewModel) {
    Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(state.user?.displayName.orEmpty(), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Text(state.user?.email.orEmpty())
        Text(state.user?.role?.name.orEmpty())
        if (state.user?.vehicle?.isNotBlank() == true) Text(state.user.vehicle)
        Text("★ ${state.user?.rating ?: 5.0}")
        Spacer(Modifier.height(24.dp))
        OutlinedButton(viewModel::signOut) { Text("Sign out") }
    }
}

private fun GeoPoint.toLatLng() = LatLng(latitude, longitude)

private fun money(cents: Int, currency: String): String = NumberFormat.getCurrencyInstance().apply {
    this.currency = runCatching { Currency.getInstance(currency) }.getOrDefault(Currency.getInstance("USD"))
}.format(cents / 100.0)
