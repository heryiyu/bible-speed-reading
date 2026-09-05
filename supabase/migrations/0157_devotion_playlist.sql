-- 0157_devotion_playlist.sql
--
-- 每日靈修：每份計畫綁一個 YouTube 播放清單（該靈修系列的影片依序放在裡面）。
-- 管理端編輯每一天時，可以「依日期抓候選」——伺服器端（nlc-data 的
-- devotion_fetch_playlist_videos action）讀這裡的 rules.devotionPlaylistId，
-- 去抓 YouTube 官方公開 RSS（youtube.com/feeds/videos.xml?playlist_id=...，
-- 不用登入、不用 API 金鑰），把最近的影片列成候選給管理員挑。
--
-- 這支只做三件事，全部 CREATE OR REPLACE / 加欄位式的 UPDATE，冪等可重跑：
--   1. 新增 set_devotional_plan_playlist_id（比照 0145 的
--      set_devotional_plan_future_open，只有 admin/pastor 能呼叫）。
--   2. list_devotion_days 的回傳多帶一個 playlistId（給管理端 toolbar 顯示 /
--      預填）。其餘欄位與 0152 版完全一致。
--   3. 把「使徒行傳靈修（一）」現有的播放清單 ID 種進去（僅在還沒設定時）。
--
-- 不動 get_devotional_plan（會友端不需要 playlistId）。
-- 部署：Supabase SQL editor 執行後，重新部署 nlc-data（新 RPC 要進 allowlist）。

BEGIN;

-- ── 1. 管理：設定 / 清除這份計畫綁定的 YouTube 播放清單 ─────────────────────
CREATE OR REPLACE FUNCTION public.set_devotional_plan_playlist_id(
  p_global_plan_id UUID,
  p_playlist_id TEXT,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID := public.resolve_quiz_actor(p_actor_id);
  cleaned  TEXT := NULLIF(BTRIM(COALESCE(p_playlist_id, '')), '');
BEGIN
  IF NOT public._devotion_actor_can_manage(actor_id) THEN
    RAISE EXCEPTION 'devotion_admin_required';
  END IF;

  -- 允許清空（傳空字串）；有值時必須長得像 YouTube 播放清單 ID。
  IF cleaned IS NOT NULL AND cleaned !~ '^PL[A-Za-z0-9_-]{10,}$' THEN
    RAISE EXCEPTION 'devotion_playlist_id_invalid';
  END IF;

  UPDATE public.global_plans
  SET rules = CASE
        WHEN cleaned IS NULL
          THEN COALESCE(rules, '{}'::jsonb) - 'devotionPlaylistId'
        ELSE COALESCE(rules, '{}'::jsonb) || jsonb_build_object('devotionPlaylistId', cleaned)
      END
  WHERE id = p_global_plan_id AND plan_kind = 'devotional';
  IF NOT FOUND THEN RAISE EXCEPTION 'devotional_plan_not_found'; END IF;

  RETURN jsonb_build_object('planId', p_global_plan_id, 'playlistId', cleaned);
END;
$$;

REVOKE ALL ON FUNCTION public.set_devotional_plan_playlist_id(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_devotional_plan_playlist_id(uuid, text, uuid)
  TO authenticated, service_role;

-- ── 2. list_devotion_days 回傳多帶 playlistId（其餘同 0152）─────────────────
CREATE OR REPLACE FUNCTION public.list_devotion_days(
  p_global_plan_id UUID,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID := public.resolve_quiz_actor(p_actor_id);
  gp       public.global_plans%ROWTYPE;
  rows_j   JSONB;
BEGIN
  IF NOT public._devotion_actor_can_manage(actor_id) THEN
    RAISE EXCEPTION 'devotion_admin_required';
  END IF;
  SELECT * INTO gp FROM public.global_plans
  WHERE id = p_global_plan_id AND plan_kind = 'devotional';
  IF NOT FOUND THEN RAISE EXCEPTION 'devotional_plan_not_found'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',           d.id,
    'dayIndex',     d.day_index,
    'displayDate',  (gp.start_date + (d.day_index - 1))::TEXT,
    'title',        d.title,
    'passageLabel', d.passage_label,
    'passageRefs',  d.passage_refs,
    'reflections',  d.reflections,
    'videoUrl',     d.video_url,
    'videoTitle',   d.video_title,
    'isPublished',  d.is_published
  ) ORDER BY d.day_index), '[]'::jsonb)
  INTO rows_j
  FROM public.plan_devotion_days d
  WHERE d.global_plan_id = gp.id;

  RETURN jsonb_build_object(
    'planId',     gp.id,
    'name',       gp.name,
    'startDate',  gp.start_date::TEXT,
    'endDate',    gp.end_date::TEXT,
    'futureOpen', COALESCE((gp.rules ->> 'devotionFutureOpen')::BOOLEAN, FALSE),
    'playlistId', gp.rules ->> 'devotionPlaylistId',
    'days',       rows_j
  );
END;
$$;

-- ── 3. 種入「使徒行傳靈修（一）」現有播放清單（僅在尚未設定時）──────────────
UPDATE public.global_plans
SET rules = COALESCE(rules, '{}'::jsonb)
            || jsonb_build_object('devotionPlaylistId', 'PLnuGQey7c9Ct5eJxKwrNgM8-sWuPvp3xg')
WHERE id = '00000000-0000-0000-d1f0-000000000001'
  AND plan_kind = 'devotional'
  AND (rules ->> 'devotionPlaylistId') IS NULL;

COMMIT;
