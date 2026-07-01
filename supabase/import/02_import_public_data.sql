-- Convert staged public/shared old app data into the clean schema.
-- This script intentionally imports NO users and NO user-linked records.
-- It does not import profiles, user_identities, reading_plans, reading_logs, or devotional_notes.

BEGIN;

CREATE OR REPLACE FUNCTION import_staging.to_text_array(value TEXT)
RETURNS TEXT[]
LANGUAGE plpgsql
AS $nlc_import$
DECLARE
  trimmed TEXT;
  parsed_json JSONB;
BEGIN
  trimmed := NULLIF(BTRIM(value), '');
  IF trimmed IS NULL THEN
    RETURN ARRAY[]::TEXT[];
  END IF;

  IF LEFT(trimmed, 1) = '[' THEN
    parsed_json := trimmed::JSONB;
    RETURN ARRAY(SELECT jsonb_array_elements_text(parsed_json));
  END IF;

  RETURN trimmed::TEXT[];
EXCEPTION WHEN OTHERS THEN
  RETURN ARRAY[trimmed]::TEXT[];
END;
$nlc_import$;

-- Great regions
INSERT INTO public.great_regions (name, sort_order, created_at, updated_at)
SELECT DISTINCT ON (name)
  name,
  COALESCE(NULLIF(sort_order, '')::INTEGER, 0),
  COALESCE(NULLIF(created_at, '')::TIMESTAMPTZ, NOW()),
  COALESCE(NULLIF(updated_at, '')::TIMESTAMPTZ, NOW())
FROM import_staging.great_regions
WHERE NULLIF(TRIM(name), '') IS NOT NULL
ORDER BY name, COALESCE(NULLIF(sort_order, '')::INTEGER, 0)
ON CONFLICT (name) DO UPDATE SET
  sort_order = EXCLUDED.sort_order,
  updated_at = NOW();

-- Pastoral zones. Region linkage is restored by old exported IDs inside staging.
INSERT INTO public.pastoral_zones (great_region_id, name, sort_order, created_at, updated_at)
SELECT DISTINCT ON (pz.name, gr_new.id)
  gr_new.id,
  pz.name,
  COALESCE(NULLIF(pz.sort_order, '')::INTEGER, 0),
  COALESCE(NULLIF(pz.created_at, '')::TIMESTAMPTZ, NOW()),
  COALESCE(NULLIF(pz.updated_at, '')::TIMESTAMPTZ, NOW())
FROM import_staging.pastoral_zones pz
LEFT JOIN import_staging.great_regions gr_old ON gr_old.id = pz.great_region_id
LEFT JOIN public.great_regions gr_new ON gr_new.name = gr_old.name
WHERE NULLIF(TRIM(pz.name), '') IS NOT NULL
ORDER BY pz.name, gr_new.id, COALESCE(NULLIF(pz.sort_order, '')::INTEGER, 0)
ON CONFLICT (name, great_region_id) DO UPDATE SET
  sort_order = EXCLUDED.sort_order,
  updated_at = NOW();

-- Small groups. Zone linkage is restored by old exported IDs inside staging.
INSERT INTO public.small_groups (pastoral_zone_id, name, sort_order, created_at, updated_at)
SELECT DISTINCT ON (sg.name, pz_new.id)
  pz_new.id,
  sg.name,
  COALESCE(NULLIF(sg.sort_order, '')::INTEGER, 0),
  COALESCE(NULLIF(sg.created_at, '')::TIMESTAMPTZ, NOW()),
  COALESCE(NULLIF(sg.updated_at, '')::TIMESTAMPTZ, NOW())
FROM import_staging.small_groups sg
LEFT JOIN import_staging.pastoral_zones pz_old ON pz_old.id = sg.pastoral_zone_id
LEFT JOIN import_staging.great_regions gr_old ON gr_old.id = pz_old.great_region_id
LEFT JOIN public.great_regions gr_new ON gr_new.name = gr_old.name
LEFT JOIN public.pastoral_zones pz_new
  ON pz_new.name = pz_old.name
 AND (pz_new.great_region_id = gr_new.id OR (pz_new.great_region_id IS NULL AND gr_new.id IS NULL))
WHERE NULLIF(TRIM(sg.name), '') IS NOT NULL
ORDER BY sg.name, pz_new.id, COALESCE(NULLIF(sg.sort_order, '')::INTEGER, 0)
ON CONFLICT (name, pastoral_zone_id) DO UPDATE SET
  sort_order = EXCLUDED.sort_order,
  updated_at = NOW();

-- Global plans. created_by is intentionally left NULL.
INSERT INTO public.global_plans (
  name,
  description,
  start_date,
  end_date,
  target_books,
  cover_image_url,
  is_hidden,
  created_by,
  created_at,
  updated_at
)
SELECT DISTINCT ON (name, NULLIF(start_date, '')::DATE, NULLIF(end_date, '')::DATE)
  name,
  description,
  NULLIF(start_date, '')::DATE,
  NULLIF(end_date, '')::DATE,
  import_staging.to_text_array(target_books),
  NULLIF(cover_image_url, ''),
  COALESCE(NULLIF(is_hidden, '')::BOOLEAN, FALSE),
  NULL,
  COALESCE(NULLIF(created_at, '')::TIMESTAMPTZ, NOW()),
  COALESCE(NULLIF(updated_at, '')::TIMESTAMPTZ, NOW())
FROM import_staging.global_plans
WHERE NULLIF(TRIM(name), '') IS NOT NULL
  AND NULLIF(start_date, '') IS NOT NULL
  AND NULLIF(end_date, '') IS NOT NULL
ORDER BY name, NULLIF(start_date, '')::DATE, NULLIF(end_date, '')::DATE, COALESCE(NULLIF(updated_at, '')::TIMESTAMPTZ, NULLIF(created_at, '')::TIMESTAMPTZ, NOW()) DESC;

-- Public announcements. created_by is intentionally left NULL.
INSERT INTO public.church_announcements (
  title,
  content,
  created_by,
  is_published,
  published_at,
  created_at,
  updated_at
)
SELECT
  title,
  content,
  NULL,
  COALESCE(NULLIF(is_published, '')::BOOLEAN, TRUE),
  COALESCE(NULLIF(published_at, '')::TIMESTAMPTZ, NULLIF(created_at, '')::TIMESTAMPTZ, NOW()),
  COALESCE(NULLIF(created_at, '')::TIMESTAMPTZ, NOW()),
  COALESCE(NULLIF(updated_at, '')::TIMESTAMPTZ, NOW())
FROM import_staging.church_announcements
WHERE NULLIF(TRIM(title), '') IS NOT NULL;

COMMIT;
