-- Guild owns both operational control state and the CoC activity stars.
-- A collection timestamp is evidence, not the time an in-game action occurred.

CREATE TABLE guild.clan_collection_settings (
    clan_key bigint PRIMARY KEY REFERENCES guild.dim_clan,
    enabled boolean NOT NULL DEFAULT true,
    membership_poll_seconds integer NOT NULL DEFAULT 120 CHECK (membership_poll_seconds > 0),
    raid_report_seconds integer NOT NULL DEFAULT 28800 CHECK (raid_report_seconds > 0),
    automatic_freeze_minutes integer NOT NULL DEFAULT 60 CHECK (automatic_freeze_minutes >= 0),
    sheet_document_id text
);
CREATE TABLE guild.war_reminder_setting (
    clan_key bigint NOT NULL REFERENCES guild.clan_collection_settings,
    seconds_before_end integer NOT NULL CHECK (seconds_before_end > 0),
    PRIMARY KEY (clan_key, seconds_before_end)
);
COMMENT ON TABLE guild.war_reminder_setting IS
    'Per-clan offsets; initial application configuration should insert 28800 and 14400 seconds.';

CREATE TABLE guild.clan_membership_poll (
    poll_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clan_key bigint NOT NULL REFERENCES guild.clan_collection_settings,
    source_correlation_id text NOT NULL UNIQUE CHECK (source_correlation_id <> ''),
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    outcome text NOT NULL CHECK (outcome IN ('complete', 'incomplete', 'failed')),
    failure_code text,
    UNIQUE (poll_key, clan_key),
    CHECK (outcome <> 'failed' OR failure_code IS NOT NULL)
);
CREATE TABLE guild.fact_clan_member_observation (
    poll_key bigint NOT NULL REFERENCES guild.clan_membership_poll,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    in_game_role text,
    donations bigint CHECK (donations >= 0),
    donations_received bigint CHECK (donations_received >= 0),
    PRIMARY KEY (poll_key, player_key)
);
COMMENT ON TABLE guild.fact_clan_member_observation IS
    'The state of one clan member as one poll saw it: role and season-to-date donation counters. '
    'A row is stored only when the state changed; record_clan_member_observation decides. '
    'clan_membership_poll has one row for every poll and proves that the poll ran. A member '
    'without a row for a poll had the state of their latest earlier row.';
CREATE TABLE guild.fact_clan_membership_change (
    membership_change_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    poll_key bigint NOT NULL,
    clan_key bigint NOT NULL,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    change_kind text NOT NULL CHECK (change_kind IN ('observed_join', 'observed_departure')),
    previous_success_at timestamptz,
    observed_at timestamptz NOT NULL,
    FOREIGN KEY (poll_key, clan_key) REFERENCES guild.clan_membership_poll (poll_key, clan_key),
    UNIQUE (poll_key, player_key, change_kind),
    CHECK (previous_success_at IS NULL OR previous_success_at <= observed_at)
);
CREATE FUNCTION guild.require_complete_membership_poll() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
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
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    clan_key bigint NOT NULL,
    observed_since timestamptz NOT NULL,
    observed_until timestamptz,
    confirmed_through timestamptz NOT NULL,
    boundary_policy text NOT NULL CHECK (boundary_policy <> ''),
    coverage_status text NOT NULL CHECK (coverage_status IN ('adequate', 'insufficient_data')),
    first_poll_key bigint NOT NULL,
    last_poll_key bigint NOT NULL,
    FOREIGN KEY (clan_key) REFERENCES guild.clan_collection_settings,
    FOREIGN KEY (first_poll_key, clan_key) REFERENCES guild.clan_membership_poll (poll_key, clan_key),
    FOREIGN KEY (last_poll_key, clan_key) REFERENCES guild.clan_membership_poll (poll_key, clan_key),
    CHECK (observed_until IS NULL OR observed_until > observed_since),
    CHECK (confirmed_through >= observed_since),
    CHECK (observed_until IS NULL OR confirmed_through <= observed_until),
    EXCLUDE USING gist (player_key WITH =,
        tstzrange(observed_since, observed_until, '[)') WITH &&)
);
CREATE FUNCTION guild.validate_membership_period_evidence() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
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

-- A period cannot leave current membership because a worker supplies an
-- arbitrary end time. The observed_departure fact is the durable closure
-- proof, and its source poll must be complete at exactly that boundary.
-- Failed or incomplete polls cannot produce a departure.
CREATE INDEX membership_departure_boundary
ON guild.fact_clan_membership_change (clan_key, player_key, observed_at)
WHERE change_kind = 'observed_departure';

CREATE FUNCTION guild.membership_has_closing_evidence(
    p_clan_key bigint, p_player_key bigint, p_observed_until timestamptz
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT EXISTS (
        SELECT FROM guild.fact_clan_membership_change c
        JOIN guild.clan_membership_poll p
            ON p.poll_key = c.poll_key AND p.clan_key = c.clan_key
        WHERE c.clan_key = p_clan_key
            AND c.player_key = p_player_key AND c.change_kind = 'observed_departure'
            AND c.observed_at = p_observed_until
            AND p.observed_at = p_observed_until AND p.outcome = 'complete'
    );
$$;

CREATE FUNCTION guild.require_membership_closing_evidence() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.player_key, NEW.clan_key, NEW.observed_since, NEW.first_poll_key)
            IS DISTINCT FROM
            (OLD.player_key, OLD.clan_key, OLD.observed_since, OLD.first_poll_key) THEN
            RAISE EXCEPTION 'Membership period identity and first observation cannot be rewritten'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.confirmed_through < OLD.confirmed_through THEN
            RAISE EXCEPTION 'Out-of-order evidence cannot rewind confirmed membership'
                USING ERRCODE = '23514';
        END IF;
        IF OLD.observed_until IS NOT NULL AND NEW.observed_until IS DISTINCT FROM OLD.observed_until THEN
            RAISE EXCEPTION 'Closed membership boundaries cannot be rewritten; record a new membership interval'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.observed_until IS NOT NULL AND NOT guild.membership_has_closing_evidence(
        NEW.clan_key, NEW.player_key, NEW.observed_until
    ) THEN
        RAISE EXCEPTION 'Closing membership requires an observed departure from a complete poll at the exact boundary'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER membership_period_closing_evidence BEFORE INSERT OR UPDATE
ON guild.observed_clan_membership_period FOR EACH ROW
EXECUTE FUNCTION guild.require_membership_closing_evidence();
COMMENT ON TABLE guild.observed_clan_membership_period IS
    'Derived observation-based intervals, not exact game join times. Closing requires a matching '
    'observed_departure from a complete poll at observed_until. confirmed_through remains the '
    'last positive coverage boundary and may precede closing evidence; it must not rewind. '
    'An API failure or incomplete response must not close a current period.';
CREATE VIEW guild.current_observed_clan_member AS
SELECT player_key, clan_key, observed_since, confirmed_through, coverage_status
FROM guild.observed_clan_membership_period WHERE observed_until IS NULL;
CREATE FUNCTION guild.is_currently_tracked_player(p_player_key bigint)
RETURNS boolean LANGUAGE sql STABLE
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT EXISTS (
        SELECT FROM guild.current_observed_clan_member m
        JOIN guild.clan_collection_settings s USING (clan_key)
        WHERE m.player_key = p_player_key
            AND s.enabled AND m.coverage_status = 'adequate'
    )
$$;

-- The game resets the donation counters of the clan member list when a
-- season ends. The project owner chose a fixed calendar for that boundary:
-- the last Monday of the month at 05:00 UTC. The seasons are stored so that
-- a row can be corrected if the game departs from the rule.
CREATE TABLE guild.dim_coc_season (
    season_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    season_month date NOT NULL UNIQUE CHECK (extract(day FROM season_month) = 1),
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    CHECK (starts_at < ends_at),
    EXCLUDE USING gist (tstzrange(starts_at, ends_at, '[)') WITH &&)
);
COMMENT ON TABLE guild.dim_coc_season IS
    'One game season, named by the month in which it ends. ensure_coc_season creates a row from '
    'the calendar rule. The seasons are the same for every guild.';
