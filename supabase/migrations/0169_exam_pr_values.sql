-- 0169_exam_pr_values.sql
--
-- 大測驗 PR 值（百分等級）。設計見對話 2026-09-08。
--
--  · PR 公式：round( (低於 x + 0.5×等於 x) / 母體 × 100 )，夾 1–99；母體 < 5 → NULL。
--  · 母體一律「本測驗正式作答且已批改」者（attempt_kind='official' AND status='graded'）。
--  · 可見性：
--      會友端 exam_get_my_result —— 只有「正式卷+已批改+已公布」才計算並回傳。
--      後台 exam_get_stats       —— admin / pastor（系統管理員 / 牧者）發布前也看得到（做分析用）；
--                                   大區 / 牧區 / 小組長等範圍主管，要成績公布後才看得到。
--    公布後整卷鎖定 → PR 為定值。
--
--  會友端 exam_get_my_result（公布後才給）：
--    prChurch          —— 本人總分在全教會的 PR
--    teams[]           —— 本人所屬 3/6 人隊各一筆：{division,name,greatRegion,pastoralZone,avg,pr}
--                          大區/牧區取隊長的；只有隊伍平均與 PR，不含任何隊友分數。
--
--  後台 exam_get_stats（見上可見性；其餘欄位不受影響）：
--    roster[].prChurch / prZone / prGroup  —— 個人總分在 全教會 / 本人牧區 / 本人小組 的 PR
--    byRegion[].pr / byZone[].pr / byGroup[].pr —— 該單位平均在「全教會同層級」的 PR
--    teamRanking[].pr + greatRegion + pastoralZone —— 隊平均在「全教會同 division 各隊」的 PR；
--                          大區/牧區取隊長的（名次照舊保留）
--    PR 一律以全教會母體計算，不用 scoped 子集，會友與後台看到的一致。
--
-- 部署：SQL editor 執行即可。純函式定義（CREATE OR REPLACE），不動簽章、不用重部署
-- Edge Function。接在 0168 之後（同一支 exam_get_stats）。冪等。

-- ── 1. PR 計算 ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._exam_pr(p_value NUMERIC, p_pop NUMERIC[])
RETURNS INTEGER
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  -- p_pop 需為不含 NULL 的母體分數陣列。母體 < 5 視為樣本太少 → NULL。
  SELECT CASE
    WHEN p_value IS NULL THEN NULL
    WHEN COALESCE(array_length(p_pop, 1), 0) < 5 THEN NULL
    ELSE GREATEST(1, LEAST(99, ROUND((
      (SELECT COUNT(*) FROM unnest(p_pop) v WHERE v < p_value)
      + 0.5 * (SELECT COUNT(*) FROM unnest(p_pop) v WHERE v = p_value)
    )::numeric / array_length(p_pop, 1) * 100)::integer))
  END
$$;

COMMENT ON FUNCTION public._exam_pr(NUMERIC, NUMERIC[])
IS 'PR 百分等級：round((低於+0.5×等於)/母體×100)，夾 1–99；母體<5 或值為 NULL 回 NULL。母體陣列須不含 NULL。';

-- ── 2. 全教會「某 division 每支隊的固定分母平均」母體陣列 ────────────────────
--    沿用 0168 的 carry 鏈收斂（每條鏈取最新階段名單去重）。只納入有人作答的隊。
CREATE OR REPLACE FUNCTION public._exam_team_avg_pop(p_paper_id UUID, p_division INTEGER)
RETURNS NUMERIC[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
  WITH RECURSIVE team_root(id, anchor) AS (
    SELECT rt.id, rt.id FROM public.reading_teams rt
    WHERE rt.carried_from_team_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.reading_teams p WHERE p.id = rt.carried_from_team_id)
    UNION ALL
    SELECT rt.id, r.anchor FROM public.reading_teams rt
    JOIN team_root r ON rt.carried_from_team_id = r.id
  ),
  latest_team AS (
    SELECT DISTINCT ON (tr.anchor, rt.division) rt.id team_id, rt.division
    FROM public.reading_teams rt
    JOIN team_root tr ON tr.id = rt.id
    WHERE rt.division = p_division
    ORDER BY tr.anchor, rt.division, rt.created_at DESC, rt.id DESC
  )
  SELECT COALESCE(array_agg(x.avg_total), '{}')
  FROM (
    SELECT ROUND(COALESCE(SUM(a.total_score) FILTER (WHERE a.status = 'graded'), 0)::numeric / p_division, 1) avg_total
    FROM latest_team lt
    JOIN public.reading_team_members m ON m.team_id = lt.team_id
    LEFT JOIN public.exam_attempts a
      ON a.user_id = m.user_id AND a.paper_id = p_paper_id
     AND a.attempt_kind = 'official' AND a.status IN ('submitted', 'graded')
    GROUP BY lt.team_id
    HAVING COUNT(a.id) FILTER (WHERE a.status IN ('submitted', 'graded')) > 0
  ) x
