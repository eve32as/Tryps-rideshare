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

@Test func turnByTurnProgressAdvancesAtManeuverAndStopsAtFinalStep() {
    var progress = TurnByTurnProgress()
    #expect(progress.currentStepIndex == 0)
    let approaching = progress.advanceIfReached(distanceToManeuver: 50, stepCount: 3)
    #expect(!approaching)
    #expect(progress.currentStepIndex == 0)
    let passed = progress.advanceIfReached(distanceToManeuver: 90, stepCount: 3)
    #expect(passed)
    #expect(progress.currentStepIndex == 1)
    progress.reset()
    let reached = progress.advanceIfReached(distanceToManeuver: 35, stepCount: 3)
    #expect(reached)
    #expect(progress.currentStepIndex == 1)
    let reachedNext = progress.advanceIfReached(distanceToManeuver: 0, stepCount: 3)
    #expect(reachedNext)
    #expect(progress.currentStepIndex == 2)
    let atFinalStep = progress.advanceIfReached(distanceToManeuver: 10, stepCount: 3)
    #expect(!atFinalStep)
    let invalidDistance = progress.advanceIfReached(distanceToManeuver: .nan, stepCount: 3)
    #expect(!invalidDistance)
    progress.reset()
    #expect(progress.currentStepIndex == 0)
}