CREATE FUNCTION guild.coc_season_end(p_month date) RETURNS timestamptz
LANGUAGE sql IMMUTABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT (date_trunc('week', date_trunc('month', p_month::timestamp) + interval '1 month - 1 day')
        + interval '5 hours') AT TIME ZONE 'UTC'
$$;
COMMENT ON FUNCTION guild.coc_season_end IS
    'The calendar rule: the last Monday of the month of p_month at 05:00 UTC.';
CREATE FUNCTION guild.ensure_coc_season(p_at timestamptz DEFAULT clock_timestamp()) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    result bigint;
    month_start date := date_trunc('month', p_at AT TIME ZONE 'UTC')::date;
    ending date;
BEGIN
    SELECT season_key INTO result FROM guild.dim_coc_season
    WHERE starts_at <= p_at AND ends_at > p_at;
    IF FOUND THEN RETURN result; END IF;
    ending := CASE WHEN p_at < guild.coc_season_end(month_start) THEN month_start
        ELSE (month_start + interval '1 month')::date END;
    INSERT INTO guild.dim_coc_season (season_month, starts_at, ends_at)
    VALUES (ending, guild.coc_season_end((ending - interval '1 month')::date),
        guild.coc_season_end(ending))
    ON CONFLICT (season_month) DO NOTHING RETURNING season_key INTO result;
    IF result IS NULL THEN
        SELECT season_key INTO STRICT result FROM guild.dim_coc_season WHERE season_month = ending;
    END IF;
    RETURN result;
END;
$$;
COMMENT ON FUNCTION guild.ensure_coc_season IS
    'Returns the season that contains p_at and creates its row when it is missing.';

-- The member list poll runs every membership_poll_seconds. Storing every
-- member for every poll repeats the same state about 700 times a day, so a
-- member's row is stored only when it says something new:
--   the clan has no earlier row for the member;
--   the role or a donation counter differs from the member's latest earlier row;
--   the member left the clan after that row and is back;
--   that row belongs to an earlier season, so each season starts with a baseline.
CREATE FUNCTION guild.record_clan_member_observation(p_poll bigint, p_player bigint,
    p_in_game_role text, p_donations bigint, p_donations_received bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    poll guild.clan_membership_poll%ROWTYPE;
    previous record;
    season bigint;
    season_starts_at timestamptz;
    stored integer;
BEGIN
    SELECT * INTO poll FROM guild.clan_membership_poll WHERE poll_key = p_poll;
    IF NOT FOUND OR poll.outcome = 'failed' THEN
        RAISE EXCEPTION 'Member state requires a poll that returned members' USING ERRCODE = '23514';
    END IF;
    IF p_player IS NULL OR p_donations IS NULL OR p_donations_received IS NULL THEN
        RAISE EXCEPTION 'Member state requires the player and both donation counters'
            USING ERRCODE = '23514';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('clan-member-observation'),
        hashtext(poll.clan_key::text || ':' || p_player::text));
    season := guild.ensure_coc_season(poll.observed_at);
    SELECT starts_at INTO STRICT season_starts_at FROM guild.dim_coc_season
    WHERE season_key = season;
    SELECT o.in_game_role, o.donations, o.donations_received, earlier.observed_at INTO previous
    FROM guild.fact_clan_member_observation o
    JOIN guild.clan_membership_poll earlier USING (poll_key)
    WHERE o.player_key = p_player AND earlier.clan_key = poll.clan_key AND earlier.observed_at < poll.observed_at
    ORDER BY earlier.observed_at DESC LIMIT 1;
    IF FOUND AND previous.observed_at >= season_starts_at
        AND (previous.in_game_role, previous.donations, previous.donations_received)
            IS NOT DISTINCT FROM (p_in_game_role, p_donations, p_donations_received)
        AND NOT EXISTS (SELECT FROM guild.fact_clan_membership_change c
            WHERE c.clan_key = poll.clan_key
                AND c.player_key = p_player AND c.change_kind = 'observed_departure'
                AND c.observed_at > previous.observed_at AND c.observed_at <= poll.observed_at) THEN
        RETURN false;
    END IF;
    INSERT INTO guild.fact_clan_member_observation
        (poll_key, player_key, in_game_role, donations, donations_received)
    VALUES (p_poll, p_player, p_in_game_role, p_donations, p_donations_received)
    ON CONFLICT (poll_key, player_key) DO NOTHING;
    GET DIAGNOSTICS stored = ROW_COUNT;
    RETURN stored = 1;
END;
$$;
COMMENT ON FUNCTION guild.record_clan_member_observation IS
    'Collector interface: call once for every member of every poll that returned members. Stores '
    'the member state only when it changed and returns whether a row was stored.';

CREATE VIEW guild.current_clan_member_state AS
SELECT m.clan_key, m.player_key, latest.in_game_role, latest.donations,
    latest.donations_received, latest.observed_at AS state_observed_at
FROM guild.current_observed_clan_member m
LEFT JOIN LATERAL (
    SELECT o.in_game_role, o.donations, o.donations_received, p.observed_at
    FROM guild.fact_clan_member_observation o
    JOIN guild.clan_membership_poll p USING (poll_key)
    WHERE o.player_key = m.player_key AND p.clan_key = m.clan_key
    ORDER BY p.observed_at DESC LIMIT 1
) latest ON true;
COMMENT ON VIEW guild.current_clan_member_state IS
    'The member list as the latest poll saw it: each current member with their latest stored state.';
CREATE VIEW guild.clan_member_season_donation AS
SELECT DISTINCT ON (p.clan_key, s.season_key, o.player_key)
    p.clan_key, s.season_key, s.season_month, o.player_key,
    o.donations, o.donations_received, p.observed_at AS counter_observed_at
FROM guild.fact_clan_member_observation o
JOIN guild.clan_membership_poll p USING (poll_key)
JOIN guild.dim_coc_season s ON p.observed_at >= s.starts_at AND p.observed_at < s.ends_at
WHERE o.donations IS NOT NULL
ORDER BY p.clan_key, s.season_key, o.player_key, p.observed_at DESC;
COMMENT ON VIEW guild.clan_member_season_donation IS
    'Donations of one account in one clan and season: the last counters that a poll saw before '
    'the season ended. The counters are the values the game reports; nothing is added to them. '
    'A member who was in the clan during a season has a row, with zero when they donated nothing.';

CREATE TABLE guild.dim_war (
    war_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clan_a_key bigint NOT NULL REFERENCES guild.dim_clan,
    clan_b_key bigint NOT NULL REFERENCES guild.dim_clan,
    preparation_started_at timestamptz NOT NULL,
    started_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    team_size smallint NOT NULL CHECK (team_size > 0),
    attacks_per_member smallint NOT NULL CHECK (attacks_per_member > 0),
    war_kind text NOT NULL DEFAULT 'regular' CHECK (war_kind IN ('regular', 'cwl', 'custom')),
    source_war_tag text UNIQUE,
    attack_allowance_source text NOT NULL DEFAULT 'api'
        CHECK (attack_allowance_source IN ('api', 'game_format')),
    identity_source text NOT NULL
        CHECK (identity_source IN ('clan_pair_preparation', 'manual_validated', 'cwl_war_tag')),
    UNIQUE (war_key, source_war_tag),
    UNIQUE (clan_a_key, clan_b_key, preparation_started_at),
    CHECK (source_war_tag IS NULL OR btrim(source_war_tag) <> ''),
    CHECK (identity_source <> 'cwl_war_tag' OR (war_kind = 'cwl' AND source_war_tag IS NOT NULL)),
    CHECK (attack_allowance_source <> 'game_format' OR (war_kind = 'cwl' AND attacks_per_member = 1)),
    CHECK (clan_a_key < clan_b_key),
    CHECK (preparation_started_at <= started_at AND started_at < ends_at)
);
COMMENT ON TABLE guild.dim_war IS
    'Conformed observed war identity for regular, CWL and custom wars. Preserve opaque source war '
    'tags when supplied by request context; missing tags and attack allowances must not be invented.';
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
    'Complete sanitized war response for retaining available fields beyond typed projections. '
    'Never persist verification request/response tokens.';
