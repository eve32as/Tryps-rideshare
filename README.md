# Tryps Rideshare

Tryps is a Kotlin Android rideshare MVP for riders and drivers. It uses Jetpack Compose, Material 3, Google Maps, Firebase Authentication, Cloud Firestore, Cloud Functions, and Cloud Messaging. With no cloud credentials it starts in a fully local demo mode.

## Features

- Email/password registration and sign-in with rider and driver roles
- Pickup and destination search, route map, demand-aware server fare quotes, cash collection tracking, cash split allocation, and admin-issued ride passes
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
- `users/{uid}/ridePasses/{passId}` stores server-issued pass ride counts and expiration; clients may read but cannot issue or modify passes.

Ride recommendations use a deterministic reliability-adjusted score based on traffic-aware pickup ETA, driver cancellation/completion history, observed ETA error, and vehicle-category compatibility. Trusted Cloud Functions record cancellations, completions, and pickup-time error samples using idempotent events. Fare quotes apply capped 1.00×/1.25×/1.50× demand multipliers based on nearby open rides and recently available drivers; each rider-bound quote expires after five minutes and can be used for one ride request. This is a heuristic rather than trained ML; weather forecasts, trained models, and automatic multi-driver assignment remain future work.

Cash ride requests can allocate the fare in equal-cent shares across the requesting rider and up to four registered rider accounts. This is an offline cash arrangement only: the app does not charge invited participants, and the assigned driver confirms receipt of the total cash fare after completing the trip. A ride pass covers one ride per remaining pass credit; only a caller with the trusted Firebase Auth `admin` custom claim can issue passes through the `issueRidePass` Cloud Function. Pass purchases and card processing are not implemented. The card choice remains explicitly simulated and never charges a card. Pass sales, card payments, refunds, and settlements require a payment-provider integration and its server-side verification/webhook setup.
