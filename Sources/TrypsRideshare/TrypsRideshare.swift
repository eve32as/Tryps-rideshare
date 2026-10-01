#if canImport(SwiftUI)
import SwiftUI

@main
struct TrypsRideshareApp: App {
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
