-- Guild owns both operational control state and the CoC activity stars.
-- A collection timestamp is evidence, not the time an in-game action occurred.

CREATE TABLE guild.clan_collection_settings (
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    enabled boolean NOT NULL DEFAULT true,
    membership_poll_seconds integer NOT NULL DEFAULT 120 CHECK (membership_poll_seconds > 0),
    raid_report_seconds integer NOT NULL DEFAULT 28800 CHECK (raid_report_seconds > 0),
    PRIMARY KEY (guild_key, clan_key)
);
CREATE TABLE guild.war_reminder_setting (
    guild_key bigint NOT NULL,
    clan_key bigint NOT NULL,
    seconds_before_end integer NOT NULL CHECK (seconds_before_end > 0),
    PRIMARY KEY (guild_key, clan_key, seconds_before_end),
    FOREIGN KEY (guild_key, clan_key) REFERENCES guild.clan_collection_settings
);
COMMENT ON TABLE guild.war_reminder_setting IS
    'Per-clan offsets; initial application configuration should insert 28800 and 14400 seconds.';

CREATE TABLE guild.clan_membership_poll (
    poll_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL,
    clan_key bigint NOT NULL,
    source_correlation_id text NOT NULL UNIQUE CHECK (source_correlation_id <> ''),
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    outcome text NOT NULL CHECK (outcome IN ('complete', 'incomplete', 'failed')),
    failure_code text,
    FOREIGN KEY (guild_key, clan_key) REFERENCES guild.clan_collection_settings,
    UNIQUE (poll_key, guild_key, clan_key),
    CHECK (outcome <> 'failed' OR failure_code IS NOT NULL)
);
CREATE TABLE guild.fact_clan_member_observation (
    poll_key bigint NOT NULL REFERENCES guild.clan_membership_poll,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    in_game_role text,
    PRIMARY KEY (poll_key, player_key)
);
CREATE TABLE guild.fact_clan_membership_change (
    membership_change_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    poll_key bigint NOT NULL,
    guild_key bigint NOT NULL,
    clan_key bigint NOT NULL,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    change_kind text NOT NULL CHECK (change_kind IN ('observed_join', 'observed_departure')),
    previous_success_at timestamptz,
    observed_at timestamptz NOT NULL,
    FOREIGN KEY (poll_key, guild_key, clan_key)
        REFERENCES guild.clan_membership_poll (poll_key, guild_key, clan_key),
    UNIQUE (poll_key, player_key, change_kind),
    CHECK (previous_success_at IS NULL OR previous_success_at <= observed_at)
);
CREATE FUNCTION guild.require_complete_membership_poll() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM guild.clan_membership_poll p
        WHERE p.poll_key = NEW.poll_key AND p.outcome = 'complete'
            AND p.observed_at = NEW.observed_at
    ) THEN
        RAISE EXCEPTION 'Membership changes require a complete poll at the same observation time'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER membership_change_complete_poll BEFORE INSERT OR UPDATE
ON guild.fact_clan_membership_change FOR EACH ROW
EXECUTE FUNCTION guild.require_complete_membership_poll();

CREATE TABLE guild.observed_clan_membership_period (
    membership_period_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    clan_key bigint NOT NULL,
    observed_since timestamptz NOT NULL,
    observed_until timestamptz,
    confirmed_through timestamptz NOT NULL,
    boundary_policy text NOT NULL CHECK (boundary_policy <> ''),
    coverage_status text NOT NULL CHECK (coverage_status IN ('adequate', 'insufficient_data')),
    first_poll_key bigint NOT NULL,
    last_poll_key bigint NOT NULL,
    FOREIGN KEY (guild_key, clan_key) REFERENCES guild.clan_collection_settings,
    FOREIGN KEY (first_poll_key, guild_key, clan_key)
        REFERENCES guild.clan_membership_poll (poll_key, guild_key, clan_key),
    FOREIGN KEY (last_poll_key, guild_key, clan_key)
        REFERENCES guild.clan_membership_poll (poll_key, guild_key, clan_key),
    CHECK (observed_until IS NULL OR observed_until > observed_since),
    CHECK (confirmed_through >= observed_since),
    CHECK (observed_until IS NULL OR confirmed_through <= observed_until),
    EXCLUDE USING gist (guild_key WITH =, player_key WITH =,
        tstzrange(observed_since, observed_until, '[)') WITH &&)
);
COMMENT ON TABLE guild.observed_clan_membership_period IS
    'Derived observation-based intervals, not exact game join times. Failed polling must not close a period. '
    'confirmed_through bounds evidence; open periods must not silently extrapolate to now.';
