-- 0171_exam_answer_explanation.sql
--
-- 簡答題「參考答案」「評分要點」是給批改用的內部資料，不該原封不動送到會友端
-- （之前 exam_get_my_result 直接把整個 q.payload 回傳，公布成績後會友就看得到）。
--
-- 改動：
--  1. exam_papers 加 show_answer_explanation（預設關）：管理員決定要不要讓會友
--     看到「答案詳解」，跟 auto_score_enabled 一樣是隨時可切換的開關，不受
--     results_published_at 鎖定（詳解只是補充閱讀，不影響成績公平性）。
--  2. 六種題型的 payload 都可以填 answerExplanation（管理員在題目編輯處填寫）；
--     預設空白，一般題目不用填——只有有爭議或需要補充說明的題目才個別填寫。
--     簡答題另外分開有 referenceAnswer／rubric，是批改用的內部資料，跟
--     answerExplanation（寫給會友看）是兩回事。
--  3. exam_get_my_result 的 answers[].payload 一律用 _exam_member_answer_payload()
--     過濾：簡答題永遠拿掉 referenceAnswer／rubric；所有題型的 answerExplanation
--     一律拿掉，只有開關開著且該題有填內容時才附回去。批改用的
--     exam_get_grading_queue / exam_get_grading_sheet 等不受影響，繼續看得到
--     完整 referenceAnswer／rubric。
--  4. _exam_public_payload（作答期間／成績公布前看到的 payload）也順手拿掉
--     answerExplanation——不管開關狀態，成績還沒公布就不該先看到詳解。
--  5. exam_set_question_explanation：單獨編輯一題的 answerExplanation，不受
--     paper.status 影響（exam_upsert_question 要求 status='draft' 才能存，但
--     通常是測驗關閉、看到結果之後才想補寫詳解，這支只動這一個欄位所以不用管
--     試卷是否已鎖定）。前端在題目已鎖定時改用這支存檔，而不是整份 upsert。
--
-- 部署：SQL editor 執行即可；需另外重部署 nlc-data Edge Function
-- （把 exam_set_answer_explanation_visible、exam_set_question_explanation
-- 加進 EXAM_RPC_FUNCTIONS / EXAM_ADMIN_RPC_FUNCTIONS 允許清單）。冪等。

ALTER TABLE public.exam_papers
  ADD COLUMN IF NOT EXISTS show_answer_explanation BOOLEAN NOT NULL DEFAULT FALSE;

-- ── 作答期間／未公布前看到的 payload：answerExplanation 一律不該在這裡出現
-- （不管開關有沒有開，成績都還沒公布，本來就不該先看到詳解）。原本非簡答題
-- 直接把整包 payload 原封不動送出，answerExplanation 加進六種題型後會跟著提早外流。
CREATE OR REPLACE FUNCTION public._exam_public_payload(p_section TEXT, p_payload JSONB, p_points NUMERIC)
RETURNS JSONB
LANGUAGE SQL IMMUTABLE SET search_path = pg_catalog, public
AS $$
  SELECT CASE
    WHEN p_section = 'shortanswer' THEN jsonb_build_object(
      'stem', p_payload -> 'stem',
      'maxPoints', COALESCE(p_payload -> 'maxPoints', to_jsonb(p_points))
    )
    ELSE COALESCE(p_payload, '{}'::jsonb) - 'answerExplanation'
  END;
$$;

-- ── 會友端 payload 過濾：拿掉評分用欄位，視開關附上答案詳解（六種題型皆適用）──
CREATE OR REPLACE FUNCTION public._exam_member_answer_payload(
  p_section TEXT, p_payload JSONB, p_show_explanation BOOLEAN
)
RETURNS JSONB
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT
    (CASE
      WHEN p_section = 'shortanswer' THEN COALESCE(p_payload, '{}'::jsonb) - 'referenceAnswer' - 'rubric'
      ELSE COALESCE(p_payload, '{}'::jsonb)
    END) - 'answerExplanation'
    || CASE
         WHEN p_show_explanation AND COALESCE(TRIM(p_payload->>'answerExplanation'), '') <> ''
         THEN jsonb_build_object('answerExplanation', p_payload->'answerExplanation')
         ELSE '{}'::jsonb
       END
