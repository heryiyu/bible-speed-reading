-- 0164_exam_grading_seq.sql
--
-- 大測驗簡答批改：給每一份被指派的考卷一個「固定的批改序號」，指派當下就決定、
-- 之後不會變（改派給別的批改人員也保留同一號）。這樣後台指派清單和批改頁看到
-- 的是同一個編號，批改人員之間、批改人員與同工之間可以用「第 5 份」互相對照。
--
--   · 範圍：每份試卷（paper）各自 1..N，跨所有被指派的作答者、不分批改人員。
--   · 指定時機：exam_grading_assignments 第一次 INSERT 該 attempt 時，由 BEFORE
--     INSERT 觸發器補上 seq = 該 paper 目前 MAX(seq) + 1。
--   · exam_assign_attempts 的 ON CONFLICT DO UPDATE（改派）是 UPDATE 不是 INSERT，
--     觸發器不會動它 → 序號保留。所以完全不用改 exam_assign_attempts 的函式本體。
--   · 序號不回收、不重編：某份被刪掉再指派會拿新的（較大）號碼。
--
-- 部署：Supabase SQL editor 執行。函式簽名都沒變 → GRANT 不受影響、nlc-data
-- 不用重部署。冪等。

BEGIN;

-- ── 1. 欄位 + 回填既有指派 + 查詢索引 ──────────────────────────────────────
ALTER TABLE public.exam_grading_assignments
  ADD COLUMN IF NOT EXISTS seq INTEGER;

WITH numbered AS (
  SELECT attempt_id,
         ROW_NUMBER() OVER (PARTITION BY paper_id ORDER BY assigned_at, attempt_id) AS rn
  FROM public.exam_grading_assignments
  WHERE seq IS NULL
)
UPDATE public.exam_grading_assignments ga
SET seq = numbered.rn
FROM numbered
WHERE ga.attempt_id = numbered.attempt_id
  AND ga.seq IS NULL;

CREATE INDEX IF NOT EXISTS exam_grading_assignments_paper_seq_idx
  ON public.exam_grading_assignments (paper_id, seq);

-- ── 2. BEFORE INSERT 觸發器：自動補下一個序號 ────────────────────────────────
CREATE OR REPLACE FUNCTION public._exam_grading_assign_seq()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.seq IS NULL THEN
    SELECT COALESCE(MAX(seq), 0) + 1
    INTO NEW.seq
    FROM public.exam_grading_assignments
    WHERE paper_id = NEW.paper_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_exam_grading_assign_seq ON public.exam_grading_assignments;
CREATE TRIGGER trg_exam_grading_assign_seq
  BEFORE INSERT ON public.exam_grading_assignments
  FOR EACH ROW EXECUTE FUNCTION public._exam_grading_assign_seq();

