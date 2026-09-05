-- 0159_devotion_publish_all.sql
--
-- 每日靈修管理：一顆「全部發佈」按鈕——把這份計畫所有天的 is_published 一次設成
-- TRUE。批次匯入不會自動發佈，逐日一天天勾很累；而「未來日期是否對會友開放」
-- 已經由 rules.devotionFutureOpen（get_devotional_plan 會依當天日期把未來日
-- 標成 locked）負責，所以這裡就是單純「全部發佈、之後靠日期自動一天天開鎖」。
--
-- 只新增一支 admin/pastor 專用 RPC，冪等。
-- 部署：SQL editor 執行後，重新部署 nlc-data（新 RPC 要進 allowlist）。

BEGIN;

CREATE OR REPLACE FUNCTION public.set_all_devotion_days_published(
  p_global_plan_id UUID,
  p_published BOOLEAN DEFAULT TRUE,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID := public.resolve_quiz_actor(p_actor_id);
  v_target BOOLEAN := COALESCE(p_published, TRUE);
  n        INT;
BEGIN
  IF NOT public._devotion_actor_can_manage(actor_id) THEN
    RAISE EXCEPTION 'devotion_admin_required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.global_plans
                 WHERE id = p_global_plan_id AND plan_kind = 'devotional') THEN
    RAISE EXCEPTION 'devotional_plan_not_found';
  END IF;

  UPDATE public.plan_devotion_days
  SET is_published = v_target,
      updated_by   = actor_id,
      updated_at   = NOW()
  WHERE global_plan_id = p_global_plan_id
    AND is_published IS DISTINCT FROM v_target;
  GET DIAGNOSTICS n = ROW_COUNT;

  RETURN jsonb_build_object('planId', p_global_plan_id, 'published', v_target, 'changed', n);
END;
$$;

REVOKE ALL ON FUNCTION public.set_all_devotion_days_published(uuid, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_all_devotion_days_published(uuid, boolean, uuid)
  TO authenticated, service_role;

COMMIT;
