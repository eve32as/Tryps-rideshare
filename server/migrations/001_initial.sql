CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS app_users (
    id TEXT PRIMARY KEY,
    role TEXT NOT NULL CHECK (role IN ('rider', 'driver')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS drivers (
    user_id TEXT PRIMARY KEY REFERENCES app_users(id) ON DELETE CASCADE,
    stripe_account_id TEXT UNIQUE NOT NULL,
    available BOOLEAN NOT NULL DEFAULT false,
    location GEOGRAPHY(POINT, 4326),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS drivers_location_idx
    ON drivers USING GIST (location)
    WHERE available = true;

CREATE TABLE IF NOT EXISTS rides (
    id UUID PRIMARY KEY,
    rider_user_id TEXT NOT NULL REFERENCES app_users(id),
    driver_user_id TEXT NOT NULL REFERENCES drivers(user_id),
    pickup_label TEXT NOT NULL,
    pickup GEOGRAPHY(POINT, 4326) NOT NULL,
    destination_label TEXT NOT NULL,
    destination GEOGRAPHY(POINT, 4326) NOT NULL,
    ride_type TEXT NOT NULL,
    amount_cents INTEGER NOT NULL CHECK (amount_cents > 0),
    currency TEXT NOT NULL,
    payment_intent_id TEXT UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('awaiting_payment', 'confirmed', 'cancelled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS rides_rider_created_idx
    ON rides (rider_user_id, created_at DESC);