-- ── 3. 批改頁「我的工作區」名單：多回傳 seq（其餘同 0146）──────────────────
CREATE OR REPLACE FUNCTION public.exam_get_grading_workspace(
  p_paper_id UUID,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID := public.resolve_quiz_actor(p_actor_id);
  pr       public.exam_papers%ROWTYPE;
  is_staff BOOLEAN := public._exam_actor_role(actor_id) IN ('admin', 'pastor');
BEGIN
  IF actor_id IS NULL THEN RAISE EXCEPTION 'exam_forbidden'; END IF;
  SELECT * INTO pr FROM public.exam_papers WHERE id = p_paper_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'exam_paper_not_found'; END IF;

  IF NOT is_staff AND NOT EXISTS (
    SELECT 1 FROM public.exam_grading_assignments ga
    WHERE ga.paper_id = p_paper_id AND ga.grader_id = actor_id
  ) THEN
    RAISE EXCEPTION 'exam_grading_not_assigned';
  END IF;

  RETURN jsonb_build_object(
    'paper', jsonb_build_object(
      'id', pr.id, 'title', pr.title,
      'resultsPublished', pr.results_published_at IS NOT NULL,
      'shortCount', (SELECT COUNT(*) FROM public.exam_questions q
                     WHERE q.paper_id = pr.id AND q.section = 'shortanswer'),
      'shortPoints', (SELECT COALESCE(SUM(q.points), 0) FROM public.exam_questions q
                      WHERE q.paper_id = pr.id AND q.section = 'shortanswer')
    ),
    'roster', COALESCE((
      SELECT jsonb_agg(row_to_json(t)::jsonb ORDER BY t.seq, t.pastoral_zone, t.small_group, t.name)
      FROM (
        SELECT
          a.id            AS "attemptId",
          ga.seq          AS seq,
          p.name          AS name,
          p.great_region  AS "greatRegion",
          p.pastoral_zone AS "pastoralZone",
          p.small_group   AS "smallGroup",
          p.pastoral_zone AS pastoral_zone,
          p.small_group   AS small_group,
          a.submitted_at  AS "submittedAt",
          (SELECT COUNT(*) FROM public.exam_answers ea
             WHERE ea.attempt_id = a.id AND ea.section = 'shortanswer')             AS "shortTotal",
          (SELECT COUNT(*) FROM public.exam_answers ea
             WHERE ea.attempt_id = a.id AND ea.section = 'shortanswer'
               AND ea.awarded_points IS NOT NULL)                                   AS "shortGraded",
          (SELECT COUNT(*) FROM public.exam_questions q
             WHERE q.paper_id = a.paper_id AND q.section = 'shortanswer')           AS "shortQuestions",
          a.status        AS "attemptStatus",
          EXISTS (SELECT 1 FROM public.exam_grading_drafts d WHERE d.attempt_id = a.id) AS "hasDraft",
          public._exam_attempt_grading_rev(a.id) AS rev
        FROM public.exam_grading_assignments ga
        JOIN public.exam_attempts a ON a.id = ga.attempt_id
        JOIN public.profiles p ON p.id = a.user_id
        WHERE ga.paper_id = p_paper_id
          AND (is_staff OR ga.grader_id = actor_id)
      ) t
    ), '[]'::jsonb)
  );
END;
$$;

-- ── 4. 後台「可指派清單」：多回傳 gradingSeq（其餘同 0146）─────────────────
CREATE OR REPLACE FUNCTION public.exam_list_gradable_attempts(
  p_paper_id UUID,
  p_filter   JSONB DEFAULT '{}'::jsonb,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
AS $$
DECLARE
  actor_id UUID := public.resolve_quiz_actor(p_actor_id);
  f_zone   TEXT := NULLIF(BTRIM(COALESCE(p_filter->>'zone', '')), '');
  f_status TEXT := COALESCE(NULLIF(p_filter->>'status', ''), 'all');
  f_assign TEXT := COALESCE(NULLIF(p_filter->>'assigned', ''), 'all');
BEGIN
  IF public._exam_actor_role(actor_id) NOT IN ('admin', 'pastor') THEN
    RAISE EXCEPTION 'exam_admin_required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exam_papers WHERE id = p_paper_id) THEN
    RAISE EXCEPTION 'exam_paper_not_found';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_to_json(t)::jsonb ORDER BY t.pastoral_zone, t.small_group, t.name)
    FROM (
      SELECT
        a.id                       AS "attemptId",
        p.name                     AS name,
        p.great_region             AS "greatRegion",
        p.pastoral_zone            AS "pastoralZone",
        p.small_group              AS "smallGroup",
        p.pastoral_zone            AS pastoral_zone,
        p.small_group              AS small_group,
        a.submitted_at             AS "submittedAt",
        a.status                   AS status,
        (SELECT COUNT(*) FROM public.exam_questions q
           WHERE q.paper_id = a.paper_id AND q.section = 'shortanswer')             AS "shortTotal",
        (SELECT COUNT(*) FROM public.exam_answers ea
           WHERE ea.attempt_id = a.id AND ea.section = 'shortanswer'
             AND ea.awarded_points IS NOT NULL)                                     AS "shortGraded",
        ga.grader_id               AS "assignedGraderId",
        gp.name                    AS "assignedGraderName",
        ga.seq                     AS "gradingSeq"
      FROM public.exam_attempts a
      JOIN public.profiles p ON p.id = a.user_id
      LEFT JOIN public.exam_grading_assignments ga ON ga.attempt_id = a.id
      LEFT JOIN public.profiles gp ON gp.id = ga.grader_id
      WHERE a.paper_id = p_paper_id
        AND a.attempt_kind = 'official'
        AND a.status IN ('submitted', 'graded')
        AND (f_zone IS NULL OR p.pastoral_zone = f_zone)
        AND (f_status = 'all'
             OR (f_status = 'graded'  AND a.status = 'graded')
             OR (f_status = 'pending' AND a.status <> 'graded'))
        AND (f_assign = 'all'
             OR (f_assign = 'yes' AND ga.grader_id IS NOT NULL)
             OR (f_assign = 'no'  AND ga.grader_id IS NULL))
    ) t
  ), '[]'::jsonb);
END;
$$;

COMMIT;