CREATE FUNCTION guild.validate_membership_period_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT FROM guild.clan_membership_poll p
                    WHERE p.poll_key = NEW.first_poll_key AND p.outcome = 'complete'
                        AND p.observed_at <= NEW.observed_since)
        OR NOT EXISTS (SELECT FROM guild.clan_membership_poll p
                        WHERE p.poll_key = NEW.last_poll_key AND p.outcome = 'complete'
                        AND p.observed_at = NEW.confirmed_through) THEN
        RAISE EXCEPTION 'Membership periods require complete, temporally consistent poll evidence'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER membership_period_evidence BEFORE INSERT OR UPDATE ON guild.observed_clan_membership_period
FOR EACH ROW EXECUTE FUNCTION guild.validate_membership_period_evidence();
CREATE VIEW guild.current_observed_clan_member AS
SELECT guild_key, player_key, clan_key, observed_since, confirmed_through, coverage_status
FROM guild.observed_clan_membership_period WHERE observed_until IS NULL;
CREATE FUNCTION guild.is_currently_tracked_player(p_guild_key bigint, p_player_key bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT FROM guild.current_observed_clan_member m
        JOIN guild.clan_collection_settings s USING (guild_key, clan_key)
        WHERE m.guild_key = p_guild_key AND m.player_key = p_player_key
            AND s.enabled AND m.coverage_status = 'adequate'
    )
$$;

CREATE TABLE guild.dim_war (
    war_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clan_a_key bigint NOT NULL REFERENCES guild.dim_clan,
    clan_b_key bigint NOT NULL REFERENCES guild.dim_clan,
    preparation_started_at timestamptz NOT NULL,
    started_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    team_size smallint NOT NULL CHECK (team_size > 0),
    attacks_per_member smallint NOT NULL CHECK (attacks_per_member > 0),
    identity_source text NOT NULL CHECK (identity_source IN ('clan_pair_preparation', 'manual_validated')),
    UNIQUE (clan_a_key, clan_b_key, preparation_started_at),
    CHECK (clan_a_key < clan_b_key),
    CHECK (preparation_started_at <= started_at AND started_at < ends_at)
);
COMMENT ON TABLE guild.dim_war IS
    'Local regular-war identity. Canonical sorted clan pair + preparation timestamp is a deduplication '
    'policy to validate against live responses; no assumption of a universal API warTag.';
CREATE TABLE guild.fact_war_observation (
    war_key bigint NOT NULL REFERENCES guild.dim_war,
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    source_payload jsonb NOT NULL CHECK (jsonb_typeof(source_payload) = 'object'),
    PRIMARY KEY (war_key, observed_at),
    CHECK (NOT jsonb_path_exists(source_payload, '$.**.token'))
);
COMMENT ON TABLE guild.fact_war_observation IS
    'Complete sanitized regular-war response for retaining available fields beyond typed projections. '
    'Only regular-war responses belong here; never persist verification request/response tokens.';
