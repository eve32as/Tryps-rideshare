# Tryps Rideshare

A SwiftUI rideshare app prototype for iPhone and iPad. The booking screen includes a custom illustrated map, pickup and destination details, searchable destinations, ride tiers with upfront fares, and a ride request confirmation.

## Run the app

Open `TrypsRideshare.xcodeproj` in Xcode, select an iPhone or iPad simulator, and run the `TrypsRideshare` scheme. The iOS app requires iOS 17 or later.

The project also includes a Swift package so its non-Apple fallback can be built and tested from the command line:

```sh
swift test
```

Ride options, locations, fares, and payment details are sample data; live maps, location services, payments, and ride dispatch are not connected.
