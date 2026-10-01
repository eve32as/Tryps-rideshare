#if canImport(SwiftUI)
import SwiftUI
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(UIKit)
import UIKit
class TrypsApplicationDelegate: NSObject, UIApplicationDelegate { }
#endif

@main
struct TrypsRideshareApp: App {
#if canImport(UIKit)
    @UIApplicationDelegateAdaptor(TrypsApplicationDelegate.self) private var applicationDelegate
#endif
    @StateObject private var account = FirebaseAccountStore.shared
    @StateObject private var locationManager = PickupLocationManager()

    init() {
        #if canImport(FirebaseCore)
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil,
           FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem {
                        Label("Ride", systemImage: "car.side.fill")
                    }

                DriverExperienceView(account: account, locationManager: locationManager)
                    .tabItem {
                        Label("Drive", systemImage: "steeringwheel")
                    }
            }
            .tint(TrypsStyle.green)
        }
    }
}
#else
@main
struct TrypsRideshareApp {
    static func main() {
        print("Tryps Rideshare is a SwiftUI app. Open this package on an Apple platform to run the app.")
    }
}
#endif
