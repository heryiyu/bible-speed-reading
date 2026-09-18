-- ============================================================================
-- 0185_daily_quiz_five_types_and_answer_timing.sql
-- ----------------------------------------------------------------------------
-- 今日小測驗（daily_quizzes / quiz_attempts）升級第一階段：
--   1. 讓自訂題目（"Version C"，publish_daily_quiz 的 p_custom_questions）
--      可以用大測驗同一套「題型一~五」（是非/單選/多選/配對/排序），
--      不再只能單選——validate_daily_quiz_questions 依每題是否帶 `type`
--      欄位分流：沒帶 type 的舊格式走原本一模一樣的驗證規則（AI 產生的
--      A/B 版、既有單選自訂題完全不受影響），帶 type 的新格式走新規則。
--   2. 判分邏輯（public._quiz_answer_is_correct）直接沿用大測驗
--      0096_speed_reading_exam.sql 裡 _exam_answer_is_correct 的公式，並讓
--      _exam_answer_is_correct 改成呼叫這個共用函式，避免兩邊各留一份。
--   3. 新增「逐題送出＋最後結算」兩個 RPC（daily_quiz_submit_answer /
--      daily_quiz_finalize_attempt），取代「整份一次送出」的送出方式——
--      每題各自是一次小寫入，前端之後會透過既有離線佇列
--      （PwaCoordinator/IndexedDbClient，跟 reading-log 同一套）排隊送出，
--      避免像大測驗簡答題那次事故一樣，因為一次送出大 payload 被截斷、
--      本機資料又已經清掉而救不回來。舊的 submit_daily_quiz 保留原樣，
--      前端還沒切過去之前完全不受影響。
--   4. quiz_attempts 加 started_at / status，讓「作答中」跟「已送出」可以
--      分開，score/total 在作答中之前允許是 NULL。
--   5. 修正一個既有的資料完整性小漏洞：quiz_attempts.score 的 CHECK 還停
--      在舊的 `BETWEEN 0 AND 5`，但 0090 已經把 total 放寬到最多 10 題
--      （Version C 自訂題）——理論上 6 分以上的自訂題成績目前寫不進去。
--      這裡一併修正成 `score BETWEEN 0 AND total`。
--   6. 新增通用的 schedule_announcement(...)：任何功能要「發一則排程公告」
--      都呼叫這個，而不是各自寫 INSERT INTO church_announcements——小測驗
--      PR 公布之後會用它，但它本身跟小測驗無關，之後其他功能也能用。
--   7. quiz_questions_for_member(...) 原本寫死只認舊格式（question/options/
--      correctIndex），會友端拿到的 questions 都是先經過這個函式過濾。如果
--      沒有一起改，Version C 的五型自訂題目就算 validate/publish 都過了，
--      會友端 get_daily_quiz_dashboard 撈出來的 payload/answerKey 全部會被
--      這個函式吃掉，題目會空白——這裡也依 `type` 分流，沒帶 type 的舊格式
--      行為完全不變。
--
-- 不會自動部署：跟其他 migration 一樣，需要手動 `supabase db push` 或在
-- SQL editor 執行。本檔全部是新增欄位/新函式，沒有動到任何既有函式的
-- 參數簽章，正式站現有的小測驗發布/作答流程不受影響。
-- ============================================================================

-- ── 1. quiz_attempts 欄位擴充 ────────────────────────────────────────────

ALTER TABLE public.quiz_attempts
  ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'submitted';

ALTER TABLE public.quiz_attempts
  DROP CONSTRAINT IF EXISTS quiz_attempts_status_check;
ALTER TABLE public.quiz_attempts
  ADD CONSTRAINT quiz_attempts_status_check CHECK (status IN ('in_progress', 'submitted'));

-- 既有資料一律視為「當初一次送出即完成」：補上 started_at = completed_at，
-- 讓舊資料在新的時間統計（作答花費時間）查詢下也有一致的欄位可用。
UPDATE public.quiz_attempts SET started_at = completed_at WHERE started_at IS NULL;

ALTER TABLE public.quiz_attempts ALTER COLUMN started_at SET NOT NULL;
ALTER TABLE public.quiz_attempts ALTER COLUMN started_at SET DEFAULT NOW();