CREATE TABLE guild.war_participant (
    war_key bigint NOT NULL REFERENCES guild.dim_war,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    PRIMARY KEY (war_key, player_key),
    UNIQUE (war_key, clan_key, player_key)
);
CREATE FUNCTION guild.require_war_side() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT FROM guild.dim_war w WHERE w.war_key = NEW.war_key
                    AND NEW.clan_key IN (w.clan_a_key, w.clan_b_key)) THEN
        RAISE EXCEPTION 'Participant clan is not a side of this war' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER war_participant_side BEFORE INSERT OR UPDATE ON guild.war_participant
FOR EACH ROW EXECUTE FUNCTION guild.require_war_side();
CREATE TABLE guild.fact_war_roster_observation (
    war_key bigint NOT NULL,
    clan_key bigint NOT NULL,
    player_key bigint NOT NULL,
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    player_name text NOT NULL,
    town_hall_level smallint NOT NULL CHECK (town_hall_level > 0),
    map_position smallint NOT NULL CHECK (map_position > 0),
    opponent_attacks smallint CHECK (opponent_attacks >= 0),
    PRIMARY KEY (war_key, player_key, observed_at),
    FOREIGN KEY (war_key, clan_key, player_key) REFERENCES guild.war_participant (war_key, clan_key, player_key)
);
CREATE TABLE guild.fact_war_clan_observation (
    war_key bigint NOT NULL REFERENCES guild.dim_war,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    observed_at timestamptz NOT NULL,
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    state text NOT NULL CHECK (state IN ('preparation', 'inWar', 'warEnded')),
    stars integer NOT NULL CHECK (stars >= 0),
    attacks integer NOT NULL CHECK (attacks >= 0),
    destruction_percentage numeric(8,5) NOT NULL CHECK (destruction_percentage BETWEEN 0 AND 100),
    PRIMARY KEY (war_key, clan_key, observed_at)
);
CREATE TRIGGER war_clan_observation_side BEFORE INSERT OR UPDATE ON guild.fact_war_clan_observation
FOR EACH ROW EXECUTE FUNCTION guild.require_war_side();
CREATE TABLE guild.fact_war_attack (
    attack_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    war_key bigint NOT NULL REFERENCES guild.dim_war,
    attacker_key bigint NOT NULL REFERENCES guild.dim_player_account,
    defender_key bigint NOT NULL REFERENCES guild.dim_player_account,
    attack_order integer NOT NULL CHECK (attack_order > 0),
    stars smallint NOT NULL CHECK (stars BETWEEN 0 AND 3),
    destruction_percentage numeric(8,5) NOT NULL CHECK (destruction_percentage BETWEEN 0 AND 100),
    duration_seconds integer CHECK (duration_seconds >= 0),
    occurred_at timestamptz,
    first_observed_at timestamptz NOT NULL,
    last_observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    UNIQUE (war_key, attack_order),
    FOREIGN KEY (war_key, attacker_key) REFERENCES guild.war_participant,
    FOREIGN KEY (war_key, defender_key) REFERENCES guild.war_participant,
    CHECK (attacker_key <> defender_key),
    CHECK (first_observed_at <= last_observed_at)
);
COMMENT ON COLUMN guild.fact_war_attack.occurred_at IS
    'Nullable: API attack duration is not an occurrence timestamp. Never substitute observation time.';
CREATE FUNCTION guild.require_opposing_war_accounts() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT clan_key FROM guild.war_participant WHERE war_key = NEW.war_key AND player_key = NEW.attacker_key)
        = (SELECT clan_key FROM guild.war_participant WHERE war_key = NEW.war_key AND player_key = NEW.defender_key) THEN
        RAISE EXCEPTION 'War attack must target the opposing clan' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER war_attack_opposing_sides BEFORE INSERT OR UPDATE ON guild.fact_war_attack
FOR EACH ROW EXECUTE FUNCTION guild.require_opposing_war_accounts();

