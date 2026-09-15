-- Migration 0180: Require issue_reports inserts to be the caller's own, logged-in
--
-- 0030's "Allow anonymous and authenticated inserts" policy was
-- `WITH CHECK (true)` for both `anon` and `authenticated` — Security
-- Advisor's rls_policy_always_true finding. Since the anon key is public
-- (shipped in config.js), anyone could POST directly to
-- /rest/v1/issue_reports with an arbitrary user_id (impersonating a real
-- member), no rate limit, and freeform metadata — completely bypassing
-- nlc-data's server-authoritative user_id handling, which only protects the
-- production Logto path, not a direct PostgREST call with the public key.
--
-- Decision (confirmed with the app owner): guest/anonymous bug reports are
-- no longer a required product feature, so this closes to logged-in members
-- inserting only their own report.
--
-- Note: user_id on this table is a profiles.id, not a Supabase auth.uid()
-- directly (profiles.auth_user_id maps one-to-the-other) — the same
-- distinction current_profile_id() exists to resolve elsewhere, so the
-- check uses that instead of comparing straight to auth.uid().
--
-- nlc-data (service_role) is unaffected — RLS never applied to it.

DROP POLICY IF EXISTS "Allow anonymous and authenticated inserts" ON public.issue_reports;

CREATE POLICY "Members insert their own reports" ON public.issue_reports
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = public.current_profile_id());