-- 作答中的 attempt 還沒有分數/完成時間，兩者都要能是 NULL；
-- 舊的送出流程（submit_daily_quiz）INSERT 沒有列出 completed_at 這欄，
-- 靠的就是欄位原本的 DEFAULT NOW() 隱式帶入——所以這裡只拿掉 NOT NULL，
-- 刻意保留 DEFAULT 不動，舊流程行為不變。新的 daily_quiz_submit_answer
-- 建立「作答中」那一列時，INSERT 會明確把 completed_at 寫成 NULL
-- （明確帶值本來就會覆蓋掉欄位的 DEFAULT，不需要也不該去動 DEFAULT 本身）。
ALTER TABLE public.quiz_attempts ALTER COLUMN score DROP NOT NULL;
ALTER TABLE public.quiz_attempts ALTER COLUMN completed_at DROP NOT NULL;
ALTER TABLE public.quiz_attempts ALTER COLUMN answers SET DEFAULT '[]'::JSONB;

-- score 的合法範圍要跟著 total 走，不是寫死 0~5（0090 已把 total 放寬到 2~10）。
ALTER TABLE public.quiz_attempts DROP CONSTRAINT IF EXISTS quiz_attempts_score_check;
ALTER TABLE public.quiz_attempts
  ADD CONSTRAINT quiz_attempts_score_check CHECK (score IS NULL OR (score >= 0 AND score <= total));

-- ── 2. daily_quizzes 欄位擴充（PR 公布時間閘門，供之後的 Phase 使用）──────

ALTER TABLE public.daily_quizzes
  ADD COLUMN IF NOT EXISTS leaderboard_published_at TIMESTAMPTZ;

COMMENT ON COLUMN public.daily_quizzes.leaderboard_published_at IS
  '一三五出題各自獨立作答，PR 值卻是下週一才一次公布——這個時間點就是 PR 解鎖的閘門，跟審核/發布是完全獨立的兩件事，不要合併。';

-- ── 3. 共用判分函式（型一~五），跟大測驗 _exam_answer_is_correct 同一套公式 ──

CREATE OR REPLACE FUNCTION public._quiz_answer_is_correct(
  p_type      TEXT,
  p_answer_key JSONB,
  p_response   JSONB
)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_answer_key IS NULL OR p_response IS NULL THEN RETURN FALSE; END IF;

  IF p_type IN ('truefalse', 'single', 'matching', 'ordering') THEN
    -- jsonb 物件相等與 key 順序無關；陣列相等看順序（排序題正是要看順序）
    RETURN p_answer_key = p_response;
  ELSIF p_type = 'multiple' THEN
    RETURN (
      SELECT COALESCE(jsonb_agg(e ORDER BY e::text), '[]'::jsonb)
      FROM jsonb_array_elements(p_answer_key) e
    ) = (
      SELECT COALESCE(jsonb_agg(e ORDER BY e::text), '[]'::jsonb)
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_response) = 'array' THEN p_response ELSE '[]'::jsonb END) e
    );
  END IF;
  RETURN FALSE;
END;
$$;

REVOKE ALL ON FUNCTION public._quiz_answer_is_correct(TEXT, JSONB, JSONB) FROM PUBLIC;

COMMENT ON FUNCTION public._quiz_answer_is_correct(TEXT, JSONB, JSONB) IS
  '型一~五（是非/單選/多選/配對/排序）共用判分公式。跟 _exam_answer_is_correct 是同一套邏輯——後者改為呼叫這個函式，不要兩邊各維護一份。';

-- 大測驗原本的判分函式改為呼叫上面的共用版本；輸入輸出行為完全不變
-- （shortanswer 一樣回 NULL，其餘五型的判定邏輯字面上一模一樣搬過來），
-- 純粹是把重複的公式收斂成一份。
CREATE OR REPLACE FUNCTION public._exam_answer_is_correct(
  p_section     TEXT,
  p_answer_key  JSONB,
  p_response    JSONB
)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_section = 'shortanswer' THEN RETURN NULL; END IF;
  RETURN public._quiz_answer_is_correct(p_section, p_answer_key, p_response);
END;
$$;

REVOKE ALL ON FUNCTION public._exam_answer_is_correct(TEXT, JSONB, JSONB) FROM PUBLIC;

