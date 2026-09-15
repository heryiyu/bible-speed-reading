-- Migration 0173: Revoke `anon` EXECUTE on every public-schema function
--
-- Supabase's Security Advisor flagged ~100+ functions in `public` as
-- executable by the `anon` role via PostgREST (/rest/v1/rpc/<name>) — a
-- Supabase project's default ALTER DEFAULT PRIVILEGES grants EXECUTE on new
-- functions to `anon`/`authenticated` automatically, and none of these
-- migrations ever revoked it back out.
--
-- Most of these functions (the `p_actor_id`-parameterized ones especially,
-- e.g. exam_grade_attempt, disband_reading_team, set_profile_managed_scopes)
-- are only meant to be called by supabase/functions/nlc-data/index.ts using
-- the service_role key, which injects a Logto-verified p_actor_id itself
-- (see nlc-data's RPC_FUNCTIONS allowlist). Because the functions trust
-- p_actor_id as given rather than deriving it from auth.uid(), any holder of
-- the public anon key — logged in or not — could call them directly via
-- PostgREST and pass an arbitrary p_actor_id, completely bypassing Logto
-- auth and nlc-data's allowlist/admin checks (e.g. impersonate an admin to
-- grade exams, disband teams, or grant themselves managed scopes).
--
-- The app never calls any RPC as a genuinely anonymous (not-logged-in)
-- caller — even the dev/localhost Google-login path that calls
-- state.supabase.rpc(...) directly (see js/db.js) always does so as
-- `authenticated`. So revoking `anon` EXECUTE across the board is safe and
-- breaks nothing; it only closes the "no login at all" attack surface.
-- `authenticated` is deliberately left untouched here — a handful of
-- functions are called directly by dev/localhost clients as authenticated,
-- and trimming that requires a per-function audit, not a blanket revoke.
--
-- service_role is unaffected (Postgres role attributes, not grants, decide
-- its access — it bypasses RLS/grants entirely), so nlc-data keeps working.

DO $$
DECLARE
  r RECORD;
  n INT := 0;
BEGIN
  FOR r IN
    SELECT p.oid, n.nspname AS schema_name, p.proname AS func_name,
           pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format(
      'REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM anon;',
      r.schema_name, r.func_name, r.args
    );
    n := n + 1;
  END LOOP;

  RAISE NOTICE 'Revoked anon EXECUTE on % function(s) in public schema.', n;
END $$;