CREATE TABLE guild.fact_player_counter_observation (
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    town_hall_level smallint CHECK (town_hall_level > 0),
    war_stars bigint CHECK (war_stars >= 0),
    trophies integer CHECK (trophies >= 0),
    donations bigint CHECK (donations >= 0),
    donations_received bigint CHECK (donations_received >= 0),
    clan_capital_contributions bigint CHECK (clan_capital_contributions >= 0),
    PRIMARY KEY (player_key, observed_at)
);
COMMENT ON TABLE guild.fact_player_counter_observation IS
    'Profile snapshots are nonadditive across time. Counter differences require period baselines '
    'and explicit handling of resets. clan_capital_contributions is donations, NOT raid loot.';
CREATE TABLE guild.dim_achievement (
    achievement_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_name text NOT NULL,
    village text NOT NULL,
    UNIQUE (source_name, village)
);
CREATE TABLE guild.fact_player_achievement_observation (
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    achievement_key bigint NOT NULL REFERENCES guild.dim_achievement,
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    value bigint NOT NULL CHECK (value >= 0),
    target bigint CHECK (target >= 0),
    stars smallint CHECK (stars BETWEEN 0 AND 3),
    PRIMARY KEY (player_key, achievement_key, observed_at)
);
CREATE VIEW guild.latest_player_counter AS
SELECT DISTINCT ON (player_key) * FROM guild.fact_player_counter_observation
ORDER BY player_key, observed_at DESC;
CREATE VIEW guild.current_clan_lifetime_war_stars AS
SELECT m.guild_key, m.clan_key, m.player_key, p.war_stars, p.observed_at AS counter_observed_at,
        m.confirmed_through AS membership_confirmed_through,
        dense_rank() OVER (PARTITION BY m.guild_key, m.clan_key ORDER BY p.war_stars DESC) AS position
FROM guild.current_observed_clan_member m
JOIN guild.latest_player_counter p USING (player_key)
WHERE p.war_stars IS NOT NULL;
COMMENT ON VIEW guild.current_clan_lifetime_war_stars IS
    'Current-clan eligibility first; latest lifetime counter includes stars from all clans. '
    'Observation freshness remains visible; this view does not invent a missing-data tolerance.';

CREATE TABLE guild.clan_games_schedule (
    guild_key bigint PRIMARY KEY REFERENCES guild.dim_guild,
    enabled boolean NOT NULL DEFAULT true,
    start_day smallint NOT NULL DEFAULT 22 CHECK (start_day BETWEEN 1 AND 31),
    start_time_utc time NOT NULL DEFAULT '08:00',
    event_seconds integer NOT NULL DEFAULT 518400 CHECK (event_seconds > 86400),
    account_points_cap integer NOT NULL DEFAULT 4000 CHECK (account_points_cap > 0)
);
CREATE TABLE guild.dim_clan_games_event (
    event_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    account_points_cap integer NOT NULL CHECK (account_points_cap > 0),
    schedule_source text NOT NULL CHECK (schedule_source IN ('configured_schedule', 'manual')),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    UNIQUE (guild_key, starts_at),
    UNIQUE (event_key, guild_key),
    CHECK (ends_at > starts_at + interval '24 hours')
);
COMMENT ON TABLE guild.dim_clan_games_event IS
    'Schedule/cap are configured evidence, not verified API calendar metadata. Freeze event values '
    'when creating the event; changing the recurring schedule must not rewrite past events.';
CREATE FUNCTION guild.create_scheduled_clan_games(p_guild_key bigint, p_year integer, p_month integer)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE s guild.clan_games_schedule; event_start timestamptz; result_key bigint;
BEGIN
    SELECT * INTO STRICT s FROM guild.clan_games_schedule WHERE guild_key = p_guild_key AND enabled;
    event_start := (make_date(p_year, p_month, s.start_day) + s.start_time_utc) AT TIME ZONE 'UTC';
    INSERT INTO guild.dim_clan_games_event
        (guild_key, starts_at, ends_at, account_points_cap, schedule_source, source_correlation_id)
    VALUES (p_guild_key, event_start, event_start + make_interval(secs => s.event_seconds),
            s.account_points_cap, 'configured_schedule', 'schedule:' || p_year || ':' || p_month)
    ON CONFLICT (guild_key, starts_at) DO NOTHING RETURNING event_key INTO result_key;
    IF result_key IS NULL THEN
        SELECT event_key INTO result_key FROM guild.dim_clan_games_event
        WHERE guild_key = p_guild_key AND starts_at = event_start;
    END IF;
    RETURN result_key;
