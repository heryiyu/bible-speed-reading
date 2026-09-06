-- ============================================================================
-- 0166_get_org_structure_tree.sql
--
-- 效能：js/db.js 的 loadOrgStructure() 以前掃全教會 profiles（每季千餘列 ×
-- 分頁 6-7 個請求）只為了推導出「有哪些大區 / 牧區 / 小組」的 distinct 清單，
-- 再另外 2 個小查詢抓 great_regions / pastoral_zones 的 sort_order。
--
-- 這支 RPC 一次回全部（一個小 JSONB）：
--   { rows: [{great_region, pastoral_zone, small_group}, …DISTINCT 非空…],
--     regionSort: {name: sort_order}, zoneSort: {name: sort_order} }
--
-- 對象範圍：由 nlc-data Edge Function 傳入呼叫者的角色與管轄範圍（EF 已用
-- getProfileRoleCode / managed_* 解析過，跟 applyForcedScope 對 profiles 的
-- 收斂邏輯同一套），這支只照參數過濾，不自己判角色——避免兩邊各判一次而分歧。
--   admin / pastor           → 全教會
--   great_zone_leader        → great_region = ANY(p_scope_regions)
--   zone_leader              → pastoral_zone = ANY(p_scope_zones)
--   group_leader             → small_group   = ANY(p_scope_groups)
--   一般會友                 → 只有自己那一列（等同舊路徑 getVisibleProfileIds
--                              回 [self]）
--
-- 前端保留舊路徑當 fallback（RPC 不存在 / 出錯就退回 profiles 掃描 + 2 查詢），
-- 所以這支可以先部署或後部署都不會壞。
--
-- 部署：Supabase SQL editor 執行，或 supabase db push。純新增函式。
-- ============================================================================

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
  v_whole_church BOOLEAN := p_role_code IN ('admin', 'pastor');
  v_rows         JSONB;
  v_region_sort  JSONB := '{}'::JSONB;
  v_zone_sort    JSONB := '{}'::JSONB;
BEGIN
  IF p_actor_id IS NULL THEN
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
      OR profile.id = p_actor_id
      OR (
        profile.is_demo = FALSE AND profile.is_active = TRUE AND (
             (p_role_code = 'great_zone_leader' AND profile.great_region  = ANY(p_scope_regions))
          OR (p_role_code = 'zone_leader'        AND profile.pastoral_zone = ANY(p_scope_zones))
          OR (p_role_code = 'group_leader'       AND profile.small_group   = ANY(p_scope_groups))
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
