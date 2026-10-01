# Tryps Rideshare

Tryps is a SwiftUI iOS rideshare prototype with MapKit place search and directions,
current-location pickup, Sign in with Apple, driver matching, scheduled rides,
driver location sharing, saved places, ratings, and Stripe Connect/PaymentSheet.
Fare estimates use server-side driving routes and signed, time-limited quotes.
The booking map can show coarse nearby driver activity; drivers can receive
pickup and destination proximity alerts; the last calculated route is cached for
short interruptions.

## iOS app

Open `TrypsRideshare.xcodeproj` in Xcode 16 or later, enable the Sign in with
Apple capability for the `com.tryps.rideshare` App ID, and configure:

- `TRYPS_API_BASE_URL`: the deployed API base URL (HTTPS required).
- `STRIPE_PUBLISHABLE_KEY`: the publishable key for the same Stripe account as
  the API. The checked-in value is only a placeholder.
- Enable Sign in with Apple and Push Notifications for the App ID and use an
  APNs-capable provisioning profile. Debug uses the APNs sandbox; Release uses
  production APNs.

The app uses the Stripe iOS SDK through Swift Package Manager. Do not add Stripe
secret keys to the Xcode project or app.

## API and database

The API uses Node.js 20+, PostgreSQL with PostGIS, and Stripe Connect. From
`server/`, install packages and apply the schema:

```sh
cp .env.example .env
# Fill in the local test credentials and service URLs.
set -a
. ./.env
set +a
npm ci
psql "$DATABASE_URL" -f migrations/001_initial.sql
psql "$DATABASE_URL" -f migrations/002_advanced_features.sql
npm test
npm start
```

Set the variables shown in `server/.env.example` in the hosting environment.
Generate `SESSION_SECRET` with a cryptographically secure random value. Use TLS
for the API and database connection (`DATABASE_SSL=true` enables TLS for the
PostgreSQL client), keep Stripe secret and webhook keys in the server's secret
manager, and configure the Stripe webhook endpoint at
`/v1/webhooks/stripe` for `payment_intent.succeeded`, `payment_intent.canceled`,
`refund.updated`, and `refund.failed`. The database role needs permission to install/use
PostGIS or the extension must be enabled by the database administrator.
The built-in rate limiter uses per-process memory; configure a shared store
before running multiple API instances.

Enable the Google Routes API and provide `GOOGLE_ROUTES_API_KEY` to the API
service. Restrict this key to the Routes API, keep it only in the server's secret
manager, and configure provider quotas and billing alerts. Route lookups have an
8-second timeout; if routing is unavailable, fare estimates and ride requests
fail closed rather than silently falling back to straight-line distance.

`PLATFORM_FEE_BPS` is the platform commission in basis points; set this to the
agreed business rate. The API calculates estimates from Google Routes driving
distance, rounded to 0.1 km, plus configurable base, per-kilometer, ride-category,
and minimum charges. Estimates are signed and bound to the requested coordinates
and ride type for 10 minutes; ride creation charges the verified quote amount
instead of silently recalculating a different fare. Set `FARE_BASE_CENTS`,
`FARE_PER_KM_CENTS`, and `FARE_MINIMUM_CENTS` to approved local prices. Current
sample fares are USD-only; `STRIPE_CONNECT_COUNTRY` must match the business's
supported country. Driver onboarding return and refresh URLs must be HTTPS URLs
hosted by your service.

For APNs, configure all of `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`,
and `APNS_HOST` in the server secret manager. Use the `.p8` signing key contents
for `APNS_PRIVATE_KEY` (newlines may be escaped as `\n`); never commit the key.
Set `APNS_HOST` to `api.sandbox.push.apple.com` for development builds and
`api.push.apple.com` for Release. Notifications are best-effort; APNs delivery
is not guaranteed.

The rider map's driver-activity heatmap is authenticated, rounded to roughly
2-km geographic cells, includes only cells with at least three currently active
drivers, and caps displayed counts. It reports available-driver density, not
rider demand, arrival guarantees, or a safety score. Drivers with assigned rides
can receive local entry alerts within 150 meters of pickup and destination when
Always location permission is enabled. These alerts are informational and never
change ride status automatically.

## Prototype limitations

The server selects the nearest online, onboarded driver within 10 km and
reserves that driver for the ride. The driver screen sends a heartbeat and polls
for assigned rides while open; drivers without fresh location or heartbeat data
for 2 minutes are excluded from matching. Unpaid ride reservations expire after
20 minutes. Driver identity/safety verification, server-side ride-history sync,
and configurable cancellation fees are not implemented.
Riders can
request a full refund for a confirmed ride before it is completed; the API
reverses the connected-driver transfer and platform fee through Stripe. Refund
availability depends on Stripe's charge state and connected-account balance,
and settlement time depends on the payment method and bank. Scheduled rides are
dispatched within 15 minutes of pickup; the rider must open Activity to complete
payment once a driver is matched; APNs alerts are sent when configured. Drivers
must opt in to Always location permission to share updates while Tryps is
backgrounded. iOS may throttle background location, and a driver with stale
location data is excluded from matching. The rider Activity screen polls while
open, and trip-share pages refresh every 15 seconds. Configure
`TRIP_SHARE_BASE_URL` as the public
HTTPS URL ending in `/v1/shared-trips`; share tokens grant access to trip
status and the driver's latest location and expire 24 hours after the trip's
scheduled, completed, or created time. Ratings are one per participant and only
available after completion; saved places are private to the signed-in rider.

The booking map retains only its most recent route geometry on device for up to
24 hours and can redraw it during a network interruption. This is not an offline
map download or turn-by-turn navigation; Apple map tiles and directions may still
be unavailable without connectivity, and location can be stale in a tunnel.

The signed fare quote is charged when the rider confirms payment; the sample rate
card is not a finalized production pricing policy. Configure Stripe in test mode
first and complete operational, legal, safety, privacy, and payment testing
before accepting live rides or charges.