END;
$$;
CREATE FUNCTION guild.clan_games_observed_target(p_event_key bigint, p_player_key bigint, p_checkpoint timestamptz)
RETURNS TABLE (observed_seconds numeric, required_points numeric)
LANGUAGE sql STABLE AS $$
    WITH e AS (
        SELECT * FROM guild.dim_clan_games_event WHERE event_key = p_event_key
    ), clipped AS (
        SELECT range_agg(tstzrange(greatest(m.observed_since, e.starts_at),
                    least(coalesce(m.observed_until, m.confirmed_through), m.confirmed_through,
                        e.ends_at, p_checkpoint), '[)')) AS periods
        FROM e JOIN guild.observed_clan_membership_period m ON m.guild_key = e.guild_key
        WHERE m.player_key = p_player_key
            AND m.observed_since < least(m.confirmed_through, e.ends_at, p_checkpoint)
            AND greatest(m.observed_since, e.starts_at)
                < least(coalesce(m.observed_until, m.confirmed_through), m.confirmed_through, e.ends_at, p_checkpoint)
    ), seconds AS (
        SELECT coalesce(sum(extract(epoch FROM upper(r) - lower(r))), 0)::numeric AS value
        FROM clipped CROSS JOIN LATERAL unnest(periods) AS r
    )
    SELECT s.value, 0.10::numeric * e.account_points_cap * s.value
            / extract(epoch FROM e.ends_at - e.starts_at)
    FROM seconds s CROSS JOIN e
$$;
COMMENT ON FUNCTION guild.clan_games_observed_target IS
    'Unrounded mathematical target only. Union observed intervals across tracked clans, clip to '
    'checkpoint/event, never extrapolate an ongoing interval beyond confirmed_through. A zero '
    'does not establish adequate evidence. Attribution, tolerance and rounding are deliberately separate.';

CREATE TABLE guild.fact_clan_games_progress (
    progress_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.dim_clan_games_event,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    measurement_method text NOT NULL CHECK (measurement_method IN ('achievement_delta', 'manual_evidence', 'verified_event_source')),
    evidence_status text NOT NULL CHECK (evidence_status IN ('adequate', 'insufficient_data')),
    points integer CHECK (points >= 0),
    baseline_achievement_key bigint,
    baseline_observed_at timestamptz,
    ending_achievement_key bigint,
    ending_observed_at timestamptz,
    evidence_note text NOT NULL CHECK (evidence_note <> ''),
    UNIQUE (event_key, player_key, observed_at),
    UNIQUE (progress_key, event_key, player_key),
    FOREIGN KEY (player_key, baseline_achievement_key, baseline_observed_at)
        REFERENCES guild.fact_player_achievement_observation (player_key, achievement_key, observed_at),
    FOREIGN KEY (player_key, ending_achievement_key, ending_observed_at)
        REFERENCES guild.fact_player_achievement_observation (player_key, achievement_key, observed_at),
    CHECK (evidence_status <> 'adequate' OR points IS NOT NULL),
    CHECK (baseline_observed_at IS NULL OR baseline_observed_at <= observed_at),
    CHECK (ending_observed_at IS NULL OR ending_observed_at <= observed_at),
    CHECK (measurement_method <> 'achievement_delta' OR evidence_status <> 'adequate' OR
        (baseline_achievement_key IS NOT NULL AND ending_achievement_key = baseline_achievement_key
            AND baseline_observed_at IS NOT NULL AND ending_observed_at >= baseline_observed_at))
);
CREATE FUNCTION guild.validate_clan_games_progress() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cap integer; baseline_value bigint; ending_value bigint;
BEGIN
    SELECT account_points_cap INTO cap FROM guild.dim_clan_games_event WHERE event_key = NEW.event_key;
    IF NEW.points > cap THEN
        RAISE EXCEPTION 'Event points exceed configured account cap' USING ERRCODE = '23514';
    END IF;
    IF NEW.measurement_method = 'achievement_delta' AND NEW.evidence_status = 'adequate' THEN
        SELECT value INTO baseline_value FROM guild.fact_player_achievement_observation
        WHERE player_key = NEW.player_key AND achievement_key = NEW.baseline_achievement_key AND observed_at = NEW.baseline_observed_at;
        SELECT value INTO ending_value FROM guild.fact_player_achievement_observation
        WHERE player_key = NEW.player_key AND achievement_key = NEW.ending_achievement_key AND observed_at = NEW.ending_observed_at;
        IF ending_value - baseline_value IS DISTINCT FROM NEW.points::bigint OR ending_value < baseline_value THEN
            RAISE EXCEPTION 'Achievement evidence must support the nonnegative points difference' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_progress_evidence BEFORE INSERT OR UPDATE ON guild.fact_clan_games_progress
