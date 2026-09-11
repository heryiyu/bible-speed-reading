-- 0170_exam_paper_linked_plan.sql
--
-- 併入原本規劃、後來刪除的 exam_stats_first_round_filter.sql（那支從未實際
-- 部署過就被本檔的 exam_get_stats 整個取代——拆兩支只會造成「先跑一支再跑
-- 另一支把它蓋掉」的困惑，所以直接刪掉、內容併進來這一支）：
--
--  A. 大測驗統計加「該書卷是否讀過至少一遍」的判定，可切換「只統計已讀完的人」。
--     規則（使用者 2026-09-09）：例如「聖經速讀測驗_創世紀」對應速讀第一階段
--     的創世記，要那個人讀過創世記 ≥ 1 遍，測驗成績才算數。
--       · roster[] 每列多一個 firstRoundDone（true/false/null）——null＝沒帶
--         書卷、不判定。
--       · p_require_first_round=true 時：整體/各大區/各牧區/各小組/組隊規模/
--         團隊排行/PR 母體一律只算「讀過該書卷一遍」的人；roster 仍列出所有
--         人（含被排除者）。overall.notReadCount＝被排除的人數。
--       · 「讀過一遍」判定（_user_read_book_once）：該人有任一 reading_plans，
--         其 target_books 含該書卷，且 current_round>=2（第1遍必然100%系統
--         才讓升），或第1遍打卡的相異章數>=該書卷章數（讀完100%但沒按「進入
--         下一遍」的人也算）。
--
--  B. 大測驗試卷可以直接「用 id 綁定對應哪一個計畫」（通常是某個
--     church_campaign_stage），不靠標題文字比對書卷去猜、也不靠考生現在人在
--     哪個計畫反推。可以留空＝單純獨立測驗卷，不對應任何計畫。
--
-- 使用者需求（2026-09-09～2026-09-11）：
--   「這樣對應不精準要用id去對應，這個試卷就是單單對應那個計畫」
--   「在製造測驗卷的時候要可以設定是對應哪個計劃，可以不要對應單純獨立測驗卷」
--
-- 設計（使用者：「我希望要草稿狀態才能改，不然沒意義」）：
--   · exam_papers 新增 linked_plan_id（可為 NULL＝獨立測驗卷）。
--   · **只能在草稿狀態改**，沿用既有「測試版／正式版」架構，不另開後門：
--       exam_upsert_paper（測試版草稿建立/編輯時）可一併帶 linked_plan_id；
--       用 JSONB `?` 判斷 payload 有沒有帶這個 key，沒帶＝不動舊值——跟
--       sections 之類欄位「留空不動」的慣例一致。
--       exam_push_to_live（推上正式版）把 linked_plan_id 一併從測試版複製到
--       正式版——這是正式版唯一「拿到」這個設定的管道；正式版一旦有人作答，
--       exam_push_to_live 本來就擋住不能再推（exam_push_live_has_attempts），
--       所以正式版發布之後這個設定自然鎖住，不需要額外加限制。
--   · exam_get_stats 的 teamRanking / byTeamSize**只跟著 pr.linked_plan_id 走**
--     （使用者：「排名邏輯就是跟著綁定的 id 去做就好不用再額外多出不必要的
--     判斷」）：設定了就只鎖那一個計畫；拿掉舊版「書卷比對」「考生目前掛哪個
--     計畫」兩層 fallback——判斷依據只剩「有沒有綁定」一件事。
--   · **沒綁定，或綁定的計畫本身沒有登記任何 3/6 人隊，就完全不顯示團隊統計**
--     （使用者：「沒有綁定計畫就不用團隊排名了，那些有關團隊統計就直接隱藏，
--     不要亂對應團隊跑出錯誤資訊」＋「如果計畫本身也沒有團隊資訊也不用團隊
--     排名」）：靠 SQL 本身自然產生空結果，不用額外判斷——latest_team 的
--     WHERE 直接鎖「division IN(3,6) 且屬於 linked_plan_id」，沒綁定或那個
--     計畫沒隊，候選集合本來就是空的，teamRanking/byTeamSize 自然變成 []，
--     不會把不相干的人拼湊成一份誤導性的假團隊資料。
--   · 例外：「聖經速讀測驗_創世紀」的正式版**已經有人作答**，exam_push_to_live
--     擋住無法再推，沒有草稿路徑可以補設定。這次只能破例，直接下 SQL 手動改
--     這一筆（見檔尾註解），以後新出的試卷都走正常的草稿→推正式版流程。
--
-- 部署：SQL editor 執行本檔即可，完全自包含（含 A 段需要的 _user_read_book_once），
-- 不需要先跑任何其他檔案。純 DDL + CREATE OR REPLACE，可重複執行。
-- 不用重部署 Edge Function（沒有新增 RPC，nlc-data allowlist 不用動）。

