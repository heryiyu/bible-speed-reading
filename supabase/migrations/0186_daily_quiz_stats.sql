-- ============================================================================
-- 0186_daily_quiz_stats.sql
-- ----------------------------------------------------------------------------
-- 今日小測驗升級第二階段：後台結果統計（唯讀，不動任何既有寫入路徑）。
--
--   public.daily_quiz_get_stats(p_global_plan_id, p_from_date, p_to_date, p_actor_id)
--
--   給 admin / pastor / 大區主管 / 牧區主管 / 小組長查後台結果，可見範圍沿用
--   既有的 can_manage_quiz_group(actor_id, small_group_id) 判斷（跟
--   publish_daily_quiz 同一套權限模型，不另外發明）。回傳三塊：
--     trend      —— 逐日參與率／平均分／平均作答時間（給趨勢折線圖）
--     roster     —— 逐人逐次作答明細（給搜尋/匯出/時間-正確率散點圖）
--     byQuestion —— 逐日逐題答對率／平均作答時間（給「這題大家是不是都很難」）
--
--   參與率分母＝該次測驗發布對象的小組中，「已加入這個讀經計畫」
--   （reading_plans 有一筆對應 global_plan_id）且在籍的會友數——不是小組
--   在籍人數，也不是整體計畫參與率，是「這場考試理論上有幾個人可以考」。
--
--   時間統計只採計 completed_at > started_at 的資料：0185 對舊版
--   submit_daily_quiz（一次送出）留下來的既有紀錄，把 started_at 回填成等於
--   completed_at（沒有更細的時間資料可用），如果照樣拿去平均會把平均時間
--   洗成偏低的假象——這裡直接排除掉，只統計真的量得到作答時間的紀錄。
--
-- 不會自動部署：需要手動 supabase db push 或在 SQL editor 執行；純新增函式，
-- 不改動任何既有資料表/函式。
-- ============================================================================

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
        SELECT quiz_date, SUM(eligible) AS eligible_sum
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
        'avgTimeSeconds', a.avg_time_seconds
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

REVOKE ALL ON FUNCTION public.daily_quiz_get_stats(UUID, DATE, DATE, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.daily_quiz_get_stats(UUID, DATE, DATE, UUID) TO authenticated;

COMMENT ON FUNCTION public.daily_quiz_get_stats(UUID, DATE, DATE, UUID) IS
  '後台小測驗結果：逐日參與率/平均分/平均時間趨勢、逐人作答明細（搜尋/匯出/時間-正確率散點圖用）、逐題答對率/平均時間。可見範圍沿用 can_manage_quiz_group，跟 publish_daily_quiz 同一套權限模型。';
