-- TEST ENVIRONMENT ONLY
-- Clears participation/progress from the obsolete church campaign and all
-- current stage plans. Keeps profiles, organization data, and plan rules.
-- reading_logs are removed automatically through reading_plans ON DELETE CASCADE.

BEGIN;

-- Remove temporary small-home registrations for both the master and stage plans.
DELETE FROM public.small_home_teams team
USING public.global_plans plan
WHERE team.global_plan_id = plan.id
  AND (
    plan.id = '00000000-0000-0000-c026-000000002029'::UUID
    OR plan.plan_kind = 'church_campaign_stage'
    OR plan.id::TEXT LIKE '00000000-0000-0000-a000-%'
  );

-- Remove rule edit history created during testing, without deleting current rules.
DELETE FROM public.plan_rule_versions version
USING public.global_plans plan
WHERE version.global_plan_id = plan.id
  AND (
    plan.id = '00000000-0000-0000-c026-000000002029'::UUID
    OR plan.plan_kind = 'church_campaign_stage'
    OR plan.id::TEXT LIKE '00000000-0000-0000-a000-%'
  );

-- Remove all test enrollments for the old giant plan, the ten stage plans,
-- and legacy monthly/category plans. Their reading_logs cascade-delete.
DELETE FROM public.reading_plans enrollment
USING public.global_plans plan
WHERE enrollment.global_plan_id = plan.id
  AND (
    plan.id = '00000000-0000-0000-c026-000000002029'::UUID
    OR plan.plan_kind = 'church_campaign_stage'
    OR plan.id::TEXT LIKE '00000000-0000-0000-a000-%'
  );

-- Also clear legacy local-key enrollments that were never linked to global_plans.
DELETE FROM public.reading_plans
WHERE global_plan_id IS NULL
  AND (
    preset_key IN ('q1', 'q2', 'q3', 'q4', 'church_2026_2029')
    OR preset_key LIKE 'm\_%' ESCAPE '\'
  );

-- Remove obsolete monthly/category plan definitions. New stage definitions stay.
DELETE FROM public.global_plans
WHERE id::TEXT LIKE '00000000-0000-0000-a000-%';

-- Keep the master only as the hidden editable source of truth.
-- Delete duplicate legacy cards, then retain the canonical UUID only as internal rule storage.
DELETE FROM public.global_plans
WHERE id <> '00000000-0000-0000-c026-000000002029'::UUID
  AND replace(replace(name, '–', '-'), '—', '-') = '2026-2029 新生生命聖經速讀計畫';

UPDATE public.global_plans
SET name = '教會階段規則設定',
    description = 'Internal campaign rule configuration; not a joinable reading plan.',
    target_books = ARRAY[]::TEXT[],
    is_hidden = TRUE
WHERE id = '00000000-0000-0000-c026-000000002029'::UUID;

COMMIT;

-- Expected result: zero test participants for each stage.
SELECT
  plan.name,
  COUNT(enrollment.id) AS participant_count
FROM public.global_plans plan
LEFT JOIN public.reading_plans enrollment ON enrollment.global_plan_id = plan.id
WHERE plan.plan_kind = 'church_campaign_stage'
GROUP BY plan.id, plan.name, plan.start_date
ORDER BY plan.start_date;