ALTER TABLE public.exam_papers
  ADD COLUMN IF NOT EXISTS linked_plan_id UUID REFERENCES public.global_plans(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.exam_papers.linked_plan_id IS
  '這份測驗卷對應哪一個計畫（通常是某個 church_campaign_stage）。NULL＝獨立測驗卷，不對應任何計畫。設定後，exam_get_stats 的團隊排行只統計這個計畫底下登記的隊伍，不受標題書卷比對或考生現況影響。';

-- ── 0. _user_read_book_once：「讀過該書卷一遍」的判定 ──────────────────────
CREATE OR REPLACE FUNCTION public._user_read_book_once(p_user_id UUID, p_book TEXT, p_chapters INTEGER)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
  SELECT p_user_id IS NULL OR p_book IS NULL OR BTRIM(p_book) = '' OR EXISTS (
    SELECT 1 FROM public.reading_plans rp
    WHERE rp.user_id = p_user_id
      AND p_book = ANY(rp.target_books)
      AND (
        rp.current_round >= 2
        OR (
          p_chapters IS NOT NULL AND p_chapters > 0
          AND (SELECT COUNT(DISTINCT l.chapter) FROM public.reading_logs l
               WHERE l.user_id = p_user_id AND l.book = p_book AND COALESCE(l.round, 1) = 1) >= p_chapters
        )
      )
  )
$$;
REVOKE ALL ON FUNCTION public._user_read_book_once(UUID, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._user_read_book_once(UUID, TEXT, INTEGER) TO authenticated, service_role;

-- ── 1. exam_upsert_paper：建立/編輯草稿時可一併設定 linked_plan_id ──────────
CREATE OR REPLACE FUNCTION public.exam_upsert_paper(p_payload JSONB, p_actor_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id   UUID := public.resolve_quiz_actor(p_actor_id);
  v_paper_id UUID := NULLIF(p_payload ->> 'id', '')::uuid;
  v_sections JSONB := p_payload -> 'sections';
  v_has_plan BOOLEAN := p_payload ? 'linked_plan_id';
  v_plan_id  UUID := NULLIF(p_payload ->> 'linked_plan_id', '')::uuid;
  row_out    public.exam_papers%ROWTYPE;
BEGIN
  IF public._exam_actor_role(actor_id) NOT IN ('admin', 'pastor') THEN
    RAISE EXCEPTION 'exam_admin_required';
  END IF;
  IF v_plan_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.global_plans WHERE id = v_plan_id) THEN
    RAISE EXCEPTION 'plan_not_found';
  END IF;

  IF v_paper_id IS NULL THEN
    IF v_sections IS NULL THEN
      v_sections := jsonb_build_array(
        jsonb_build_object('type','truefalse','count',20,'pointsPer',1),
        jsonb_build_object('type','single','count',20,'pointsPer',1),
        jsonb_build_object('type','multiple','count',10,'pointsPer',1),
        jsonb_build_object('type','matching','count',10,'pointsPer',1),
        jsonb_build_object('type','ordering','count',10,'pointsPer',1),
        jsonb_build_object('type','shortanswer','count',3,'pointsPer',10));
    END IF;
    INSERT INTO public.exam_papers (title, description, mode, open_at, close_at,
        duration_minutes, total_points, pledge, sections, section_targets, linked_plan_id, created_by)
    VALUES (
      COALESCE(NULLIF(p_payload ->> 'title', ''), '速讀測驗'),
      COALESCE(p_payload ->> 'description', ''),
      COALESCE(NULLIF(p_payload ->> 'mode', ''), 'test'),
      NULLIF(p_payload ->> 'open_at', '')::timestamptz,
      NULLIF(p_payload ->> 'close_at', '')::timestamptz,
      COALESCE((p_payload ->> 'duration_minutes')::smallint, 75),
      GREATEST(public._exam_sections_total(v_sections)::smallint, 1),
      COALESCE(p_payload -> 'pledge', jsonb_build_object('openText','', 'rules','[]'::jsonb, 'consentTemplate','')),
      v_sections,
      public._exam_sections_targets(v_sections),
      v_plan_id,
      actor_id)
    RETURNING * INTO row_out;
  ELSE
    UPDATE public.exam_papers SET
      title = COALESCE(NULLIF(p_payload ->> 'title', ''), title),
      description = COALESCE(p_payload ->> 'description', description),
      mode = COALESCE(NULLIF(p_payload ->> 'mode', ''), mode),
      open_at = COALESCE(NULLIF(p_payload ->> 'open_at', '')::timestamptz, open_at),
      close_at = COALESCE(NULLIF(p_payload ->> 'close_at', '')::timestamptz, close_at),
      duration_minutes = COALESCE((p_payload ->> 'duration_minutes')::smallint, duration_minutes),
      pledge = COALESCE(p_payload -> 'pledge', pledge),
      sections = COALESCE(v_sections, sections),
      section_targets = CASE WHEN v_sections IS NOT NULL
                             THEN public._exam_sections_targets(v_sections) ELSE section_targets END,
      total_points = CASE WHEN v_sections IS NOT NULL
                          THEN GREATEST(public._exam_sections_total(v_sections)::smallint, 1)
                          ELSE COALESCE((p_payload ->> 'total_points')::smallint, total_points) END,
      linked_plan_id = CASE WHEN v_has_plan THEN v_plan_id ELSE linked_plan_id END
    WHERE id = v_paper_id AND status = 'draft'
    RETURNING * INTO row_out;
    IF NOT FOUND THEN RAISE EXCEPTION 'exam_paper_not_editable'; END IF;
  END IF;

  RETURN to_jsonb(row_out);
END;
$$;

-- ── 2. exam_push_to_live：推正式版時把 linked_plan_id 一併從測試版帶過去 ───
-- 這是正式版唯一「拿到」這個設定的管道——沒有另開後門讓已發佈的正式版事後
-- 被改，維持「只能草稿狀態改」。函式其餘邏輯照抄 0118，只多這一個欄位。
CREATE OR REPLACE FUNCTION public.exam_push_to_live(p_test_paper_id UUID, p_actor_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID := public.resolve_quiz_actor(p_actor_id);
  src public.exam_papers%ROWTYPE;
  dst public.exam_papers%ROWTYPE;
  did_create BOOLEAN := FALSE;
  reverted   BOOLEAN := FALSE;
BEGIN
  IF public._exam_actor_role(actor_id) NOT IN ('admin', 'pastor') THEN
    RAISE EXCEPTION 'exam_admin_required';
  END IF;

  SELECT * INTO src FROM public.exam_papers WHERE id = p_test_paper_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'exam_paper_not_found'; END IF;
  IF src.mode <> 'test' THEN RAISE EXCEPTION 'exam_push_source_not_test'; END IF;

  SELECT * INTO dst FROM public.exam_papers
  WHERE pushed_from_id = src.id AND mode = 'live'
  ORDER BY created_at DESC LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO public.exam_papers (
      title, description, mode, status, open_at, close_at,
      duration_minutes, total_points, pledge, sections, section_targets,
      announcement, announcement_published, linked_plan_id, pushed_from_id, created_by)
    VALUES (
      src.title, src.description, 'live', 'draft', src.open_at, src.close_at,
      src.duration_minutes, src.total_points, src.pledge, src.sections, src.section_targets,
      src.announcement, FALSE, src.linked_plan_id, src.id, actor_id)
    RETURNING * INTO dst;
    did_create := TRUE;
  ELSE
    -- 防呆 1：正式版已有人作答 → 不准再推（會換 question id、毀掉已計分結果）
    IF EXISTS (SELECT 1 FROM public.exam_attempts WHERE paper_id = dst.id) THEN
      RAISE EXCEPTION 'exam_push_live_has_attempts';
    END IF;
    -- 防呆 2：測驗進行中 → 先關閉測驗再更新題目
    IF dst.status = 'published' THEN
      RAISE EXCEPTION 'exam_push_live_not_closed';
    END IF;

    reverted := (dst.status = 'closed');
    UPDATE public.exam_papers SET
      title = src.title,
      description = src.description,
      open_at = src.open_at,
      close_at = src.close_at,
      duration_minutes = src.duration_minutes,
      total_points = src.total_points,
      pledge = src.pledge,
      sections = src.sections,
      section_targets = src.section_targets,
      linked_plan_id = src.linked_plan_id,
      status = CASE WHEN dst.status = 'closed' THEN 'draft' ELSE dst.status END,
      published_at = NULL,
      published_by = NULL
      -- announcement / announcement_published 由正式版自己維護，push 不動
    WHERE id = dst.id
    RETURNING * INTO dst;
  END IF;

  -- 題目整份覆蓋（新 id、同內容）
  DELETE FROM public.exam_questions WHERE paper_id = dst.id;
  INSERT INTO public.exam_questions (paper_id, section, position, points, payload, answer_key)
  SELECT dst.id, section, position, points, payload, answer_key
  FROM public.exam_questions WHERE paper_id = src.id;

  RETURN jsonb_build_object(
    'livePaperId', dst.id, 'created', did_create, 'reverted', reverted, 'liveStatus', dst.status
  );
END;
$$;

-- ── 3. exam_get_stats：teamRanking 只跟著 pr.linked_plan_id 走 ─────────────
-- 舊的 2 參數版（0169）換成下面的 5 參數版；DROP 只清舊簽章（重跑時 no-op，
-- 5 參數版已存在時這支也早已不存在），新簽章用 CREATE OR REPLACE，整份檔案
-- 可以重複執行。
DROP FUNCTION IF EXISTS public.exam_get_stats(UUID, UUID);

CREATE OR REPLACE FUNCTION public.exam_get_stats(
  p_paper_id UUID,
  p_actor_id UUID DEFAULT NULL,
  p_require_first_round BOOLEAN DEFAULT FALSE,
  p_reading_book TEXT DEFAULT NULL,
  p_book_chapters INTEGER DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID:=public.resolve_quiz_actor(p_actor_id);actor public.profiles%ROWTYPE;role_c TEXT;
  pr public.exam_papers%ROWTYPE;mreg TEXT[];mzon TEXT[];mgrp TEXT[];scoped UUID[];scoped_stats UUID[];scope_label TEXT;
  scope_all BOOLEAN;v_book TEXT;v_filter BOOLEAN;
  pr_visible BOOLEAN;results_pub BOOLEAN;church_scores NUMERIC[];region_avgs NUMERIC[];zone_avgs NUMERIC[];
  group_avgs NUMERIC[];team3_avgs NUMERIC[];team6_avgs NUMERIC[];
BEGIN
  PERFORM public._exam_close_expired_papers();
  SELECT * INTO actor FROM public.profiles WHERE id=actor_id;
  role_c:=COALESCE(public.role_code(actor.role_id),'member');
  IF role_c NOT IN('admin','pastor','great_zone_leader','zone_leader','group_leader') THEN RAISE EXCEPTION 'exam_admin_required'; END IF;
  SELECT * INTO pr FROM public.exam_papers WHERE id=p_paper_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'exam_paper_not_found'; END IF;
  mreg:=ARRAY(SELECT NULLIF(BTRIM(x),'')FROM UNNEST(STRING_TO_ARRAY(COALESCE(NULLIF(actor.managed_regions,''),actor.great_region,''),','))x WHERE NULLIF(BTRIM(x),'')IS NOT NULL);
  mzon:=ARRAY(SELECT NULLIF(BTRIM(x),'')FROM UNNEST(STRING_TO_ARRAY(COALESCE(NULLIF(actor.managed_zones,''),actor.pastoral_zone,''),','))x WHERE NULLIF(BTRIM(x),'')IS NOT NULL);
  mgrp:=ARRAY(SELECT NULLIF(BTRIM(x),'')FROM UNNEST(STRING_TO_ARRAY(COALESCE(NULLIF(actor.managed_groups,''),actor.small_group,''),','))x WHERE NULLIF(BTRIM(x),'')IS NOT NULL);
  scope_label:=CASE WHEN role_c IN('admin','pastor')THEN'all' ELSE'scoped' END;
  scope_all:=(role_c IN('admin','pastor'));
  v_book:=NULLIF(BTRIM(COALESCE(p_reading_book,'')),'');
  v_filter:=COALESCE(p_require_first_round,FALSE) AND v_book IS NOT NULL;

  SELECT COALESCE(array_agg(a.id),'{}')INTO scoped
  FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
  WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND(
    role_c IN('admin','pastor')OR(role_c='great_zone_leader' AND p.great_region=ANY(mreg))
    OR(role_c='zone_leader' AND p.pastoral_zone=ANY(mzon))
    OR(role_c='group_leader' AND p.small_group=ANY(mgrp)));

  -- 只統計已讀完該書卷一遍的人（toggle 開啟時）
  IF v_filter THEN
    SELECT COALESCE(array_agg(a.id),'{}')INTO scoped_stats
    FROM public.exam_attempts a
    WHERE a.id=ANY(scoped) AND public._user_read_book_once(a.user_id,v_book,p_book_chapters);
  ELSE
    scoped_stats:=scoped;
  END IF;

  results_pub:=pr.results_published_at IS NOT NULL;
  pr_visible:=results_pub OR scope_all;
  IF pr_visible THEN
    church_scores:=ARRAY(SELECT a.total_score FROM public.exam_attempts a
      WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND a.status='graded' AND a.total_score IS NOT NULL
        AND(NOT v_filter OR public._user_read_book_once(a.user_id,v_book,p_book_chapters)));
    region_avgs:=ARRAY(SELECT ROUND(AVG(a.total_score)::numeric,1)FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND a.status='graded'
        AND(NOT v_filter OR public._user_read_book_once(a.user_id,v_book,p_book_chapters))
      GROUP BY COALESCE(NULLIF(p.great_region,''),'（未分區）'));
    zone_avgs:=ARRAY(SELECT ROUND(AVG(a.total_score)::numeric,1)FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND a.status='graded'
        AND(NOT v_filter OR public._user_read_book_once(a.user_id,v_book,p_book_chapters))
      GROUP BY COALESCE(NULLIF(p.great_region,''),'（未分區）'),COALESCE(NULLIF(p.pastoral_zone,''),'（未分牧區）'));
    group_avgs:=ARRAY(SELECT ROUND(AVG(a.total_score)::numeric,1)FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND a.status='graded'
        AND(NOT v_filter OR public._user_read_book_once(a.user_id,v_book,p_book_chapters))
      GROUP BY COALESCE(NULLIF(p.pastoral_zone,''),'（未分牧區）'),COALESCE(NULLIF(p.small_group,''),'（未分組）'));
    team3_avgs:=public._exam_team_avg_pop(pr.id,3);
    team6_avgs:=public._exam_team_avg_pop(pr.id,6);
  END IF;

  RETURN jsonb_build_object(
    'paper',jsonb_build_object('id',pr.id,'title',pr.title,'status',pr.status,'mode',pr.mode,'totalPoints',pr.total_points,'linkedPlanId',pr.linked_plan_id),
    'scope',scope_label,'prVisible',pr_visible,'resultsPublished',results_pub,
    'readingBook',v_book,'requireFirstRound',v_filter,
    'overall',(SELECT jsonb_build_object('attempts',COUNT(*),
      'submitted',COUNT(*)FILTER(WHERE a.status IN('submitted','graded')),
      'graded',COUNT(*)FILTER(WHERE a.status='graded'),'inProgress',COUNT(*)FILTER(WHERE a.status='in_progress'),
      'avgAuto',ROUND(AVG(a.auto_score)FILTER(WHERE a.status IN('submitted','graded'))::numeric,1),
      'avgManual',ROUND(AVG(a.manual_score)FILTER(WHERE a.status='graded')::numeric,1),
      'avgTotal',ROUND(AVG(a.total_score)FILTER(WHERE a.status='graded')::numeric,1),
      'maxTotal',MAX(a.total_score)FILTER(WHERE a.status='graded'),'minTotal',MIN(a.total_score)FILTER(WHERE a.status='graded'),
      'notReadCount',(SELECT COUNT(*)FROM public.exam_attempts a2 WHERE a2.id=ANY(scoped)AND a2.status IN('submitted','graded')
        AND v_book IS NOT NULL AND NOT public._user_read_book_once(a2.user_id,v_book,p_book_chapters)))
      FROM public.exam_attempts a WHERE a.id=ANY(scoped_stats)),
    'byRegion',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',x.name,'count',x.count,'graded',x.graded,
      'avgTotal',x."avgTotal",'pr',CASE WHEN pr_visible THEN public._exam_pr(x."avgTotal",region_avgs)ELSE NULL END)
      ORDER BY x.sort_order NULLS LAST,x.name)FROM(
      SELECT COALESCE(NULLIF(p.great_region,''),'（未分區）')name,gr.sort_order,COUNT(*)count,
        COUNT(*)FILTER(WHERE a.status='graded')graded,ROUND(AVG(a.total_score)FILTER(WHERE a.status='graded')::numeric,1)"avgTotal"
      FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      LEFT JOIN public.great_regions gr ON gr.name=p.great_region
      WHERE a.id=ANY(scoped_stats)AND a.status IN('submitted','graded')GROUP BY 1,gr.sort_order)x),'[]'::jsonb),
    'byZone',COALESCE((SELECT jsonb_agg(jsonb_build_object('region',x.region,'name',x.name,'count',x.count,'graded',x.graded,
      'avgTotal',x."avgTotal",'pr',CASE WHEN pr_visible THEN public._exam_pr(x."avgTotal",zone_avgs)ELSE NULL END)
      ORDER BY x.region_sort NULLS LAST,x.zone_sort NULLS LAST,x.region,x.name)FROM(
      SELECT COALESCE(NULLIF(p.great_region,''),'（未分區）')region,
        COALESCE(NULLIF(p.pastoral_zone,''),'（未分牧區）')name,
        gr.sort_order region_sort,pz.sort_order zone_sort,COUNT(*)count,
        COUNT(*)FILTER(WHERE a.status='graded')graded,ROUND(AVG(a.total_score)FILTER(WHERE a.status='graded')::numeric,1)"avgTotal"
      FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      LEFT JOIN public.great_regions gr ON gr.name=p.great_region
      LEFT JOIN public.pastoral_zones pz ON pz.name=p.pastoral_zone AND pz.great_region_id=gr.id
      WHERE a.id=ANY(scoped_stats)AND a.status IN('submitted','graded')GROUP BY 1,2,gr.sort_order,pz.sort_order)x),'[]'::jsonb),
    'byGroup',COALESCE((SELECT jsonb_agg(jsonb_build_object('zone',x.zone,'name',x.name,'count',x.count,'graded',x.graded,
      'avgTotal',x."avgTotal",'pr',CASE WHEN pr_visible THEN public._exam_pr(x."avgTotal",group_avgs)ELSE NULL END)
      ORDER BY x.zone_sort NULLS LAST,x.zone,x.name)FROM(
      SELECT COALESCE(NULLIF(p.pastoral_zone,''),'（未分牧區）')zone,
        COALESCE(NULLIF(p.small_group,''),'（未分組）')name,
        pz.sort_order zone_sort,COUNT(*)count,
        COUNT(*)FILTER(WHERE a.status='graded')graded,ROUND(AVG(a.total_score)FILTER(WHERE a.status='graded')::numeric,1)"avgTotal"
      FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      LEFT JOIN public.great_regions gr ON gr.name=p.great_region
      LEFT JOIN public.pastoral_zones pz ON pz.name=p.pastoral_zone AND pz.great_region_id=gr.id
      WHERE a.id=ANY(scoped_stats)AND a.status IN('submitted','graded')GROUP BY 1,2,pz.sort_order)x),'[]'::jsonb),
    -- 沒綁定計畫的獨立測驗卷不顯示任何團隊統計（byTeamSize / teamRanking）：
    -- 沒有計畫脈絡就沒有「這份卷的團隊」這個概念，硬要算只會把毫不相干、
    -- 剛好也在某個 3/6 人隊的人湊在一起，變成誤導性的假資訊。byTeamSize 的
    -- 隊員身分判定也加 m.global_plan_id=pr.linked_plan_id，只認「在這個計畫
    -- 底下」的隊籍——不然即使這個計畫本身沒隊，個人若剛好在別的計畫掛著
    -- 3/6 人隊，也會被誤算進來，一樣是誤導性資訊。
    'byTeamSize',CASE WHEN pr.linked_plan_id IS NULL THEN '[]'::jsonb ELSE
      COALESCE((SELECT jsonb_agg(jsonb_build_object('label',b.label,'count',b.cnt,
      'graded',b.graded,'avgTotal',b.avg_total)ORDER BY b.sort)FROM(
      SELECT bl.label,bl.sort,COUNT(*)FILTER(WHERE bl.member)cnt,
        COUNT(*)FILTER(WHERE bl.member AND a.status='graded')graded,
        ROUND(AVG(a.total_score)FILTER(WHERE bl.member AND a.status='graded')::numeric,1)avg_total
      FROM public.exam_attempts a CROSS JOIN LATERAL(VALUES
        ('3 人團隊'::text,1,EXISTS(SELECT 1 FROM public.reading_team_members m WHERE m.user_id=a.user_id AND m.division=3 AND m.global_plan_id=pr.linked_plan_id)),
        ('6 人團隊'::text,2,EXISTS(SELECT 1 FROM public.reading_team_members m WHERE m.user_id=a.user_id AND m.division=6 AND m.global_plan_id=pr.linked_plan_id)),
        ('未組隊'::text,3,NOT EXISTS(SELECT 1 FROM public.reading_team_members m WHERE m.user_id=a.user_id AND m.division IN(3,6) AND m.global_plan_id=pr.linked_plan_id))
      )bl(label,sort,member)WHERE a.id=ANY(scoped_stats)AND a.status IN('submitted','graded')
      GROUP BY bl.label,bl.sort)b WHERE b.cnt>0),'[]'::jsonb)
    END,
    'teamRanking',COALESCE((
      WITH RECURSIVE team_root(id,anchor)AS(
        SELECT rt.id,rt.id FROM public.reading_teams rt
        WHERE rt.carried_from_team_id IS NULL
           OR NOT EXISTS(SELECT 1 FROM public.reading_teams p WHERE p.id=rt.carried_from_team_id)
        UNION ALL
        SELECT rt.id,r.anchor FROM public.reading_teams rt
        JOIN team_root r ON rt.carried_from_team_id=r.id
      ),
      -- 排行榜只跟著試卷自己綁定的 pr.linked_plan_id 走，沒有其他判斷/猜測：
      -- 沒綁定就直接 WHERE FALSE，candidate 集合是空的，teamRanking 自然是
      -- []（不用團隊排名）；有綁定但那個計畫底下根本沒登記任何 3/6 人隊，
      -- candidate 集合一樣是空的，同樣自然變成 []（計畫本身沒有團隊資訊也
      -- 不用團隊排名）——兩種情況都不用另外判斷，讓 SQL 本身自然產生空結果。
      -- 有隊的話，每條隊伍鏈只留「屬於這個計畫」的那一節：已經升到下一階段
      -- 的隊伍鏈，找不到符合的一節就整支從候選中消失，同一條鏈也不重複認列。
      latest_team AS(
        SELECT DISTINCT ON(tr.anchor,rt.division)
          rt.id team_id,rt.name,rt.division,rt.global_plan_id,rt.captain_id
        FROM public.reading_teams rt
        JOIN team_root tr ON tr.id=rt.id
        WHERE rt.division IN(3,6)
          AND pr.linked_plan_id IS NOT NULL
          AND rt.global_plan_id=pr.linked_plan_id
        ORDER BY tr.anchor,rt.division,rt.created_at DESC,rt.id DESC
      )
      -- 分數只算「有作答（且開關開時＝有讀完）」的成員（scoped_stats），分母固定 division。
      -- 缺口再拆三類讓管理員看得出原因：
      --   notRead    ＝有考試、但沒讀完該書卷（開關開時不計分；開關關時恆 0）
      --   notTested  ＝隊員本人完全沒有這份測驗的 submitted/graded 作答
      --   emptySlots ＝隊伍沒滿 division 人
      SELECT jsonb_agg(jsonb_build_object('teamId',t.team_id,'name',t.name,
        'division',t.division,'rank',t.rnk,'completed',t.completed,'submitted',t.submitted_cnt,
        'notRead',t.not_read_cnt,'notTested',t.not_tested_cnt,'emptySlots',t.empty_slots,
        'greatRegion',t.captain_region,'pastoralZone',t.captain_zone,
        'teamTotal',t.team_total,'avgTotal',t.avg_total,
        'pr',CASE WHEN pr_visible AND t.submitted_cnt>0
          THEN public._exam_pr(t.avg_total,CASE t.division WHEN 3 THEN team3_avgs WHEN 6 THEN team6_avgs END)
          ELSE NULL END)
        ORDER BY t.division,t.rnk,t.name)
      FROM(
        SELECT ranked.team_id,ranked.name,ranked.division,ranked.completed,ranked.submitted_cnt,
          ranked.not_read_cnt,ranked.not_tested_cnt,ranked.empty_slots,
          ranked.team_total,ranked.avg_total,ranked.captain_region,ranked.captain_zone,
          RANK()OVER(PARTITION BY ranked.division ORDER BY ranked.avg_total DESC)rnk
        FROM(
          SELECT lt.team_id,lt.name,lt.division,cap.great_region captain_region,cap.pastoral_zone captain_zone,
            COUNT(a.id)FILTER(WHERE a.id=ANY(scoped_stats)AND a.status='graded')completed,
            COUNT(a.id)FILTER(WHERE a.id=ANY(scoped_stats)AND a.status IN('submitted','graded'))submitted_cnt,
            GREATEST(0,COUNT(a.id)FILTER(WHERE a.status IN('submitted','graded'))
              -COUNT(a.id)FILTER(WHERE a.id=ANY(scoped_stats)AND a.status IN('submitted','graded')))not_read_cnt,
            GREATEST(0,COUNT(DISTINCT m.user_id)
              -COUNT(a.id)FILTER(WHERE a.status IN('submitted','graded')))not_tested_cnt,
            GREATEST(0,lt.division-COUNT(DISTINCT m.user_id))empty_slots,
            COALESCE(SUM(a.total_score)FILTER(WHERE a.id=ANY(scoped_stats)AND a.status='graded'),0)team_total,
            ROUND(COALESCE(SUM(a.total_score)FILTER(WHERE a.id=ANY(scoped_stats)AND a.status='graded'),0)::numeric/lt.division,1)avg_total
          FROM latest_team lt
          LEFT JOIN public.profiles cap ON cap.id=lt.captain_id
          JOIN public.reading_team_members m ON m.team_id=lt.team_id
          LEFT JOIN public.exam_attempts a
            ON a.user_id=m.user_id AND a.paper_id=pr.id AND a.attempt_kind='official' AND a.id=ANY(scoped)
          GROUP BY lt.team_id,lt.name,lt.division,lt.global_plan_id,cap.great_region,cap.pastoral_zone
          -- lt 已經是「屬於 linked_plan_id 的隊」（latest_team 的 WHERE 保證），
          -- 這裡只差要不要對 admin 顯示 0 分墊底的隊；範圍主管一律只看有人作答的隊。
          HAVING scope_all OR COUNT(a.id)FILTER(WHERE a.status IN('submitted','graded'))>0
        )ranked
      )t
    ),'[]'::jsonb),
    'byQuestion',COALESCE((SELECT jsonb_agg(x ORDER BY x."sectionRank",x.position)FROM(
      SELECT q.section,q.position,public._exam_section_rank(q.section)"sectionRank",COUNT(ea.*)answered,
        COUNT(ea.*)FILTER(WHERE ea.auto_correct)correct,
        ROUND((COUNT(ea.*)FILTER(WHERE ea.auto_correct))::numeric/NULLIF(COUNT(ea.*),0),3)"correctRate"
      FROM public.exam_questions q JOIN public.exam_answers ea ON ea.question_id=q.id
      JOIN public.exam_attempts a ON a.id=ea.attempt_id AND a.status IN('submitted','graded')AND a.id=ANY(scoped_stats)
      WHERE q.paper_id=pr.id AND q.section<>'shortanswer' GROUP BY q.id,q.section,q.position)x),'[]'::jsonb),
    'roster',COALESCE((SELECT jsonb_agg(jsonb_build_object('userId',a.user_id,'name',p.name,
      'greatRegion',p.great_region,'pastoralZone',p.pastoral_zone,'smallGroup',p.small_group,
      'teamLabel',(SELECT CASE WHEN bool_or(m.division=3)AND bool_or(m.division=6)THEN'3+6 人團隊'
        WHEN bool_or(m.division=3)THEN'3 人團隊' WHEN bool_or(m.division=6)THEN'6 人團隊' ELSE'個人'END
        FROM public.reading_team_members m WHERE m.user_id=a.user_id),
      'status',a.status,'autoScore',a.auto_score,'manualScore',a.manual_score,'totalScore',a.total_score,
      'submittedAt',a.submitted_at,
      'firstRoundDone',CASE WHEN v_book IS NULL THEN NULL ELSE public._user_read_book_once(a.user_id,v_book,p_book_chapters)END,
      'prChurch',CASE WHEN pr_visible AND a.status='graded'
        AND(NOT v_filter OR public._user_read_book_once(a.user_id,v_book,p_book_chapters))
        THEN public._exam_pr(a.total_score,church_scores)ELSE NULL END,
      'prZone',CASE WHEN pr_visible AND a.status='graded'
        AND(NOT v_filter OR public._user_read_book_once(a.user_id,v_book,p_book_chapters))
        THEN public._exam_pr(a.total_score,
        ARRAY(SELECT a2.total_score FROM public.exam_attempts a2 JOIN public.profiles p2 ON p2.id=a2.user_id
          WHERE a2.paper_id=pr.id AND a2.attempt_kind='official' AND a2.status='graded' AND a2.total_score IS NOT NULL
            AND(NOT v_filter OR public._user_read_book_once(a2.user_id,v_book,p_book_chapters))
            AND COALESCE(NULLIF(p2.pastoral_zone,''),'（未分牧區）')=COALESCE(NULLIF(p.pastoral_zone,''),'（未分牧區）')))
        ELSE NULL END,
      'prGroup',CASE WHEN pr_visible AND a.status='graded'
        AND(NOT v_filter OR public._user_read_book_once(a.user_id,v_book,p_book_chapters))
        THEN public._exam_pr(a.total_score,
        ARRAY(SELECT a2.total_score FROM public.exam_attempts a2 JOIN public.profiles p2 ON p2.id=a2.user_id
          WHERE a2.paper_id=pr.id AND a2.attempt_kind='official' AND a2.status='graded' AND a2.total_score IS NOT NULL
            AND(NOT v_filter OR public._user_read_book_once(a2.user_id,v_book,p_book_chapters))
            AND COALESCE(NULLIF(p2.small_group,''),'（未分組）')=COALESCE(NULLIF(p.small_group,''),'（未分組）')))
        ELSE NULL END)
      ORDER BY a.total_score DESC NULLS LAST,a.submitted_at ASC)
      FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      WHERE a.id=ANY(scoped)AND a.status IN('submitted','graded')),'[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.exam_get_stats(UUID,UUID,BOOLEAN,TEXT,INTEGER) TO authenticated;

COMMENT ON FUNCTION public.exam_get_stats(UUID,UUID,BOOLEAN,TEXT,INTEGER)
IS '正式測驗統計。p_reading_book/p_book_chapters：對應書卷（roster[].firstRoundDone 判定「讀過該書卷一遍」＝有 target_books 含該卷且 current_round>=2 或第1遍打卡滿章數的 reading_plans）。p_require_first_round=true → 整體/各大區/牧區/小組/組隊/團隊排行/PR母體只算讀過的人（roster 仍列全部，overall.notReadCount=被排除數）。byTeamSize/teamRanking 只跟著 pr.linked_plan_id 走，不看書卷、不看考生現在掛哪個計畫：沒綁定，或綁定的計畫底下沒登記任何 3/6 人隊，兩者都自然回傳 []（latest_team 的候選集合本來就是空的）——不顯示團隊統計，不會把不相干的人拼成誤導性的假團隊資料。有隊時 latest_team 只認那個計畫底下那一節，不會抓到已升到下一階段的隊，也不會同鏈重複認列。每列另帶 notRead（有考試沒讀完）/notTested（隊員沒作答）/emptySlots（隊沒滿），分母固定 division。PR 沿用 0169。';

-- ============================================================================
-- 手動一次性例外——不是本檔自動執行的一部分，請自行複製、確認 WHERE 條件
-- 抓到的是唯一一列之後再單獨執行。
--
-- 「聖經速讀測驗_創世紀」的正式版已經有人作答，exam_push_to_live 擋住無法
-- 再推、沒有草稿路徑可以補設定，這裡破例直接手動 UPDATE 這一筆。以後新出
-- 的試卷一律在測試版（草稿）設定「對應計畫」、靠推正式版帶過去，不要再用
-- 這種手動方式。
--
-- 先確認只抓到一列（正式版）：
--   SELECT id, title, mode, status FROM public.exam_papers
--   WHERE title = '聖經速讀測驗_創世紀' AND mode = 'live';
--
-- 確認後執行（第一階段熱身賽＝c026-00000000000<1>，見 0017）：
--   UPDATE public.exam_papers
--   SET linked_plan_id = '00000000-0000-0000-c026-000000000001'
--   WHERE title = '聖經速讀測驗_創世紀' AND mode = 'live';
-- ============================================================================
