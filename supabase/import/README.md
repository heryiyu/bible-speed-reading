# Import public/shared old data only

This import intentionally excludes all users and all user-linked data.

Imported:

- `great_regions`
- `pastoral_zones`
- `small_groups`
- `global_plans`
- `church_announcements`

Not imported:

- `profiles`
- `user_identities`
- Supabase `auth.users`
- `reading_plans`
- `reading_logs`
- `devotional_notes`
- any old `user_id` / `created_by` relationship

Flow:

1. In the NEW Supabase project, run `01_create_staging_tables.sql`.
2. In the OLD Supabase project, export CSV files from the public tables.
3. In the NEW Supabase project, import each CSV into the matching `import_staging.*` table.
4. Run `02_import_public_data.sql` in the NEW project.

The staging tables now use the same column names as normal Supabase CSV exports:

- `id`
- `great_region_id`
- `pastoral_zone_id`
- `created_by`

But user-linked columns such as `created_by` are ignored during final import and become `NULL`.
