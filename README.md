# Tryps Rideshare

Tryps is a Kotlin Android rideshare MVP for riders and drivers. It uses Jetpack Compose, Material 3, Google Maps, Firebase Authentication, Cloud Firestore, Cloud Functions, and Cloud Messaging. With no cloud credentials it starts in a fully local demo mode.

## Features

- Email/password registration and sign-in with rider and driver roles
- Pickup and destination search, route map, demand-aware server fare quotes, and simulated payment
- Ride request, category-aware driver acceptance, trip status, cancellation, history, and ratings
- Driver vehicle categories, availability, location updates, and traffic-aware pickup recommendations
- Push-notification service for ride updates
- Offline-friendly Firestore listeners and a no-credentials demo backend
- Firestore security rules and server-only Google Routes/Places API access

## Architecture

| Module | Responsibility |
| --- | --- |
| `app` | Compose UI, navigation, Android permissions, location, notifications |
| `domain` | Repository contracts and business validation |
| `data` | Firebase and in-memory demo repository implementations |
| `core:model` | Shared immutable models |
| `functions` | Authenticated ride recommendations, locked demand-aware quotes, ride requests, and place-search Cloud Functions |

## Requirements

- Android Studio with JDK 17, Android SDK 35, and AGP 9.x support
- A Firebase project with Email/Password Authentication, Firestore, Functions, and Messaging
- Google Maps SDK for Android, Routes API, and Places API (New)
- Node.js 22 and Firebase CLI for backend deployment

## Configuration

Secrets are never committed. Supply these as Gradle properties in `~/.gradle/gradle.properties`, with `-P`, or as environment variables:

```properties
MAPS_API_KEY=android-restricted-key
FIREBASE_API_KEY=firebase-web-api-key
FIREBASE_APP_ID=firebase-android-app-id
FIREBASE_PROJECT_ID=firebase-project-id
```

Restrict `MAPS_API_KEY` to the Android package and signing certificate. The Android app never receives the server key. Configure and deploy that key through Firebase Secret Manager:

```bash
firebase functions:secrets:set GOOGLE_MAPS_API_KEY
firebase deploy --only firestore:rules,functions
```

When the three Firebase values are absent, Tryps uses demo mode. Sign in with `rider@demo.com` or `driver@demo.com` and any password of at least six characters.

## Build and test

```bash
./gradlew test
./gradlew :app:assembleDebug
./gradlew :app:assembleRelease
cd functions && npm test && npm audit --omit=dev
```

The release build is unsigned until a secure local or CI signing configuration is supplied.
GitHub Actions runs these checks on every pull request and `main` push, then uploads
the debug and unsigned release APKs as the `tryps-apks` workflow artifact. The
workflow can also be started manually from the Actions tab.

## Data model

- `users/{uid}` stores account role, profile, driver vehicle category, and server-maintained matching metrics.
- `drivers/{uid}` stores availability and latest location.
- `rides/{rideId}` stores route, requested vehicle category, server quote, participants, status, pickup ETA at acceptance, and optional rating.

Ride recommendations use a deterministic reliability-adjusted score based on traffic-aware pickup ETA, driver cancellation/completion history, observed ETA error, and vehicle-category compatibility. Trusted Cloud Functions record cancellations, completions, and pickup-time error samples using idempotent events. Fare quotes apply capped 1.00×/1.25×/1.50× demand multipliers based on nearby open rides and recently available drivers; each rider-bound quote expires after five minutes and can be used for one ride request. This is a heuristic rather than trained ML; weather forecasts, trained models, and automatic multi-driver assignment remain future work.
