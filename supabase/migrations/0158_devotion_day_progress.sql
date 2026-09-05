-- 0158_devotion_day_progress.sql
--
-- 每日靈修「會友端」的個人進度與心得：
--   ① 經文進度 / 思想經文的「已讀 / 已思想」打勾
--   ② 每一條思想經文可以點進去寫「心得」（反思文字）
--
-- 先前這些全部只存在 localStorage（見 plan.js renderDevotionViewer 的
-- devotion_read_ / devotion_thought_ key），換裝置、清快取就消失。心得是會友
-- 會很在意不能弄丟的反思內容，所以搬上 Supabase，跟 verse_notes（migration
-- 0075）同一種「一人一份、只有自己看得到、絕不分享給同工」的模式。
--
-- 一張表兼顧打勾與心得：一列 = 某人某計畫某天的某個項目（經文 or 第 i 條思想），
-- 帶 done（打勾）與 note（心得）。前端對「最近一週內的日子」才把打勾寫上來，
-- 更早的打勾維持本機；心得則一律寫上來。
--
-- 部署：Supabase SQL editor 執行後，重新部署 nlc-data（2 支新 RPC 要進
-- allowlist）。冪等，可重跑。

BEGIN;

-- ── 1. 表 ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.devotion_day_progress (
  id             UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id        UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  global_plan_id UUID NOT NULL REFERENCES public.global_plans(id) ON DELETE CASCADE,
  day_index      INTEGER NOT NULL CHECK (day_index >= 1),
  item_kind      TEXT NOT NULL CHECK (item_kind IN ('passage', 'think')),
  item_index     INTEGER NOT NULL DEFAULT 0 CHECK (item_index >= 0),
  done           BOOLEAN NOT NULL DEFAULT FALSE,
  note           TEXT NOT NULL DEFAULT '',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, global_plan_id, day_index, item_kind, item_index)
);

CREATE INDEX IF NOT EXISTS idx_devotion_day_progress_user_plan
  ON public.devotion_day_progress (user_id, global_plan_id);

DROP TRIGGER IF EXISTS trg_devotion_day_progress_updated_at ON public.devotion_day_progress;
CREATE TRIGGER trg_devotion_day_progress_updated_at
  BEFORE UPDATE ON public.devotion_day_progress
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.devotion_day_progress ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS devotion_day_progress_manage_own ON public.devotion_day_progress;
CREATE POLICY devotion_day_progress_manage_own ON public.devotion_day_progress
  FOR ALL TO authenticated
  USING (user_id = public.current_profile_id())
  WITH CHECK (user_id = public.current_profile_id());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.devotion_day_progress TO authenticated;

-- ── 2. 會友：列出自己在這份計畫的所有進度 / 心得 ───────────────────────────
CREATE OR REPLACE FUNCTION public.list_devotion_progress(
  p_global_plan_id UUID,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID := public.resolve_quiz_actor(p_actor_id);
  items    JSONB;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'dayIndex',  p.day_index,
    'itemKind',  p.item_kind,
    'itemIndex', p.item_index,
    'done',      p.done,
    'note',      p.note
  ) ORDER BY p.day_index, p.item_kind, p.item_index), '[]'::jsonb)
  INTO items
  FROM public.devotion_day_progress p
  WHERE p.user_id = actor_id
    AND p.global_plan_id = p_global_plan_id;

  RETURN jsonb_build_object('planId', p_global_plan_id, 'items', items);
END;
$$;

-- ── 3. 會友：寫入 / 更新一個項目（打勾 or 心得）────────────────────────────
CREATE OR REPLACE FUNCTION public.upsert_devotion_progress(
  p_payload JSONB,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID := public.resolve_quiz_actor(p_actor_id);
  v_plan   UUID := (p_payload ->> 'globalPlanId')::UUID;
  v_day    INT  := (p_payload ->> 'dayIndex')::INT;
  v_kind   TEXT := p_payload ->> 'itemKind';
  v_idx    INT  := COALESCE((p_payload ->> 'itemIndex')::INT, 0);
  v_done   BOOLEAN := COALESCE((p_payload ->> 'done')::BOOLEAN, FALSE);
  v_note   TEXT := BTRIM(COALESCE(p_payload ->> 'note', ''));
  v_id     UUID;
BEGIN
  IF v_plan IS NULL OR v_day IS NULL OR v_day < 1 OR v_idx < 0
     OR v_kind NOT IN ('passage', 'think') THEN
    RAISE EXCEPTION 'devotion_progress_payload_invalid';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.global_plans
                 WHERE id = v_plan AND plan_kind = 'devotional') THEN
    RAISE EXCEPTION 'devotional_plan_not_found';
  END IF;

  INSERT INTO public.devotion_day_progress
    (user_id, global_plan_id, day_index, item_kind, item_index, done, note)
  VALUES (actor_id, v_plan, v_day, v_kind, v_idx, v_done, v_note)
  ON CONFLICT (user_id, global_plan_id, day_index, item_kind, item_index)
  DO UPDATE SET done = EXCLUDED.done,
               note = EXCLUDED.note,
               updated_at = NOW()
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id, 'dayIndex', v_day, 'itemKind', v_kind, 'itemIndex', v_idx,
    'done', v_done, 'note', v_note
  );
END;
$$;

-- ── 權限 ───────────────────────────────────────────────────────────────────
DO $$
DECLARE fn TEXT;
BEGIN
  FOR fn IN SELECT unnest(ARRAY[
    'list_devotion_progress(uuid, uuid)',
    'upsert_devotion_progress(jsonb, uuid)'
  ]) LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated, service_role', fn);
  END LOOP;
END $$;

COMMIT;
