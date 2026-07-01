-- Import public/shared old app data only.
-- Run this in the NEW Supabase project first.
--
-- These staging tables are shaped to match normal Supabase CSV exports from
-- the old public tables. Most columns are TEXT so CSV import is forgiving.
-- Do NOT import profiles, user_identities, reading_plans, reading_logs, or devotional_notes here.

CREATE SCHEMA IF NOT EXISTS import_staging;

DROP TABLE IF EXISTS import_staging.church_announcements;
DROP TABLE IF EXISTS import_staging.global_plans;
DROP TABLE IF EXISTS import_staging.small_groups;
DROP TABLE IF EXISTS import_staging.pastoral_zones;
DROP TABLE IF EXISTS import_staging.great_regions;

CREATE TABLE import_staging.great_regions (
  id TEXT,
  name TEXT,
  sort_order TEXT,
  created_at TEXT,
  updated_at TEXT
);

CREATE TABLE import_staging.pastoral_zones (
  id TEXT,
  great_region_id TEXT,
  name TEXT,
  sort_order TEXT,
  created_at TEXT,
  updated_at TEXT
);

CREATE TABLE import_staging.small_groups (
  id TEXT,
  pastoral_zone_id TEXT,
  name TEXT,
  sort_order TEXT,
  created_at TEXT,
  updated_at TEXT
);

CREATE TABLE import_staging.global_plans (
  id TEXT,
  name TEXT,
  description TEXT,
  start_date TEXT,
  end_date TEXT,
  target_books TEXT,
  cover_image_url TEXT,
  is_hidden TEXT,
  created_by TEXT,
  created_at TEXT,
  updated_at TEXT
);

CREATE TABLE import_staging.church_announcements (
  id TEXT,
  title TEXT,
  content TEXT,
  created_by TEXT,
  is_published TEXT,
  published_at TEXT,
  created_at TEXT,
  updated_at TEXT
);