FOR EACH ROW EXECUTE FUNCTION guild.validate_clan_games_progress();
CREATE VIEW guild.latest_clan_games_progress AS
SELECT DISTINCT ON (event_key, player_key) * FROM guild.fact_clan_games_progress
ORDER BY event_key, player_key, observed_at DESC;

CREATE TABLE guild.fact_clan_games_account_assessment (
    account_assessment_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.dim_clan_games_event,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    checkpoint_kind text NOT NULL CHECK (checkpoint_kind IN ('t_minus_24h', 'final')),
    checkpoint_at timestamptz NOT NULL,
    calculation_version integer NOT NULL CHECK (calculation_version > 0),
    calculated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    rule_version text NOT NULL CHECK (rule_version <> ''),
    attribution_policy text NOT NULL CHECK (attribution_policy <> ''),
    membership_status text NOT NULL CHECK (membership_status IN ('adequate', 'insufficient_data')),
    points_status text NOT NULL CHECK (points_status IN ('adequate', 'insufficient_data')),
    attribution_status text NOT NULL CHECK (attribution_status IN ('adequate', 'insufficient_data')),
    progress_key bigint,
    observed_seconds numeric NOT NULL CHECK (observed_seconds >= 0),
    eligible_points numeric CHECK (eligible_points >= 0),
    required_points numeric NOT NULL CHECK (required_points >= 0),
    evidence_note text NOT NULL CHECK (evidence_note <> ''),
    result text GENERATED ALWAYS AS (
        CASE WHEN membership_status <> 'adequate' OR points_status <> 'adequate'
                    OR attribution_status <> 'adequate' OR eligible_points IS NULL
                THEN 'insufficient_data'
                WHEN eligible_points >= required_points THEN 'pass' ELSE 'fail' END
    ) STORED,
    UNIQUE (event_key, player_key, checkpoint_kind, calculation_version),
    UNIQUE (account_assessment_key, event_key, player_key, checkpoint_kind),
    FOREIGN KEY (progress_key, event_key, player_key)
        REFERENCES guild.fact_clan_games_progress (progress_key, event_key, player_key),
    CHECK (points_status <> 'adequate' OR progress_key IS NOT NULL)
);
CREATE FUNCTION guild.validate_clan_games_assessment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e guild.dim_clan_games_event; maximum_points numeric; supported_seconds numeric;
BEGIN
    SELECT * INTO e FROM guild.dim_clan_games_event WHERE event_key = NEW.event_key;
    IF NEW.checkpoint_at IS DISTINCT FROM
        (CASE NEW.checkpoint_kind WHEN 'final' THEN e.ends_at ELSE e.ends_at - interval '24 hours' END) THEN
        RAISE EXCEPTION 'Assessment checkpoint must match the event boundary' USING ERRCODE = '23514';
    END IF;
    IF NEW.observed_seconds > extract(epoch FROM NEW.checkpoint_at - e.starts_at)
        OR NEW.required_points IS DISTINCT FROM
            (0.10::numeric * e.account_points_cap * NEW.observed_seconds / extract(epoch FROM e.ends_at - e.starts_at)) THEN
        RAISE EXCEPTION 'Requirement must be unrounded 10 percent of cap prorated over full event duration' USING ERRCODE = '23514';
    END IF;
    IF NEW.points_status = 'adequate' THEN
        SELECT points INTO maximum_points FROM guild.fact_clan_games_progress
        WHERE progress_key = NEW.progress_key AND evidence_status = 'adequate'
            AND observed_at <= NEW.checkpoint_at;
        IF maximum_points IS NULL OR NEW.eligible_points IS NULL OR NEW.eligible_points > maximum_points THEN
            RAISE EXCEPTION 'Adequate assessment requires supported eligible points' USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.membership_status = 'adequate' THEN
        SELECT observed_seconds INTO supported_seconds
        FROM guild.clan_games_observed_target(NEW.event_key, NEW.player_key, NEW.checkpoint_at);
        IF NEW.observed_seconds > supported_seconds THEN
            RAISE EXCEPTION 'Assessment membership time exceeds observed evidence' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_assessment_evidence BEFORE INSERT OR UPDATE ON guild.fact_clan_games_account_assessment
