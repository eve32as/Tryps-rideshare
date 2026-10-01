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

1. Create a Firebase project and register an iOS app with bundle identifier `com.tryps.rideshare`. Enable the **Routes API** in the linked Google Cloud project and attach billing/quotas.
2. Enable **Email/Password** in Authentication and create a Cloud Firestore database.
3. Download `GoogleService-Info.plist`, add it to `TrypsRideshare.xcodeproj`, and include it in the app target. The file is git-ignored; never commit it.
4. Install the Firebase CLI, authenticate it, and deploy the backend and database rules:

   ```sh
   firebase login
   firebase deploy --only firestore:rules,firestore:indexes,functions --project YOUR_FIREBASE_PROJECT_ID
   ```

   On first deploy, provide `GOOGLE_ROUTES_API_KEY` and `STRIPE_SECRET_KEY` when prompted for the function secrets, and set `STRIPE_PUBLISHABLE_KEY` to your Stripe **test** publishable key. Restrict the Google key to Routes API, monitor quotas, and never put it in the app.
5. In Stripe, add a webhook endpoint for the deployed `stripeWebhook` function and subscribe to `payment_intent.succeeded` and `payment_intent.payment_failed`. Set its signing secret with Secret Manager and redeploy Functions:

   ```sh
   firebase functions:secrets:set STRIPE_WEBHOOK_SECRET --project YOUR_FIREBASE_PROJECT_ID
   firebase deploy --only functions --project YOUR_FIREBASE_PROJECT_ID
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

### Route pricing and matching

The server requests a driving route from Google Routes API and calculates all ride options from that route's exact distance in meters (rounded up to the next cent); it never accepts a client-provided fare or distance. A single route request prices all displayed ride classes. Route lookup errors fail quote creation rather than silently falling back to straight-line pricing. Quotes expire after five minutes and store route distance and estimated duration with the fare.

The version 2 USD rate card in `functions/domain.js` is:

| Ride | Base | Per route km |
| --- | ---: | ---: |
| Everyday | $2.50 | $1.25 |
| Comfort | $4.00 | $1.75 |
| XL | $6.00 | $2.25 |

All rides add a $1.50 booking fee and have a $5.00 minimum fare. The quote returns and displays the base, route-distance charge, booking fee, and any minimum-fare adjustment. These are proposed MVP rates, not market-validated or jurisdiction-approved; review them before live use. Route duration/distance is an estimate and the completed trip may differ.

Driver matching queries Firestore geohash bounds within 15 km, filters to approved/available drivers with a location updated in the last two minutes, ranks by exact great-circle distance, and sends offers to up to ten nearest drivers. Offers expire after one minute; a scheduled Function retries unmatched or expired rides. The driver app refreshes its location while open and online. This is a bounded MVP dispatcher: it does not account for road ETA, traffic, driver capacity beyond availability, location spoofing, or guaranteed delivery. Validate the pricing and dispatch model, location/privacy disclosures, legal terms, and payment configuration before production use.
