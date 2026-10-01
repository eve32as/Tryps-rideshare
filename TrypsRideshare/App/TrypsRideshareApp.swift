import SwiftData
import SwiftUI

@main
struct TrypsRideshareApp: App {
    @UIApplicationDelegateAdaptor(TrypsAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: RideBooking.self)
    }
}
