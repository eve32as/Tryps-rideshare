import Foundation
import SwiftData

@Model
final class RideBooking {
    var id: UUID
    var pickup: String
    var destination: String
    var rideName: String
    var fare: String
    var requestedAt: Date

    init(pickup: String, destination: String, rideName: String, fare: String) {
        id = UUID()
        self.pickup = pickup
        self.destination = destination
        self.rideName = rideName
        self.fare = fare
        requestedAt = .now
    }
}
