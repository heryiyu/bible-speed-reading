-- Migration 0177: Second sweep revoking `anon` EXECUTE on public functions
--
-- 0173 ran the same dynamic REVOKE and cut the Security Advisor's
-- anon_security_definer_function_executable list from 90+ down to ~30, but
-- didn't reach zero (e.g. current_profile_id, get_my_profile,
-- handle_new_auth_user, several enforce_*/protect_profile_* triggers, a
-- handful of exam_* functions were still anon-executable in the next scan).
-- sync_church_organization — also still in that list — is handled
-- separately in 0176 (dropped as dead code) rather than here.
--
-- This is the exact same idempotent, privilege-state-driven sweep as 0173:
-- it revokes anon EXECUTE from whatever public function still has it right
-- now, regardless of why the first pass missed these. Safe to run again.

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

  RAISE NOTICE 'Revoked anon EXECUTE on % function(s) in public schema (sweep 2).', n;
END $$;
