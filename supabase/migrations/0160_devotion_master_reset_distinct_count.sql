-- 0160_devotion_master_reset_distinct_count.sql
--
-- 修正：關閉「每日靈修／小組聚會週計畫」總開關時，回傳的 resetCount 是被刪掉的
-- 「列數」，不是「人數」。一個會友若同時開了兩個功能就有兩列，會被算成 2 →
-- 管理端提示「已一併清空 N 位會友」的數字偏大（實測 3 人開兩功能顯示成 5）。
-- 改成 COUNT(DISTINCT profile_id)。
--
-- 只 CREATE OR REPLACE，函式簽章不變 → GRANT / nlc-data allowlist 都不用動，
-- 不需要重新部署 Edge Function，SQL editor 跑完即生效。冪等。

BEGIN;

CREATE OR REPLACE FUNCTION public.set_devotion_group_features_master(
  p_enabled BOOLEAN,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id    UUID := public.resolve_quiz_actor(p_actor_id);
  actor_admin BOOLEAN;
  reset_count INT := 0;
BEGIN
  SELECT public.role_code((SELECT role_id FROM public.profiles WHERE id = actor_id)) = 'admin'
  INTO actor_admin;
  IF NOT COALESCE(actor_admin, FALSE) THEN
    RAISE EXCEPTION 'devotion_group_master_admin_required';
  END IF;

  UPDATE public.app_feature_settings
  SET enabled = COALESCE(p_enabled, FALSE)
  WHERE key = 'devotion_group_features_master';

  IF NOT COALESCE(p_enabled, FALSE) THEN
    WITH deleted AS (
      DELETE FROM public.profile_feature_preferences
      WHERE feature_key IN ('daily_devotion', 'group_meeting_plan')
      RETURNING profile_id
    )
    SELECT COUNT(DISTINCT profile_id) INTO reset_count FROM deleted;
  END IF;

  RETURN jsonb_build_object('enabled', COALESCE(p_enabled, FALSE), 'resetCount', reset_count);
END;
$$;

COMMIT;
