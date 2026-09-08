-- 0167_exam_team_ranking_from_membership.sql
--
-- 修「3 人隊排行 / 6 人隊排行都顯示 0 隊」。
--
-- 病因：teamRanking 這段從 0121 起就寫成
--     FROM public.reading_teams rt
--     JOIN public.exam_attempts a ON a.reading_team_id = rt.id AND a.id = ANY(scoped)
--   但 exam_attempts.reading_team_id「作答時幾乎沒帶到」——前端只有在使用者
--   這個 session 剛好載入過組隊畫面時，start() 才拿得到 state.myReadingTeam.id
--   傳進 exam_start_attempt(p_reading_team_id)，其餘一律是 NULL。0121 當時就為了
--   同一個原因把 byTeamSize 改成即時查 reading_team_members，卻漏掉 teamRanking。
--   → 這個 JOIN 幾乎接不到任何列 → teamRanking 永遠是 []。
--
-- 修法：teamRanking 也改成即時從 reading_team_members 推隊籍（跟 byTeamSize 同款），
--   完全不靠 exam_attempts.reading_team_id 快照。
--
-- 需求（使用者 2026-09-08）：
--   · 不管隊上幾個人、幾個人去考，隊伍平均一律 = 隊伍總分 ÷ division（3 或 6）；
--     沒作答 / 沒批改的成員按 0 分計（＝總分只加 graded 的，分母固定）。← 本來就這樣，保留。
--   · 隊伍「都要列出來」：系統管理員 / 牧者看得到「有成員參加過本測驗的那些梯次」
--     底下的每一支 3/6 人隊，包含 0 人作答的（顯示 0 分、排最後）。
--   · 範圍主管（大區/牧區/小組長）仍只看得到自己範圍內『真的有人作答』的隊，
--     避免外洩其他範圍的隊名（scoped 陣列已經把 attempt 限制在其管理範圍）。
--
-- 部署：SQL editor 執行即可。純 CREATE OR REPLACE，不動簽章、不用重部署 Edge Function。冪等。

