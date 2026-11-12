-- Leaderboard reporting calendars are independent of GMT warning months and
-- CWL signup deadlines. Period boundaries and the policy used to create them
-- are retained rather than recomputed from today's timezone setting.

CREATE TABLE guild.leaderboard_calendar_policy (
    calendar_policy_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    timezone_name text NOT NULL DEFAULT 'Etc/UTC',
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    requested_by_user_key bigint REFERENCES guild.dim_discord_user,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    UNIQUE (calendar_policy_key, timezone_name)
);

-- The one current selection belongs to the guild's configuration row. Policy
-- versions and frozen reporting periods remain separate historical records.
ALTER TABLE guild.guild_settings
    ADD COLUMN leaderboard_next_policy_key bigint,
    ADD COLUMN leaderboard_next_timezone_name text,
    ADD COLUMN leaderboard_policy_selected_at timestamptz,
    ADD CONSTRAINT leaderboard_selection_complete CHECK (
        (leaderboard_next_policy_key IS NULL) = (leaderboard_next_timezone_name IS NULL)
        AND (leaderboard_next_policy_key IS NULL) = (leaderboard_policy_selected_at IS NULL)
    ),
    ADD CONSTRAINT leaderboard_selected_policy FOREIGN KEY
        (leaderboard_next_policy_key, leaderboard_next_timezone_name)
        REFERENCES guild.leaderboard_calendar_policy (calendar_policy_key, timezone_name);

CREATE VIEW guild.leaderboard_calendar_state AS
SELECT guild_key, leaderboard_next_policy_key AS next_policy_key,
    leaderboard_next_timezone_name AS next_timezone_name,
    leaderboard_policy_selected_at AS selected_at
FROM guild.guild_settings
WHERE leaderboard_next_policy_key IS NOT NULL
WITH LOCAL CHECK OPTION;
COMMENT ON VIEW guild.leaderboard_calendar_state IS
    'Latest requested policy for the next uncreated period. Runtime writes use the '
    'authorized setter; changing this pointer never updates an existing period.';

CREATE TABLE guild.dim_leaderboard_monthly_period (
    period_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    calendar_policy_key bigint NOT NULL,
    timezone_name text NOT NULL,
    sequence_number integer NOT NULL UNIQUE CHECK (sequence_number > 0),
    calendar_month date NOT NULL UNIQUE
        CHECK (calendar_month = date_trunc('month', calendar_month::timestamp)::date),
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    previous_period_key bigint UNIQUE REFERENCES guild.dim_leaderboard_monthly_period,
    is_transition boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (calendar_policy_key, timezone_name)
        REFERENCES guild.leaderboard_calendar_policy (calendar_policy_key, timezone_name),
    CHECK (starts_at < ends_at),
    CHECK ((sequence_number = 1) = (previous_period_key IS NULL)),
    EXCLUDE USING gist (tstzrange(starts_at, ends_at, '[)') WITH &&)
);
COMMENT ON TABLE guild.dim_leaderboard_monthly_period IS
    'Append-only reporting boundaries. A timezone transition starts at the prior '
    'period end and ends at the next month label boundary in the new zone. '
    'is_transition exposes the resulting shortened/extended period; no gap, '
    'double-counting, or historical boundary rewrite is introduced.';

CREATE FUNCTION guild.validate_leaderboard_timezone() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF NEW.timezone_name IS NULL OR NOT EXISTS (
        SELECT FROM pg_timezone_names WHERE name = NEW.timezone_name
    ) THEN
        RAISE EXCEPTION 'A recognized named timezone is required' USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER leaderboard_policy_timezone BEFORE INSERT
    ON guild.leaderboard_calendar_policy FOR EACH ROW
    EXECUTE FUNCTION guild.validate_leaderboard_timezone();

CREATE FUNCTION guild.reject_leaderboard_history_mutation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    RAISE EXCEPTION 'Leaderboard policies and reporting periods are append-only'
        USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER leaderboard_policy_immutable BEFORE UPDATE OR DELETE
    ON guild.leaderboard_calendar_policy FOR EACH ROW
    EXECUTE FUNCTION guild.reject_leaderboard_history_mutation();
CREATE TRIGGER leaderboard_period_immutable BEFORE UPDATE OR DELETE
    ON guild.dim_leaderboard_monthly_period FOR EACH ROW
    EXECUTE FUNCTION guild.reject_leaderboard_history_mutation();

