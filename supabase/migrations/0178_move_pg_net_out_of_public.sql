-- Migration 0178: Move pg_net out of public via drop + recreate
--
-- ALTER EXTENSION pg_net SET SCHEMA fails on Supabase's pg_net build
-- ("extension does not support SET SCHEMA" — it's not marked relocatable).
-- The only way to move it is to drop and recreate it in the target schema.
--
-- This briefly clears pg_net's own internal queue of in-flight async HTTP
-- requests. All 3 current callers (issue-report sheet sync trigger [0077],
-- daily-quiz generation scheduling [0085], devotion video sync [0155]) use
-- net.http_post as fire-and-forget notifications, not durable state, so
-- losing an in-flight request at the moment this runs just means that one
-- notification is missed — not silent data loss. Run this at low traffic,
-- and re-trigger each of those 3 flows once afterward to confirm
-- net.http_post still resolves correctly (they all reference the function
-- as net.http_post(...), which keeps working once pg_net is back, just in
-- the new schema).

CREATE SCHEMA IF NOT EXISTS extensions;
DROP EXTENSION IF EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
