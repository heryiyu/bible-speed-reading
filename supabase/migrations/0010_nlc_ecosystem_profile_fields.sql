-- ==========================================================
-- Migration: 0010_nlc_ecosystem_profile_fields.sql
-- NLC ecosystem identity + Member Hub context references
-- Keeps profiles.id as Supabase auth.users UUID for existing FKs/RLS
-- ==========================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS identity_provider TEXT,
  ADD COLUMN IF NOT EXISTS identity_subject TEXT,
  ADD COLUMN IF NOT EXISTS member_id UUID,
  ADD COLUMN IF NOT EXISTS membership_status TEXT,
  ADD COLUMN IF NOT EXISTS home_node_id UUID,
  ADD COLUMN IF NOT EXISTS home_node_name TEXT,
  ADD COLUMN IF NOT EXISTS hub_primary_role TEXT,
  ADD COLUMN IF NOT EXISTS hub_roles JSONB DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS member_context_synced_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS org_fields_locked BOOLEAN NOT NULL DEFAULT FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS profiles_identity_provider_subject_idx
  ON public.profiles (identity_provider, identity_subject)
  WHERE identity_subject IS NOT NULL;

CREATE INDEX IF NOT EXISTS profiles_member_id_idx
  ON public.profiles (member_id)
  WHERE member_id IS NOT NULL;

COMMENT ON COLUMN public.profiles.identity_provider IS 'External IdP name, e.g. logto';
COMMENT ON COLUMN public.profiles.identity_subject IS 'Stable Logto sub for identity anchoring';
COMMENT ON COLUMN public.profiles.member_id IS 'Member Hub canonical member UUID';
COMMENT ON COLUMN public.profiles.org_fields_locked IS 'When true, org/role fields are synced from Member Hub only';