CREATE TABLE guild.war_participant (
    war_key bigint NOT NULL REFERENCES guild.dim_war,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    PRIMARY KEY (war_key, player_key),
    UNIQUE (war_key, clan_key, player_key)
);
CREATE FUNCTION guild.require_war_side() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
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
CREATE FUNCTION guild.require_opposing_war_accounts() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
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
SELECT m.clan_key, m.player_key, p.war_stars, p.observed_at AS counter_observed_at,
        m.confirmed_through AS membership_confirmed_through,
        dense_rank() OVER (PARTITION BY m.clan_key ORDER BY p.war_stars DESC) AS position
FROM guild.current_observed_clan_member m
JOIN guild.latest_player_counter p USING (player_key)
WHERE p.war_stars IS NOT NULL;
COMMENT ON VIEW guild.current_clan_lifetime_war_stars IS
    'Current-clan eligibility first; latest lifetime counter includes stars from all clans. '
    'Observation freshness remains visible; this view does not invent a missing-data tolerance.';

ALTER TABLE guild.guild_settings
    ADD COLUMN clan_games_enabled boolean NOT NULL DEFAULT true,
    ADD COLUMN clan_games_start_day smallint NOT NULL DEFAULT 22
        CHECK (clan_games_start_day BETWEEN 1 AND 28),
    ADD COLUMN clan_games_start_time_utc time NOT NULL DEFAULT '08:00',
    ADD COLUMN clan_games_event_seconds integer NOT NULL DEFAULT 518400
        CHECK (clan_games_event_seconds > 86400),
    ADD COLUMN clan_games_account_points_cap integer NOT NULL DEFAULT 4000
        CHECK (clan_games_account_points_cap > 0),
    ADD COLUMN clan_games_refresh_seconds integer NOT NULL DEFAULT 900
        CHECK (clan_games_refresh_seconds > 0);
CREATE VIEW guild.clan_games_schedule AS
SELECT guild_key, clan_games_enabled AS enabled, clan_games_start_day AS start_day,
    clan_games_start_time_utc AS start_time_utc, clan_games_event_seconds AS event_seconds,
    clan_games_account_points_cap AS account_points_cap
FROM guild.guild_settings;
CREATE TABLE guild.dim_clan_games_event (
    event_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    starts_at timestamptz NOT NULL UNIQUE,
    ends_at timestamptz NOT NULL,
    account_points_cap integer NOT NULL CHECK (account_points_cap > 0),
    schedule_source text NOT NULL CHECK (schedule_source IN ('configured_schedule', 'manual')),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    CHECK (ends_at > starts_at + interval '24 hours'),
    EXCLUDE USING gist (tstzrange(starts_at, ends_at, '[)') WITH &&)
);
COMMENT ON TABLE guild.dim_clan_games_event IS
    'Schedule/cap are configured evidence, not verified API calendar metadata. Freeze event values '
    'when creating the event; changing the recurring schedule must not rewrite past events.';
CREATE FUNCTION guild.create_scheduled_clan_games(p_year integer, p_month integer)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE s guild.clan_games_schedule; event_start timestamptz; result_key bigint;
BEGIN
    SELECT * INTO s FROM guild.clan_games_schedule WHERE enabled;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No enabled Clan Games schedule is configured for this guild'
            USING ERRCODE = '23514';
    END IF;
    event_start := (make_date(p_year, p_month, s.start_day) + s.start_time_utc) AT TIME ZONE 'UTC';
    INSERT INTO guild.dim_clan_games_event
        (starts_at, ends_at, account_points_cap, schedule_source, source_correlation_id)
    VALUES (event_start, event_start + make_interval(secs => s.event_seconds),
            s.account_points_cap, 'configured_schedule', 'schedule:' || p_year || ':' || p_month)
    ON CONFLICT (starts_at) DO NOTHING RETURNING event_key INTO result_key;
    IF result_key IS NULL THEN
        SELECT event_key INTO result_key FROM guild.dim_clan_games_event
        WHERE starts_at = event_start;
    END IF;
    RETURN result_key;