CREATE FUNCTION guild.validate_leaderboard_period() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous_period guild.dim_leaderboard_monthly_period%ROWTYPE;
    canonical_start timestamptz;
    canonical_end timestamptz;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('leaderboard-calendar'), 0);
    canonical_start := NEW.calendar_month::timestamp AT TIME ZONE NEW.timezone_name;
    canonical_end := (NEW.calendar_month + interval '1 month')::timestamp
        AT TIME ZONE NEW.timezone_name;
    IF NEW.previous_period_key IS NULL THEN
        IF NEW.sequence_number <> 1 OR EXISTS (
            SELECT FROM guild.dim_leaderboard_monthly_period
        ) OR NEW.starts_at IS DISTINCT FROM canonical_start OR NEW.is_transition THEN
            RAISE EXCEPTION 'Initial leaderboard period must use its calendar boundary'
                USING ERRCODE = '23514';
        END IF;
    ELSE
        SELECT * INTO STRICT previous_period
        FROM guild.dim_leaderboard_monthly_period
        WHERE period_key = NEW.previous_period_key;
        IF NEW.sequence_number <> previous_period.sequence_number + 1
            OR NEW.calendar_month <> (previous_period.calendar_month + interval '1 month')::date
            OR NEW.starts_at IS DISTINCT FROM previous_period.ends_at THEN
            RAISE EXCEPTION 'Reporting periods must continue the prior period without a gap'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.ends_at IS DISTINCT FROM canonical_end
        OR NEW.is_transition IS DISTINCT FROM (NEW.starts_at <> canonical_start) THEN
        RAISE EXCEPTION 'Period end and transition flag must match the selected timezone'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER leaderboard_period_boundaries BEFORE INSERT
    ON guild.dim_leaderboard_monthly_period FOR EACH ROW
    EXECUTE FUNCTION guild.validate_leaderboard_period();

CREATE FUNCTION guild.ensure_leaderboard_monthly_period(
    p_at timestamptz DEFAULT statement_timestamp()
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    selected guild.leaderboard_calendar_state%ROWTYPE;
    previous_period guild.dim_leaderboard_monthly_period%ROWTYPE;
    next_month date;
    first_start timestamptz;
    next_start timestamptz;
    next_end timestamptz;
    selected_policy bigint;
    result_key bigint;
BEGIN
    IF p_at IS NULL OR p_at > statement_timestamp() THEN
        RAISE EXCEPTION 'Cannot pre-freeze a future leaderboard period'
            USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.dim_guild) THEN
        RAISE EXCEPTION 'Guild does not exist' USING ERRCODE = '23503';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('leaderboard-calendar'), 0);
    SELECT period_key INTO result_key FROM guild.dim_leaderboard_monthly_period
    WHERE p_at >= starts_at AND p_at < ends_at;
    IF FOUND THEN RETURN result_key; END IF;

    SELECT * INTO selected FROM guild.leaderboard_calendar_state;
    IF NOT FOUND THEN
        INSERT INTO guild.leaderboard_calendar_policy (timezone_name, reason)
        VALUES ('Etc/UTC', 'Initial GMT leaderboard calendar')
        RETURNING calendar_policy_key INTO selected_policy;
        INSERT INTO guild.guild_settings (guild_key, leaderboard_next_policy_key,
            leaderboard_next_timezone_name, leaderboard_policy_selected_at)
        SELECT guild_key, selected_policy, 'Etc/UTC', clock_timestamp() FROM guild.dim_guild
        ON CONFLICT (guild_key) DO UPDATE
        SET leaderboard_next_policy_key = EXCLUDED.leaderboard_next_policy_key,
            leaderboard_next_timezone_name = EXCLUDED.leaderboard_next_timezone_name,
            leaderboard_policy_selected_at = EXCLUDED.leaderboard_policy_selected_at;
        SELECT * INTO STRICT selected FROM guild.leaderboard_calendar_state;
    END IF;

    SELECT * INTO previous_period FROM guild.dim_leaderboard_monthly_period
    ORDER BY sequence_number DESC LIMIT 1;
    IF NOT FOUND THEN
        next_month := date_trunc('month', p_at AT TIME ZONE selected.next_timezone_name)::date;
        next_start := next_month::timestamp AT TIME ZONE selected.next_timezone_name;
        next_end := (next_month + interval '1 month')::timestamp
            AT TIME ZONE selected.next_timezone_name;
        INSERT INTO guild.dim_leaderboard_monthly_period
            (calendar_policy_key, timezone_name, sequence_number, calendar_month,
                starts_at, ends_at, is_transition)
        VALUES (selected.next_policy_key, selected.next_timezone_name, 1, next_month,
                next_start, next_end, false)
        RETURNING period_key INTO result_key;
        RETURN result_key;
    END IF;
    SELECT min(starts_at) INTO first_start FROM guild.dim_leaderboard_monthly_period;
    IF p_at < first_start THEN
        RAISE EXCEPTION 'No calendar coverage exists before the first recorded period'
            USING ERRCODE = '22023';
    END IF;

    LOOP
        next_month := (previous_period.calendar_month + interval '1 month')::date;
        next_start := previous_period.ends_at;
        next_end := (next_month + interval '1 month')::timestamp
            AT TIME ZONE selected.next_timezone_name;
        INSERT INTO guild.dim_leaderboard_monthly_period
            (calendar_policy_key, timezone_name, sequence_number, calendar_month,
                starts_at, ends_at, previous_period_key, is_transition)
        VALUES (selected.next_policy_key, selected.next_timezone_name,
                previous_period.sequence_number + 1, next_month, next_start, next_end,
                previous_period.period_key,
                next_start <> next_month::timestamp AT TIME ZONE selected.next_timezone_name)
        RETURNING * INTO previous_period;
        IF p_at < previous_period.ends_at THEN RETURN previous_period.period_key; END IF;
    END LOOP;