$$;

COMMENT ON FUNCTION public._exam_member_answer_payload(TEXT, JSONB, BOOLEAN)
IS '會友端看到的題目 payload：簡答題另外拿掉 referenceAnswer／rubric（批改內部用）；所有題型的 answerExplanation 一律先拿掉，開關開著且該題有填內容時才附回去（管理員寫給會友看的詳解，預設空白、只在需要時個別填寫）。';

-- ── 開關：顯示／隱藏答案詳解（admin/pastor，隨時可切換，不受成績公布鎖定）──
CREATE OR REPLACE FUNCTION public.exam_set_answer_explanation_visible(
  p_paper_id UUID, p_enabled BOOLEAN, p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE actor_id UUID := public.resolve_quiz_actor(p_actor_id); pr public.exam_papers%ROWTYPE;
BEGIN
  IF public._exam_actor_role(actor_id) NOT IN ('admin', 'pastor') THEN RAISE EXCEPTION 'exam_admin_required'; END IF;
  SELECT * INTO pr FROM public.exam_papers WHERE id = p_paper_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'exam_paper_not_found'; END IF;
  UPDATE public.exam_papers SET show_answer_explanation = COALESCE(p_enabled, FALSE) WHERE id = pr.id;
  RETURN jsonb_build_object('paperId', pr.id, 'showAnswerExplanation', COALESCE(p_enabled, FALSE));
END;
$$;

GRANT EXECUTE ON FUNCTION public.exam_set_answer_explanation_visible(UUID, BOOLEAN, UUID) TO authenticated;

-- ── 單題答案詳解：不受試卷鎖定影響，隨時可編輯 ──
-- exam_upsert_question 要求 paper.status='draft'（題幹/選項/正解定稿後就鎖住），
-- 但大部分時候管理員是在測驗關閉、看到作答結果之後才想補寫詳解——這支只動
-- payload 裡的 answerExplanation 一個欄位，不碰題幹/選項/正解，所以不用管
-- 試卷是不是還在草稿狀態。
CREATE OR REPLACE FUNCTION public.exam_set_question_explanation(
  p_question_id UUID, p_explanation TEXT, p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE actor_id UUID := public.resolve_quiz_actor(p_actor_id); q public.exam_questions%ROWTYPE;
BEGIN
  IF public._exam_actor_role(actor_id) NOT IN ('admin', 'pastor') THEN RAISE EXCEPTION 'exam_admin_required'; END IF;
  SELECT * INTO q FROM public.exam_questions WHERE id = p_question_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'exam_question_not_found'; END IF;
  UPDATE public.exam_questions
    SET payload = COALESCE(payload, '{}'::jsonb) || jsonb_build_object('answerExplanation', COALESCE(TRIM(p_explanation), ''))
    WHERE id = q.id
    RETURNING * INTO q;
  RETURN jsonb_build_object('questionId', q.id, 'answerExplanation', q.payload ->> 'answerExplanation');
END;
$$;

GRANT EXECUTE ON FUNCTION public.exam_set_question_explanation(UUID, TEXT, UUID) TO authenticated;

-- ── exam_get_my_result：payload 改走 _exam_member_answer_payload（其餘欄位與 0169 相同）──
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
      'payload',CASE WHEN show_full
        THEN public._exam_member_answer_payload(q.section,q.payload,pr.show_answer_explanation)
        ELSE public._exam_public_payload(q.section,q.payload,q.points)END,
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
IS '回傳本人完整試卷結果；成績公布前只顯示本人作答，公布後才顯示正解與評分。簡答題的 referenceAnswer／rubric 一律不外流；所有題型的 answerExplanation 只有 show_answer_explanation 開著時才附上。PR（prChurch、teams[].pr）只有正式卷+已批改+已公布才計算，管理員預覽不給，且不含任何隊友分數；teams[] 帶隊長的大區/牧區。';
