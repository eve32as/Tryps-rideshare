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
    var rideID: String?
    var shareURL: String?
    var status: String?

    init(
        pickup: String,
        destination: String,
        rideName: String,
        fare: String,
        rideID: String? = nil,
        shareURL: String? = nil,
        status: String? = nil
    ) {
        id = UUID()
        self.pickup = pickup
        self.destination = destination
        self.rideName = rideName
        self.fare = fare
        self.rideID = rideID
        self.shareURL = shareURL
        self.status = status
        requestedAt = .now
    }
}
