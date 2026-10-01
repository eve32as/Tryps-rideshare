import Testing
@testable import TrypsRideshare

@Test func example() async throws {
    // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    // Swift Testing Documentation
    // https://swiftpackageindex.com/swiftlang/swift-testing/documentation
}

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
