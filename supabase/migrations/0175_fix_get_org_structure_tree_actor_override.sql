-- Migration 0175: Close scope-spoofing bypass in get_org_structure_tree
--
-- Root cause: unlike publish_global_plan_rules / create_region_stage_cohort,
-- this function (0166) never verified who was calling it — it fully trusted
-- whatever p_role_code / p_scope_regions / p_scope_zones / p_scope_groups
-- the caller supplied, by design ("這支只照參數過濾，不自己判角色"), on the
-- assumption that only nlc-data would ever call it after resolving the
-- caller's real role from Member Hub's leadership label.
--
-- Because the function is GRANTed to `authenticated` (js/db.js calls it
-- directly in dev/localhost mode), any authenticated member could call it
-- straight over PostgREST and pass p_role_code: 'admin' to get the entire
-- church's org structure (region/zone/group names), bypassing the intended
-- "regular member only sees their own row" scoping. Lower severity than the
-- set_profile_managed_scopes bug (0174) since this is read-only, non-PII
-- data — but still a real access-control bypass.
--
-- Fix: getProfileRoleCode()'s logic (parsing Member Hub leadership labels)
-- lives in supabase/functions/nlc-data/index.ts and is not duplicated here
-- — reimplementing it in SQL would just create two copies to keep in sync.
-- Instead, only a service_role caller (i.e. nlc-data, which has already
-- verified the Logto token and resolved the real role/scope) may supply a
-- non-default p_actor_id/p_role_code/p_scope_*. Any other caller
-- (authenticated/anon hitting PostgREST directly) has all of those forced
-- to "just me" regardless of what it passes — mirroring the fail-closed
-- default already established for empty managed scopes.
--
-- nlc-data itself is unaffected: it always calls this with p_actor_id set
-- and runs as service_role, so it keeps getting the real, resolved scope.

CREATE OR REPLACE FUNCTION public.get_org_structure_tree(
  p_actor_id      UUID,
  p_role_code     TEXT   DEFAULT 'member',
  p_scope_regions TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_scope_zones   TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_scope_groups  TEXT[] DEFAULT ARRAY[]::TEXT[]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $get_org_structure_tree$
DECLARE
  resolved_actor_id      UUID;
  resolved_role_code     TEXT;
  resolved_scope_regions TEXT[];
  resolved_scope_zones   TEXT[];
  resolved_scope_groups  TEXT[];
  v_whole_church         BOOLEAN;
  v_rows                 JSONB;
  v_region_sort          JSONB := '{}'::JSONB;
  v_zone_sort            JSONB := '{}'::JSONB;
BEGIN
  IF auth.role() = 'service_role' THEN
    -- nlc-data has already verified the Logto token and resolved the
    -- caller's real role/scope from Member Hub data — trust it as given.
    resolved_actor_id      := p_actor_id;
    resolved_role_code     := COALESCE(p_role_code, 'member');
    resolved_scope_regions := COALESCE(p_scope_regions, ARRAY[]::TEXT[]);
    resolved_scope_zones   := COALESCE(p_scope_zones, ARRAY[]::TEXT[]);
    resolved_scope_groups  := COALESCE(p_scope_groups, ARRAY[]::TEXT[]);
  ELSE
    -- Any direct caller (authenticated/anon over PostgREST) never gets to
    -- claim a role or scope — forced to their own session identity and the
    -- narrowest ("just me") view, no matter what it passes.
    resolved_actor_id      := public.current_profile_id();
    resolved_role_code     := 'member';
    resolved_scope_regions := ARRAY[]::TEXT[];
    resolved_scope_zones   := ARRAY[]::TEXT[];
    resolved_scope_groups  := ARRAY[]::TEXT[];
  END IF;

  v_whole_church := resolved_role_code IN ('admin', 'pastor');

  IF resolved_actor_id IS NULL THEN
    RETURN jsonb_build_object('rows', '[]'::JSONB, 'regionSort', v_region_sort, 'zoneSort', v_zone_sort);
  END IF;

  SELECT COALESCE(
           jsonb_agg(DISTINCT jsonb_build_object(
             'great_region',  profile.great_region,
             'pastoral_zone', profile.pastoral_zone,
             'small_group',   profile.small_group
           )),
           '[]'::JSONB
         )
    INTO v_rows
  FROM public.profiles profile
  WHERE COALESCE(BTRIM(profile.great_region), '') <> ''
    AND (
      v_whole_church
      OR profile.id = resolved_actor_id
      OR (
        profile.is_demo = FALSE AND profile.is_active = TRUE AND (
             (resolved_role_code = 'great_zone_leader' AND profile.great_region  = ANY(resolved_scope_regions))
          OR (resolved_role_code = 'zone_leader'        AND profile.pastoral_zone = ANY(resolved_scope_zones))
          OR (resolved_role_code = 'group_leader'       AND profile.small_group   = ANY(resolved_scope_groups))
        )
      )
    );

  -- sort_order 表（migration 0133）在舊環境可能還沒有——抓不到就回空物件，
  -- 前端會自動退回字母排序。
  BEGIN
    SELECT COALESCE(jsonb_object_agg(name, sort_order), '{}'::JSONB) INTO v_region_sort FROM public.great_regions;
  EXCEPTION WHEN undefined_table THEN v_region_sort := '{}'::JSONB;
  END;
  BEGIN
    SELECT COALESCE(jsonb_object_agg(name, sort_order), '{}'::JSONB) INTO v_zone_sort FROM public.pastoral_zones;
  EXCEPTION WHEN undefined_table THEN v_zone_sort := '{}'::JSONB;
  END;

  RETURN jsonb_build_object('rows', v_rows, 'regionSort', v_region_sort, 'zoneSort', v_zone_sort);
END;
$get_org_structure_tree$;

REVOKE ALL ON FUNCTION public.get_org_structure_tree(UUID, TEXT, TEXT[], TEXT[], TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_org_structure_tree(UUID, TEXT, TEXT[], TEXT[], TEXT[]) TO authenticated, service_role;
