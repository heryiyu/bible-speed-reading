-- ============================================================================
-- 0188_daily_quiz_leaderboard_reveal_and_pr.sql
-- ----------------------------------------------------------------------------
-- 今日小測驗升級第三階段：PR 公布 + 會友端「我的測驗」查詢。
--
--   public.daily_quiz_reveal_leaderboard(plan, quiz_date)
--     admin/pastor 專用：把某一天（該計畫下所有版本 A/B/C）的
--     leaderboard_published_at 一次設為 NOW()。前三名你們會自行另外公告，
--     APP 裡從頭到尾不會出現任何名單/排名——這支只是解鎖 PR 值可以被查詢，
--     不做「聚合前三名」這種事。
--
--   public.daily_quiz_get_my_results(plan, from, to)
--     會友端：只回傳呼叫者自己的分數；PR 值（全教會/牧區/小組/讀經隊）
--     只有在 leaderboard_published_at 已設定時才計算並回傳，公布前一律
--     NULL。PR 公式直接沿用大測驗的 public._exam_pr，不重寫。
--
--   讀經隊 PR 刻意不比照 0169 的 carry 鏈收斂（reading_teams.carried_from_
--   team_id 遞迴 CTE）——reading_team_members 對 (global_plan_id, user_id)
--   本來就是唯一，直接反映「現在」的隊籍即可；小測驗是計畫進行中的每週
--   活動，不像大測驗要跨梯次比較，這裡刻意簡化，先不做那層複雜度。
--
--   GRANT/REVOKE 已經吃過一次虧（見 0187 的教訓）：這裡全部明確列出
--   `FROM PUBLIC, anon`，不會再只寫 `FROM PUBLIC` 就以為夠了。
-- ============================================================================

