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

Deploying the scheduled ride retry function requires a Firebase project on the Blaze plan. Deploy `firestore.indexes.json` with the Functions and rules so geohash and retry queries can run.

### Driver administration

Driver applications are stored for review and do not grant driver access until approved. The `approveDriverApplication` callable requires an account with the `admin` custom claim. Bootstrap the first administrator using Application Default Credentials (do not download or commit a service-account key):

```sh
gcloud auth application-default login
GCLOUD_PROJECT=YOUR_FIREBASE_PROJECT_ID node functions/scripts/grant-admin.js FIREBASE_AUTH_UID
```

After adding the claim, sign out and back in or use **Refresh account access** in the profile. An administrator client can then call `approveDriverApplication` with the pending driver's UID. Approved drivers must allow foreground location and keep the driver screen open while online; location refreshes every minute, and locations older than two minutes are excluded from offers.

### Local checks

```sh
npm ci --prefix functions
npm test --prefix functions
npm audit --prefix functions
swift test
```

SwiftUI, MapKit, Firebase Apple SDK, and Stripe PaymentSheet require Xcode for a native iOS build; `swift test` on Linux exercises only the portable Swift code and tests.

### Pricing and matching

The server owns a versioned USD rate card in `functions/domain.js`: Everyday $8.00 + $1.80/km, Comfort $12.00 + $2.40/km, and XL $16.00 + $3.00/km, plus a $2.00 booking fee and $11.00 minimum fare. It models distance as 1.25 times straight-line distance, then returns a fare breakdown; this is an estimate, not a navigation route or guaranteed final fare. The rate card is capped at 200 estimated kilometers. Change and review rates on the server before deploying pricing changes.

Driver matching queries Firestore geohash bounds within 15 km, filters to approved/available drivers with a location updated in the last two minutes, ranks by exact great-circle distance, and sends offers to up to ten nearest drivers. Offers expire after one minute; a scheduled Function retries unmatched or expired rides. The driver app refreshes its location while open and online. This is a bounded MVP dispatcher: it does not account for road ETA, traffic, driver capacity beyond availability, location spoofing, or guaranteed delivery. Validate the pricing and dispatch model, location/privacy disclosures, legal terms, and payment configuration before production use.
