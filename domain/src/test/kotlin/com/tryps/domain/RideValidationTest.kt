package com.tryps.domain

import com.tryps.model.GeoPoint
import com.tryps.model.Place
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RideValidationTest {
    @Test
    fun rejectsInvalidCredentials() {
        assertEquals("Enter a valid email address", RideValidation.loginError("rider", "secret"))
        assertEquals("Password must contain at least 6 characters", RideValidation.loginError("rider@test.com", "123"))
        assertNull(RideValidation.loginError("rider@test.com", "secret"))
    }

    @Test
    fun rejectsIdenticalRoute() {
        val place = Place("Home", location = GeoPoint(1.0, 2.0))
        assertEquals("Pickup and destination must differ", RideValidation.routeError(place, place))
    }
}
