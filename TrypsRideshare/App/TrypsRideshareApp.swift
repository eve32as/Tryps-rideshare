import SwiftData
import SwiftUI

@main
struct TrypsRideshareApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: RideBooking.self)
    }
}
