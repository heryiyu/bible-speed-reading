-- 一次檢查 memory 裡標記「未部署／待確認」的 migration 是否真的已經套用到正式站。
-- 純讀取 information_schema / pg_proc，不會動任何資料。

SELECT '0143 exam_backfill_shortanswer (簡答題救援 function)' AS migration_check,
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'exam_backfill_shortanswer' AND pronamespace = 'public'::regnamespace) AS deployed
UNION ALL
SELECT '0144 get_unjoined_plan_members (400 修復 function)',
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'get_unjoined_plan_members' AND pronamespace = 'public'::regnamespace)
UNION ALL
SELECT '0145 plan_devotion_days (每日靈修 table)',
       to_regclass('public.plan_devotion_days') IS NOT NULL
UNION ALL
SELECT '0147 join_reading_team_by_code (換隊 function)',
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'join_reading_team_by_code' AND pronamespace = 'public'::regnamespace)
UNION ALL
SELECT '0148 plan_group_meeting_weeks (小組聚會週計畫 table)',
       to_regclass('public.plan_group_meeting_weeks') IS NOT NULL
UNION ALL
SELECT '0152 plan_devotion_days.title (每日主題欄)',
       EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='plan_devotion_days' AND column_name='title')
UNION ALL
SELECT '0146 exam_grading_assignments (線上批改 table)',
       to_regclass('public.exam_grading_assignments') IS NOT NULL
UNION ALL
SELECT '0154 carry_reading_teams_to_stage 不帶 level (0154 目前版本已修正)',
       (SELECT pg_get_functiondef(p.oid) NOT LIKE '%level%'
        FROM pg_proc p WHERE p.proname = 'carry_reading_teams_to_stage' AND p.pronamespace = 'public'::regnamespace
        LIMIT 1)
UNION ALL
SELECT '0163 _reading_team_block_ended_stage_edits (鎖已結束階段 trigger function)',
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = '_reading_team_block_ended_stage_edits' AND pronamespace = 'public'::regnamespace)
UNION ALL
SELECT '0164 exam_grading_assignments.seq (批改序號欄)',
       EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='exam_grading_assignments' AND column_name='seq')
UNION ALL
SELECT '0169 _exam_pr (大測驗 PR 值 function)',
       EXISTS (SELECT 1 FROM pg_proc WHERE proname = '_exam_pr' AND pronamespace = 'public'::regnamespace)
UNION ALL
SELECT '0170 exam_papers.linked_plan_id (測驗綁定計畫欄)',
       EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='exam_papers' AND column_name='linked_plan_id')
UNION ALL
SELECT '0165 reading_plans.level (P0 hotfix 留下的孤兒欄位，理論上還在)',
       EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='reading_plans' AND column_name='level')
ORDER BY 1;
