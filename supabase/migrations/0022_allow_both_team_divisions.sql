-- Allow one profile to join one 3-person team and one 6-person team in the
-- same church campaign stage. Existing memberships keep their team division.

ALTER TABLE public.reading_team_members
  ADD COLUMN IF NOT EXISTS division SMALLINT;

UPDATE public.reading_team_members membership
SET division = team.division
FROM public.reading_teams team
WHERE team.id = membership.team_id
  AND membership.division IS DISTINCT FROM team.division;

ALTER TABLE public.reading_team_members
  ALTER COLUMN division SET NOT NULL;

ALTER TABLE public.reading_team_members
  DROP CONSTRAINT IF EXISTS reading_team_members_division_check;
ALTER TABLE public.reading_team_members
  ADD CONSTRAINT reading_team_members_division_check CHECK (division IN (3, 6));

DO $drop_old_unique$
DECLARE constraint_name TEXT;
BEGIN
  SELECT constraint_row.conname INTO constraint_name
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid = 'public.reading_team_members'::regclass
    AND constraint_row.contype = 'u'
    AND pg_get_constraintdef(constraint_row.oid) = 'UNIQUE (global_plan_id, user_id)'
  LIMIT 1;

  IF constraint_name IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.reading_team_members DROP CONSTRAINT %I',
      constraint_name
    );
  END IF;
END;
$drop_old_unique$;

ALTER TABLE public.reading_team_members
  DROP CONSTRAINT IF EXISTS reading_team_members_plan_user_division_key;
ALTER TABLE public.reading_team_members
  ADD CONSTRAINT reading_team_members_plan_user_division_key
  UNIQUE (global_plan_id, user_id, division);

DO $team_composite_key$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.reading_teams'::regclass
      AND conname = 'reading_teams_id_plan_division_key'
  ) THEN
    ALTER TABLE public.reading_teams
      ADD CONSTRAINT reading_teams_id_plan_division_key
      UNIQUE (id, global_plan_id, division);
  END IF;
END;
$team_composite_key$;

ALTER TABLE public.reading_team_members
  DROP CONSTRAINT IF EXISTS reading_team_members_team_plan_fk;
ALTER TABLE public.reading_team_members
  DROP CONSTRAINT IF EXISTS reading_team_members_team_plan_division_fk;
ALTER TABLE public.reading_team_members
  ADD CONSTRAINT reading_team_members_team_plan_division_fk
  FOREIGN KEY (team_id, global_plan_id, division)
  REFERENCES public.reading_teams(id, global_plan_id, division)
  ON DELETE CASCADE;

CREATE OR REPLACE FUNCTION public.get_my_reading_team(
  p_global_plan_id UUID,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $get_my_reading_teams$
DECLARE
  actor_id UUID;
  team_contexts JSONB;
BEGIN
  actor_id := public.resolve_reading_team_actor(p_actor_id);

  WITH my_teams AS (
    SELECT team.*
    FROM public.reading_teams team
    JOIN public.reading_team_members own_membership
      ON own_membership.team_id = team.id
     AND own_membership.global_plan_id = team.global_plan_id
     AND own_membership.division = team.division
    WHERE own_membership.user_id = actor_id
      AND own_membership.global_plan_id = p_global_plan_id
  ), contexts AS (
    SELECT
      selected_team.division,
      jsonb_build_object(
        'team', jsonb_build_object(
          'id', selected_team.id,
          'globalPlanId', selected_team.global_plan_id,
          'name', selected_team.name,
          'division', selected_team.division,
          'capacity', selected_team.division,
          'memberCount', (
            SELECT COUNT(*)::INTEGER
            FROM public.reading_team_members count_membership
            WHERE count_membership.team_id = selected_team.id
          ),
          'status', CASE WHEN (
            SELECT COUNT(*)
            FROM public.reading_team_members count_membership
            WHERE count_membership.team_id = selected_team.id
          ) = selected_team.division THEN 'ready' ELSE 'forming' END,
          'captainId', selected_team.captain_id,
          'inviteCode', selected_team.invite_code,
          'createdAt', selected_team.created_at
        ),
        'members', (
          SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
              'userId', member_row.user_id,
              'name', member_row.name,
              'avatarUrl', member_row.avatar_url,
              'role', member_row.member_role,
              'isMe', member_row.user_id = actor_id,
              'joinedAt', member_row.joined_at,
              'hasJoinedPlan', member_row.plan_id IS NOT NULL,
              'currentRound', member_row.current_round,
              'chaptersRead', member_row.chapters_read,
              'todayRead', member_row.today_read,
              'lastReadAt', member_row.last_read_at
            ) ORDER BY CASE WHEN member_row.member_role = 'captain' THEN 0 ELSE 1 END, member_row.joined_at
          ), '[]'::JSONB)
          FROM (
            SELECT
              membership.user_id,
              membership.member_role,
              membership.joined_at,
              profile.name,
              profile.avatar_url,
              plan.id AS plan_id,
              COALESCE(plan.current_round, 1) AS current_round,
              COALESCE(progress.chapters_read, 0) AS chapters_read,
              COALESCE(progress.today_read, 0) AS today_read,
              progress.last_read_at
            FROM public.reading_team_members membership
            JOIN public.profiles profile ON profile.id = membership.user_id
            LEFT JOIN public.reading_plans plan
              ON plan.user_id = membership.user_id
             AND plan.global_plan_id = selected_team.global_plan_id
            LEFT JOIN LATERAL (
              SELECT
                COUNT(*) FILTER (WHERE log.round = COALESCE(plan.current_round, 1))::INTEGER AS chapters_read,
                COUNT(*) FILTER (
                  WHERE log.round = COALESCE(plan.current_round, 1)
                    AND log.read_at::DATE = CURRENT_DATE
                )::INTEGER AS today_read,
                MAX(log.read_at) AS last_read_at
              FROM public.reading_logs log
              WHERE log.plan_id = plan.id
            ) progress ON TRUE
            WHERE membership.team_id = selected_team.id
          ) member_row
        )
      ) AS context
    FROM my_teams selected_team
  )
  SELECT COALESCE(jsonb_agg(context ORDER BY division), '[]'::JSONB)
  INTO team_contexts
  FROM contexts;

  RETURN jsonb_build_object(
    'teams', team_contexts,
    -- Keep the first context for older clients during a rolling deployment.
    'team', team_contexts->0->'team',
    'members', COALESCE(team_contexts->0->'members', '[]'::JSONB)
  );