FOR EACH ROW EXECUTE FUNCTION guild.validate_clan_games_assessment();
CREATE TABLE guild.fact_clan_games_member_assessment (
    member_assessment_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.dim_clan_games_event,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    checkpoint_kind text NOT NULL CHECK (checkpoint_kind IN ('t_minus_24h', 'final')),
    calculation_version integer NOT NULL CHECK (calculation_version > 0),
    calculated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    attribution_policy text NOT NULL CHECK (attribution_policy <> ''),
    attribution_status text NOT NULL CHECK (attribution_status IN ('adequate', 'insufficient_data')),
    evidence_note text NOT NULL CHECK (evidence_note <> ''),
    UNIQUE (event_key, user_key, checkpoint_kind, calculation_version),
    UNIQUE (member_assessment_key, event_key, checkpoint_kind),
    UNIQUE (member_assessment_key, event_key, checkpoint_kind, user_key)
);
CREATE TABLE guild.clan_games_member_account_input (
    member_assessment_key bigint NOT NULL,
    account_assessment_key bigint NOT NULL,
    event_key bigint NOT NULL,
    checkpoint_kind text NOT NULL,
    player_key bigint NOT NULL,
    attribution_key bigint,
    guild_key bigint NOT NULL,
    user_key bigint NOT NULL,
    PRIMARY KEY (member_assessment_key, player_key),
    FOREIGN KEY (member_assessment_key, event_key, checkpoint_kind, user_key)
        REFERENCES guild.fact_clan_games_member_assessment (member_assessment_key, event_key, checkpoint_kind, user_key),
    FOREIGN KEY (event_key, guild_key)
        REFERENCES guild.dim_clan_games_event (event_key, guild_key),
    FOREIGN KEY (account_assessment_key, event_key, player_key, checkpoint_kind)
        REFERENCES guild.fact_clan_games_account_assessment (account_assessment_key, event_key, player_key, checkpoint_kind),
    FOREIGN KEY (attribution_key, guild_key, user_key, player_key)
        REFERENCES guild.metric_attribution_episode (attribution_key, guild_key, user_key, player_key)
);
CREATE FUNCTION guild.validate_clan_games_member_input() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE expected_guild bigint; expected_user bigint; attribution_status text;
BEGIN
    SELECT e.guild_key, m.user_key, m.attribution_status
    INTO expected_guild, expected_user, attribution_status
    FROM guild.fact_clan_games_member_assessment m
    JOIN guild.dim_clan_games_event e USING (event_key)
    WHERE m.member_assessment_key = NEW.member_assessment_key;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Member assessment does not exist' USING ERRCODE = '23503';
    END IF;
    IF (NEW.guild_key IS NOT NULL AND NEW.guild_key <> expected_guild)
        OR (NEW.user_key IS NOT NULL AND NEW.user_key <> expected_user)
        OR (attribution_status = 'adequate' AND NEW.attribution_key IS NULL) THEN
        RAISE EXCEPTION 'Member input must identify its member, guild and supported attribution episode'
            USING ERRCODE = '23514';
    END IF;
    NEW.guild_key := expected_guild;
    NEW.user_key := expected_user;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_member_input_attribution BEFORE INSERT OR UPDATE ON guild.clan_games_member_account_input
