-- Migration 0183: Drop the one-time old-project import staging schema
--
-- Security Advisor flagged import_staging.to_text_array for a mutable
-- search_path. This schema isn't part of the regular migration history —
-- it lives in supabase/import/ as a standalone, one-time toolkit for moving
-- public/shared data (great_regions, pastoral_zones, small_groups,
-- global_plans, church_announcements — explicitly no users or user-linked
-- data) from an old Supabase project into this one (see
-- supabase/import/README.md). 02_import_public_data.sql never dropped the
-- staging schema afterward; it's just been sitting unused since that
-- one-time migration completed (this project is now 183 migrations past
-- that point). Dropping it removes the flagged function along with the
-- rest of the leftover staging tables in one shot.

DROP SCHEMA IF EXISTS import_staging CASCADE;
