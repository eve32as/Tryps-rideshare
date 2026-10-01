#if canImport(SwiftUI)
import SwiftUI
#if canImport(FirebaseCore)
import FirebaseCore
#endif

@main
struct TrypsRideshareApp: App {
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
            ContentView()
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