FOR EACH ROW EXECUTE FUNCTION guild.validate_clan_games_member_input();
CREATE VIEW guild.clan_games_member_result AS
SELECT m.member_assessment_key, m.event_key, m.user_key, m.checkpoint_kind, m.calculation_version,
        count(a.account_assessment_key) AS account_count,
        sum(a.eligible_points) AS eligible_points,
        sum(a.required_points) AS required_points,
        CASE WHEN m.attribution_status <> 'adequate' OR count(a.account_assessment_key) = 0
                    OR bool_or(i.attribution_key IS NULL)
                    OR bool_or(a.result = 'insufficient_data') THEN 'insufficient_data'
            WHEN sum(a.eligible_points) >= sum(a.required_points) THEN 'pass' ELSE 'fail' END AS result
FROM guild.fact_clan_games_member_assessment m
LEFT JOIN guild.clan_games_member_account_input i USING (member_assessment_key)
LEFT JOIN guild.fact_clan_games_account_assessment a USING (account_assessment_key)
GROUP BY m.member_assessment_key;
COMMENT ON TABLE guild.clan_games_member_account_input IS
    'Explicit, deduplicated assessment inputs. Account-link attribution intersections and gap/transfer '
    'rules remain unresolved. Do not infer eligibility merely from the current Discord link.';
COMMENT ON VIEW guild.clan_games_member_result IS
    'Leadership-only application projection: sums per-account targets once across clans; no exemptions. '
    'Application authorization must gate pass/fail; generic database membership is not authorization.';

CREATE TABLE guild.dim_raid_weekend (
    raid_weekend_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    UNIQUE (clan_key, starts_at),
    CHECK (starts_at < ends_at)
);
CREATE TABLE guild.fact_raid_member_observation (
    raid_weekend_key bigint NOT NULL REFERENCES guild.dim_raid_weekend,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    capital_resources_looted bigint NOT NULL CHECK (capital_resources_looted >= 0),
    PRIMARY KEY (raid_weekend_key, player_key, observed_at)
);
CREATE VIEW guild.latest_raid_member_total AS
SELECT DISTINCT ON (raid_weekend_key, player_key) * FROM guild.fact_raid_member_observation
ORDER BY raid_weekend_key, player_key, observed_at DESC;
COMMENT ON VIEW guild.latest_raid_member_total IS
    'Per-account latest weekend total, never summed across observations or Discord alts. '
    'Source is raid-member capitalResourcesLooted, not profile clanCapitalContributions.';

CREATE INDEX player_counter_observation_recent ON guild.fact_player_counter_observation (observed_at DESC);
CREATE INDEX achievement_observation_recent ON guild.fact_player_achievement_observation (achievement_key, observed_at DESC);
CREATE INDEX war_attack_attacker ON guild.fact_war_attack (attacker_key, war_key);
CREATE INDEX war_attack_defender ON guild.fact_war_attack (defender_key, war_key);
CREATE INDEX membership_poll_recent ON guild.clan_membership_poll (guild_key, clan_key, observed_at DESC);