END;
$$;
COMMENT ON FUNCTION guild.ensure_leaderboard_monthly_period IS
    'Trusted worker entry point. Serializes period creation, freezes calendar metadata, '
    'and never materializes future periods. Initialize from the earliest supported '
    'reporting date before publishing historical monthly boards.';

CREATE FUNCTION guild.set_leaderboard_timezone(
    p_actor bigint, p_timezone text, p_reason text,
    p_operation uuid DEFAULT gen_random_uuid()
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    existing_policy guild.leaderboard_calendar_policy%ROWTYPE;
    result_key bigint;
    old_actor text := current_setting('guild.actor_user_key', true);
    old_source text := current_setting('guild.change_source', true);
    old_reason text := current_setting('guild.change_reason', true);
BEGIN
    IF p_actor IS NULL OR NOT guild.can_configure(p_actor) THEN
        RAISE EXCEPTION 'Configured Admin role or developer required'
            USING ERRCODE = '42501';
    END IF;
    IF p_timezone IS NULL OR NOT EXISTS (
        SELECT FROM pg_timezone_names WHERE name = p_timezone
    ) OR p_reason IS NULL OR btrim(p_reason) = '' OR p_operation IS NULL THEN
        RAISE EXCEPTION 'Named timezone, operation identity, and reason are required'
            USING ERRCODE = '22023';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('leaderboard-calendar'), 0);
    SELECT * INTO existing_policy FROM guild.leaderboard_calendar_policy
    WHERE operation_id = p_operation;
    IF FOUND THEN
        IF (existing_policy.requested_by_user_key, existing_policy.timezone_name,
                existing_policy.reason)
            IS DISTINCT FROM (p_actor, p_timezone, p_reason) THEN
            RAISE EXCEPTION 'Calendar operation identity conflicts with an existing request'
                USING ERRCODE = '23514';
        END IF;
        RETURN existing_policy.calendar_policy_key;
    END IF;

    -- Freeze the active month under the previously selected policy before
    -- recording a new next-period choice, even if no board was queried yet.
    PERFORM guild.ensure_leaderboard_monthly_period(statement_timestamp());
    PERFORM set_config('guild.actor_user_key', p_actor::text, true);
    PERFORM set_config('guild.change_source', 'command', true);
    PERFORM set_config('guild.change_reason', p_reason, true);
    INSERT INTO guild.leaderboard_calendar_policy
        (operation_id, timezone_name, requested_by_user_key, reason)
    VALUES (p_operation, p_timezone, p_actor, p_reason)
    RETURNING calendar_policy_key INTO result_key;
    UPDATE guild.leaderboard_calendar_state
    SET next_policy_key = result_key, next_timezone_name = p_timezone,
        selected_at = clock_timestamp();
    PERFORM set_config('guild.actor_user_key', coalesce(old_actor, ''), true);
    PERFORM set_config('guild.change_source', coalesce(old_source, ''), true);
    PERFORM set_config('guild.change_reason', coalesce(old_reason, ''), true);
    RETURN result_key;
