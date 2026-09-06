-- 0162_devotion_group_hidden.sql
--
-- 政策審核期間：把「每日靈修」「小組聚會週計畫」對「所有人」隱藏——包含系統
-- 管理員 / 牧者本人（平常他們即使功能沒對會友開放也看得到，用來先建內容）。
-- 內容不刪，只是全部入口（首頁卡片、「我的計畫」清單、管理分頁）都不出現。
--
-- 用一個 app_feature_settings 旗標 devotion_group_hidden：
--   TRUE  → 全部隱藏（連 admin/pastor）。
--   FALSE → 恢復原本行為（master 總開關 + 每人偏好 + admin/pastor 一律看得到）。
--
-- 這支只設旗標，不改任何 RPC。前端 plan.js / home.js / admin.js 讀這個旗標，
-- 命中就讓所有可見性判斷回 false。會友端的 get_devotional_plan /
-- get_group_meeting_plan 本來就擋非管理者，這裡再把管理者的前端入口也收掉。
--
-- 政策通過、要重新顯示時，二選一：
--   (A) 系統管理 → 功能設定 →「完全隱藏（政策審核中）」開關關掉，或
--   (B) SQL：UPDATE public.app_feature_settings SET enabled = FALSE WHERE key = 'devotion_group_hidden';
--
-- 部署：SQL editor 執行 + 部署前端。不需要重新部署 Edge Function。

BEGIN;

INSERT INTO public.app_feature_settings (key, enabled, description)
VALUES ('devotion_group_hidden', TRUE,
        '政策審核期間：每日靈修／小組聚會週計畫對所有人（含系統管理員／牧者）隱藏。政策通過後改為 FALSE 即恢復。')
ON CONFLICT (key) DO NOTHING;

-- 明確地「現在就隱藏」（若這個 key 之前已存在且是 FALSE，也拉回 TRUE）。
UPDATE public.app_feature_settings
SET enabled = TRUE
WHERE key = 'devotion_group_hidden';

COMMIT;
