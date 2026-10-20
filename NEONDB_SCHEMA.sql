-- Run in Neon SQL editor. Ingestion must go through a secured server-side API.
CREATE TABLE IF NOT EXISTS devices (
  id BIGSERIAL PRIMARY KEY,
  platform TEXT NOT NULL,
  serial_number TEXT,
  hostname TEXT NOT NULL,
  asset_tag TEXT,
  manufacturer TEXT,
  model TEXT,
  purchase_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(platform, serial_number)
);
CREATE TABLE IF NOT EXISTS device_health_checks (
  id BIGSERIAL PRIMARY KEY,
  device_id BIGINT NOT NULL REFERENCES devices(id),
  collected_at_utc TIMESTAMPTZ NOT NULL,
  schema_version TEXT NOT NULL,
  overall_status TEXT,
  ratings JSONB NOT NULL DEFAULT '{}'::jsonb,
  metrics JSONB NOT NULL DEFAULT '{}'::jsonb,
  processes JSONB NOT NULL DEFAULT '{}'::jsonb,
  raw_report JSONB NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(device_id, collected_at_utc)
);
CREATE INDEX IF NOT EXISTS health_device_recent_idx ON device_health_checks(device_id, collected_at_utc DESC);
CREATE INDEX IF NOT EXISTS health_status_idx ON device_health_checks(overall_status);
-- Do not expose these tables directly to browsers or endpoint scripts.