$$;

REVOKE ALL ON FUNCTION public._exam_team_avg_pop(UUID, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._exam_team_avg_pop(UUID, INTEGER) TO authenticated, service_role;

-- ── 3. 會友端結果：加 prChurch + teams[]（公布後才給） ─────────────────────────
CREATE OR REPLACE FUNCTION public.exam_get_my_result(
  p_paper_id UUID,p_actor_id UUID DEFAULT NULL,p_attempt_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE actor_id UUID:=public.resolve_quiz_actor(p_actor_id);
  is_staff BOOLEAN:=public._exam_actor_role(actor_id)IN('admin','pastor');
  at public.exam_attempts%ROWTYPE;pr public.exam_papers%ROWTYPE;published BOOLEAN;show_full BOOLEAN;
  show_pr BOOLEAN;church_scores NUMERIC[];
BEGIN
  PERFORM public._exam_close_expired_papers();
  IF p_attempt_id IS NOT NULL THEN
    SELECT * INTO at FROM public.exam_attempts WHERE id=p_attempt_id AND paper_id=p_paper_id
      AND(user_id=actor_id OR is_staff);
  ELSE
    SELECT * INTO at FROM public.exam_attempts WHERE paper_id=p_paper_id AND user_id=actor_id AND attempt_kind='official';
  END IF;
  IF NOT FOUND THEN RETURN jsonb_build_object('state','no_attempt'); END IF;
  SELECT * INTO pr FROM public.exam_papers WHERE id=at.paper_id;
  published:=pr.results_published_at IS NOT NULL;
  show_full:=(at.status='graded')AND(published OR is_staff);
  -- PR：只有「正式卷 + 已批改 + 已公布」才計算。管理員預覽（published=false）也不給。
  show_pr:=(at.attempt_kind='official')AND(at.status='graded')AND published;
  IF show_pr THEN
    church_scores:=ARRAY(SELECT x.total_score FROM public.exam_attempts x
      WHERE x.paper_id=at.paper_id AND x.attempt_kind='official' AND x.status='graded'
        AND x.total_score IS NOT NULL);
  END IF;
  RETURN jsonb_build_object(
    'state',CASE WHEN at.status='in_progress'THEN'in_progress' WHEN show_full THEN'graded' ELSE'submitted' END,
    'attemptId',at.id,'attemptKind',at.attempt_kind,'countsTowardScore',at.attempt_kind='official',
    'resultsPublished',published,'staffPreview',(show_full AND NOT published AND is_staff),
    'reviewVisibility',CASE WHEN show_full THEN'full_review' ELSE'responses_only' END,
    'autoScore',CASE WHEN show_full THEN at.auto_score ELSE NULL END,
    'manualScore',CASE WHEN show_full THEN at.manual_score ELSE NULL END,
    'totalScore',CASE WHEN show_full THEN at.total_score ELSE NULL END,
    -- ── PR（公布後才有；不含任何隊友分數，只有隊伍平均與 PR）──
    'prPublished',show_pr,
    'prChurch',CASE WHEN show_pr THEN public._exam_pr(at.total_score,church_scores) ELSE NULL END,
    'teams',CASE WHEN show_pr THEN COALESCE((
      WITH RECURSIVE team_root(id,anchor)AS(
        SELECT rt.id,rt.id FROM public.reading_teams rt
        WHERE rt.carried_from_team_id IS NULL
           OR NOT EXISTS(SELECT 1 FROM public.reading_teams p WHERE p.id=rt.carried_from_team_id)
        UNION ALL
        SELECT rt.id,r.anchor FROM public.reading_teams rt JOIN team_root r ON rt.carried_from_team_id=r.id
      ),
      latest_team AS(
        SELECT DISTINCT ON(tr.anchor,rt.division)rt.id team_id,rt.name,rt.division,rt.captain_id
        FROM public.reading_teams rt JOIN team_root tr ON tr.id=rt.id
        WHERE rt.division IN(3,6)
        ORDER BY tr.anchor,rt.division,rt.created_at DESC,rt.id DESC
      )
      SELECT jsonb_agg(jsonb_build_object('division',td.division,'name',td.name,
        'greatRegion',td.captain_region,'pastoralZone',td.captain_zone,
        'avg',td.avg_total,
        'pr',public._exam_pr(td.avg_total,public._exam_team_avg_pop(at.paper_id,td.division)))
        ORDER BY td.division)
      FROM(
        SELECT lt.team_id,lt.name,lt.division,cap.great_region captain_region,cap.pastoral_zone captain_zone,
          ROUND(COALESCE(SUM(a.total_score)FILTER(WHERE a.status='graded'),0)::numeric/lt.division,1)avg_total
        FROM latest_team lt
        LEFT JOIN public.profiles cap ON cap.id=lt.captain_id
        JOIN public.reading_team_members mm ON mm.team_id=lt.team_id
        LEFT JOIN public.exam_attempts a
          ON a.user_id=mm.user_id AND a.paper_id=at.paper_id
         AND a.attempt_kind='official' AND a.status IN('submitted','graded')
        WHERE EXISTS(SELECT 1 FROM public.reading_team_members me
          WHERE me.team_id=lt.team_id AND me.user_id=actor_id)
        GROUP BY lt.team_id,lt.name,lt.division,cap.great_region,cap.pastoral_zone
      )td
    ),'[]'::jsonb) ELSE NULL END,
    'answers',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'questionId',q.id,'section',q.section,'position',q.position,'points',q.points,
      'sectionRank',public._exam_section_rank(q.section),'response',ea.response,
      'autoCorrect',CASE WHEN show_full THEN ea.auto_correct ELSE NULL END,
      'awardedPoints',CASE WHEN show_full THEN ea.awarded_points ELSE NULL END,
      'graderComment',CASE WHEN show_full AND at.attempt_kind='official' THEN ea.grader_comment ELSE NULL END,
      'payload',CASE WHEN show_full THEN q.payload ELSE public._exam_public_payload(q.section,q.payload,q.points)END,
      'answerKey',CASE WHEN show_full AND q.section<>'shortanswer'THEN q.answer_key ELSE NULL END)
      ORDER BY public._exam_section_rank(q.section),q.position)
      FROM public.exam_questions q LEFT JOIN public.exam_answers ea
        ON ea.question_id=q.id AND ea.attempt_id=at.id
      WHERE q.paper_id=at.paper_id),'[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.exam_get_my_result(UUID,UUID,UUID) TO authenticated;

