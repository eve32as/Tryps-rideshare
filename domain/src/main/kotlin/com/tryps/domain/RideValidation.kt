package com.tryps.domain

import com.tryps.model.Place

object RideValidation {
    fun loginError(email: String, password: String): String? = when {
        !email.contains("@") -> "Enter a valid email address"
        password.length < 6 -> "Password must contain at least 6 characters"
        else -> null
    }

    fun routeError(pickup: Place?, destination: Place?): String? = when {
        pickup == null -> "Choose a pickup"
        destination == null -> "Choose a destination"
        pickup.location == destination.location -> "Pickup and destination must differ"
        else -> null
    }
}
