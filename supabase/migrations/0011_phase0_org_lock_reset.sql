-- Phase 0: org_fields_locked is reserved for Phase 1 Hub org sync; reset any early integration flags.

UPDATE public.profiles
SET org_fields_locked = FALSE
WHERE org_fields_locked = TRUE;

COMMENT ON COLUMN public.profiles.org_fields_locked IS
  'Reserved for Phase 1 Member Hub org sync. Phase 0: always false; local org tree remains authoritative.';