-- ── 4. validate_daily_quiz_questions：依每題是否帶 `type` 分流 ────────────
--    沒帶 type 的舊格式＝原本一模一樣的驗證規則（完全不變）；
--    帶 type 的新格式＝依型一~五各自的形狀驗證。

CREATE OR REPLACE FUNCTION public.validate_daily_quiz_questions(
  p_questions JSONB,
  p_min_count INTEGER,
  p_max_count INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $validate_daily_quiz_questions$
DECLARE
  question       JSONB;
  question_type  TEXT;
  payload        JSONB;
  answer_key     JSONB;
  correct_index  INTEGER;
  option_count   INTEGER;
  left_count     INTEGER;
  right_count    INTEGER;
  item_count     INTEGER;
  seen_ids       JSONB := '[]'::JSONB;
BEGIN
  IF jsonb_typeof(p_questions) <> 'array'
    OR jsonb_array_length(p_questions) < p_min_count
    OR jsonb_array_length(p_questions) > p_max_count
  THEN
    RAISE EXCEPTION 'invalid_quiz_question_count';
  END IF;

  FOR question IN SELECT value FROM jsonb_array_elements(p_questions)
  LOOP
    question_type := question->>'type';

    -- 舊格式（AI 產生 / 既有單選自訂題）：規則完全不變。
    IF question_type IS NULL THEN
      IF BTRIM(COALESCE(question->>'question', '')) = ''
        OR BTRIM(COALESCE(question->>'verseRef', '')) = ''
        OR BTRIM(COALESCE(question->>'explanation', '')) = ''
        OR jsonb_typeof(question->'options') <> 'array'
        OR jsonb_array_length(question->'options') <> 4
        OR COALESCE(question->>'correctIndex', '') !~ '^[0-3]$'
      THEN
        RAISE EXCEPTION 'invalid_quiz_question';
      END IF;
      correct_index := (question->>'correctIndex')::INTEGER;
      IF BTRIM(COALESCE(question->'options'->>correct_index, '')) = '' THEN
        RAISE EXCEPTION 'invalid_quiz_question';
      END IF;
      CONTINUE;
    END IF;

    -- 新格式：型一~五。
    IF question_type NOT IN ('truefalse', 'single', 'multiple', 'matching', 'ordering') THEN
      RAISE EXCEPTION 'invalid_quiz_question_type';
    END IF;
    IF BTRIM(COALESCE(question->>'id', '')) = '' THEN
      RAISE EXCEPTION 'invalid_quiz_question_id';
    END IF;
    IF seen_ids ? (question->>'id') THEN
      RAISE EXCEPTION 'duplicate_quiz_question_id';
    END IF;
    seen_ids := seen_ids || to_jsonb(question->>'id');

    payload := question->'payload';
    answer_key := question->'answerKey';
    IF jsonb_typeof(payload) <> 'object' OR BTRIM(COALESCE(payload->>'stem', '')) = '' THEN
      RAISE EXCEPTION 'invalid_quiz_question';
    END IF;

    IF question_type = 'truefalse' THEN
      IF jsonb_typeof(answer_key) <> 'boolean' THEN RAISE EXCEPTION 'invalid_quiz_answer_key'; END IF;

    ELSIF question_type IN ('single', 'multiple') THEN
      IF jsonb_typeof(payload->'options') <> 'array' THEN RAISE EXCEPTION 'invalid_quiz_question'; END IF;
      option_count := jsonb_array_length(payload->'options');
      IF option_count < 2 THEN RAISE EXCEPTION 'invalid_quiz_question'; END IF;
      IF EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(payload->'options') AS opt WHERE BTRIM(opt) = ''
      ) THEN RAISE EXCEPTION 'invalid_quiz_question'; END IF;

      IF question_type = 'single' THEN
        IF jsonb_typeof(answer_key) <> 'number' THEN RAISE EXCEPTION 'invalid_quiz_answer_key'; END IF;
        IF (answer_key)::TEXT::NUMERIC < 0 OR (answer_key)::TEXT::NUMERIC >= option_count THEN
          RAISE EXCEPTION 'invalid_quiz_answer_key';
        END IF;
      ELSE
        IF jsonb_typeof(answer_key) <> 'array' OR jsonb_array_length(answer_key) = 0 THEN
          RAISE EXCEPTION 'invalid_quiz_answer_key';
        END IF;
        IF EXISTS (
          SELECT 1 FROM jsonb_array_elements(answer_key) e
          WHERE jsonb_typeof(e) <> 'number' OR e::TEXT::NUMERIC < 0 OR e::TEXT::NUMERIC >= option_count
        ) THEN RAISE EXCEPTION 'invalid_quiz_answer_key'; END IF;
        -- 不可重複選同一個選項索引
        IF (SELECT COUNT(DISTINCT e::TEXT) FROM jsonb_array_elements(answer_key) e) <> jsonb_array_length(answer_key) THEN
          RAISE EXCEPTION 'invalid_quiz_answer_key';
        END IF;
      END IF;

    ELSIF question_type = 'matching' THEN
      IF jsonb_typeof(payload->'left') <> 'array' OR jsonb_typeof(payload->'right') <> 'array' THEN
        RAISE EXCEPTION 'invalid_quiz_question';
      END IF;
      left_count := jsonb_array_length(payload->'left');
      right_count := jsonb_array_length(payload->'right');
      IF left_count < 2 OR left_count <> right_count THEN RAISE EXCEPTION 'invalid_quiz_question'; END IF;
      IF jsonb_typeof(answer_key) <> 'object' THEN RAISE EXCEPTION 'invalid_quiz_answer_key'; END IF;
      -- key 集合要等於 left 的 id 集合，value 集合要等於 right 的 id 集合（一一對應）
      IF (
        SELECT COALESCE(jsonb_agg(k ORDER BY k), '[]'::jsonb) FROM jsonb_object_keys(answer_key) k
      ) <> (
        SELECT COALESCE(jsonb_agg(l->>'id' ORDER BY (l->>'id')), '[]'::jsonb) FROM jsonb_array_elements(payload->'left') l
      ) THEN RAISE EXCEPTION 'invalid_quiz_answer_key'; END IF;
      IF (
        SELECT COUNT(DISTINCT value) FROM jsonb_each_text(answer_key)
      ) <> right_count THEN RAISE EXCEPTION 'invalid_quiz_answer_key'; END IF;

    ELSIF question_type = 'ordering' THEN
      IF jsonb_typeof(payload->'items') <> 'array' THEN RAISE EXCEPTION 'invalid_quiz_question'; END IF;
      item_count := jsonb_array_length(payload->'items');
      IF item_count < 2 THEN RAISE EXCEPTION 'invalid_quiz_question'; END IF;
      IF jsonb_typeof(answer_key) <> 'array' OR jsonb_array_length(answer_key) <> item_count THEN
        RAISE EXCEPTION 'invalid_quiz_answer_key';
      END IF;
      IF (
        SELECT COALESCE(jsonb_agg(e ORDER BY e::text), '[]'::jsonb) FROM jsonb_array_elements(answer_key) e
      ) <> (
        SELECT COALESCE(jsonb_agg(to_jsonb(item->>'id') ORDER BY (item->>'id')), '[]'::jsonb) FROM jsonb_array_elements(payload->'items') item
      ) THEN RAISE EXCEPTION 'invalid_quiz_answer_key'; END IF;
    END IF;
  END LOOP;