COMMENT ON FUNCTION public.exam_get_my_result(UUID,UUID,UUID)
IS '回傳本人完整試卷結果；成績公布前只顯示本人作答，公布後才顯示正解與評分。PR（prChurch、teams[].pr）只有正式卷+已批改+已公布才計算，管理員預覽不給，且不含任何隊友分數；teams[] 帶隊長的大區/牧區。';

-- ── 4. 後台統計：5 張表加 PR 欄 + 團隊排行加大區/牧區 ────────────────────────
CREATE OR REPLACE FUNCTION public.exam_get_stats(p_paper_id UUID,p_actor_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID:=public.resolve_quiz_actor(p_actor_id);actor public.profiles%ROWTYPE;role_c TEXT;
  pr public.exam_papers%ROWTYPE;mreg TEXT[];mzon TEXT[];mgrp TEXT[];scoped UUID[];scope_label TEXT;
  scope_all BOOLEAN;v_plans UUID[];
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
  SELECT COALESCE(array_agg(a.id),'{}')INTO scoped
  FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
  WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND(
    role_c IN('admin','pastor')OR(role_c='great_zone_leader' AND p.great_region=ANY(mreg))
    OR(role_c='zone_leader' AND p.pastoral_zone=ANY(mzon))
    OR(role_c='group_leader' AND p.small_group=ANY(mgrp)));

  SELECT COALESCE(array_agg(DISTINCT rtm.global_plan_id),'{}')INTO v_plans
  FROM public.reading_team_members rtm
  WHERE rtm.user_id IN(SELECT a.user_id FROM public.exam_attempts a WHERE a.id=ANY(scoped));

  -- PR 母體：一律全教會（不受 scoped 影響）。
  -- 可見性：admin/pastor 隨時可見；範圍主管要成績公布後才可見。
  results_pub:=pr.results_published_at IS NOT NULL;
  pr_visible:=results_pub OR scope_all;
  IF pr_visible THEN
    -- church_scores 用原始 total_score；by-unit 母體與顯示的 avgTotal 一樣 ROUND(,1) 對齊。
    church_scores:=ARRAY(SELECT a.total_score FROM public.exam_attempts a
      WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND a.status='graded' AND a.total_score IS NOT NULL);
    region_avgs:=ARRAY(SELECT ROUND(AVG(a.total_score)::numeric,1)FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND a.status='graded'
      GROUP BY COALESCE(NULLIF(p.great_region,''),'（未分區）'));
    zone_avgs:=ARRAY(SELECT ROUND(AVG(a.total_score)::numeric,1)FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND a.status='graded'
      GROUP BY COALESCE(NULLIF(p.great_region,''),'（未分區）'),COALESCE(NULLIF(p.pastoral_zone,''),'（未分牧區）'));
    group_avgs:=ARRAY(SELECT ROUND(AVG(a.total_score)::numeric,1)FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      WHERE a.paper_id=pr.id AND a.attempt_kind='official' AND a.status='graded'
      GROUP BY COALESCE(NULLIF(p.pastoral_zone,''),'（未分牧區）'),COALESCE(NULLIF(p.small_group,''),'（未分組）'));
    team3_avgs:=public._exam_team_avg_pop(pr.id,3);
    team6_avgs:=public._exam_team_avg_pop(pr.id,6);
  END IF;

  RETURN jsonb_build_object(
    'paper',jsonb_build_object('id',pr.id,'title',pr.title,'status',pr.status,'mode',pr.mode,'totalPoints',pr.total_points),
    'scope',scope_label,'prVisible',pr_visible,'resultsPublished',results_pub,
    'overall',(SELECT jsonb_build_object('attempts',COUNT(*),
      'submitted',COUNT(*)FILTER(WHERE a.status IN('submitted','graded')),
      'graded',COUNT(*)FILTER(WHERE a.status='graded'),'inProgress',COUNT(*)FILTER(WHERE a.status='in_progress'),
      'avgAuto',ROUND(AVG(a.auto_score)FILTER(WHERE a.status IN('submitted','graded'))::numeric,1),
      'avgManual',ROUND(AVG(a.manual_score)FILTER(WHERE a.status='graded')::numeric,1),
      'avgTotal',ROUND(AVG(a.total_score)FILTER(WHERE a.status='graded')::numeric,1),
      'maxTotal',MAX(a.total_score)FILTER(WHERE a.status='graded'),'minTotal',MIN(a.total_score)FILTER(WHERE a.status='graded'))
      FROM public.exam_attempts a WHERE a.id=ANY(scoped)),
    'byRegion',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',x.name,'count',x.count,'graded',x.graded,
      'avgTotal',x."avgTotal",'pr',CASE WHEN pr_visible THEN public._exam_pr(x."avgTotal",region_avgs)ELSE NULL END)
      ORDER BY x.sort_order NULLS LAST,x.name)FROM(
      SELECT COALESCE(NULLIF(p.great_region,''),'（未分區）')name,gr.sort_order,COUNT(*)count,
        COUNT(*)FILTER(WHERE a.status='graded')graded,ROUND(AVG(a.total_score)FILTER(WHERE a.status='graded')::numeric,1)"avgTotal"
      FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      LEFT JOIN public.great_regions gr ON gr.name=p.great_region
      WHERE a.id=ANY(scoped)AND a.status IN('submitted','graded')GROUP BY 1,gr.sort_order)x),'[]'::jsonb),
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
      WHERE a.id=ANY(scoped)AND a.status IN('submitted','graded')GROUP BY 1,2,gr.sort_order,pz.sort_order)x),'[]'::jsonb),
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
      WHERE a.id=ANY(scoped)AND a.status IN('submitted','graded')GROUP BY 1,2,pz.sort_order)x),'[]'::jsonb),
    'byTeamSize',COALESCE((SELECT jsonb_agg(jsonb_build_object('label',b.label,'count',b.cnt,
      'graded',b.graded,'avgTotal',b.avg_total)ORDER BY b.sort)FROM(
      SELECT bl.label,bl.sort,COUNT(*)FILTER(WHERE bl.member)cnt,
        COUNT(*)FILTER(WHERE bl.member AND a.status='graded')graded,
        ROUND(AVG(a.total_score)FILTER(WHERE bl.member AND a.status='graded')::numeric,1)avg_total
      FROM public.exam_attempts a CROSS JOIN LATERAL(VALUES
        ('3 人團隊'::text,1,EXISTS(SELECT 1 FROM public.reading_team_members m WHERE m.user_id=a.user_id AND m.division=3)),
        ('6 人團隊'::text,2,EXISTS(SELECT 1 FROM public.reading_team_members m WHERE m.user_id=a.user_id AND m.division=6)),
        ('未組隊'::text,3,NOT EXISTS(SELECT 1 FROM public.reading_team_members m WHERE m.user_id=a.user_id AND m.division IN(3,6)))
      )bl(label,sort,member)WHERE a.id=ANY(scoped)AND a.status IN('submitted','graded')
      GROUP BY bl.label,bl.sort)b WHERE b.cnt>0),'[]'::jsonb),
    'teamRanking',COALESCE((
      WITH RECURSIVE team_root(id,anchor)AS(
        SELECT rt.id,rt.id FROM public.reading_teams rt
        WHERE rt.carried_from_team_id IS NULL
           OR NOT EXISTS(SELECT 1 FROM public.reading_teams p WHERE p.id=rt.carried_from_team_id)
        UNION ALL
        SELECT rt.id,r.anchor FROM public.reading_teams rt
        JOIN team_root r ON rt.carried_from_team_id=r.id
      ),
      latest_team AS(
        SELECT DISTINCT ON(tr.anchor,rt.division)
          rt.id team_id,rt.name,rt.division,rt.global_plan_id,rt.captain_id
        FROM public.reading_teams rt
        JOIN team_root tr ON tr.id=rt.id
        WHERE rt.division IN(3,6)
        ORDER BY tr.anchor,rt.division,rt.created_at DESC,rt.id DESC
      )
      SELECT jsonb_agg(jsonb_build_object('teamId',t.team_id,'name',t.name,
        'division',t.division,'rank',t.rnk,'completed',t.completed,'submitted',t.submitted_cnt,
        'greatRegion',t.captain_region,'pastoralZone',t.captain_zone,
        'teamTotal',t.team_total,'avgTotal',t.avg_total,
        'pr',CASE WHEN pr_visible AND t.submitted_cnt>0
          THEN public._exam_pr(t.avg_total,CASE t.division WHEN 3 THEN team3_avgs WHEN 6 THEN team6_avgs END)
          ELSE NULL END)
        ORDER BY t.division,t.rnk,t.name)
      FROM(
        SELECT ranked.team_id,ranked.name,ranked.division,ranked.completed,ranked.submitted_cnt,
          ranked.team_total,ranked.avg_total,ranked.captain_region,ranked.captain_zone,
          RANK()OVER(PARTITION BY ranked.division ORDER BY ranked.avg_total DESC)rnk
        FROM(
          SELECT lt.team_id,lt.name,lt.division,cap.great_region captain_region,cap.pastoral_zone captain_zone,
            COUNT(a.id)FILTER(WHERE a.status='graded')completed,
            COUNT(a.id)FILTER(WHERE a.status IN('submitted','graded'))submitted_cnt,
            COALESCE(SUM(a.total_score)FILTER(WHERE a.status='graded'),0)team_total,
            ROUND(COALESCE(SUM(a.total_score)FILTER(WHERE a.status='graded'),0)::numeric/lt.division,1)avg_total
          FROM latest_team lt
          LEFT JOIN public.profiles cap ON cap.id=lt.captain_id
          JOIN public.reading_team_members m ON m.team_id=lt.team_id
          LEFT JOIN public.exam_attempts a
            ON a.user_id=m.user_id AND a.paper_id=pr.id AND a.attempt_kind='official' AND a.id=ANY(scoped)
          GROUP BY lt.team_id,lt.name,lt.division,lt.global_plan_id,cap.great_region,cap.pastoral_zone
          HAVING(scope_all AND lt.global_plan_id=ANY(v_plans))
              OR COUNT(a.id)FILTER(WHERE a.status IN('submitted','graded'))>0
        )ranked
      )t
    ),'[]'::jsonb),
    'byQuestion',COALESCE((SELECT jsonb_agg(x ORDER BY x."sectionRank",x.position)FROM(
      SELECT q.section,q.position,public._exam_section_rank(q.section)"sectionRank",COUNT(ea.*)answered,
        COUNT(ea.*)FILTER(WHERE ea.auto_correct)correct,
        ROUND((COUNT(ea.*)FILTER(WHERE ea.auto_correct))::numeric/NULLIF(COUNT(ea.*),0),3)"correctRate"
      FROM public.exam_questions q JOIN public.exam_answers ea ON ea.question_id=q.id
      JOIN public.exam_attempts a ON a.id=ea.attempt_id AND a.status IN('submitted','graded')AND a.id=ANY(scoped)
      WHERE q.paper_id=pr.id AND q.section<>'shortanswer' GROUP BY q.id,q.section,q.position)x),'[]'::jsonb),
    'roster',COALESCE((SELECT jsonb_agg(jsonb_build_object('userId',a.user_id,'name',p.name,
      'greatRegion',p.great_region,'pastoralZone',p.pastoral_zone,'smallGroup',p.small_group,
      'teamLabel',(SELECT CASE WHEN bool_or(m.division=3)AND bool_or(m.division=6)THEN'3+6 人團隊'
        WHEN bool_or(m.division=3)THEN'3 人團隊' WHEN bool_or(m.division=6)THEN'6 人團隊' ELSE'個人'END
        FROM public.reading_team_members m WHERE m.user_id=a.user_id),
      'status',a.status,'autoScore',a.auto_score,'manualScore',a.manual_score,'totalScore',a.total_score,
      'submittedAt',a.submitted_at,
      'prChurch',CASE WHEN pr_visible AND a.status='graded'
        THEN public._exam_pr(a.total_score,church_scores)ELSE NULL END,
      'prZone',CASE WHEN pr_visible AND a.status='graded' THEN public._exam_pr(a.total_score,
        ARRAY(SELECT a2.total_score FROM public.exam_attempts a2 JOIN public.profiles p2 ON p2.id=a2.user_id
          WHERE a2.paper_id=pr.id AND a2.attempt_kind='official' AND a2.status='graded' AND a2.total_score IS NOT NULL
            AND COALESCE(NULLIF(p2.pastoral_zone,''),'（未分牧區）')=COALESCE(NULLIF(p.pastoral_zone,''),'（未分牧區）')))
        ELSE NULL END,
      'prGroup',CASE WHEN pr_visible AND a.status='graded' THEN public._exam_pr(a.total_score,
        ARRAY(SELECT a2.total_score FROM public.exam_attempts a2 JOIN public.profiles p2 ON p2.id=a2.user_id
          WHERE a2.paper_id=pr.id AND a2.attempt_kind='official' AND a2.status='graded' AND a2.total_score IS NOT NULL
            AND COALESCE(NULLIF(p2.small_group,''),'（未分組）')=COALESCE(NULLIF(p.small_group,''),'（未分組）')))
        ELSE NULL END)
      ORDER BY a.total_score DESC NULLS LAST,a.submitted_at ASC)
      FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      WHERE a.id=ANY(scoped)AND a.status IN('submitted','graded')),'[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.exam_get_stats(UUID,UUID) TO authenticated;

COMMENT ON FUNCTION public.exam_get_stats(UUID,UUID)
IS '正式測驗統計；teamRanking 即時查 reading_team_members 推隊籍 + carried_from_team_id 收斂 carry 鏈去重，隊伍平均固定除以 division，並帶隊長的大區/牧區；roster/byRegion/byZone/byGroup/teamRanking 帶 PR 值（全教會同層級為母體、夾 1–99、母體<5 為 NULL）。PR 可見性：admin/pastor 隨時可見，範圍主管須成績公布後（prVisible 旗標）。';
