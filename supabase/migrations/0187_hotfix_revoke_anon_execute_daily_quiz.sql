-- ============================================================================
-- 0187_hotfix_revoke_anon_execute_daily_quiz.sql  —  安全性 hotfix，請盡快部署
-- ----------------------------------------------------------------------------
-- 部署 0185/0186 後用 anon key 實測發現：`REVOKE ALL ... FROM PUBLIC`（0185/
-- 0186 用的寫法，抄自舊版 0096 的 _exam_answer_is_correct）對這批新函式沒有
-- 真的擋掉 anon（未登入）的呼叫權限。
--
-- 對照 0182（sweep 3）的紀錄才確認根因：這個專案的新函式預設會拿到一個
-- PUBLIC 授權，但 anon 實際拿到的執行權有時候是「直接對 anon 的授權」，
-- 不是單純透過 PUBLIC 繼承——只 REVOKE FROM PUBLIC 對這種情況是 no-op，
-- 這正是 0182 那份文件開頭解釋過的同一個坑（sweep 1/2 失敗、sweep 3 改成
-- `FROM PUBLIC, anon` 才真的堵住）。0185/0186 是 0182 之後才新增的函式，
-- 沒有被那次 sweep 掃到，所以重蹈覆轍。
--
-- 實測證實 public.schedule_announcement 在完全沒有 GRANT、只有
-- `REVOKE ALL FROM PUBLIC` 的情況下，未登入的 anon key 仍然可以直接呼叫
-- 成功——而且這支函式本身沒有任何呼叫者身分檢查（設計上只給其他已經做過
-- 檢查的 SECURITY DEFINER 函式內部呼叫），所以這是真的可以被任何人拿去
-- 對正式站 church_announcements 發公告的漏洞，不是理論風險。驗證過程中
-- 已經真的寫入一筆標題 "probe-test-do-not-use" 的公告，需要手動到後台
-- 「公告管理」刪除。
--
-- 這裡明確把 PUBLIC、anon、authenticated 都列出來 REVOKE（不像 0182 那樣
-- 事後統一補 GRANT authenticated, service_role 給掃到的每一支——這批函式
-- 裡有幾支是刻意只給 service_role／只透過 nlc-data 呼叫，不應該連
-- authenticated 都開放，開放的話等於繞過 nlc-data 的 feature flag 檢查跟
-- actor 注入），需要 authenticated 的兩支再個別補回 GRANT。
-- ============================================================================

-- 只給 service_role（只透過其他 SECURITY DEFINER 函式或 nlc-data 內部呼叫，
-- 不應該被任何登入或未登入的使用者直接呼叫）：
REVOKE ALL ON FUNCTION public._quiz_answer_is_correct(TEXT, JSONB, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._exam_answer_is_correct(TEXT, JSONB, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.schedule_announcement(TEXT, TEXT, TIMESTAMPTZ, UUID, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.daily_quiz_submit_answer(UUID, TEXT, JSONB, INTEGER, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.daily_quiz_finalize_attempt(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- 這兩支本來就是設計給 authenticated 呼叫（透過 nlc-data 的 rpc action，
-- p_actor_id 由 nlc-data 注入），只需要拿掉 anon：
REVOKE ALL ON FUNCTION public.daily_quiz_get_stats(UUID, DATE, DATE, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.daily_quiz_get_stats(UUID, DATE, DATE, UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.validate_daily_quiz_questions(JSONB, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validate_daily_quiz_questions(JSONB, INTEGER, INTEGER) TO authenticated, service_role;

-- 安全網：照 0182 sweep 3 的同一套偵測方式（has_function_privilege），把
-- 「現在還是 anon 可執行」但不在上面名單裡的 public schema 函式也列出來
-- （只是列出來、RAISE NOTICE，不自動改權限——這批不確定各自的正確 GRANT
-- 對象是誰，不能像 0182 那樣統一補 authenticated，需要人工個別確認）。
DO $$
DECLARE
  r RECORD;
  remaining TEXT[] := '{}';
BEGIN
  FOR r IN
    SELECT p.proname AS func_name, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    remaining := remaining || (r.func_name || '(' || r.args || ')');
  END LOOP;

  IF array_length(remaining, 1) > 0 THEN
    RAISE NOTICE '仍有 % 支 public schema 函式 anon 可執行，需要人工檢查是否該收斂：%', array_length(remaining, 1), remaining;
  ELSE
    RAISE NOTICE '掃描完成：目前沒有任何 public schema 函式對 anon 開放執行權。';
  END IF;
END $$;