END;
$validate_daily_quiz_questions$;

REVOKE ALL ON FUNCTION public.validate_daily_quiz_questions(JSONB, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_daily_quiz_questions(JSONB, INTEGER, INTEGER) TO authenticated, service_role;

-- ── 4b. quiz_questions_for_member：依 type 分流，讓五型題目過濾後不失真 ───

CREATE OR REPLACE FUNCTION public.quiz_questions_for_member(
  p_questions JSONB,
  p_include_answers BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
SET search_path = pg_catalog
AS $quiz_questions_for_member$
  SELECT COALESCE(jsonb_agg(
    CASE WHEN question ? 'type' THEN
      jsonb_build_object(
        'id', question->>'id',
        'type', question->>'type',
        'payload', question->'payload',
        'verseRef', question->>'verseRef'
      ) || CASE WHEN p_include_answers THEN jsonb_build_object(
        'answerKey', question->'answerKey',
        'explanation', question->>'explanation'
      ) ELSE '{}'::JSONB END
    ELSE
      jsonb_build_object(
        'id', question->>'id',
        'question', question->>'question',
        'options', question->'options',
        'verseRef', question->>'verseRef'
      ) || CASE WHEN p_include_answers THEN jsonb_build_object(
        'correctIndex', (question->>'correctIndex')::INTEGER,
        'explanation', question->>'explanation'
      ) ELSE '{}'::JSONB END
    END
    ORDER BY ordinal
  ), '[]'::JSONB)
  FROM jsonb_array_elements(COALESCE(p_questions, '[]'::JSONB)) WITH ORDINALITY AS item(question, ordinal);
$quiz_questions_for_member$;

-- ── 5. 通用排程公告（跟小測驗無關的獨立能力，之後 PR 公布會呼叫它）──────

CREATE OR REPLACE FUNCTION public.schedule_announcement(
  p_title        TEXT,
  p_content      TEXT,
  p_published_at TIMESTAMPTZ DEFAULT NOW(),
  p_created_by   UUID DEFAULT NULL,
  p_expires_at   TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  new_id UUID;
BEGIN
  IF BTRIM(COALESCE(p_title, '')) = '' THEN RAISE EXCEPTION 'announcement_title_required'; END IF;
  INSERT INTO public.church_announcements(title, content, is_published, published_at, expires_at, created_by)
  VALUES (p_title, COALESCE(p_content, ''), TRUE, COALESCE(p_published_at, NOW()), p_expires_at, p_created_by)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

REVOKE ALL ON FUNCTION public.schedule_announcement(TEXT, TEXT, TIMESTAMPTZ, UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.schedule_announcement(TEXT, TEXT, TIMESTAMPTZ, UUID, TIMESTAMPTZ) TO service_role;

-- ── 6. 逐題送出 + 最後結算（新流程，不動舊的 submit_daily_quiz）──────────

CREATE OR REPLACE FUNCTION public.daily_quiz_submit_answer(
  p_publication_id      UUID,
  p_question_id         TEXT,
  p_response            JSONB,
  p_time_spent_seconds  INTEGER DEFAULT NULL,
  p_actor_id            UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $daily_quiz_submit_answer$
DECLARE
  actor_id         UUID;
  publication_row  public.quiz_publications%ROWTYPE;
  quiz_row         public.daily_quizzes%ROWTYPE;
  attempt_row      public.quiz_attempts%ROWTYPE;
  question         JSONB;
  question_type    TEXT;
  is_correct       BOOLEAN;
  remaining_answers JSONB;
  updated_answers  JSONB;
BEGIN
  actor_id := public.resolve_quiz_actor(p_actor_id);
  SELECT * INTO publication_row FROM public.quiz_publications WHERE id = p_publication_id;
  IF publication_row.id IS NULL THEN RAISE EXCEPTION 'quiz_publication_not_found'; END IF;
  IF NOT public.profile_belongs_to_quiz_group(actor_id, publication_row.small_group_id) THEN
    RAISE EXCEPTION 'quiz_assignment_required';
  END IF;
  SELECT * INTO quiz_row FROM public.daily_quizzes WHERE id = publication_row.quiz_id;
  IF quiz_row.id IS NULL OR quiz_row.review_status <> 'approved' THEN RAISE EXCEPTION 'quiz_not_available'; END IF;

  SELECT q INTO question FROM jsonb_array_elements(quiz_row.questions) q
    WHERE COALESCE(q->>'id', '') = p_question_id;
  IF question IS NULL THEN RAISE EXCEPTION 'quiz_question_not_found'; END IF;
  -- 舊格式（AI 產生）沒有 type 欄位，一律當單選判分。
  question_type := COALESCE(question->>'type', 'single');
  is_correct := public._quiz_answer_is_correct(
    question_type,
    COALESCE(question->'answerKey', question->'correctIndex'),
    p_response
  );

  SELECT * INTO attempt_row FROM public.quiz_attempts
    WHERE publication_id = p_publication_id AND user_id = actor_id;

  IF attempt_row.id IS NULL THEN
    INSERT INTO public.quiz_attempts(publication_id, user_id, answers, score, total, status, started_at, completed_at)
    VALUES (p_publication_id, actor_id, '[]'::JSONB, NULL, jsonb_array_length(quiz_row.questions), 'in_progress', NOW(), NULL)
    ON CONFLICT (publication_id, user_id) DO NOTHING
    RETURNING * INTO attempt_row;
    IF attempt_row.id IS NULL THEN
      SELECT * INTO attempt_row FROM public.quiz_attempts
        WHERE publication_id = p_publication_id AND user_id = actor_id;
    END IF;
  END IF;

  IF attempt_row.status = 'submitted' THEN RAISE EXCEPTION 'quiz_already_submitted'; END IF;

  -- 同一題重送＝取代舊的那筆（讓離線佇列重試也是安全、可重複執行的操作）。
  SELECT COALESCE(jsonb_agg(a), '[]'::JSONB) INTO remaining_answers
  FROM jsonb_array_elements(attempt_row.answers) a
  WHERE COALESCE(a->>'questionId', '') <> p_question_id;

  updated_answers := remaining_answers || jsonb_build_array(jsonb_build_object(
    'questionId', p_question_id,
    'response', p_response,
    'correct', is_correct,
    'timeSpentSeconds', p_time_spent_seconds
  ));

  UPDATE public.quiz_attempts SET answers = updated_answers WHERE id = attempt_row.id;

  RETURN jsonb_build_object(
    'attemptId', attempt_row.id,
    'questionId', p_question_id,
    'correct', is_correct,
    'answeredCount', jsonb_array_length(updated_answers),
    'totalQuestions', attempt_row.total
  );
END;
$daily_quiz_submit_answer$;

REVOKE ALL ON FUNCTION public.daily_quiz_submit_answer(UUID, TEXT, JSONB, INTEGER, UUID) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.daily_quiz_finalize_attempt(
  p_publication_id UUID,
  p_actor_id       UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $daily_quiz_finalize_attempt$
DECLARE
  actor_id      UUID;
  attempt_row   public.quiz_attempts%ROWTYPE;
  correct_count INTEGER;
BEGIN
  actor_id := public.resolve_quiz_actor(p_actor_id);
  SELECT * INTO attempt_row FROM public.quiz_attempts
    WHERE publication_id = p_publication_id AND user_id = actor_id;
  IF attempt_row.id IS NULL THEN RAISE EXCEPTION 'quiz_attempt_not_found'; END IF;

  IF attempt_row.status = 'submitted' THEN
    RETURN jsonb_build_object(
      'attemptId', attempt_row.id, 'score', attempt_row.score, 'total', attempt_row.total,
      'completedAt', attempt_row.completed_at, 'alreadySubmitted', TRUE
    );
  END IF;

  IF jsonb_array_length(attempt_row.answers) < attempt_row.total THEN
    RAISE EXCEPTION 'quiz_incomplete';
  END IF;

  SELECT COUNT(*) INTO correct_count
  FROM jsonb_array_elements(attempt_row.answers) a
  WHERE (a->>'correct')::BOOLEAN IS TRUE;

  UPDATE public.quiz_attempts
  SET score = correct_count, status = 'submitted', completed_at = NOW()
  WHERE id = attempt_row.id
  RETURNING * INTO attempt_row;

  RETURN jsonb_build_object(
    'attemptId', attempt_row.id, 'score', attempt_row.score, 'total', attempt_row.total,
    'answers', attempt_row.answers, 'completedAt', attempt_row.completed_at
  );
END;
$daily_quiz_finalize_attempt$;

REVOKE ALL ON FUNCTION public.daily_quiz_finalize_attempt(UUID, UUID) FROM PUBLIC;

COMMENT ON FUNCTION public.daily_quiz_submit_answer(UUID, TEXT, JSONB, INTEGER, UUID) IS
  '逐題送出（取代整份一次送出）；同一題重送會覆蓋舊值，離線佇列重試安全。只做小寫入，不帶整份題目內容。';
COMMENT ON FUNCTION public.daily_quiz_finalize_attempt(UUID, UUID) IS
  '所有題目都送出後呼叫，結算分數、標記 submitted。本身不帶任何題目內容，避免大 payload 截斷風險。';
