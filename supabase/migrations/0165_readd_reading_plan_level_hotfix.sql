-- ============================================================================
-- 0165_readd_reading_plan_level_hotfix.sql   ⚠️ P0 HOTFIX — 立即部署
--
-- 症狀：使用者「無法進入計畫」，錯誤 `column "level" of relation
--       "reading_plans" does not exist`。
--
-- 根因：0138 DROP 掉了 reading_plans.level，但它用 pg_get_functiondef +
--       字串 replace 的方式去清 carry_reading_teams_to_stage 裡的
--       `INSERT INTO reading_plans(... level ...)`——pg_get_functiondef 會
--       重排縮排，pattern 沒命中就只 RAISE WARNING、函式沒改（0138 自己的
--       註解已標「pattern 未命中請人工檢查」）。0154 的 CREATE OR REPLACE
--       版本也仍帶著 `level,` / `'normal',`。所以 live 的
--       carry_reading_teams_to_stage 一被呼叫（隊長帶隊進下一階段、或舊前端
--       的一次性自動彈窗）就撞「column does not exist」，整個進入計畫流程失敗。
--
-- 這支的作用：把欄位加回來當無害的 no-op，讓現行函式立刻恢復。
--   · 前端 solo-join（joinPresetPlan）本來就沒送 level → 靠 DEFAULT 補。
--   · 0138 之後沒有任何地方「讀」level：進度轉換 trigger 已被 0138 改成只檢查
--     user_id，不再碰 level / was_downgraded / downgrade_locked_until。
--   · 因此加回這個欄位不會重新啟用任何舊的升降級判斷。
--
-- 之後的正式清理（另一支 migration，不急）：把 carry_reading_teams_to_stage
-- 用 CREATE OR REPLACE 明確重寫成不帶 level 的版本（以 0154 為基準），再
-- 重新 DROP COLUMN level。在那之前這個欄位就放著。
--
-- 部署：Supabase SQL editor 執行，或 supabase db push。純資料庫、可獨立上。
-- ============================================================================

BEGIN;

ALTER TABLE public.reading_plans
  ADD COLUMN IF NOT EXISTS level TEXT DEFAULT 'normal';

-- 既有列（0138 之前建立的）DROP 後再 ADD 會是 NULL；補成 'normal' 保持一致，
-- 避免任何殘留邏輯對 NULL 有意外反應。
UPDATE public.reading_plans SET level = 'normal' WHERE level IS NULL;

COMMIT;
