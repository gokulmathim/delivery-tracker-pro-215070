-- Delivery Tracker database schema + minimal seed data
-- Intended to be safe to run multiple times (uses IF NOT EXISTS / ON CONFLICT).
-- Run via: psql postgresql://... -f schema_and_seed.sql

BEGIN;

-- UUID support
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Updated-at trigger helper
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Roles enum
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
    CREATE TYPE user_role AS ENUM ('admin', 'user', 'driver');
  END IF;
END$$;

-- Delivery status enum
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'delivery_status') THEN
    CREATE TYPE delivery_status AS ENUM (
      'created',
      'picked_up',
      'in_transit',
      'out_for_delivery',
      'delivered',
      'exception',
      'cancelled'
    );
  END IF;
END$$;

-- Users
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  full_name TEXT,
  role user_role NOT NULL DEFAULT 'user',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_set_updated_at'
  ) THEN
    CREATE TRIGGER trg_users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END$$;

-- Refresh/auth tokens (for session refresh)
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  ip_address INET,
  user_agent TEXT
);

-- Deliveries
CREATE TABLE IF NOT EXISTS deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tracking_number TEXT NOT NULL UNIQUE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, -- customer/owner
  assigned_driver_id UUID REFERENCES users(id) ON DELETE SET NULL, -- optional
  carrier TEXT,
  title TEXT,
  description TEXT,
  origin_address TEXT,
  destination_address TEXT,
  scheduled_delivery_date DATE,
  current_status delivery_status NOT NULL DEFAULT 'created',
  current_location_lat DOUBLE PRECISION,
  current_location_lng DOUBLE PRECISION,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_deliveries_set_updated_at'
  ) THEN
    CREATE TRIGGER trg_deliveries_set_updated_at
    BEFORE UPDATE ON deliveries
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END$$;

-- Delivery status events (timeline)
CREATE TABLE IF NOT EXISTS delivery_status_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
  status delivery_status NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  note TEXT,
  created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL
);

-- Location pings (time-series)
CREATE TABLE IF NOT EXISTS location_pings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
  pinged_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lat DOUBLE PRECISION NOT NULL,
  lng DOUBLE PRECISION NOT NULL,
  accuracy_m DOUBLE PRECISION,
  speed_mps DOUBLE PRECISION,
  heading_deg DOUBLE PRECISION,
  source TEXT
);

-- Notification preferences (per user)
CREATE TABLE IF NOT EXISTS notification_preferences (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  email_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  push_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  sms_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  notify_on_status_change BOOLEAN NOT NULL DEFAULT TRUE,
  notify_on_exception BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notification_preferences_set_updated_at'
  ) THEN
    CREATE TRIGGER trg_notification_preferences_set_updated_at
    BEFORE UPDATE ON notification_preferences
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END$$;

-- Notification logs (audit of notifications sent)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_channel') THEN
    CREATE TYPE notification_channel AS ENUM ('email', 'push', 'sms');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_status') THEN
    CREATE TYPE notification_status AS ENUM ('queued', 'sent', 'failed');
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS notification_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  delivery_id UUID REFERENCES deliveries(id) ON DELETE SET NULL,
  channel notification_channel NOT NULL,
  status notification_status NOT NULL DEFAULT 'queued',
  event_type TEXT NOT NULL, -- e.g., status_changed, exception
  payload JSONB,
  error_message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sent_at TIMESTAMPTZ
);

-- Indexes for lookups by user_id, delivery_id, and time
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_expires_at ON refresh_tokens(expires_at);

CREATE INDEX IF NOT EXISTS idx_deliveries_user_id ON deliveries(user_id);
CREATE INDEX IF NOT EXISTS idx_deliveries_assigned_driver_id ON deliveries(assigned_driver_id);
CREATE INDEX IF NOT EXISTS idx_deliveries_created_at ON deliveries(created_at);
CREATE INDEX IF NOT EXISTS idx_deliveries_updated_at ON deliveries(updated_at);
CREATE INDEX IF NOT EXISTS idx_deliveries_current_status ON deliveries(current_status);