CREATE OR REPLACE FUNCTION public.exam_get_stats(p_paper_id UUID,p_actor_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID:=public.resolve_quiz_actor(p_actor_id);actor public.profiles%ROWTYPE;role_c TEXT;
  pr public.exam_papers%ROWTYPE;mreg TEXT[];mzon TEXT[];mgrp TEXT[];scoped UUID[];scope_label TEXT;
  scope_all BOOLEAN;v_plans UUID[];
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

  -- 「有成員實際作答過本測驗」的梯次（global_plan_id）集合；供系統管理員 / 牧者
  -- 列出這些梯次底下的每一支隊（含 0 人作答的），不至於把歷來所有舊梯次的隊都倒出來。
  SELECT COALESCE(array_agg(DISTINCT rtm.global_plan_id),'{}')INTO v_plans
  FROM public.reading_team_members rtm
  WHERE rtm.user_id IN(SELECT a.user_id FROM public.exam_attempts a WHERE a.id=ANY(scoped));

  RETURN jsonb_build_object(
    'paper',jsonb_build_object('id',pr.id,'title',pr.title,'status',pr.status,'mode',pr.mode,'totalPoints',pr.total_points),
    'scope',scope_label,
    'overall',(SELECT jsonb_build_object('attempts',COUNT(*),
      'submitted',COUNT(*)FILTER(WHERE a.status IN('submitted','graded')),
      'graded',COUNT(*)FILTER(WHERE a.status='graded'),'inProgress',COUNT(*)FILTER(WHERE a.status='in_progress'),
      'avgAuto',ROUND(AVG(a.auto_score)FILTER(WHERE a.status IN('submitted','graded'))::numeric,1),
      'avgManual',ROUND(AVG(a.manual_score)FILTER(WHERE a.status='graded')::numeric,1),
      'avgTotal',ROUND(AVG(a.total_score)FILTER(WHERE a.status='graded')::numeric,1),
      'maxTotal',MAX(a.total_score)FILTER(WHERE a.status='graded'),'minTotal',MIN(a.total_score)FILTER(WHERE a.status='graded'))
      FROM public.exam_attempts a WHERE a.id=ANY(scoped)),
    'byRegion',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',x.name,'count',x.count,'graded',x.graded,'avgTotal',x."avgTotal")
      ORDER BY x.sort_order NULLS LAST,x.name)FROM(
      SELECT COALESCE(NULLIF(p.great_region,''),'（未分區）')name,gr.sort_order,COUNT(*)count,
        COUNT(*)FILTER(WHERE a.status='graded')graded,ROUND(AVG(a.total_score)FILTER(WHERE a.status='graded')::numeric,1)"avgTotal"
      FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      LEFT JOIN public.great_regions gr ON gr.name=p.great_region
      WHERE a.id=ANY(scoped)AND a.status IN('submitted','graded')GROUP BY 1,gr.sort_order)x),'[]'::jsonb),
    'byZone',COALESCE((SELECT jsonb_agg(jsonb_build_object('region',x.region,'name',x.name,'count',x.count,'graded',x.graded,'avgTotal',x."avgTotal")
      ORDER BY x.region_sort NULLS LAST,x.zone_sort NULLS LAST,x.region,x.name)FROM(
      SELECT COALESCE(NULLIF(p.great_region,''),'（未分區）')region,
        COALESCE(NULLIF(p.pastoral_zone,''),'（未分牧區）')name,
        gr.sort_order region_sort,pz.sort_order zone_sort,COUNT(*)count,
        COUNT(*)FILTER(WHERE a.status='graded')graded,ROUND(AVG(a.total_score)FILTER(WHERE a.status='graded')::numeric,1)"avgTotal"
      FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      LEFT JOIN public.great_regions gr ON gr.name=p.great_region
      LEFT JOIN public.pastoral_zones pz ON pz.name=p.pastoral_zone AND pz.great_region_id=gr.id
      WHERE a.id=ANY(scoped)AND a.status IN('submitted','graded')GROUP BY 1,2,gr.sort_order,pz.sort_order)x),'[]'::jsonb),
    'byGroup',COALESCE((SELECT jsonb_agg(jsonb_build_object('zone',x.zone,'name',x.name,'count',x.count,'graded',x.graded,'avgTotal',x."avgTotal")
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
    -- teamRanking：隊籍即時查 reading_team_members（不靠 exam_attempts.reading_team_id）。
    --   team_total = 隊上成員在本測驗 graded 的 total_score 加總（未完成者不加 → 等同 0 分）
    --   avg_total  = team_total ÷ rt.division（固定 3 或 6，跟實際人數無關）
    --   顯示範圍：系統管理員 / 牧者 → v_plans 梯次底下每支隊（含 0 人作答）；
    --            範圍主管 → 只有自己範圍內真的有人作答的隊（submitted_cnt > 0）。
    'teamRanking',COALESCE((SELECT jsonb_agg(jsonb_build_object('teamId',t.team_id,'name',t.name,
      'division',t.division,'rank',t.rnk,'completed',t.completed,'submitted',t.submitted_cnt,
      'teamTotal',t.team_total,'avgTotal',t.avg_total)ORDER BY t.division,t.rnk,t.name)FROM(
      SELECT ranked.team_id,ranked.name,ranked.division,ranked.completed,ranked.submitted_cnt,
        ranked.team_total,ranked.avg_total,
        RANK()OVER(PARTITION BY ranked.division ORDER BY ranked.avg_total DESC)rnk
      FROM(
        SELECT rt.id team_id,rt.name,rt.division,
          COUNT(a.id)FILTER(WHERE a.status='graded')completed,
          COUNT(a.id)FILTER(WHERE a.status IN('submitted','graded'))submitted_cnt,
          COALESCE(SUM(a.total_score)FILTER(WHERE a.status='graded'),0)team_total,
          ROUND(COALESCE(SUM(a.total_score)FILTER(WHERE a.status='graded'),0)::numeric/rt.division,1)avg_total
        FROM public.reading_teams rt
        JOIN public.reading_team_members m ON m.team_id=rt.id
        LEFT JOIN public.exam_attempts a
          ON a.user_id=m.user_id AND a.paper_id=pr.id AND a.attempt_kind='official' AND a.id=ANY(scoped)
        WHERE rt.division IN(3,6)
        GROUP BY rt.id,rt.name,rt.division
        HAVING(scope_all AND rt.global_plan_id=ANY(v_plans))
            OR COUNT(a.id)FILTER(WHERE a.status IN('submitted','graded'))>0
      )ranked
    )t),'[]'::jsonb),
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
      'submittedAt',a.submitted_at)ORDER BY a.total_score DESC NULLS LAST,a.submitted_at ASC)
      FROM public.exam_attempts a JOIN public.profiles p ON p.id=a.user_id
      WHERE a.id=ANY(scoped)AND a.status IN('submitted','graded')),'[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.exam_get_stats(UUID,UUID) TO authenticated;

COMMENT ON FUNCTION public.exam_get_stats(UUID,UUID)
IS '正式測驗統計；teamRanking 即時查 reading_team_members 推隊籍（不靠 exam_attempts.reading_team_id 快照），隊伍平均固定除以 division，未完成成員按 0 分計；系統管理員/牧者列出參與梯次底下每支隊（含 0 人作答），範圍主管只看範圍內有人作答的隊。byRegion/byZone/byGroup 依 great_regions/pastoral_zones.sort_order 顯示。';
