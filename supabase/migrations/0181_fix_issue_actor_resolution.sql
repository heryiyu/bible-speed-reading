-- Migration 0181: Fix _issue_actor to resolve the real profile id safely
--
-- Found while auditing the 179 authenticated_security_definer_function_
-- executable entries by tracing which shared "resolve p_actor_id" helper
-- each family of functions uses. exam_*/quiz_*/devotion_*/group_meeting_*
-- all go through resolve_quiz_actor (0084) and reading_team_* through
-- resolve_reading_team_actor (0019) — both already guard with
-- `p_actor_id IS NOT NULL AND auth.role() <> 'service_role' →
-- actor_override_forbidden`. The issue-report conversation family
-- (issue_thread_get/post/mark_read/drop_attachment/set_attachment/
-- unread_summary, issue_my_reports, issue_admin_*) instead uses
-- `_issue_actor`, which had neither protection:
--
--   SELECT COALESCE(auth.uid(), p_actor_id);
--
-- Two problems: (1) no override guard at all — when auth.uid() is NULL
-- (anon, or a stray direct call) it fully trusts p_actor_id; (2) even when
-- auth.uid() IS present, that's the Supabase Auth user id, not this app's
-- profiles.id (profiles.auth_user_id maps one to the other) — comparing it
-- against issue_reports.user_id (a profiles.id) never matches, so a real
-- dev/localhost login can't actually read or post to its own report thread.
--
-- Not currently exploitable in production: anon's EXECUTE on these
-- functions was already revoked (0173/0177), and nlc-data always supplies
-- p_actor_id as service_role with the Logto-verified profile.id. This is a
-- correctness/defense-in-depth fix, bringing _issue_actor in line with
-- resolve_quiz_actor/resolve_reading_team_actor.

CREATE OR REPLACE FUNCTION public._issue_actor(p_actor_id uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_actor_id IS NOT NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'actor_override_forbidden';
  END IF;
  RETURN COALESCE(p_actor_id, public.current_profile_id());
END;
$$;
REVOKE ALL ON FUNCTION public._issue_actor(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._issue_actor(uuid) TO authenticated, service_role;
