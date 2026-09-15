-- Migration 0182: Third sweep — revoke PUBLIC (not just anon) EXECUTE
--
-- Root cause of why 0173 and 0177 left ~29 functions untouched: Postgres
-- grants EXECUTE on every newly created function to the PUBLIC pseudo-role
-- by default. Functions created in early migrations (0001, 0009, 0019,
-- 0031, 0084, ...) never got an explicit `REVOKE ALL FROM PUBLIC`
-- afterward, so `anon`'s ability to call them comes from that PUBLIC grant,
-- not a grant made to `anon` by name. `REVOKE EXECUTE ... FROM anon` only
-- removes a privilege recorded against the `anon` role specifically — it is
-- a no-op when the actual grant is "TO PUBLIC", which is exactly why
-- running that same sweep twice (0173, 0177) produced identical remaining
-- lists. The individually-patched functions in this series (0174, 0175,
-- 0179, 0181) worked because those all explicitly did
-- `REVOKE ALL ... FROM PUBLIC`, not `FROM anon`.
--
-- This sweep revokes from both PUBLIC and anon (covering either grant path)
-- for every function currently anon-executable, then re-grants to
-- authenticated + service_role so nothing legitimate breaks: nlc-data
-- (service_role) and the handful of functions js/db.js calls directly as
-- authenticated (e.g. exam_get_stats, exam_home_exams, exam_my_papers,
-- exam_grade_answers_batch, exam_set_answer_explanation_visible,
-- exam_set_question_explanation) keep working. The rest of this batch
-- (current_profile_id, get_my_profile, trigger functions like
-- enforce_reading_log_plan_owner, protect_profile_*, etc.) are internal
-- helpers/triggers never called directly by the app; granting authenticated
-- on them is harmless (trigger functions error at runtime if invoked
-- directly regardless of grant) and keeps this sweep uniform and simple
-- rather than hand-picking grants per function.

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
      'REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM PUBLIC, anon;',
      r.schema_name, r.func_name, r.args
    );
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO authenticated, service_role;',
      r.schema_name, r.func_name, r.args
    );
    n := n + 1;
  END LOOP;

  RAISE NOTICE 'Revoked PUBLIC/anon EXECUTE and re-granted authenticated/service_role on % function(s) (sweep 3).', n;
END $$;