END;
$$;

-- Definitions establish which formulas are supported. Unknown monthly metric
-- semantics remain explicit; no cumulative snapshot is silently used as an
-- arbitrary month's earned score. This is a metric catalog, not score storage.
CREATE TABLE guild.leaderboard_metric_definition (
    metric_key text NOT NULL,
    period_kind text NOT NULL CHECK (period_kind IN ('monthly', 'all_time', 'event', 'season')),
    subject_kind text NOT NULL CHECK (subject_kind IN ('discord_member', 'player_account')),
    calculation_method text NOT NULL CHECK (calculation_method IN
        ('award_sum', 'latest_lifetime_counter', 'event_evidence', 'requires_definition')),
    definition_status text NOT NULL CHECK (definition_status IN ('supported', 'needs_definition')),
    evidence_requirement text NOT NULL CHECK (btrim(evidence_requirement) <> ''),
    PRIMARY KEY (metric_key, period_kind),
    CHECK ((definition_status = 'needs_definition') = (calculation_method = 'requires_definition'))
);
INSERT INTO guild.leaderboard_metric_definition VALUES
    ('chat_xp', 'monthly', 'discord_member', 'award_sum', 'supported',
        'Credited message awards within retained reporting-period boundaries'),
    ('chat_xp', 'all_time', 'discord_member', 'award_sum', 'supported',
        'All credited awards; current Discord membership controls display'),
    ('war_stars', 'all_time', 'player_account', 'latest_lifetime_counter', 'supported',
        'Latest profile warStars, including other clans; current clan controls display'),
    ('war_stars', 'monthly', 'player_account', 'requires_definition', 'needs_definition',
        'Define supported baselines or source-time attribution; attack duration is not a timestamp'),
    ('clan_games_points', 'event', 'player_account', 'event_evidence', 'supported',
        'Supported event counter deltas and tracked participating-clan attribution'),
    ('clan_games_points', 'monthly', 'player_account', 'requires_definition', 'needs_definition',
        'Define event-to-calendar attribution and baseline coverage before ranking'),
    ('raid_capital_gold', 'event', 'player_account', 'event_evidence', 'supported',
        'Latest per-account raid-weekend capitalResourcesLooted, not summed snapshots'),
    ('raid_capital_gold', 'monthly', 'player_account', 'requires_definition', 'needs_definition',
        'Define attribution of weekends crossing reporting boundaries'),
    ('cwl_stars', 'season', 'player_account', 'event_evidence', 'supported',
        'Deduplicated attacks joined to the registered CWL cycle and actual war context');

CREATE VIEW guild.chat_xp_current_member_all_time AS
SELECT a.user_key, sum(a.xp)::bigint AS xp_total,
    count(*) AS credited_messages,
    dense_rank() OVER (ORDER BY sum(a.xp) DESC) AS position
FROM guild.fact_chat_xp_award a
JOIN guild.discord_member_state s USING (user_key)
WHERE s.is_present
GROUP BY a.user_key;

CREATE VIEW guild.chat_xp_monthly_leaderboard AS
SELECT p.period_key, p.calendar_month, p.timezone_name,
    p.starts_at, p.ends_at, p.is_transition, a.user_key,
    sum(a.xp)::bigint AS xp_total, count(*) AS credited_messages,
    dense_rank() OVER (PARTITION BY p.period_key ORDER BY sum(a.xp) DESC) AS position
FROM guild.dim_leaderboard_monthly_period p
JOIN guild.fact_chat_xp_award a
    ON a.message_sent_at >= p.starts_at AND a.message_sent_at < p.ends_at
JOIN guild.discord_member_state s ON s.user_key = a.user_key
WHERE s.is_present
GROUP BY p.period_key, a.user_key;

CREATE VIEW guild.current_chat_xp_monthly_leaderboard AS
SELECT * FROM guild.chat_xp_monthly_leaderboard
WHERE starts_at <= statement_timestamp() AND statement_timestamp() < ends_at;

COMMENT ON VIEW guild.chat_xp_monthly_leaderboard IS
    'Current-membership projection of credited XP over immutable reporting periods. '
    'Departure hides retained history until rejoin. Earning-role loss does not erase '
    'awards; any additional role-based board eligibility is a future explicit policy.';