-- ── 1. 公布動作 ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.daily_quiz_reveal_leaderboard(
  p_global_plan_id UUID,
  p_quiz_date DATE,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $daily_quiz_reveal_leaderboard$
DECLARE
  actor_id UUID;
  actor_role TEXT;
  updated_count INTEGER;
BEGIN
  actor_id := public.resolve_quiz_actor(p_actor_id);
  SELECT public.role_code(role_id) INTO actor_role FROM public.profiles WHERE id = actor_id;
  IF actor_role NOT IN ('admin', 'pastor') THEN
    RAISE EXCEPTION 'quiz_reveal_permission_required';
  END IF;

  UPDATE public.daily_quizzes
  SET leaderboard_published_at = NOW()
  WHERE global_plan_id = p_global_plan_id AND quiz_date = p_quiz_date;
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  IF updated_count = 0 THEN RAISE EXCEPTION 'quiz_not_found_for_date'; END IF;

  RETURN jsonb_build_object('globalPlanId', p_global_plan_id, 'quizDate', p_quiz_date, 'updatedRows', updated_count);
END;
$daily_quiz_reveal_leaderboard$;

REVOKE ALL ON FUNCTION public.daily_quiz_reveal_leaderboard(UUID, DATE, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.daily_quiz_reveal_leaderboard(UUID, DATE, UUID) TO authenticated;

-- ── 2. PR 母體小工具（私有，只給其他 SECURITY DEFINER 函式內部呼叫）───────

-- 某一天、某個範圍（不給 zone/group 就是全教會）的所有已送出分數。
CREATE OR REPLACE FUNCTION public._daily_quiz_score_pop(
  p_global_plan_id UUID,
  p_quiz_date DATE,
  p_pastoral_zone_id UUID DEFAULT NULL,
  p_small_group_id UUID DEFAULT NULL
)
RETURNS NUMERIC[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
  SELECT COALESCE(array_agg(qa.score::numeric), '{}')
  FROM public.quiz_attempts qa
  JOIN public.quiz_publications qp ON qp.id = qa.publication_id
  JOIN public.daily_quizzes dq ON dq.id = qp.quiz_id
  LEFT JOIN public.small_groups sg ON sg.id = qp.small_group_id
  WHERE dq.global_plan_id = p_global_plan_id
    AND dq.quiz_date = p_quiz_date
    AND qa.status = 'submitted'
    AND (p_small_group_id IS NULL OR qp.small_group_id = p_small_group_id)
    AND (p_pastoral_zone_id IS NULL OR sg.pastoral_zone_id = p_pastoral_zone_id)
$$;

REVOKE ALL ON FUNCTION public._daily_quiz_score_pop(UUID, DATE, UUID, UUID) FROM PUBLIC, anon, authenticated;

-- 某一天、某個 division（3 或 6 人隊）的每支隊伍平均分（隊內成員平均，
-- 只納入當天有送出成績的隊伍）。
CREATE OR REPLACE FUNCTION public._daily_quiz_team_avg_pop(
  p_global_plan_id UUID,
  p_quiz_date DATE,
  p_division INTEGER
)
RETURNS NUMERIC[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
  SELECT COALESCE(array_agg(x.avg_score), '{}')
  FROM (
    SELECT ROUND(AVG(qa.score)::numeric, 1) AS avg_score
    FROM public.reading_team_members rtm
    JOIN public.reading_teams rt ON rt.id = rtm.team_id
    JOIN public.quiz_attempts qa ON qa.user_id = rtm.user_id
    JOIN public.quiz_publications qp ON qp.id = qa.publication_id
    JOIN public.daily_quizzes dq ON dq.id = qp.quiz_id
    WHERE rt.division = p_division
      AND rtm.global_plan_id = p_global_plan_id
      AND dq.global_plan_id = p_global_plan_id
      AND dq.quiz_date = p_quiz_date
      AND qa.status = 'submitted'
    GROUP BY rtm.team_id
  ) x
$$;

REVOKE ALL ON FUNCTION public._daily_quiz_team_avg_pop(UUID, DATE, INTEGER) FROM PUBLIC, anon, authenticated;

-- ── 3. 會友端：我的小測驗成績 + PR（公布後才有）──────────────────────────

CREATE OR REPLACE FUNCTION public.daily_quiz_get_my_results(
  p_global_plan_id UUID,
  p_from_date DATE,
  p_to_date DATE,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $daily_quiz_get_my_results$
DECLARE
  actor_id UUID;
BEGIN
  actor_id := public.resolve_quiz_actor(p_actor_id);
  IF p_from_date IS NULL OR p_to_date IS NULL OR p_from_date > p_to_date THEN
    RAISE EXCEPTION 'quiz_stats_date_range_required';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'quizDate', ma.quiz_date,
      'score', ma.score,
      'total', ma.total,
      'prPublished', ma.pr_published,
      'prChurch', CASE WHEN ma.pr_published
        THEN public._exam_pr(ma.score::numeric, public._daily_quiz_score_pop(p_global_plan_id, ma.quiz_date))
        ELSE NULL END,
      'prZone', CASE WHEN ma.pr_published AND ma.pastoral_zone_id IS NOT NULL
        THEN public._exam_pr(ma.score::numeric, public._daily_quiz_score_pop(p_global_plan_id, ma.quiz_date, ma.pastoral_zone_id))
        ELSE NULL END,
      'prGroup', CASE WHEN ma.pr_published AND ma.small_group_id IS NOT NULL
        THEN public._exam_pr(ma.score::numeric, public._daily_quiz_score_pop(p_global_plan_id, ma.quiz_date, NULL, ma.small_group_id))
        ELSE NULL END,
      'teams', CASE WHEN ma.pr_published THEN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'division', t.division,
          'avg', t.avg_score,
          'pr', public._exam_pr(t.avg_score, public._daily_quiz_team_avg_pop(p_global_plan_id, ma.quiz_date, t.division))
        ))
        FROM (
          SELECT rt.division, ROUND(AVG(qa2.score)::numeric, 1) AS avg_score
          FROM public.reading_team_members my_team
          JOIN public.reading_teams rt ON rt.id = my_team.team_id
          JOIN public.reading_team_members peer ON peer.team_id = my_team.team_id
          JOIN public.quiz_attempts qa2 ON qa2.user_id = peer.user_id
          JOIN public.quiz_publications qp2 ON qp2.id = qa2.publication_id
          JOIN public.daily_quizzes dq2 ON dq2.id = qp2.quiz_id
          WHERE my_team.user_id = actor_id
            AND my_team.global_plan_id = p_global_plan_id
            AND dq2.global_plan_id = p_global_plan_id
            AND dq2.quiz_date = ma.quiz_date
            AND qa2.status = 'submitted'
          GROUP BY rt.division, my_team.team_id
        ) t
      ), '[]'::jsonb) ELSE NULL END
    ) ORDER BY ma.quiz_date DESC)
    FROM (
      SELECT qa.score, qa.total, dq.quiz_date,
        dq.leaderboard_published_at IS NOT NULL AS pr_published,
        qp.small_group_id, sg.pastoral_zone_id
      FROM public.quiz_attempts qa
      JOIN public.quiz_publications qp ON qp.id = qa.publication_id
      JOIN public.daily_quizzes dq ON dq.id = qp.quiz_id
      LEFT JOIN public.small_groups sg ON sg.id = qp.small_group_id
      WHERE qa.user_id = actor_id
        AND dq.global_plan_id = p_global_plan_id
        AND dq.quiz_date BETWEEN p_from_date AND p_to_date
        AND qa.status = 'submitted'
    ) ma
  ), '[]'::jsonb);
