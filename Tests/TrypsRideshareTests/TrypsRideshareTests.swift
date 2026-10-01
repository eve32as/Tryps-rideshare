import Foundation
import Testing
@testable import TrypsRideshare

@Test func bookingRequiresValidStopsAndAnAvailableRoute() {
    #expect(BookingReadiness.canRequestRide(
        hasPickup: true,
        hasDestination: true,
        hasRoute: true,
        isCalculatingRoute: false
    ))
    #expect(!BookingReadiness.canRequestRide(
        hasPickup: false,
        hasDestination: true,
        hasRoute: true,
        isCalculatingRoute: false
    ))
    #expect(!BookingReadiness.canRequestRide(
        hasPickup: true,
        hasDestination: false,
        hasRoute: true,
        isCalculatingRoute: false
    ))
    #expect(!BookingReadiness.canRequestRide(
        hasPickup: true,
        hasDestination: true,
        hasRoute: false,
        isCalculatingRoute: false
    ))
    #expect(!BookingReadiness.canRequestRide(
        hasPickup: true,
        hasDestination: true,
        hasRoute: true,
        isCalculatingRoute: true
    ))
}

@Test func fareIncludesBothStopSurchargesAndFormatsAsCurrency() {
    let total = BookingFare.total(baseFare: 18, pickupSurcharge: 4, dropOffSurcharge: 24)
    #expect(total == 46)
    #expect(BookingFare.formatted(total, locale: Locale(identifier: "en_US")) == "$46")
}
