enum BookingReadiness {
    static func canRequestRide(
        hasPickup: Bool,
        hasDestination: Bool,
        hasRoute: Bool,
        isCalculatingRoute: Bool
    ) -> Bool {
        hasPickup && hasDestination && hasRoute && !isCalculatingRoute
    }
}