END;
$daily_quiz_get_my_results$;

REVOKE ALL ON FUNCTION public.daily_quiz_get_my_results(UUID, DATE, DATE, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.daily_quiz_get_my_results(UUID, DATE, DATE, UUID) TO authenticated;

COMMENT ON FUNCTION public.daily_quiz_get_my_results(UUID, DATE, DATE, UUID) IS
  '會友端「我的測驗」小測驗分頁用：只回傳呼叫者自己的分數；PR（全教會/牧區/小組/讀經隊）只有 leaderboard_published_at 已設定才計算，公布前一律 NULL。不含任何他人分數或名次。';

-- ── 4. daily_quiz_get_stats（0186）補一個欄位：後台要知道某天 PR 公布了
--    沒有，才能顯示「公布 PR」按鈕該不該出現。0186 已經部署過，不能改那個
--    檔案本身，用 CREATE OR REPLACE 疊上去——跟這批新增函式無關的部分
--    （roster/byQuestion）原封不動照抄，只在 trend 那塊加一個欄位。

CREATE OR REPLACE FUNCTION public.daily_quiz_get_stats(
  p_global_plan_id UUID,
  p_from_date DATE,
  p_to_date DATE,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $daily_quiz_get_stats$
DECLARE
  actor_id UUID;
  actor_role TEXT;
  scoped_publication_ids UUID[];
BEGIN
  actor_id := public.resolve_quiz_actor(p_actor_id);
  SELECT public.role_code(role_id) INTO actor_role FROM public.profiles WHERE id = actor_id;
  IF actor_role NOT IN ('admin', 'pastor', 'great_zone_leader', 'zone_leader', 'group_leader') THEN
    RAISE EXCEPTION 'quiz_stats_permission_required';
  END IF;
  IF p_from_date IS NULL OR p_to_date IS NULL OR p_from_date > p_to_date THEN
    RAISE EXCEPTION 'quiz_stats_date_range_required';
  END IF;

  SELECT COALESCE(array_agg(qp.id), '{}') INTO scoped_publication_ids
  FROM public.quiz_publications qp
  JOIN public.daily_quizzes dq ON dq.id = qp.quiz_id
  WHERE dq.global_plan_id = p_global_plan_id
    AND qp.quiz_date BETWEEN p_from_date AND p_to_date
    AND public.can_manage_quiz_group(actor_id, qp.small_group_id);

  RETURN jsonb_build_object(
    'trend', COALESCE((
      WITH per_publication AS (
        SELECT
          dq.quiz_date,
          qp.id AS publication_id,
          dq.leaderboard_published_at IS NOT NULL AS leaderboard_published,
          (
            SELECT COUNT(DISTINCT p.id)
            FROM public.profiles p
            JOIN public.reading_plans rp ON rp.user_id = p.id AND rp.global_plan_id = p_global_plan_id
            WHERE p.small_group_id = qp.small_group_id AND p.is_active = TRUE
          ) AS eligible
        FROM public.quiz_publications qp
        JOIN public.daily_quizzes dq ON dq.id = qp.quiz_id
        WHERE qp.id = ANY(scoped_publication_ids)
      ),
      eligible_by_date AS (
        SELECT quiz_date, SUM(eligible) AS eligible_sum, bool_or(leaderboard_published) AS leaderboard_published
        FROM per_publication
        GROUP BY quiz_date
      ),
      attempts_by_date AS (
        SELECT
          pp.quiz_date,
          COUNT(qa.id) FILTER (WHERE qa.status = 'submitted') AS submitted_count,
          ROUND(AVG(qa.score) FILTER (WHERE qa.status = 'submitted')::numeric, 1) AS avg_score,
          ROUND(AVG(EXTRACT(EPOCH FROM (qa.completed_at - qa.started_at)))
            FILTER (WHERE qa.status = 'submitted' AND qa.completed_at > qa.started_at)::numeric, 0) AS avg_time_seconds
        FROM per_publication pp
        LEFT JOIN public.quiz_attempts qa ON qa.publication_id = pp.publication_id
        GROUP BY pp.quiz_date
      )
      SELECT jsonb_agg(jsonb_build_object(
        'quizDate', e.quiz_date,
        'eligible', e.eligible_sum,
        'submitted', COALESCE(a.submitted_count, 0),
        'participationRate', CASE WHEN e.eligible_sum > 0
          THEN ROUND(COALESCE(a.submitted_count, 0)::numeric / e.eligible_sum * 100, 1) ELSE NULL END,
        'avgScore', a.avg_score,
        'avgTimeSeconds', a.avg_time_seconds,
        'leaderboardPublished', e.leaderboard_published
      ) ORDER BY e.quiz_date)
      FROM eligible_by_date e
      LEFT JOIN attempts_by_date a ON a.quiz_date = e.quiz_date
    ), '[]'::jsonb),

    'roster', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'attemptId', qa.id,
        'userId', pr.id,
        'name', pr.name,
        'smallGroup', sg.name,
        'pastoralZone', pz.name,
        'greatRegion', gr.name,
        'quizDate', dq.quiz_date,
        'score', qa.score,
        'total', qa.total,
        'timeSeconds', CASE WHEN qa.completed_at > qa.started_at
          THEN ROUND(EXTRACT(EPOCH FROM (qa.completed_at - qa.started_at))::numeric, 0) ELSE NULL END,
        'completedAt', qa.completed_at
      ) ORDER BY dq.quiz_date DESC, pr.name)
      FROM public.quiz_attempts qa
      JOIN public.quiz_publications qp ON qp.id = qa.publication_id
      JOIN public.daily_quizzes dq ON dq.id = qp.quiz_id
      JOIN public.profiles pr ON pr.id = qa.user_id
      LEFT JOIN public.small_groups sg ON sg.id = qp.small_group_id
      LEFT JOIN public.pastoral_zones pz ON pz.id = sg.pastoral_zone_id
      LEFT JOIN public.great_regions gr ON gr.id = pz.great_region_id
      WHERE qp.id = ANY(scoped_publication_ids) AND qa.status = 'submitted'
    ), '[]'::jsonb),

    'byQuestion', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'quizDate', x.quiz_date,
        'questionId', x.question_id,
        'answered', x.answered,
        'correct', x.correct_count,
        'correctRate', CASE WHEN x.answered > 0 THEN ROUND(x.correct_count::numeric / x.answered * 100, 1) ELSE NULL END,
        'avgTimeSeconds', x.avg_time_seconds
      ) ORDER BY x.quiz_date, x.question_id)
      FROM (
        SELECT
          dq.quiz_date,
          ans->>'questionId' AS question_id,
          COUNT(*) AS answered,
          COUNT(*) FILTER (WHERE (ans->>'correct')::boolean IS TRUE) AS correct_count,
          ROUND(AVG((ans->>'timeSpentSeconds')::numeric)
            FILTER (WHERE ans->>'timeSpentSeconds' IS NOT NULL), 1) AS avg_time_seconds
        FROM public.quiz_attempts qa
        JOIN public.quiz_publications qp ON qp.id = qa.publication_id
        JOIN public.daily_quizzes dq ON dq.id = qp.quiz_id
        CROSS JOIN LATERAL jsonb_array_elements(qa.answers) ans
        WHERE qp.id = ANY(scoped_publication_ids)
          AND qa.status = 'submitted'
          AND jsonb_typeof(ans) = 'object'
          AND ans ? 'questionId'
        GROUP BY dq.quiz_date, ans->>'questionId'
      ) x
    ), '[]'::jsonb)
  );
END;
$daily_quiz_get_stats$;

REVOKE ALL ON FUNCTION public.daily_quiz_get_stats(UUID, DATE, DATE, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.daily_quiz_get_stats(UUID, DATE, DATE, UUID) TO authenticated;