CREATE INDEX IF NOT EXISTS idx_delivery_status_events_delivery_id ON delivery_status_events(delivery_id);
CREATE INDEX IF NOT EXISTS idx_delivery_status_events_occurred_at ON delivery_status_events(occurred_at);
CREATE INDEX IF NOT EXISTS idx_delivery_status_events_delivery_time ON delivery_status_events(delivery_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_location_pings_delivery_id ON location_pings(delivery_id);
CREATE INDEX IF NOT EXISTS idx_location_pings_pinged_at ON location_pings(pinged_at);
CREATE INDEX IF NOT EXISTS idx_location_pings_delivery_time ON location_pings(delivery_id, pinged_at DESC);

CREATE INDEX IF NOT EXISTS idx_notification_logs_user_id ON notification_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_notification_logs_delivery_id ON notification_logs(delivery_id);
CREATE INDEX IF NOT EXISTS idx_notification_logs_created_at ON notification_logs(created_at);

-- --------------------
-- Minimal seed data
-- --------------------

-- Users (password_hash is placeholder; backend should manage real hashes)
INSERT INTO users (email, password_hash, full_name, role)
VALUES
  ('admin@local.test', 'dev-hash-admin', 'Local Admin', 'admin'),
  ('user@local.test',  'dev-hash-user',  'Local User',  'user')
ON CONFLICT (email) DO NOTHING;

-- Notification preferences
INSERT INTO notification_preferences (user_id, email_enabled, push_enabled, sms_enabled)
SELECT id, TRUE, FALSE, FALSE
FROM users
WHERE email IN ('admin@local.test', 'user@local.test')
ON CONFLICT (user_id) DO NOTHING;

-- Deliveries
INSERT INTO deliveries (
  tracking_number, user_id, carrier, title, description,
  origin_address, destination_address, scheduled_delivery_date, current_status
)
SELECT
  'TRK-LOCAL-0001',
  (SELECT id FROM users WHERE email = 'user@local.test'),
  'LocalCarrier',
  'Retro Keyboard',
  'A clicky keyboard delivery',
  'Warehouse A',
  'User Home',
  CURRENT_DATE + 2,
  'in_transit'
WHERE NOT EXISTS (SELECT 1 FROM deliveries WHERE tracking_number = 'TRK-LOCAL-0001');

INSERT INTO deliveries (
  tracking_number, user_id, carrier, title, description,
  origin_address, destination_address, scheduled_delivery_date, current_status
)
SELECT
  'TRK-LOCAL-0002',
  (SELECT id FROM users WHERE email = 'user@local.test'),
  'LocalCarrier',
  'CRT Monitor',
  'A vintage monitor delivery',
  'Warehouse B',
  'User Office',
  CURRENT_DATE + 1,
  'out_for_delivery'
WHERE NOT EXISTS (SELECT 1 FROM deliveries WHERE tracking_number = 'TRK-LOCAL-0002');

-- Status events
INSERT INTO delivery_status_events (delivery_id, status, occurred_at, note, created_by_user_id)
SELECT
  (SELECT id FROM deliveries WHERE tracking_number = 'TRK-LOCAL-0001'),
  'created',
  NOW() - INTERVAL '2 days',
  'Order created',
  (SELECT id FROM users WHERE email = 'admin@local.test')
WHERE NOT EXISTS (
  SELECT 1 FROM delivery_status_events e
  JOIN deliveries d ON d.id = e.delivery_id
  WHERE d.tracking_number = 'TRK-LOCAL-0001' AND e.status = 'created'
);

INSERT INTO delivery_status_events (delivery_id, status, occurred_at, note, created_by_user_id)
SELECT
  (SELECT id FROM deliveries WHERE tracking_number = 'TRK-LOCAL-0001'),
  'in_transit',
  NOW() - INTERVAL '6 hours',
  'Package is moving through the network',
  (SELECT id FROM users WHERE email = 'admin@local.test')
WHERE NOT EXISTS (
  SELECT 1 FROM delivery_status_events e
  JOIN deliveries d ON d.id = e.delivery_id
  WHERE d.tracking_number = 'TRK-LOCAL-0001' AND e.status = 'in_transit'
);

INSERT INTO delivery_status_events (delivery_id, status, occurred_at, note, created_by_user_id)
SELECT
  (SELECT id FROM deliveries WHERE tracking_number = 'TRK-LOCAL-0002'),
  'out_for_delivery',
  NOW() - INTERVAL '2 hours',
  'Courier is on the way',
  (SELECT id FROM users WHERE email = 'admin@local.test')
WHERE NOT EXISTS (
  SELECT 1 FROM delivery_status_events e
  JOIN deliveries d ON d.id = e.delivery_id
  WHERE d.tracking_number = 'TRK-LOCAL-0002' AND e.status = 'out_for_delivery'
);

-- Location pings (TRK-LOCAL-0001)
INSERT INTO location_pings (delivery_id, pinged_at, lat, lng, accuracy_m, source)
SELECT
  (SELECT id FROM deliveries WHERE tracking_number = 'TRK-LOCAL-0001'),
  NOW() - INTERVAL '5 hours',
  37.7749, -122.4194,
  25,
  'simulator'
WHERE NOT EXISTS (
  SELECT 1 FROM location_pings lp
  JOIN deliveries d ON d.id = lp.delivery_id
  WHERE d.tracking_number = 'TRK-LOCAL-0001' AND lp.pinged_at > NOW() - INTERVAL '5 hours 10 minutes'
);

INSERT INTO location_pings (delivery_id, pinged_at, lat, lng, accuracy_m, source)
SELECT
  (SELECT id FROM deliveries WHERE tracking_number = 'TRK-LOCAL-0001'),
  NOW() - INTERVAL '1 hour',
  37.7849, -122.4094,
  18,
  'simulator'
WHERE NOT EXISTS (
  SELECT 1 FROM location_pings lp
  JOIN deliveries d ON d.id = lp.delivery_id
  WHERE d.tracking_number = 'TRK-LOCAL-0001' AND lp.pinged_at > NOW() - INTERVAL '1 hour 10 minutes'
);

-- Location pings (TRK-LOCAL-0002)
INSERT INTO location_pings (delivery_id, pinged_at, lat, lng, accuracy_m, source)
SELECT
  (SELECT id FROM deliveries WHERE tracking_number = 'TRK-LOCAL-0002'),
  NOW() - INTERVAL '90 minutes',
  40.7128, -74.0060,
  30,
  'simulator'
WHERE NOT EXISTS (
  SELECT 1 FROM location_pings lp
  JOIN deliveries d ON d.id = lp.delivery_id
  WHERE d.tracking_number = 'TRK-LOCAL-0002' AND lp.pinged_at > NOW() - INTERVAL '100 minutes'
);

COMMIT;
