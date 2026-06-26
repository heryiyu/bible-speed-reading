-- 增加讀經計畫等級、當前遍數及是否落後降級標記
ALTER TABLE public.reading_plans ADD COLUMN IF NOT EXISTS level TEXT DEFAULT 'normal' NOT NULL;
ALTER TABLE public.reading_plans ADD COLUMN IF NOT EXISTS current_round INTEGER DEFAULT 1 NOT NULL;
ALTER TABLE public.reading_plans ADD COLUMN IF NOT EXISTS was_downgraded BOOLEAN DEFAULT FALSE NOT NULL;

-- 調整已讀記錄，加入遍數 (round) 並更新唯一性約束
ALTER TABLE public.reading_logs ADD COLUMN IF NOT EXISTS round INTEGER DEFAULT 1 NOT NULL;

-- 移除舊有的唯一性約束，並建立包含 round 的新唯一性約束
ALTER TABLE public.reading_logs DROP CONSTRAINT IF EXISTS unique_user_plan_book_chapter;
ALTER TABLE public.reading_logs ADD CONSTRAINT unique_user_plan_book_chapter_round UNIQUE (user_id, plan_id, book, chapter, round);

COMMENT ON COLUMN public.reading_plans.level IS '計畫進度等級：normal (一般), breakthrough (突破), super (超強)';
COMMENT ON COLUMN public.reading_plans.current_round IS '當前正在進行的讀經遍數';
COMMENT ON COLUMN public.reading_plans.was_downgraded IS '是否曾因進度落後而被系統自動降級';
COMMENT ON COLUMN public.reading_logs.round IS '此已讀紀錄所屬的遍數';
