-- Migration 0174: Close actor-override privilege escalation in
-- set_profile_managed_scopes
--
-- Root cause (found while auditing 0173's function list): unlike
-- resolve_quiz_actor (0084) and resolve_reading_team_actor (0019), this
-- function never rejected a client-supplied p_actor_id from a non
-- service_role caller — it only checked whether the id given IN p_actor_id
-- resolved to an admin:
--
--   actor_id := COALESCE(p_actor_id, public.current_profile_id());
--   IF auth.role() <> 'service_role' THEN
--     SELECT role_code(...) INTO actor_role FROM profiles WHERE id = actor_id;
--     IF actor_role IS DISTINCT FROM 'admin' THEN RAISE EXCEPTION ...
--
-- Any authenticated (non-admin) member who knew or guessed a real admin's
-- profile UUID could call this RPC directly via PostgREST with that UUID as
-- p_actor_id and their own id as p_profile_id, pass the admin check, and
-- grant themselves arbitrary managed_regions/managed_zones/managed_groups —
-- a straight privilege escalation. This mirrors the guard already used by
-- resolve_quiz_actor/resolve_reading_team_actor: only service_role (i.e.
-- nlc-data, after its own isAdmin() check) may supply a non-null
-- p_actor_id; every other caller's actor is forced to their own session
-- identity via current_profile_id().
--
-- No caller needs to change: nlc-data calls this via the service-role key
-- (ADMIN_RPC_FUNCTIONS gate + isAdmin() check already there), and the
-- dev/localhost client (js/db.js setProfileManagedScopes) never sends
-- p_actor_id at all — it will keep resolving to the caller's own identity.

CREATE OR REPLACE FUNCTION public.set_profile_managed_scopes(
  p_profile_id UUID,
  p_managed_regions TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_managed_zones TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_managed_groups TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $set_profile_managed_scopes$
DECLARE
  actor_id UUID;
  actor_role TEXT;
  target_role TEXT;
  normalized_regions TEXT[];
  normalized_zones TEXT[];
  normalized_groups TEXT[];
BEGIN
  IF p_actor_id IS NOT NULL AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'actor_override_forbidden';
  END IF;

  actor_id := COALESCE(p_actor_id, public.current_profile_id());

  IF auth.role() <> 'service_role' THEN
    SELECT public.role_code(profile.role_id)
    INTO actor_role
    FROM public.profiles AS profile
    WHERE profile.id = actor_id;

    IF actor_role IS DISTINCT FROM 'admin' THEN
      RAISE EXCEPTION 'managed_scope_admin_required' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT public.role_code(profile.role_id)
  INTO target_role
  FROM public.profiles AS profile
  WHERE profile.id = p_profile_id;

  IF target_role IS NULL THEN
    RAISE EXCEPTION 'managed_scope_profile_not_found';
  END IF;

  SELECT COALESCE(ARRAY_AGG(scope ORDER BY scope), ARRAY[]::TEXT[])
  INTO normalized_regions
  FROM (
    SELECT DISTINCT BTRIM(value) AS scope
    FROM UNNEST(COALESCE(p_managed_regions, ARRAY[]::TEXT[])) AS requested_value(value)
    WHERE BTRIM(value) <> ''
  ) AS normalized;

  SELECT COALESCE(ARRAY_AGG(scope ORDER BY scope), ARRAY[]::TEXT[])
  INTO normalized_zones
  FROM (
    SELECT DISTINCT BTRIM(value) AS scope
    FROM UNNEST(COALESCE(p_managed_zones, ARRAY[]::TEXT[])) AS requested_value(value)
    WHERE BTRIM(value) <> ''
  ) AS normalized;

  SELECT COALESCE(ARRAY_AGG(scope ORDER BY scope), ARRAY[]::TEXT[])
  INTO normalized_groups
  FROM (
    SELECT DISTINCT BTRIM(value) AS scope
    FROM UNNEST(COALESCE(p_managed_groups, ARRAY[]::TEXT[])) AS requested_value(value)
    WHERE BTRIM(value) <> ''
  ) AS normalized;

  UPDATE public.profiles AS profile
  SET
    managed_regions = ARRAY_TO_STRING(normalized_regions, ','),
    managed_zones = ARRAY_TO_STRING(normalized_zones, ','),
    managed_groups = ARRAY_TO_STRING(normalized_groups, ',')
  WHERE profile.id = p_profile_id;

  RETURN JSONB_BUILD_OBJECT(
    'profileId', p_profile_id,
    'roleCode', target_role,
    'managedRegions', normalized_regions,
    'managedZones', normalized_zones,
    'managedGroups', normalized_groups
  );
END;
$set_profile_managed_scopes$;

REVOKE ALL ON FUNCTION public.set_profile_managed_scopes(UUID, TEXT[], TEXT[], TEXT[], UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_profile_managed_scopes(UUID, TEXT[], TEXT[], TEXT[], UUID) TO authenticated, service_role;