END;
$$;
-- Manual fallback uses the same start identity as scheduled creation.
-- A repeat cannot silently replace the evidence behind an existing assessment.
-- A manually created event is recorded in the configuration change history.
CREATE FUNCTION guild.create_manual_clan_games(
    p_actor_user_key bigint,
    p_starts_at timestamptz,
    p_ends_at timestamptz,
    p_account_points_cap integer,
    p_reason text,
    p_source_correlation_id text DEFAULT gen_random_uuid()::text
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    result_key bigint;
    existing_event guild.dim_clan_games_event%ROWTYPE;
    previous_actor text := current_setting('guild.actor_user_key', true);
    previous_source text := current_setting('guild.change_source', true);
    previous_reason text := current_setting('guild.change_reason', true);
BEGIN
    IF p_actor_user_key IS NULL
        OR NOT guild.can_configure(p_actor_user_key) THEN
        RAISE EXCEPTION 'Admin role or developer allowlist is required to create an event'
            USING ERRCODE = '42501';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = ''
        OR p_source_correlation_id IS NULL OR btrim(p_source_correlation_id) = '' THEN
        RAISE EXCEPTION 'Manual event creation requires a reason and correlation identifier'
            USING ERRCODE = '23514';
    END IF;
    PERFORM set_config('guild.actor_user_key', p_actor_user_key::text, true);
    PERFORM set_config('guild.change_source', 'command', true);
    PERFORM set_config('guild.change_reason', p_reason, true);

    INSERT INTO guild.dim_clan_games_event
        (starts_at, ends_at, account_points_cap, schedule_source, source_correlation_id)
    VALUES (p_starts_at, p_ends_at, p_account_points_cap,
        'manual', p_source_correlation_id)
    ON CONFLICT (starts_at) DO NOTHING
    RETURNING event_key INTO result_key;
    IF result_key IS NULL THEN
        SELECT * INTO STRICT existing_event FROM guild.dim_clan_games_event
        WHERE starts_at = p_starts_at FOR SHARE;
        IF (existing_event.ends_at, existing_event.account_points_cap)
            IS DISTINCT FROM (p_ends_at, p_account_points_cap) THEN
            RAISE EXCEPTION 'An existing event has different boundaries or a points cap'
                USING ERRCODE = '23514';
        END IF;
        result_key := existing_event.event_key;
    END IF;
    PERFORM set_config('guild.actor_user_key', coalesce(previous_actor, ''), true);
    PERFORM set_config('guild.change_source', coalesce(previous_source, ''), true);
    PERFORM set_config('guild.change_reason', coalesce(previous_reason, ''), true);
    RETURN result_key;
END;
$$;
CREATE FUNCTION guild.clan_games_observed_target(p_event_key bigint, p_player_key bigint, p_checkpoint timestamptz)
RETURNS TABLE (observed_seconds numeric, required_points numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    WITH e AS (
        SELECT * FROM guild.dim_clan_games_event WHERE event_key = p_event_key
    ), clipped AS (
        SELECT range_agg(tstzrange(greatest(m.observed_since, e.starts_at),
                    least(coalesce(m.observed_until, m.confirmed_through), m.confirmed_through,
                        e.ends_at, p_checkpoint), '[)')) AS periods
        FROM e CROSS JOIN guild.observed_clan_membership_period m
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

-- Boundary checkpoints are durable rows. The regular read is one moving row per player.
CREATE VIEW guild.clan_games_collection_policy AS
SELECT guild_key, clan_games_refresh_seconds AS refresh_seconds FROM guild.guild_settings;
CREATE TABLE guild.clan_games_read_request (
    request_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.dim_clan_games_event,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    purpose text NOT NULL CHECK (purpose IN ('baseline', 'regular', 't_minus_24h', 'final', 'transfer')),
    due_at timestamptz NOT NULL,
    transfer_request_key bigint REFERENCES guild.account_transfer_request,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'succeeded', 'missed')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    missed_at timestamptz,
    UNIQUE NULLS NOT DISTINCT (event_key, player_key, purpose, due_at, transfer_request_key),
    UNIQUE (request_key, event_key, player_key),
    CHECK ((purpose = 'transfer') = (transfer_request_key IS NOT NULL)),
    CHECK ((status = 'missed') = (missed_at IS NOT NULL))
);
COMMENT ON COLUMN guild.clan_games_read_request.status IS
    'pending is still retryable. missed is terminal: no current response can supply this '
    'checkpoint any more. A missed read is absent evidence, never a zero.';
CREATE FUNCTION guild.validate_clan_games_read_request() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE e guild.dim_clan_games_event;
BEGIN
    -- Closing a request as missed changes no checkpoint identity. Its transfer
    -- may already be cancelled, rejected or expired, which is one reason to close it.
    IF TG_OP = 'UPDATE' AND NEW.status = 'missed'
        AND (NEW.event_key, NEW.player_key, NEW.purpose, NEW.due_at, NEW.transfer_request_key)
            IS NOT DISTINCT FROM
            (OLD.event_key, OLD.player_key, OLD.purpose, OLD.due_at, OLD.transfer_request_key) THEN
        RETURN NEW;
    END IF;
    SELECT * INTO STRICT e FROM guild.dim_clan_games_event WHERE event_key = NEW.event_key;
    IF (NEW.purpose = 'baseline' AND NEW.due_at <> e.starts_at)
        OR (NEW.purpose = 't_minus_24h' AND NEW.due_at <> e.ends_at - interval '24 hours')
        OR (NEW.purpose = 'final' AND NEW.due_at <> e.ends_at)
        OR (NEW.purpose IN ('regular', 'transfer')
            AND NOT (NEW.due_at >= e.starts_at AND NEW.due_at < e.ends_at)) THEN
        RAISE EXCEPTION 'Checkpoint does not match the configured event boundary' USING ERRCODE = '23514';
    END IF;
    IF NEW.transfer_request_key IS NOT NULL AND NOT EXISTS (
        SELECT FROM guild.account_transfer_request t
        WHERE t.transfer_request_key = NEW.transfer_request_key
            AND t.player_key = NEW.player_key
            AND t.status IN ('approved', 'awaiting_points', 'consumed')
            AND t.decided_at <= NEW.due_at
    ) THEN
        RAISE EXCEPTION 'Transfer checkpoint must reference its approved recipient request'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_read_request_boundary BEFORE INSERT OR UPDATE
ON guild.clan_games_read_request FOR EACH ROW
EXECUTE FUNCTION guild.validate_clan_games_read_request();
-- A regular read has no fixed slot. Each player has at most one pending regular
-- request per event, and queue_clan_games_reads moves it when the latest read or
-- the configured interval changes.
CREATE UNIQUE INDEX clan_games_read_request_pending_regular
    ON guild.clan_games_read_request (event_key, player_key)
    WHERE purpose = 'regular' AND status = 'pending';
CREATE FUNCTION guild.queue_clan_games_reads(p_event bigint, p_player bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    e guild.dim_clan_games_event; refresh_interval interval; next_due timestamptz;
    changed integer; retimed integer := 0;
BEGIN
    SELECT * INTO STRICT e FROM guild.dim_clan_games_event WHERE event_key = p_event;
    SELECT make_interval(secs => coalesce((SELECT refresh_seconds
        FROM guild.clan_games_collection_policy), 900))
    INTO refresh_interval;
    INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at)
    VALUES (e.event_key, p_player, 'baseline', e.starts_at),
        (e.event_key, p_player, 't_minus_24h', e.ends_at - interval '24 hours'),
        (e.event_key, p_player, 'final', e.ends_at)
    ON CONFLICT (event_key, player_key, purpose, due_at, transfer_request_key) DO NOTHING;
    GET DIAGNOSTICS changed = ROW_COUNT;

    -- The next regular read is one interval after the latest evidence: the
    -- event start, the newest counter read, or the newest regular request that
    -- is already closed. The last term keeps due times of one player distinct.
    SELECT greatest(e.starts_at,
            (SELECT max(c.observed_at) FROM guild.clan_games_counter_read c
                WHERE c.event_key = e.event_key AND c.player_key = p_player),
            (SELECT max(q.due_at) FROM guild.clan_games_read_request q
                WHERE q.event_key = e.event_key AND q.player_key = p_player
                    AND q.purpose = 'regular' AND q.status <> 'pending'))
        + refresh_interval
    INTO next_due;
    -- A missed regular read means the event is closed for this player.
    IF next_due < e.ends_at AND NOT EXISTS (
        SELECT FROM guild.clan_games_read_request q
        WHERE q.event_key = e.event_key AND q.player_key = p_player
            AND q.purpose = 'regular' AND q.status = 'missed'
    ) THEN
        INSERT INTO guild.clan_games_read_request AS r (event_key, player_key, purpose, due_at)
        VALUES (e.event_key, p_player, 'regular', next_due)
        ON CONFLICT (event_key, player_key) WHERE purpose = 'regular' AND status = 'pending'
        DO UPDATE SET due_at = EXCLUDED.due_at WHERE r.due_at <> EXCLUDED.due_at;
        GET DIAGNOSTICS retimed = ROW_COUNT;
    END IF;
    RETURN changed + retimed;
END;
$$;
COMMENT ON FUNCTION guild.queue_clan_games_reads IS
    'Trusted scheduler: queue the baseline, T-24 and final checkpoints once, and keep one pending '
    'regular read due one configured interval after the latest read. Returns the number of requests '
    'added or moved, so a repeated call returns 0. It does not execute an API request.';

CREATE TABLE guild.clan_games_counter_read (
    read_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_key bigint NOT NULL REFERENCES guild.clan_games_read_request,
    event_key bigint NOT NULL,
    player_key bigint NOT NULL,
    transfer_request_key bigint REFERENCES guild.account_transfer_request,
    source_fetch_key bigint NOT NULL UNIQUE REFERENCES guild.fact_api_fetch_attempt,
    achievement_key bigint NOT NULL REFERENCES guild.dim_achievement,
    observed_at timestamptz NOT NULL,
    boundary_at timestamptz NOT NULL,
    observed_clan_key bigint REFERENCES guild.dim_clan,
    clan_observation_status text NOT NULL DEFAULT 'unknown'
        CHECK (clan_observation_status IN ('known', 'no_clan', 'unknown')),
    source_as_of timestamptz,
    freshness_status text NOT NULL DEFAULT 'unknown' CHECK (freshness_status IN ('adequate', 'unknown')),
    freshness_policy text NOT NULL CHECK (btrim(freshness_policy) <> ''),
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (request_key, event_key, player_key)
        REFERENCES guild.clan_games_read_request (request_key, event_key, player_key),
    FOREIGN KEY (player_key, achievement_key, observed_at)
        REFERENCES guild.fact_player_achievement_observation (player_key, achievement_key, observed_at),
    UNIQUE (read_key, event_key, player_key),
    UNIQUE (read_key, transfer_request_key, player_key, observed_at),
    CHECK (source_as_of IS NULL OR source_as_of <= observed_at),
    CHECK ((clan_observation_status = 'known') = (observed_clan_key IS NOT NULL))
);
COMMENT ON TABLE guild.clan_games_counter_read IS
    'A successful Games Champion/home API observation, never a manually entered score. '
    'observed_at is collection time; source_as_of stays NULL unless actually supplied. '
    'Freshness adequacy is a versioned trusted-collector evidence policy, not a fabricated event timestamp.';
CREATE FUNCTION guild.validate_clan_games_counter_read() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE r guild.clan_games_read_request; e guild.dim_clan_games_event;
BEGIN
    SELECT * INTO STRICT r FROM guild.clan_games_read_request WHERE request_key = NEW.request_key;
    SELECT * INTO STRICT e FROM guild.dim_clan_games_event WHERE event_key = r.event_key;
    IF NEW.event_key <> r.event_key OR NEW.player_key <> r.player_key
        OR NEW.transfer_request_key IS DISTINCT FROM r.transfer_request_key
        OR NEW.boundary_at <> (CASE WHEN r.purpose = 'transfer' THEN NEW.observed_at ELSE r.due_at END) THEN
        RAISE EXCEPTION 'Counter read must match its requested player, event and boundary'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.dim_achievement
        WHERE achievement_key = NEW.achievement_key AND source_name = 'Games Champion' AND village = 'home') THEN
        RAISE EXCEPTION 'Clan Games reads require the Games Champion/home achievement'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT FROM guild.fact_api_fetch_attempt f
        WHERE f.fetch_key = NEW.source_fetch_key
            AND f.player_key = r.player_key AND f.endpoint_kind = 'player_profile'
            AND f.outcome = 'succeeded' AND f.http_status = 200 AND f.completed_at = NEW.observed_at
    ) THEN
        RAISE EXCEPTION 'Counter read requires a successful matching profile API response'
            USING ERRCODE = '23514';
    END IF;
    IF (r.purpose = 'baseline' AND NEW.observed_at > e.starts_at)
        OR (r.purpose = 't_minus_24h' AND NEW.observed_at > r.due_at)
        OR (r.purpose = 'transfer' AND NEW.observed_at < r.due_at)
        OR (r.purpose = 'final' AND NEW.observed_at < e.ends_at)
        OR EXISTS (
            SELECT FROM guild.dim_clan_games_event later
            WHERE later.starts_at > e.starts_at
                AND later.starts_at <= NEW.observed_at
        ) THEN
        RAISE EXCEPTION 'A current response cannot reconstruct a missed past checkpoint'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_counter_source BEFORE INSERT ON guild.clan_games_counter_read
