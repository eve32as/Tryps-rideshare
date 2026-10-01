# Tryps Rideshare

A SwiftUI rideshare app prototype for iPhone and iPad. The booking screen uses Apple Maps, device location, live place search, and driving directions with estimated trip time and distance.

## Run the app

Open `TrypsRideshare.xcodeproj` in Xcode, select an iPhone or iPad simulator, and run the `TrypsRideshare` scheme. The iOS app requires iOS 17 or later.

The project also includes a Swift package. On macOS 14 or later with a compatible Swift 6.4 toolchain, `swift test` builds the SwiftUI app target; on Linux it builds the command-line fallback and runs the portable tests:

```sh
swift test
```

The app requests location access while in use to suggest the pickup point. Pickup and drop-off can both be searched and edited. Ride confirmation stays disabled until both stops are valid and MapKit returns a driving route. If location access is denied, a pickup can be searched manually; search and routing failures are shown in the booking flow.

## Firebase accounts

The Xcode app target uses Firebase Apple SDK 12.19.2 through Swift Package Manager for Firebase Core and Firebase Authentication. To enable accounts:

1. Create an iOS app in the Firebase Console with bundle identifier `com.tryps.rideshare`.
2. Enable **Email/Password** under Authentication sign-in providers.
3. Download `GoogleService-Info.plist`, add it to the Xcode project, and ensure it is included in the app target.
4. Run the app and use the profile icon to create an account or sign in.

The Firebase config plist is intentionally git-ignored; do not commit it. If it is absent, the booking prototype remains usable and the account screen explains setup is needed. Firebase Authentication manages the session; passwords are sent to Firebase Auth and are not stored by the app.

Ride options, fares, payment details, and ride requests are still sample data. Firestore-backed saved places, trusted Cloud Functions for quotes/booking/status, payments, and driver workflows are not connected yet. Those require Firebase project configuration and deployed backend function contracts; never calculate authoritative fares or process payments in the client.
