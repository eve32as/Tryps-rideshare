ALTER TABLE rides
    ALTER COLUMN driver_user_id DROP NOT NULL,
    ADD COLUMN IF NOT EXISTS scheduled_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS payment_created_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS share_token_hash TEXT,
    ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;

UPDATE rides
SET payment_created_at = created_at
WHERE status = 'awaiting_payment'
  AND payment_intent_id IS NOT NULL
  AND payment_created_at IS NULL;

ALTER TABLE drivers
    ADD COLUMN IF NOT EXISTS location_updated_at TIMESTAMPTZ;

UPDATE drivers
SET location_updated_at = updated_at
WHERE location IS NOT NULL
  AND location_updated_at IS NULL;

ALTER TABLE rides DROP CONSTRAINT IF EXISTS rides_status_check;
ALTER TABLE rides
    ADD CONSTRAINT rides_status_check
    CHECK (status IN ('scheduled', 'awaiting_payment', 'confirmed', 'completed', 'cancelled'));

CREATE UNIQUE INDEX IF NOT EXISTS rides_share_token_hash_idx
    ON rides (share_token_hash)
    WHERE share_token_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS rides_scheduled_idx
    ON rides (scheduled_at)
    WHERE status = 'scheduled';

CREATE TABLE IF NOT EXISTS ride_ratings (
    id UUID PRIMARY KEY,
    ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
    rater_user_id TEXT NOT NULL REFERENCES app_users(id),
    rated_user_id TEXT NOT NULL REFERENCES app_users(id),
    stars SMALLINT NOT NULL CHECK (stars BETWEEN 1 AND 5),
    comment TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (ride_id, rater_user_id),
    CHECK (rater_user_id <> rated_user_id)
);

CREATE TABLE IF NOT EXISTS saved_places (
    id UUID PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 60),
    label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 200),
    location GEOGRAPHY(POINT, 4326) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, name)
);

CREATE INDEX IF NOT EXISTS saved_places_user_idx ON saved_places (user_id, created_at);

CREATE TABLE IF NOT EXISTS notification_devices (
    user_id TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
    device_token TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, device_token),
    UNIQUE (device_token)
);
