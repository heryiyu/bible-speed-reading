-- Migration 0179: Fail-closed the 3 shared "can this actor manage X" helpers
--
-- Found while investigating why sync_church_organization (0176) had the same
-- bug: three permission-check helpers compare role_code(...) directly with
-- `IN ('admin', 'pastor')` instead of wrapping in SELECT EXISTS(...). When
-- the actor_id passed in doesn't resolve to any profile (NULL, or a session
-- with no matching row), the IN comparison evaluates to NULL rather than
-- FALSE — and every caller's `IF NOT <helper>(...) THEN RAISE EXCEPTION`
-- treats a NULL condition the same as false, so the exception silently
-- never fires and the caller proceeds as if authorized.
--
-- Each caller already resolves actor_id safely via resolve_quiz_actor (which
-- blocks a non-service_role caller from impersonating someone else), so this
-- isn't an impersonation bug — it only matters when actor_id itself ends up
-- NULL/unresolvable (an anon caller if the function were ever anon-
-- executable, or an authenticated session with no matching profiles row).
-- Fixing it here is still worth doing: these 3 helpers gate every write RPC
-- for daily devotions, group-meeting plans, and exam grading, and "an edge
-- case silently grants access instead of denying it" is exactly the kind of
-- bug worth closing at the one shared choke point rather than trusting every
-- current and future caller to handle it right.
--
-- Fix: wrap each in SELECT EXISTS(...) — the same safe pattern already used
-- by can_manage_quiz_group / profile_belongs_to_quiz_group /
-- is_reading_team_member / can_send_care_reminder, which never had this bug.

CREATE OR REPLACE FUNCTION public._devotion_actor_can_manage(p_actor_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_actor_id
      AND public.role_code(role_id) IN ('admin', 'pastor')
  );
$$;
REVOKE ALL ON FUNCTION public._devotion_actor_can_manage(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._devotion_actor_can_manage(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._group_meeting_actor_can_manage(p_actor_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_actor_id
      AND public.role_code(role_id) IN ('admin', 'pastor')
  );
$$;
REVOKE ALL ON FUNCTION public._group_meeting_actor_can_manage(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._group_meeting_actor_can_manage(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._exam_actor_can_grade(p_attempt_id UUID, p_actor_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
  SELECT COALESCE(public._exam_actor_role(p_actor_id), 'member') IN ('admin', 'pastor')
      OR EXISTS (SELECT 1 FROM public.exam_grading_assignments ga
                 WHERE ga.attempt_id = p_attempt_id AND ga.grader_id = p_actor_id);
$$;
REVOKE ALL ON FUNCTION public._exam_actor_can_grade(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._exam_actor_can_grade(uuid, uuid) TO authenticated, service_role;