FOR EACH ROW EXECUTE FUNCTION guild.validate_clan_games_counter_read();
CREATE FUNCTION guild.complete_clan_games_read_request() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    -- Validated evidence wins: a read observed in time but ingested after the
    -- request was closed as missed still completes it.
    UPDATE guild.clan_games_read_request SET status = 'succeeded', missed_at = NULL
    WHERE request_key = NEW.request_key;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_counter_completed AFTER INSERT ON guild.clan_games_counter_read
FOR EACH ROW EXECUTE FUNCTION guild.complete_clan_games_read_request();

-- The rules mirror validate_clan_games_counter_read: a request is closed only
-- when that trigger could no longer accept a response observed now.
CREATE FUNCTION guild.close_missed_clan_games_reads(
    p_event bigint, p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE e guild.dim_clan_games_event; closed integer;
BEGIN
    IF p_as_of IS NULL OR p_as_of > clock_timestamp() THEN
        RAISE EXCEPTION 'A read cannot be declared missed in the future' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO STRICT e FROM guild.dim_clan_games_event WHERE event_key = p_event;
    UPDATE guild.clan_games_read_request r
    SET status = 'missed', missed_at = p_as_of
    WHERE r.event_key = e.event_key AND r.status = 'pending' AND (
        (r.purpose = 'baseline' AND p_as_of > e.starts_at)
        OR (r.purpose = 't_minus_24h' AND p_as_of > r.due_at)
        -- queue_clan_games_reads moves the one pending regular read while the
        -- event runs, so that read is lost only when the event is over.
        OR (r.purpose = 'regular' AND p_as_of >= e.ends_at)
        OR (r.purpose = 'transfer' AND EXISTS (
            SELECT FROM guild.account_transfer_request t
            WHERE t.transfer_request_key = r.transfer_request_key
                AND t.status IN ('rejected', 'cancelled', 'expired')))
        -- No request of this event can be read once the next event has started.
        OR EXISTS (
            SELECT FROM guild.dim_clan_games_event later_event
            WHERE later_event.starts_at > e.starts_at
                AND later_event.starts_at <= p_as_of)
    );
    GET DIAGNOSTICS closed = ROW_COUNT;
    RETURN closed;
END;
$$;
COMMENT ON FUNCTION guild.close_missed_clan_games_reads IS
    'Trusted scheduler: mark pending reads that no current response can satisfy as missed. '
    'final and transfer reads stay retryable until the next event starts. Idempotent.';
CREATE VIEW guild.clan_games_counter_value AS
SELECT r.*, q.purpose, q.due_at, a.value AS counter_value
FROM guild.clan_games_counter_read r
JOIN guild.clan_games_read_request q USING (request_key)
JOIN guild.fact_player_achievement_observation a
    ON a.player_key = r.player_key AND a.achievement_key = r.achievement_key
        AND a.observed_at = r.observed_at;

ALTER TABLE guild.account_link ADD CONSTRAINT account_link_transfer_counter
FOREIGN KEY (transfer_boundary_read_key, transfer_request_key, player_key, linked_at)
REFERENCES guild.clan_games_counter_read (read_key, transfer_request_key, player_key, observed_at);
ALTER TABLE guild.account_link ADD CONSTRAINT account_link_transfer_counter_context
CHECK (transfer_boundary_read_key IS NULL OR transfer_request_key IS NOT NULL);

-- Input of the transfer limit in V2: an approved transfer does not lapse while
-- its boundary read is pending, and the limit restarts when the read arrives.
CREATE FUNCTION guild.clan_games_transfer_wait_until(p_transfer bigint)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT CASE WHEN EXISTS (
            SELECT FROM guild.clan_games_read_request q
            WHERE q.transfer_request_key = p_transfer AND q.status = 'pending')
        THEN 'infinity'::timestamptz
        ELSE (SELECT max(c.observed_at) FROM guild.clan_games_counter_read c
            WHERE c.transfer_request_key = p_transfer) END
$$;
COMMENT ON FUNCTION guild.clan_games_transfer_wait_until IS
    'Private transfer-limit input: infinity while a boundary read for the transfer is pending, '
    'otherwise the time of its latest read, or NULL when it has none.';

CREATE FUNCTION guild.ensure_clan_games_transfer_read(p_transfer bigint, p_effective_at timestamptz)
RETURNS bigint LANGUAGE plpgsql
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE t guild.account_transfer_request; e guild.dim_clan_games_event; read_id bigint;
BEGIN
    SELECT * INTO STRICT t FROM guild.account_transfer_request WHERE transfer_request_key = p_transfer;
    SELECT * INTO e FROM guild.dim_clan_games_event
    WHERE starts_at <= p_effective_at AND ends_at > p_effective_at;
    IF NOT FOUND THEN RETURN 0; END IF;
    SELECT read_key INTO read_id FROM guild.clan_games_counter_value
    WHERE event_key = e.event_key AND player_key = t.player_key
        AND transfer_request_key = p_transfer AND purpose = 'transfer'
        AND observed_at = p_effective_at AND observed_at >= t.decided_at;
    IF read_id IS NOT NULL THEN RETURN read_id; END IF;
    INSERT INTO guild.clan_games_read_request
        (event_key, player_key, purpose, due_at, transfer_request_key)
    VALUES (e.event_key, t.player_key, 'transfer', p_effective_at, p_transfer)
    ON CONFLICT (event_key, player_key, purpose, due_at, transfer_request_key) DO NOTHING;
    RETURN NULL;
END;
$$;
COMMENT ON FUNCTION guild.ensure_clan_games_transfer_read IS
    'Private link-workflow gate: 0 means no active Clan Games, NULL means wait/retry, '
    'otherwise the source read must be retained on the effective link. No guessed point split.';

CREATE TABLE guild.clan_games_participation_evidence (
    participation_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.dim_clan_games_event,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    baseline_read_key bigint,
    first_increase_read_key bigint,
    inferred_clan_key bigint REFERENCES guild.dim_clan,
    status text NOT NULL DEFAULT 'insufficient_data' CHECK (status IN ('inferred', 'insufficient_data')),
    evidence_note text NOT NULL CHECK (btrim(evidence_note) <> ''),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (baseline_read_key, event_key, player_key)
        REFERENCES guild.clan_games_counter_read (read_key, event_key, player_key),
    FOREIGN KEY (first_increase_read_key, event_key, player_key)
        REFERENCES guild.clan_games_counter_read (read_key, event_key, player_key),
    UNIQUE (participation_key, event_key, player_key)
);
CREATE FUNCTION guild.infer_clan_games_participation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE b guild.clan_games_counter_value; f guild.clan_games_counter_value;
    e guild.dim_clan_games_event; inferred bigint;
BEGIN
    SELECT * INTO STRICT e FROM guild.dim_clan_games_event WHERE event_key = NEW.event_key;
    SELECT * INTO b FROM guild.clan_games_counter_value WHERE read_key = NEW.baseline_read_key;
    SELECT * INTO f FROM guild.clan_games_counter_value WHERE read_key = NEW.first_increase_read_key;
    IF b.read_key IS NOT NULL AND f.read_key IS NOT NULL
        AND b.event_key = e.event_key AND f.event_key = e.event_key
        AND b.player_key = NEW.player_key AND f.player_key = NEW.player_key
        AND b.purpose = 'baseline' AND b.boundary_at = e.starts_at
        AND b.freshness_status = 'adequate' AND f.freshness_status = 'adequate'
        AND f.counter_value > b.counter_value
        AND f.clan_observation_status = 'known'
        AND NOT EXISTS (
            SELECT FROM guild.clan_games_counter_value earlier
            WHERE earlier.event_key = e.event_key AND earlier.player_key = NEW.player_key
                AND earlier.observed_at < f.observed_at AND earlier.observed_at >= e.starts_at
                AND earlier.counter_value > b.counter_value
        ) THEN
        SELECT m.clan_key INTO inferred FROM guild.observed_clan_membership_period m
        WHERE m.player_key = NEW.player_key
            AND m.coverage_status = 'adequate' AND m.observed_since <= e.starts_at
            AND m.confirmed_through >= f.observed_at
            AND (m.observed_until IS NULL OR m.observed_until >= f.observed_at)
            AND m.clan_key = f.observed_clan_key
            AND NOT EXISTS (
                SELECT FROM guild.clan_games_counter_value observed
                WHERE observed.event_key = e.event_key AND observed.player_key = NEW.player_key
                    AND observed.observed_at >= e.starts_at AND observed.observed_at <= f.observed_at
                    AND (observed.clan_observation_status <> 'known'
                        OR observed.observed_clan_key <> m.clan_key)
            );
    END IF;
    IF NEW.inferred_clan_key IS NOT NULL AND NEW.inferred_clan_key IS DISTINCT FROM inferred THEN
        RAISE EXCEPTION 'Participating clan cannot be entered without consistent observed evidence'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.status = 'inferred' AND inferred IS NULL THEN
        RAISE EXCEPTION 'Ambiguous Clan Games participation must remain insufficient_data'
            USING ERRCODE = '23514';
    END IF;
    NEW.inferred_clan_key := inferred;
    NEW.status := CASE WHEN inferred IS NULL THEN 'insufficient_data' ELSE 'inferred' END;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_participation_inference BEFORE INSERT OR UPDATE
ON guild.clan_games_participation_evidence FOR EACH ROW
EXECUTE FUNCTION guild.infer_clan_games_participation();
COMMENT ON TABLE guild.clan_games_participation_evidence IS
    'Inference from historical tracked-clan observations, never an explicit API affiliation claim. '
    'Later changes to current clan tracking settings must not rewrite earlier event participation.';

CREATE FUNCTION guild.clan_games_attributed_target(
    p_event bigint, p_player bigint, p_attribution bigint, p_checkpoint timestamptz
) RETURNS TABLE (scope_starts_at timestamptz, scope_ends_at timestamptz,
    observed_seconds numeric, required_points numeric)
LANGUAGE sql STABLE
SET search_path = pg_catalog, guild, pg_temp AS $$
    WITH bounds AS (
        SELECT e.*,
            greatest(e.starts_at, CASE WHEN a.include_prelink_history
                THEN e.starts_at ELSE a.first_link_at END) AS lo,
            least(e.ends_at, p_checkpoint, coalesce(a.closed_at, p_checkpoint)) AS hi
        FROM guild.dim_clan_games_event e
        JOIN guild.metric_attribution_episode a
            ON a.player_key = p_player
        WHERE e.event_key = p_event AND a.attribution_key = p_attribution
    ), intervals AS (
        SELECT b.*, (SELECT range_agg(tstzrange(
            greatest(m.observed_since, b.lo),
            least(coalesce(m.observed_until, m.confirmed_through), m.confirmed_through, b.hi), '[)'))
            FROM guild.observed_clan_membership_period m
            WHERE m.player_key = p_player
                AND greatest(m.observed_since, b.lo)
                    < least(coalesce(m.observed_until, m.confirmed_through), m.confirmed_through, b.hi)
        ) AS spans FROM bounds b
    )
    SELECT lo, hi, x.seconds,
        0.10::numeric * account_points_cap * x.seconds / extract(epoch FROM ends_at - starts_at)
    FROM intervals CROSS JOIN LATERAL (
        SELECT coalesce(sum(extract(epoch FROM upper(r) - lower(r))), 0)::numeric AS seconds
        FROM unnest(spans) AS r
    ) x WHERE hi >= lo
$$;

CREATE TABLE guild.fact_clan_games_progress (
    progress_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.dim_clan_games_event,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (btrim(source_correlation_id) <> ''),
    measurement_method text NOT NULL DEFAULT 'achievement_delta' CHECK (measurement_method = 'achievement_delta'),
    evidence_status text NOT NULL CHECK (evidence_status IN ('adequate', 'insufficient_data')),
    points integer CHECK (points >= 0),
    baseline_read_key bigint,
    ending_read_key bigint,
    participation_key bigint,
    baseline_achievement_key bigint,
    baseline_observed_at timestamptz,
    ending_achievement_key bigint,
    ending_observed_at timestamptz,
    evidence_note text NOT NULL CHECK (btrim(evidence_note) <> ''),
    UNIQUE (event_key, player_key, observed_at),
    UNIQUE (progress_key, event_key, player_key),
    FOREIGN KEY (baseline_read_key, event_key, player_key)
        REFERENCES guild.clan_games_counter_read (read_key, event_key, player_key),
    FOREIGN KEY (ending_read_key, event_key, player_key)
        REFERENCES guild.clan_games_counter_read (read_key, event_key, player_key),
    FOREIGN KEY (participation_key, event_key, player_key)
        REFERENCES guild.clan_games_participation_evidence (participation_key, event_key, player_key),
    CHECK (evidence_status = 'adequate' OR points IS NULL)
);
CREATE FUNCTION guild.validate_clan_games_progress() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE b guild.clan_games_counter_value; z guild.clan_games_counter_value;
    e guild.dim_clan_games_event; delta bigint;
BEGIN
    SELECT * INTO STRICT e FROM guild.dim_clan_games_event WHERE event_key = NEW.event_key;
    SELECT * INTO b FROM guild.clan_games_counter_value WHERE read_key = NEW.baseline_read_key;
    SELECT * INTO z FROM guild.clan_games_counter_value WHERE read_key = NEW.ending_read_key;
    IF NEW.evidence_status = 'adequate' THEN
        delta := z.counter_value - b.counter_value;
        -- Measured zero is zero for every participating clan. It needs both
        -- adequate endpoints, but no fictional first-increase affiliation.
        IF b.read_key IS NULL OR z.read_key IS NULL OR b.purpose <> 'baseline'
            OR b.boundary_at <> e.starts_at OR z.observed_at <> NEW.observed_at
            OR b.freshness_status <> 'adequate' OR z.freshness_status <> 'adequate'
            OR delta < 0 OR delta > e.account_points_cap
            OR (NEW.points IS NOT NULL AND NEW.points <> delta)
            OR (delta > 0 AND NOT EXISTS (
                SELECT FROM guild.clan_games_participation_evidence p
                WHERE p.participation_key = NEW.participation_key AND p.status = 'inferred'
                    AND p.baseline_read_key = b.read_key
            )) THEN
            RAISE EXCEPTION 'Adequate Clan Games progress requires actual counter and inferred-clan evidence'
                USING ERRCODE = '23514';
        END IF;
        NEW.points := delta;
    END IF;
    IF b.read_key IS NOT NULL THEN
        NEW.baseline_achievement_key := b.achievement_key;
        NEW.baseline_observed_at := b.observed_at;
    END IF;
    IF z.read_key IS NOT NULL THEN
        NEW.ending_achievement_key := z.achievement_key;
        NEW.ending_observed_at := z.observed_at;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_progress_evidence BEFORE INSERT OR UPDATE ON guild.fact_clan_games_progress
FOR EACH ROW EXECUTE FUNCTION guild.validate_clan_games_progress();
CREATE VIEW guild.latest_clan_games_progress AS
SELECT DISTINCT ON (event_key, player_key) * FROM guild.fact_clan_games_progress
ORDER BY event_key, player_key, observed_at DESC;

-- One account can have different owners during the same event. Each assessment
-- is one attribution episode's slice, not the full account reused for each owner.
CREATE TABLE guild.fact_clan_games_account_assessment (
    account_assessment_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.dim_clan_games_event,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    attribution_key bigint,
    user_key bigint,
    checkpoint_kind text NOT NULL CHECK (checkpoint_kind IN ('t_minus_24h', 'final')),
    checkpoint_at timestamptz NOT NULL,
    calculation_version integer NOT NULL CHECK (calculation_version > 0),
    calculated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    rule_version text NOT NULL CHECK (btrim(rule_version) <> ''),
    attribution_policy text NOT NULL CHECK (btrim(attribution_policy) <> ''),
    membership_status text NOT NULL CHECK (membership_status IN ('adequate', 'insufficient_data')),
    points_status text NOT NULL CHECK (points_status IN ('adequate', 'insufficient_data')),
    attribution_status text NOT NULL CHECK (attribution_status IN ('adequate', 'insufficient_data')),
    progress_key bigint,
    participation_key bigint,
    start_read_key bigint,
    end_read_key bigint,
    scope_starts_at timestamptz NOT NULL,
    scope_ends_at timestamptz NOT NULL,
    observed_seconds numeric NOT NULL CHECK (observed_seconds >= 0),
    eligible_points numeric CHECK (eligible_points >= 0),
    required_points numeric NOT NULL CHECK (required_points >= 0),
    evidence_note text NOT NULL CHECK (btrim(evidence_note) <> ''),
    result text GENERATED ALWAYS AS (
        CASE WHEN membership_status <> 'adequate' OR points_status <> 'adequate'
                OR attribution_status <> 'adequate' OR eligible_points IS NULL
            THEN 'insufficient_data'
            WHEN eligible_points >= required_points THEN 'pass' ELSE 'fail' END
    ) STORED,
    UNIQUE NULLS NOT DISTINCT (event_key, player_key, checkpoint_kind, calculation_version, attribution_key),
    UNIQUE (account_assessment_key, event_key, player_key, checkpoint_kind, attribution_key),
    FOREIGN KEY (attribution_key, user_key, player_key)
        REFERENCES guild.metric_attribution_episode (attribution_key, user_key, player_key),
    FOREIGN KEY (progress_key, event_key, player_key)
        REFERENCES guild.fact_clan_games_progress (progress_key, event_key, player_key),
    FOREIGN KEY (participation_key, event_key, player_key)
        REFERENCES guild.clan_games_participation_evidence (participation_key, event_key, player_key),
    FOREIGN KEY (start_read_key, event_key, player_key)
        REFERENCES guild.clan_games_counter_read (read_key, event_key, player_key),
    FOREIGN KEY (end_read_key, event_key, player_key)
        REFERENCES guild.clan_games_counter_read (read_key, event_key, player_key),
    CHECK (scope_ends_at >= scope_starts_at)
);
CREATE FUNCTION guild.validate_clan_games_assessment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE e guild.dim_clan_games_event; a guild.metric_attribution_episode;
    b guild.clan_games_counter_value; z guild.clan_games_counter_value;
    computed record; delta bigint;
BEGIN
    SELECT * INTO STRICT e FROM guild.dim_clan_games_event WHERE event_key = NEW.event_key;
    IF NEW.checkpoint_at IS DISTINCT FROM
        (CASE NEW.checkpoint_kind WHEN 'final' THEN e.ends_at ELSE e.ends_at - interval '24 hours' END) THEN
        RAISE EXCEPTION 'Assessment checkpoint must match the event boundary' USING ERRCODE = '23514';
    END IF;
    IF NEW.attribution_key IS NOT NULL THEN
        SELECT * INTO STRICT a FROM guild.metric_attribution_episode WHERE attribution_key = NEW.attribution_key;
        IF a.player_key <> NEW.player_key THEN
            RAISE EXCEPTION 'Assessment attribution belongs to another account' USING ERRCODE = '23514';
        END IF;
        NEW.user_key := a.user_key;
        SELECT * INTO computed FROM guild.clan_games_attributed_target(
            e.event_key, NEW.player_key, a.attribution_key, NEW.checkpoint_at);
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Attribution episode has no interval at this checkpoint' USING ERRCODE = '23514';
        END IF;
        NEW.scope_starts_at := computed.scope_starts_at;
        NEW.scope_ends_at := computed.scope_ends_at;
        NEW.observed_seconds := computed.observed_seconds;
        NEW.required_points := computed.required_points;
    ELSE
        NEW.user_key := NULL;
        NEW.scope_starts_at := e.starts_at; NEW.scope_ends_at := NEW.checkpoint_at;
        SELECT observed_seconds, required_points INTO NEW.observed_seconds, NEW.required_points
        FROM guild.clan_games_observed_target(e.event_key, NEW.player_key, NEW.checkpoint_at);
        IF NEW.attribution_status = 'adequate' THEN
            RAISE EXCEPTION 'A member assessment must identify its historical attribution episode'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.membership_status = 'adequate' AND EXISTS (
        SELECT FROM guild.observed_clan_membership_period m
        WHERE m.player_key = NEW.player_key
            AND m.observed_since < NEW.scope_ends_at
            AND coalesce(m.observed_until, m.confirmed_through) > NEW.scope_starts_at
            AND m.coverage_status <> 'adequate'
    ) THEN
        RAISE EXCEPTION 'Uncertain presence cannot produce an adequate assessment' USING ERRCODE = '23514';
    END IF;
    IF NEW.points_status = 'adequate' THEN
        SELECT * INTO b FROM guild.clan_games_counter_value WHERE read_key = NEW.start_read_key;
        SELECT * INTO z FROM guild.clan_games_counter_value WHERE read_key = NEW.end_read_key;
        delta := z.counter_value - b.counter_value;
        -- This exception is only for a measured zero; NULL/missing endpoints
        -- still fail evidence validation and never become zero-point failures.
        IF b.read_key IS NULL OR z.read_key IS NULL OR delta < 0 OR delta > e.account_points_cap
            OR b.freshness_status <> 'adequate' OR z.freshness_status <> 'adequate'
            OR (NEW.eligible_points IS NOT NULL AND NEW.eligible_points <> delta)
            OR (delta > 0 AND NOT EXISTS (SELECT FROM guild.clan_games_participation_evidence p
                WHERE p.participation_key = NEW.participation_key AND p.status = 'inferred'
                    AND p.event_key = e.event_key AND p.player_key = NEW.player_key)) THEN
            RAISE EXCEPTION 'No manually assigned points: an attributed counter slice requires source evidence'
                USING ERRCODE = '23514';
        END IF;
        IF (NEW.scope_starts_at = e.starts_at
                AND (b.purpose <> 'baseline' OR b.boundary_at <> e.starts_at))
            OR (NEW.scope_starts_at > e.starts_at AND b.observed_at <> NEW.scope_starts_at)
            OR (NEW.scope_ends_at < NEW.checkpoint_at AND z.observed_at <> NEW.scope_ends_at)
            OR (NEW.scope_ends_at = NEW.checkpoint_at AND
                (z.boundary_at <> NEW.checkpoint_at OR z.purpose <>
                    (CASE NEW.checkpoint_kind WHEN 'final' THEN 'final' ELSE 't_minus_24h' END))) THEN
            RAISE EXCEPTION 'Counter evidence must support both ends of this ownership slice'
                USING ERRCODE = '23514';
        END IF;
        NEW.eligible_points := delta;
    ELSE
        NEW.eligible_points := NULL;
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
    attribution_policy text NOT NULL CHECK (btrim(attribution_policy) <> ''),
    attribution_status text NOT NULL CHECK (attribution_status IN ('adequate', 'insufficient_data')),
    evidence_note text NOT NULL CHECK (btrim(evidence_note) <> ''),
    UNIQUE (event_key, user_key, checkpoint_kind, calculation_version),
    UNIQUE (member_assessment_key, event_key, checkpoint_kind),
    UNIQUE (member_assessment_key, event_key, checkpoint_kind, user_key)
);
CREATE TABLE guild.clan_games_member_account_input (
    member_assessment_key bigint NOT NULL,
    account_assessment_key bigint,
    event_key bigint NOT NULL,
    checkpoint_kind text NOT NULL,
    player_key bigint NOT NULL,
    attribution_key bigint NOT NULL,
    user_key bigint NOT NULL,
    PRIMARY KEY (member_assessment_key, attribution_key),
    UNIQUE (member_assessment_key, account_assessment_key),
    FOREIGN KEY (member_assessment_key, event_key, checkpoint_kind, user_key)
        REFERENCES guild.fact_clan_games_member_assessment (member_assessment_key, event_key, checkpoint_kind, user_key),
    FOREIGN KEY (event_key) REFERENCES guild.dim_clan_games_event,
    FOREIGN KEY (account_assessment_key, event_key, player_key, checkpoint_kind, attribution_key)
        REFERENCES guild.fact_clan_games_account_assessment
            (account_assessment_key, event_key, player_key, checkpoint_kind, attribution_key),
    FOREIGN KEY (attribution_key, user_key, player_key)
        REFERENCES guild.metric_attribution_episode (attribution_key, user_key, player_key)
);
-- Freeze the expected episodes and attach their evidence on those same rows.
-- NULL means an expected assessment is missing, not an account with zero points.
-- A later first link may backfill a NEW version without changing this cohort.
CREATE VIEW guild.clan_games_member_expected_account AS
SELECT member_assessment_key, attribution_key FROM guild.clan_games_member_account_input;
CREATE FUNCTION guild.capture_clan_games_member_scope() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    INSERT INTO guild.clan_games_member_account_input (
        member_assessment_key, attribution_key, event_key, checkpoint_kind, player_key, user_key
    )
    SELECT NEW.member_assessment_key, a.attribution_key, e.event_key, NEW.checkpoint_kind,
        a.player_key, a.user_key
    FROM guild.metric_attribution_episode a
    CROSS JOIN guild.dim_clan_games_event e
    WHERE e.event_key = NEW.event_key AND a.user_key = NEW.user_key AND EXISTS (
        SELECT FROM guild.observed_clan_membership_period present
        WHERE present.player_key = a.player_key
            AND greatest(present.observed_since, e.starts_at,
                CASE WHEN a.include_prelink_history THEN e.starts_at ELSE a.first_link_at END)
            < least(coalesce(present.observed_until, present.confirmed_through), present.confirmed_through,
                coalesce(a.closed_at, e.ends_at),
                CASE NEW.checkpoint_kind WHEN 'final' THEN e.ends_at ELSE e.ends_at - interval '24 hours' END)
    );
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_member_scope_snapshot AFTER INSERT ON guild.fact_clan_games_member_assessment
FOR EACH ROW EXECUTE FUNCTION guild.capture_clan_games_member_scope();
CREATE FUNCTION guild.validate_clan_games_member_input() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE expected_user bigint;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'A frozen expected attribution episode cannot be removed' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'UPDATE' AND (
        ROW(NEW.member_assessment_key, NEW.event_key, NEW.checkpoint_kind, NEW.player_key,
            NEW.attribution_key, NEW.user_key) IS DISTINCT FROM
        ROW(OLD.member_assessment_key, OLD.event_key, OLD.checkpoint_kind, OLD.player_key,
            OLD.attribution_key, OLD.user_key)
        OR (OLD.account_assessment_key IS NOT NULL
            AND NEW.account_assessment_key IS DISTINCT FROM OLD.account_assessment_key)
    ) THEN
        RAISE EXCEPTION 'Frozen assessment scope and attached evidence are immutable'
            USING ERRCODE = '23514';
    END IF;
    SELECT m.user_key INTO expected_user
    FROM guild.fact_clan_games_member_assessment m
    WHERE m.member_assessment_key = NEW.member_assessment_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'Member assessment does not exist' USING ERRCODE = '23503'; END IF;
    IF NEW.user_key IS NOT NULL AND NEW.user_key <> expected_user THEN
        RAISE EXCEPTION 'Member input must identify its historical member' USING ERRCODE = '23514';
    END IF;
    NEW.user_key := expected_user;
    RETURN NEW;
