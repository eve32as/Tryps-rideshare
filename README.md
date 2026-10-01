# Tryps Rideshare

A SwiftUI rideshare app prototype for iPhone and iPad. The booking screen uses Apple Maps, device location, live place search, and driving directions with estimated trip time and distance.

## Run the app

Open `TrypsRideshare.xcodeproj` in Xcode, select an iPhone or iPad simulator, and run the `TrypsRideshare` scheme. The iOS app requires iOS 17 or later.

The project also includes a Swift package. On macOS 14 or later with a compatible Swift 6.4 toolchain, `swift test` builds the SwiftUI app target; on Linux it builds the command-line fallback and runs the portable tests:

```sh
swift test
```

The app requests location access while in use to suggest the pickup point. Pickup and drop-off can both be searched and edited. Ride confirmation stays disabled until both stops are valid and MapKit returns a driving route. If location access is denied, a pickup can be searched manually; search and routing failures are shown in the booking flow.

## Firebase setup

The iOS app uses Firebase Apple SDK 12.19.2 and Stripe PaymentSheet. The backend uses Firebase Admin/Cloud Functions on Node.js 22 and Stripe's server SDK. Configure your own Firebase and Stripe projects before using account, quote, booking, payment, or driver features:

1. Create a Firebase project and register an iOS app with bundle identifier `com.tryps.rideshare`.
2. Enable **Email/Password** in Authentication and create a Cloud Firestore database.
3. Download `GoogleService-Info.plist`, add it to `TrypsRideshare.xcodeproj`, and include it in the app target. The file is git-ignored; never commit it.
4. Install the Firebase CLI, authenticate it, and deploy the backend and database rules:

   ```sh
   firebase login
   firebase deploy --only firestore:rules,firestore:indexes,functions --project YOUR_FIREBASE_PROJECT_ID
   ```

   Cloud Functions deploy prompts for `STRIPE_PUBLISHABLE_KEY` if it is not already configured. Use a Stripe **test** publishable key for development.
5. Set the Stripe secret key and webhook signing secret with Secret Manager. In Stripe, add a webhook endpoint for the deployed `stripeWebhook` function and subscribe to `payment_intent.succeeded` and `payment_intent.payment_failed`, then set its signing secret:

   ```sh
   firebase functions:secrets:set STRIPE_SECRET_KEY --project YOUR_FIREBASE_PROJECT_ID
   firebase functions:secrets:set STRIPE_WEBHOOK_SECRET --project YOUR_FIREBASE_PROJECT_ID
   ```

   Redeploy Functions after setting or rotating secrets. Keep all keys out of source control; `.env*`, `GoogleService-Info.plist`, and local credentials are ignored.
6. Build and run the app from Xcode, create an account, and sign in. The client calls authenticated Functions for quotes, bookings, payment intents, cancellations/refunds, and driver actions. Firestore rules prevent clients from writing ride, quote, driver, or payment records.

### Driver administration

Driver applications are stored for review and do not grant driver access until approved. The `approveDriverApplication` callable requires an account with the `admin` custom claim. Bootstrap the first administrator using Application Default Credentials (do not download or commit a service-account key):

```sh
gcloud auth application-default login
GCLOUD_PROJECT=YOUR_FIREBASE_PROJECT_ID node functions/scripts/grant-admin.js FIREBASE_AUTH_UID
```

After adding the claim, sign out and back in or use **Refresh account access** in the profile. An administrator client can then call `approveDriverApplication` with the pending driver's UID.

### Local checks

```sh
npm ci --prefix functions
npm test --prefix functions
npm audit --prefix functions
swift test
```

SwiftUI, MapKit, Firebase Apple SDK, and Stripe PaymentSheet require Xcode for a native iOS build; `swift test` on Linux exercises only the portable Swift code and tests.

The current backend quote is an MVP estimate calculated from straight-line coordinates using rates in `functions/domain.js`; it does not use MapKit's road distance, dynamic pricing, or a production dispatch/geospatial service. Configure and validate pricing, service area, legal terms, privacy disclosures, and Stripe production settings before accepting live rides or payments.
