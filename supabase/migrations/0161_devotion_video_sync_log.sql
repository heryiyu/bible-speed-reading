-- 0161_devotion_video_sync_log.sql
--
-- 每日靈修影片自動抓取（sync-devotion-video，cron 每早 07:10）目前成功 / 失敗
-- 都沒有任何提示，管理員要去翻 Edge Function log 才知道。這裡加一張狀態表：
-- Edge Function 每天跑完把結果寫一筆（一個計畫一天一列），管理端「每日靈修」
-- 頁面頂端就能顯示「今天自動抓取：已填入 ✓ / 尚未有影片 / 失敗（原因）」。
--
-- Edge Function 用 service-role 直接 upsert 這張表（見 sync-devotion-video/
-- index.ts）；管理端透過新的 admin RPC get_devotion_video_sync_status 讀。
--
-- 部署：SQL editor 執行後，重新部署 nlc-data（新 RPC 進 allowlist）+
-- sync-devotion-video（開始寫 log）。冪等。

BEGIN;

CREATE TABLE IF NOT EXISTS public.devotion_video_sync_log (
  global_plan_id UUID NOT NULL REFERENCES public.global_plans(id) ON DELETE CASCADE,
  sync_date      DATE NOT NULL,
  day_index      INTEGER,
  status         TEXT NOT NULL,            -- updated / no_new_video_today / already_set_or_missing_day / failed / no_playlist_configured / …
  video_id       TEXT,
  video_title    TEXT,
  feed_source    TEXT,                     -- playlist:PL… / channel
  message        TEXT,
  updated        BOOLEAN NOT NULL DEFAULT FALSE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (global_plan_id, sync_date)
);

CREATE INDEX IF NOT EXISTS idx_devotion_video_sync_log_date
  ON public.devotion_video_sync_log (sync_date DESC);

ALTER TABLE public.devotion_video_sync_log ENABLE ROW LEVEL SECURITY;
-- 沒有 RLS policy：只走下面的 admin RPC（讀）+ service-role（Edge Function 寫）。
GRANT SELECT, INSERT, UPDATE ON public.devotion_video_sync_log TO service_role;

-- ── 管理：讀某計畫「今天 / 最近一次」的自動抓取狀態 ────────────────────────
CREATE OR REPLACE FUNCTION public.get_devotion_video_sync_status(
  p_global_plan_id UUID,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID := public.resolve_quiz_actor(p_actor_id);
  today_tw DATE := (NOW() AT TIME ZONE 'Asia/Taipei')::DATE;
  row_today  public.devotion_video_sync_log%ROWTYPE;
  row_latest public.devotion_video_sync_log%ROWTYPE;
BEGIN
  IF NOT public._devotion_actor_can_manage(actor_id) THEN
    RAISE EXCEPTION 'devotion_admin_required';
  END IF;

  SELECT * INTO row_today FROM public.devotion_video_sync_log
  WHERE global_plan_id = p_global_plan_id AND sync_date = today_tw;

  SELECT * INTO row_latest FROM public.devotion_video_sync_log
  WHERE global_plan_id = p_global_plan_id
  ORDER BY sync_date DESC LIMIT 1;

  RETURN jsonb_build_object(
    'today', today_tw::TEXT,
    'hasToday', row_today.global_plan_id IS NOT NULL,
    'todayStatus',  row_today.status,
    'todayMessage', row_today.message,
    'todayVideoTitle', row_today.video_title,
    'todayFeedSource', row_today.feed_source,
    'todayUpdated',  COALESCE(row_today.updated, FALSE),
    'todayAt', row_today.updated_at,
    'latestDate',   row_latest.sync_date::TEXT,
    'latestStatus', row_latest.status,
    'latestMessage', row_latest.message
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_devotion_video_sync_status(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_devotion_video_sync_status(uuid, uuid)
  TO authenticated, service_role;

COMMIT;
