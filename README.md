# Tryps Rideshare

A SwiftUI rideshare app prototype for iPhone and iPad. The booking screen uses Apple Maps, device location, live place search, and driving directions with estimated trip time and distance.

## Run the app

Open `TrypsRideshare.xcodeproj` in Xcode, select an iPhone or iPad simulator, and run the `TrypsRideshare` scheme. The iOS app requires iOS 17 or later.

The project also includes a Swift package so its non-Apple fallback can be built and tested from the command line:

```sh
swift test
```

The app requests location access while in use to identify the pickup point. If access is denied or a route cannot be found, the app reports that state and keeps the map and destination search available. Ride options, fares, payment details, and ride requests are still sample data; payments and ride dispatch are not connected.
