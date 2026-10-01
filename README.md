# Tryps Rideshare

Tryps is a SwiftUI rideshare prototype with MapKit place search and directions,
current-location pickup, Sign in with Apple, driver matching, and Stripe
Connect/PaymentSheet integration.

## iOS app

Open `TrypsRideshare.xcodeproj` in Xcode 16 or later, enable the Sign in with
Apple capability for the `com.tryps.rideshare` App ID, and configure:

- `TRYPS_API_BASE_URL`: the deployed API base URL (HTTPS required).
- `STRIPE_PUBLISHABLE_KEY`: the publishable key for the same Stripe account as
  the API. The checked-in value is only a placeholder.

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
npm test
npm start
```

Set the variables shown in `server/.env.example` in the hosting environment.
Generate `SESSION_SECRET` with a cryptographically secure random value. Use TLS
for the API and database connection (`DATABASE_SSL=true` enables TLS for the
PostgreSQL client), keep Stripe secret and webhook keys in the server's secret
manager, and configure the Stripe webhook endpoint at
`/v1/webhooks/stripe` for `payment_intent.succeeded` and
`payment_intent.canceled`. The database role needs permission to install/use
PostGIS or the extension must be enabled by the database administrator.
The built-in rate limiter uses per-process memory; configure a shared store
before running multiple API instances.

`PLATFORM_FEE_BPS` is the platform commission in basis points; set this to the
agreed business rate. Current sample fares are USD-only; `STRIPE_CONNECT_COUNTRY`
must match the business's supported country. Driver onboarding return and
refresh URLs must be HTTPS URLs hosted by your service.

## Prototype limitations

The server selects the nearest online, onboarded driver within 10 km and
reserves that driver for the ride. The driver screen sends a heartbeat and polls
for assigned rides while open; drivers without a heartbeat for 2 minutes are
taken offline automatically. Unpaid ride reservations expire after 20 minutes. Push
notifications, driver identity/safety verification, trip tracking, server-side
ride-history sync, cancellations/refunds after payment, and fare calculation
from route distance are not implemented. The fixed sample fare is charged when
the rider confirms payment; the example fee/currency are not production pricing.
Configure Stripe in test mode first and complete operational, legal, safety,
privacy, and payment testing before accepting live rides or charges.
