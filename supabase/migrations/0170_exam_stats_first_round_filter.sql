-- 0170_exam_stats_first_round_filter.sql
--
-- 大測驗統計：加「該書卷是否讀過至少一遍」的判定，並可切換「只統計已讀完的人」。
--
--  規則（使用者 2026-09-09）：例如「聖經速讀測驗_創世紀」對應速讀第一階段的創世記，
--  要那個人讀過創世記 ≥ 1 遍，測驗成績才算數。
--
--  · roster[] 每列多一個 firstRoundDone（true/false/null）——null = 沒帶書卷、不判定。
--  · p_require_first_round = true 時：整體 / 各大區 / 各牧區 / 各小組 / 組隊規模 /
--    團隊排行 / PR 母體 一律只算「讀過該書卷一遍」的人；roster 仍列出所有人（含被
--    排除者，標記出來讓管理員看得到）。overall.notReadCount = 被排除的人數。
--  · p_reading_book 為 NULL/空 → 一律不過濾（安全預設）；toggle 只影響聚合，不影響 roster。
--
--  「讀過一遍」判定（_user_read_book_once）：該人有任一 reading_plans，其 target_books
--  含該書卷，且 current_round >= 2（＝第 1 遍必然 100% 系統才讓升），或第 1 遍打卡的
--  相異章數 >= 該書卷章數（讀完 100% 但沒按「進入下一遍」的人也算）。
--
-- 部署：SQL editor 執行。含一次 DROP + CREATE（簽章從 2 參數變 5 參數）。純函式，
-- 不用重部署 Edge Function（nlc-data 對 EXAM_RPC_FUNCTIONS 是把 body.args 原樣帶入 + 注入 p_actor_id）。

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

DROP FUNCTION IF EXISTS public.exam_get_stats(UUID, UUID);

CREATE FUNCTION public.exam_get_stats(
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
  scope_all BOOLEAN;v_plans UUID[];v_book TEXT;v_filter BOOLEAN;
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

  SELECT COALESCE(array_agg(DISTINCT rtm.global_plan_id),'{}')INTO v_plans
  FROM public.reading_team_members rtm
  WHERE rtm.user_id IN(SELECT a.user_id FROM public.exam_attempts a WHERE a.id=ANY(scoped_stats));

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
    'paper',jsonb_build_object('id',pr.id,'title',pr.title,'status',pr.status,'mode',pr.mode,'totalPoints',pr.total_points),
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
    'byTeamSize',COALESCE((SELECT jsonb_agg(jsonb_build_object('label',b.label,'count',b.cnt,
      'graded',b.graded,'avgTotal',b.avg_total)ORDER BY b.sort)FROM(
      SELECT bl.label,bl.sort,COUNT(*)FILTER(WHERE bl.member)cnt,
        COUNT(*)FILTER(WHERE bl.member AND a.status='graded')graded,
        ROUND(AVG(a.total_score)FILTER(WHERE bl.member AND a.status='graded')::numeric,1)avg_total
      FROM public.exam_attempts a CROSS JOIN LATERAL(VALUES
        ('3 人團隊'::text,1,EXISTS(SELECT 1 FROM public.reading_team_members m WHERE m.user_id=a.user_id AND m.division=3)),
        ('6 人團隊'::text,2,EXISTS(SELECT 1 FROM public.reading_team_members m WHERE m.user_id=a.user_id AND m.division=6)),
        ('未組隊'::text,3,NOT EXISTS(SELECT 1 FROM public.reading_team_members m WHERE m.user_id=a.user_id AND m.division IN(3,6)))
      )bl(label,sort,member)WHERE a.id=ANY(scoped_stats)AND a.status IN('submitted','graded')
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
            ON a.user_id=m.user_id AND a.paper_id=pr.id AND a.attempt_kind='official' AND a.id=ANY(scoped_stats)
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
IS '正式測驗統計。p_reading_book/p_book_chapters：對應書卷（roster[].firstRoundDone 判定「讀過該書卷一遍」＝有 target_books 含該卷且 current_round>=2 或第1遍打卡滿章數的 reading_plans）。p_require_first_round=true → 整體/各大區/牧區/小組/組隊/團隊排行/PR母體只算讀過的人（roster 仍列全部，overall.notReadCount=被排除數）。teamRanking 沿用 0167/0168，PR 沿用 0169。';