END;
$get_my_reading_teams$;

CREATE OR REPLACE FUNCTION public.create_reading_team(
  p_global_plan_id UUID,
  p_division SMALLINT,
  p_name TEXT,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $create_reading_team$
DECLARE
  actor_id UUID;
  new_team public.reading_teams%ROWTYPE;
  generated_code TEXT;
BEGIN
  actor_id := public.resolve_reading_team_actor(p_actor_id);
  IF p_division NOT IN (3, 6) THEN RAISE EXCEPTION 'invalid_team_division'; END IF;
  IF btrim(COALESCE(p_name, '')) = '' OR char_length(btrim(p_name)) > 40 THEN
    RAISE EXCEPTION 'invalid_team_name';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.global_plans plan
    WHERE plan.id = p_global_plan_id
      AND plan.plan_kind = 'church_campaign_stage'
  ) THEN RAISE EXCEPTION 'team_plan_not_found'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.reading_team_members
    WHERE global_plan_id = p_global_plan_id
      AND user_id = actor_id
      AND division = p_division
  ) THEN RAISE EXCEPTION 'already_in_plan_division'; END IF;

  LOOP
    generated_code := upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 10));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.reading_teams WHERE invite_code = generated_code);
  END LOOP;

  INSERT INTO public.reading_teams(global_plan_id, division, name, captain_id, invite_code)
  VALUES (p_global_plan_id, p_division, btrim(p_name), actor_id, generated_code)
  RETURNING * INTO new_team;

  INSERT INTO public.reading_team_members(team_id, global_plan_id, user_id, division, member_role)
  VALUES (new_team.id, p_global_plan_id, actor_id, p_division, 'captain');

  RETURN jsonb_build_object(
    'teamId', new_team.id,
    'division', new_team.division,
    'inviteCode', new_team.invite_code,
    'status', new_team.status
  );
EXCEPTION
  WHEN unique_violation THEN RAISE EXCEPTION 'already_in_plan_division';
END;
$create_reading_team$;

CREATE OR REPLACE FUNCTION public.join_reading_team_by_code(
  p_global_plan_id UUID,
  p_invite_code TEXT,
  p_actor_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $join_reading_team$
DECLARE
  actor_id UUID;
  selected_team public.reading_teams%ROWTYPE;
  current_count INTEGER;
BEGIN
  actor_id := public.resolve_reading_team_actor(p_actor_id);

  SELECT * INTO selected_team
  FROM public.reading_teams
  WHERE global_plan_id = p_global_plan_id
    AND invite_code = upper(btrim(COALESCE(p_invite_code, '')))
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'team_invite_not_found'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.reading_team_members
    WHERE global_plan_id = p_global_plan_id
      AND user_id = actor_id
      AND division = selected_team.division
  ) THEN RAISE EXCEPTION 'already_in_plan_division'; END IF;

  SELECT COUNT(*)::INTEGER INTO current_count
  FROM public.reading_team_members WHERE team_id = selected_team.id;
  IF current_count >= selected_team.division OR selected_team.status = 'ready' THEN
    RAISE EXCEPTION 'reading_team_full';
  END IF;

  INSERT INTO public.reading_team_members(team_id, global_plan_id, user_id, division, member_role)
  VALUES (selected_team.id, p_global_plan_id, actor_id, selected_team.division, 'member');
  current_count := current_count + 1;

  IF current_count = selected_team.division THEN
    UPDATE public.reading_teams SET status = 'ready' WHERE id = selected_team.id;
  END IF;

  RETURN jsonb_build_object(
    'teamId', selected_team.id,
    'division', selected_team.division,
    'memberCount', current_count,
    'capacity', selected_team.division,
    'status', CASE WHEN current_count = selected_team.division THEN 'ready' ELSE 'forming' END
  );
EXCEPTION
  WHEN unique_violation THEN RAISE EXCEPTION 'already_in_plan_division';
END;
$join_reading_team$;

REVOKE ALL ON FUNCTION public.get_my_reading_team(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_reading_team(UUID, SMALLINT, TEXT, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.join_reading_team_by_code(UUID, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_reading_team(UUID, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_reading_team(UUID, SMALLINT, TEXT, UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.join_reading_team_by_code(UUID, TEXT, UUID) TO authenticated, service_role;
