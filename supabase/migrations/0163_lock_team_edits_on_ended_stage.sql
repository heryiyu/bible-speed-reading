-- 0163_lock_team_edits_on_ended_stage.sql
--
-- 護欄：禁止「已結束的教會挑戰階段計畫」的團隊名單被異動。
--
-- 起因（2026-09）：管理員把 Zhi Ting 退出、張中明併入「新烏4」，但改的是
-- 8 月「第1階段熱身賽」（已結束）的那支隊；9 月正在跑的「期末賽・出埃及記」
-- 是更早用「帶隊進入下一階段」複製過去的獨立隊，沒被改到，看起來就像「隔幾天
-- 又變回去」。carry 是一次性快照、之後不會回頭同步；對已結束階段做的調整因此
-- 永遠傳不到現行階段，只會製造兩邊對不起來。
--
-- 這裡用 BEFORE 觸發器，在「任何」寫入路徑（每支 RPC、未來新增的 RPC、後台
-- SQL 手改、外鍵 CASCADE）進到 reading_team_members / reading_teams 之前，
-- 檢查該列所屬計畫是不是「教會挑戰階段」且「結束日已過（Asia/Taipei）」，是就
-- RAISE EXCEPTION 'reading_team_stage_ended'。
--
-- 不受影響：
--   · 一般讀經計畫（非階段）——不管日期都能動。
--   · 尚未結束的階段——照常。
--   · carry_reading_teams_to_stage —— 它只「讀」已結束的來源階段、只「寫」進
--     目標（現行 / 未來）階段，來源不會被 UPDATE/DELETE，所以不會被擋。
--   · 刪掉整個 global_plans 列（連帶 CASCADE 刪隊）—— 查不到 plan 列時視為放行，
--     admin 清理舊階段照樣可行。
--
-- 維運例外（真的要手改已結束階段時）：同一交易先跑
--   SET LOCAL "reading_team.allow_ended_edit" = 'on';
-- 即可暫時放行。
--
-- 部署：SQL editor 執行即可。純新增觸發器，不動任何函式、不用重部署 Edge
-- Function。冪等。

BEGIN;

CREATE OR REPLACE FUNCTION public._reading_team_block_ended_stage_edits()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_plan_id UUID;
  v_end     DATE;
  v_kind    TEXT;
BEGIN
  -- 明確授權的維運修正 → 放行
  IF current_setting('reading_team.allow_ended_edit', true) = 'on' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  v_plan_id := COALESCE(NEW.global_plan_id, OLD.global_plan_id);
  IF v_plan_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  SELECT gp.end_date, gp.plan_kind
  INTO v_end, v_kind
  FROM public.global_plans gp
  WHERE gp.id = v_plan_id;

  -- 只擋「教會挑戰的階段計畫」+「結束日已過」的異動
  IF v_end IS NOT NULL
     AND v_kind IN ('church_campaign_stage', 'church_campaign_stage_cohort')
     AND v_end < (now() AT TIME ZONE 'Asia/Taipei')::date THEN
    RAISE EXCEPTION 'reading_team_stage_ended'
      USING HINT = 'This campaign stage has ended; edit the team in the current stage instead.';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_block_ended_stage_team_members ON public.reading_team_members;
CREATE TRIGGER trg_block_ended_stage_team_members
  BEFORE INSERT OR UPDATE OR DELETE ON public.reading_team_members
  FOR EACH ROW EXECUTE FUNCTION public._reading_team_block_ended_stage_edits();

DROP TRIGGER IF EXISTS trg_block_ended_stage_teams ON public.reading_teams;
CREATE TRIGGER trg_block_ended_stage_teams
  BEFORE INSERT OR UPDATE OR DELETE ON public.reading_teams
  FOR EACH ROW EXECUTE FUNCTION public._reading_team_block_ended_stage_edits();

COMMIT;