END;
$$;
CREATE TRIGGER clan_games_member_input_attribution BEFORE INSERT OR UPDATE OR DELETE
ON guild.clan_games_member_account_input
FOR EACH ROW EXECUTE FUNCTION guild.validate_clan_games_member_input();
CREATE FUNCTION guild.attach_clan_games_member_input(p_member bigint, p_account bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    UPDATE guild.clan_games_member_account_input i
    SET account_assessment_key = p_account
    FROM guild.fact_clan_games_account_assessment a
    WHERE i.member_assessment_key = p_member AND a.account_assessment_key = p_account
        AND i.attribution_key = a.attribution_key
        AND (i.account_assessment_key IS NULL OR i.account_assessment_key = p_account);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account evidence must fill its frozen member scope exactly once'
            USING ERRCODE = '23514';
    END IF;
END;
$$;
COMMENT ON FUNCTION guild.attach_clan_games_member_input IS
    'Trusted assessment worker: attach existing owner-specific evidence to an expected episode. '
    'Exact replay is idempotent; changing evidence or adding omitted scope requires a new member version.';
CREATE VIEW guild.clan_games_member_result AS
SELECT m.member_assessment_key, m.event_key, m.user_key, m.checkpoint_kind, m.calculation_version,
    count(DISTINCT a.player_key) AS account_count,
    sum(a.eligible_points) AS eligible_points,
    10 * ceil(sum(a.required_points) / 10) AS required_points,
    CASE WHEN m.attribution_status <> 'adequate' OR count(a.account_assessment_key) = 0
            OR bool_or(a.result = 'insufficient_data')
            OR bool_or(i.account_assessment_key IS NULL) THEN 'insufficient_data'
        WHEN sum(a.eligible_points) >= 10 * ceil(sum(a.required_points) / 10) THEN 'pass' ELSE 'fail' END AS result,
    sum(a.required_points) AS unrounded_required_points,
    count(a.account_assessment_key) AS attribution_slice_count
FROM guild.fact_clan_games_member_assessment m
LEFT JOIN guild.clan_games_member_account_input i USING (member_assessment_key)
LEFT JOIN guild.fact_clan_games_account_assessment a USING (account_assessment_key)
GROUP BY m.member_assessment_key;
COMMENT ON TABLE guild.clan_games_member_account_input IS
    'One frozen expected attribution episode per member calculation version, with optional source assessment. '
    'Missing evidence remains explicit; completed slices and cohort membership cannot be replaced or removed.';
COMMENT ON VIEW guild.clan_games_member_result IS
    'Sum unrounded ownership-slice targets across accounts/clans, then ceil the member total to a '
    'multiple of ten once. Inadequate evidence stays insufficient_data, never an exemption.';

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
CREATE INDEX membership_poll_recent ON guild.clan_membership_poll (clan_key, observed_at DESC);

-- Indexes follow read paths, not foreign keys as such: dimension rows are never
-- deleted, so no referencing column needs an index for a parent-side check.
-- These cover per-account history, whose keys lead with another column.
CREATE INDEX clan_member_observation_player ON guild.fact_clan_member_observation (player_key, poll_key);
CREATE INDEX clan_membership_change_player
    ON guild.fact_clan_membership_change (player_key, observed_at DESC);
CREATE INDEX war_participant_player ON guild.war_participant (player_key, war_key);
CREATE INDEX raid_member_observation_player
    ON guild.fact_raid_member_observation (player_key, raid_weekend_key);
CREATE INDEX clan_games_progress_player ON guild.fact_clan_games_progress (player_key, event_key);
CREATE INDEX api_fetch_attempt_player ON guild.fact_api_fetch_attempt (player_key, started_at DESC)
    WHERE player_key IS NOT NULL;
-- The collector asks for due work across players, not for one player's requests.
CREATE INDEX clan_games_read_request_due ON guild.clan_games_read_request (due_at)
    WHERE status = 'pending';
-- The transfer limit asks for the reads of one transfer.
CREATE INDEX clan_games_read_request_transfer
    ON guild.clan_games_read_request (transfer_request_key)
    WHERE transfer_request_key IS NOT NULL;
CREATE INDEX clan_games_counter_read_transfer
    ON guild.clan_games_counter_read (transfer_request_key)
    WHERE transfer_request_key IS NOT NULL;
