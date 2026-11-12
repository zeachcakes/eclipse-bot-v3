-- Activity-specific CWL and custom-event stars and constrained workflow state.
-- These functions persist decisions/evidence; they do not call CoC or Sheets.
CREATE TABLE guild.activity_command_operation (
    operation_id uuid PRIMARY KEY,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    action text NOT NULL,
    arguments jsonb NOT NULL CHECK (jsonb_typeof(arguments) = 'object'),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    result_key bigint
);
CREATE TABLE guild.cwl_cycle (
    cycle_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    calendar_month date NOT NULL UNIQUE CHECK (extract(day FROM calendar_month) = 1),
    signup_closes_at timestamptz GENERATED ALWAYS AS
        (calendar_month::timestamp AT TIME ZONE 'UTC') STORED,
    state text NOT NULL DEFAULT 'signups' CHECK (state IN ('signups', 'planning', 'ended')),
    ended_at timestamptz,
    CHECK ((state = 'ended') = (ended_at IS NOT NULL))
);
CREATE VIEW guild.cwl_clan_settings AS
SELECT clan_key, automatic_freeze_minutes, sheet_document_id
FROM guild.clan_collection_settings;
COMMENT ON VIEW guild.cwl_clan_settings IS
    'CWL configuration is stored with the other settings for the same tracked clan.';
CREATE TABLE guild.cwl_participating_clan (
    participation_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cycle_key bigint NOT NULL REFERENCES guild.cwl_cycle,
    clan_key bigint NOT NULL REFERENCES guild.clan_collection_settings,
    lineup_size smallint NOT NULL CHECK (lineup_size IN (15, 30)),
    selected_by bigint NOT NULL REFERENCES guild.dim_discord_user,
    selected_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (cycle_key, clan_key), UNIQUE (participation_key, cycle_key)
);
CREATE TABLE guild.cwl_clan_day (
    participation_key bigint NOT NULL REFERENCES guild.cwl_participating_clan,
    war_day smallint NOT NULL CHECK (war_day BETWEEN 1 AND 7),
    war_key bigint REFERENCES guild.dim_war,
    PRIMARY KEY (participation_key, war_day), UNIQUE (participation_key, war_key)
);
CREATE TABLE guild.fact_cwl_group_observation (
    group_observation_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cycle_key bigint NOT NULL REFERENCES guild.cwl_cycle,
    source_season text NOT NULL CHECK (btrim(source_season) <> ''),
    source_state text NOT NULL,
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL UNIQUE,
    is_complete boolean NOT NULL,
    UNIQUE (group_observation_key, cycle_key)
);
COMMENT ON COLUMN guild.fact_cwl_group_observation.source_season IS
    'Opaque source season, observed as 2026-11-02. Not constrained to YYYY-MM and not a group ID.';
CREATE TABLE guild.fact_cwl_registered_clan (
    group_observation_key bigint NOT NULL REFERENCES guild.fact_cwl_group_observation,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    PRIMARY KEY (group_observation_key, clan_key)
);
CREATE TABLE guild.fact_cwl_registered_player (
    group_observation_key bigint NOT NULL,
    clan_key bigint NOT NULL,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    town_hall_level smallint NOT NULL CHECK (town_hall_level > 0),
    source_name text NOT NULL,
    PRIMARY KEY (group_observation_key, clan_key, player_key),
    FOREIGN KEY (group_observation_key, clan_key) REFERENCES guild.fact_cwl_registered_clan
);
CREATE TABLE guild.cwl_round_war_reference (
    group_observation_key bigint NOT NULL REFERENCES guild.fact_cwl_group_observation,
    round_ordinal smallint NOT NULL CHECK (round_ordinal BETWEEN 1 AND 7),
    source_war_tag text NOT NULL CHECK (source_war_tag <> ''),
    war_key bigint,
    PRIMARY KEY (group_observation_key, round_ordinal, source_war_tag),
    FOREIGN KEY (war_key, source_war_tag) REFERENCES guild.dim_war (war_key, source_war_tag),
    CHECK (source_war_tag <> '#0' OR war_key IS NULL)
);
CREATE TABLE guild.cwl_signup (
    signup_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participation_key bigint NOT NULL,
    cycle_key bigint NOT NULL,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    FOREIGN KEY (participation_key, cycle_key)
        REFERENCES guild.cwl_participating_clan (participation_key, cycle_key),
    UNIQUE (cycle_key, player_key), UNIQUE (signup_key, participation_key, player_key)
);
CREATE FUNCTION guild.valid_cwl_availability(p_days smallint[]) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT p_days IS NOT NULL AND cardinality(p_days) BETWEEN 1 AND 7
        AND NOT EXISTS (SELECT FROM unnest(p_days) AS d WHERE d IS NULL OR d NOT BETWEEN 1 AND 7)
        AND cardinality(p_days) = (SELECT count(DISTINCT d) FROM unnest(p_days) AS d);
$$;
CREATE TABLE guild.fact_cwl_signup_revision (
    signup_revision_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    signup_key bigint NOT NULL REFERENCES guild.cwl_signup,
    revision integer NOT NULL CHECK (revision > 0),
    war_days smallint[] NOT NULL CHECK (guild.valid_cwl_availability(war_days)),
    town_hall_level smallint NOT NULL CHECK (town_hall_level > 0),
    withdrawn boolean NOT NULL DEFAULT false,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    operation_id uuid NOT NULL UNIQUE REFERENCES guild.activity_command_operation,
    UNIQUE (signup_key, revision)
);
CREATE VIEW guild.current_cwl_signup AS
SELECT DISTINCT ON (s.signup_key) s.*, r.signup_revision_key, r.war_days,
    r.town_hall_level, r.withdrawn, r.revision
FROM guild.cwl_signup s JOIN guild.fact_cwl_signup_revision r USING (signup_key)
ORDER BY s.signup_key, r.revision DESC;
CREATE TABLE guild.cwl_plan_revision (
    plan_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participation_key bigint NOT NULL REFERENCES guild.cwl_participating_clan,
    revision integer NOT NULL CHECK (revision > 0),
    source_kind text NOT NULL CHECK (source_kind IN ('automatic', 'manual')),
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    algorithm_version text NOT NULL CHECK (btrim(algorithm_version) <> ''),
    objective text NOT NULL DEFAULT 'maximize_accounts_reaching_eight'
        CHECK (objective = 'maximize_accounts_reaching_eight'),
    phase text NOT NULL CHECK (phase IN ('initial_th_availability', 'current_season_performance')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    published_at timestamptz,
    quality text NOT NULL DEFAULT 'provisional' CHECK (quality IN ('provisional', 'incomplete', 'complete')),
    UNIQUE (participation_key, revision), UNIQUE (plan_key, participation_key),
    CHECK ((source_kind = 'manual') = (actor_user_key IS NOT NULL))
);
CREATE VIEW guild.cwl_plan_day AS
SELECT p.plan_key, d.war_day::smallint AS war_day
FROM guild.cwl_plan_revision p CROSS JOIN generate_series(1, 7) AS d(war_day);
COMMENT ON VIEW guild.cwl_plan_day IS
    'Every plan has all seven days, including days without any assignments.';
CREATE TABLE guild.fact_cwl_plan_input (
    plan_key bigint NOT NULL REFERENCES guild.cwl_plan_revision,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    signup_revision_key bigint NOT NULL REFERENCES guild.fact_cwl_signup_revision,
    current_season_stars bigint NOT NULL CHECK (current_season_stars >= 0),
    current_season_attacks bigint NOT NULL CHECK (current_season_attacks >= 0),
    average_destruction numeric,
    source_war_keys bigint[] NOT NULL,
    rating numeric,
    rating_method text,
    observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (plan_key, player_key),
    CHECK (average_destruction IS NULL OR average_destruction BETWEEN 0 AND 100),
    CHECK ((rating IS NULL) = (rating_method IS NULL))
);
CREATE TABLE guild.cwl_plan_assignment (
    plan_key bigint NOT NULL REFERENCES guild.cwl_plan_revision,
    war_day smallint NOT NULL CHECK (war_day BETWEEN 1 AND 7),
    slot_number smallint NOT NULL CHECK (slot_number BETWEEN 1 AND 30),
    player_key bigint NOT NULL,
    PRIMARY KEY (plan_key, war_day, slot_number), UNIQUE (plan_key, war_day, player_key),
    FOREIGN KEY (plan_key, player_key) REFERENCES guild.fact_cwl_plan_input
);
CREATE TABLE guild.cwl_manual_pin (
    participation_key bigint NOT NULL,
    war_day smallint NOT NULL,
    slot_number smallint NOT NULL CHECK (slot_number BETWEEN 1 AND 30),
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    operation_id uuid NOT NULL REFERENCES guild.activity_command_operation,
    PRIMARY KEY (participation_key, war_day, slot_number), UNIQUE (participation_key, war_day, player_key),
    FOREIGN KEY (participation_key, war_day) REFERENCES guild.cwl_clan_day
);
CREATE TABLE guild.cwl_replan_request (
    request_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participation_key bigint NOT NULL REFERENCES guild.cwl_participating_clan,
    reason text NOT NULL,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_plan_key bigint,
    FOREIGN KEY (completed_plan_key, participation_key) REFERENCES guild.cwl_plan_revision (plan_key, participation_key)
);
CREATE TABLE guild.fact_cwl_bench_incident (
    incident_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participation_key bigint NOT NULL REFERENCES guild.cwl_participating_clan,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    war_key bigint NOT NULL REFERENCES guild.dim_war,
    attack_key bigint REFERENCES guild.fact_war_attack,
    incident_kind text NOT NULL CHECK (incident_kind IN ('poor_attack', 'missed_attack')),
    source_observed_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (participation_key, player_key, war_key), UNIQUE (incident_key, participation_key),
    CHECK ((incident_kind = 'poor_attack') = (attack_key IS NOT NULL))
);
CREATE TABLE guild.fact_cwl_bench_resolution (
    incident_key bigint PRIMARY KEY REFERENCES guild.fact_cwl_bench_incident,
    resolution text NOT NULL CHECK (resolution IN ('served', 'staff_override', 'season_expiry')),
    war_day smallint CHECK (war_day BETWEEN 1 AND 7),
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    resolved_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    operation_id uuid UNIQUE REFERENCES guild.activity_command_operation,
    CHECK ((resolution = 'served') = (war_day IS NOT NULL)),
    CHECK ((resolution = 'staff_override') = (actor_user_key IS NOT NULL))
);
CREATE TABLE guild.cwl_bench_assignment (
    incident_key bigint PRIMARY KEY,
    participation_key bigint NOT NULL,
    war_day smallint NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (incident_key, participation_key) REFERENCES guild.fact_cwl_bench_incident (incident_key, participation_key),
    FOREIGN KEY (participation_key, war_day) REFERENCES guild.cwl_clan_day
);
CREATE TABLE guild.cwl_export_revision (
    export_revision_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participation_key bigint NOT NULL REFERENCES guild.cwl_participating_clan,
    resource_kind text NOT NULL CHECK (resource_kind IN ('signups', 'lineups')),
    signup_revision_key bigint REFERENCES guild.fact_cwl_signup_revision,
    plan_key bigint REFERENCES guild.cwl_plan_revision,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    sheets_state text NOT NULL DEFAULT 'pending' CHECK (sheets_state IN ('pending', 'succeeded', 'failed', 'uncertain')),
    UNIQUE (signup_revision_key), UNIQUE (plan_key),
    CHECK ((resource_kind = 'signups') = (signup_revision_key IS NOT NULL)),
    CHECK ((resource_kind = 'lineups') = (plan_key IS NOT NULL))
);
CREATE TABLE guild.fact_cwl_export_attempt (
    export_attempt_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    export_revision_key bigint NOT NULL REFERENCES guild.cwl_export_revision,
    export_format text NOT NULL CHECK (export_format IN ('csv', 'google_sheets')),
    attempt_number integer NOT NULL CHECK (attempt_number > 0),
    outcome text NOT NULL CHECK (outcome IN ('succeeded', 'failed', 'uncertain')),
    artifact_reference text,
    error_code text,
    attempted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (export_revision_key, export_format, attempt_number)
);
CREATE TABLE guild.custom_event (
    event_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_name text NOT NULL CHECK (btrim(event_name) <> ''),
    state text NOT NULL DEFAULT 'signups' CHECK (state IN ('signups', 'roster', 'completed')),
    created_by bigint NOT NULL REFERENCES guild.dim_discord_user,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    war_key bigint UNIQUE REFERENCES guild.dim_war,
    associated_by bigint REFERENCES guild.dim_discord_user,
    association_operation_id uuid UNIQUE REFERENCES guild.activity_command_operation,
    association_reason text CHECK (btrim(association_reason) <> ''),
    CHECK ((war_key IS NULL AND associated_by IS NULL
            AND association_operation_id IS NULL AND association_reason IS NULL)
        OR (war_key IS NOT NULL AND associated_by IS NOT NULL
            AND association_operation_id IS NOT NULL AND association_reason IS NOT NULL))
);
CREATE TABLE guild.custom_event_signup (
    signup_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.custom_event,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    withdrawn boolean NOT NULL DEFAULT false,
    operation_id uuid NOT NULL REFERENCES guild.activity_command_operation,
    UNIQUE (event_key, player_key), UNIQUE (signup_key, event_key, player_key)
);
CREATE TABLE guild.custom_roster_revision (
    roster_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.custom_event,
    revision integer NOT NULL CHECK (revision > 0),
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    operation_id uuid NOT NULL UNIQUE REFERENCES guild.activity_command_operation,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (event_key, revision), UNIQUE (roster_key, event_key)
);
CREATE TABLE guild.custom_roster_account (
    roster_key bigint NOT NULL,
    event_key bigint NOT NULL,
    player_key bigint NOT NULL,
    signup_key bigint NOT NULL,
    PRIMARY KEY (roster_key, player_key),
    FOREIGN KEY (roster_key, event_key) REFERENCES guild.custom_roster_revision (roster_key, event_key),
    FOREIGN KEY (signup_key, event_key, player_key) REFERENCES guild.custom_event_signup (signup_key, event_key, player_key)
);
CREATE VIEW guild.custom_event_war AS
SELECT event_key, war_key, associated_by,
    association_operation_id AS operation_id, association_reason AS reason
FROM guild.custom_event WHERE war_key IS NOT NULL;
COMMENT ON VIEW guild.custom_event_war IS
    'The event holds one write-once game-war association; conformed war results persist independently of Discord links.';

CREATE FUNCTION guild.cwl_registration_status(p_participation bigint, p_player bigint)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    WITH latest AS (
        SELECT g.group_observation_key FROM guild.fact_cwl_group_observation g
        JOIN guild.cwl_participating_clan p ON p.cycle_key = g.cycle_key
        JOIN guild.fact_cwl_registered_clan c ON c.group_observation_key = g.group_observation_key AND c.clan_key = p.clan_key
        WHERE p.participation_key = p_participation AND g.is_complete
        ORDER BY g.observed_at DESC, g.group_observation_key DESC LIMIT 1
    )
    SELECT CASE WHEN NOT EXISTS (SELECT FROM latest) THEN 'unknown'
        WHEN EXISTS (SELECT FROM latest l JOIN guild.fact_cwl_registered_player r USING (group_observation_key)
            JOIN guild.cwl_participating_clan p ON p.clan_key = r.clan_key
            WHERE p.participation_key = p_participation AND r.player_key = p_player)
        THEN 'registered' ELSE 'not_registered' END;
$$;
CREATE FUNCTION guild.cwl_day_is_frozen(p_participation bigint, p_day smallint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT coalesce(w.started_at - make_interval(mins => s.automatic_freeze_minutes) <= statement_timestamp(), false)
    FROM guild.cwl_clan_day d JOIN guild.cwl_participating_clan p USING (participation_key)
    JOIN guild.cwl_clan_settings s USING (clan_key)
    LEFT JOIN guild.dim_war w ON w.war_key = d.war_key
    WHERE d.participation_key = p_participation AND d.war_day = p_day;
$$;
CREATE FUNCTION guild.cwl_current_performance(p_participation bigint, p_player bigint)
RETURNS TABLE (stars bigint, attacks bigint, average_destruction numeric, source_war_keys bigint[])
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT coalesce(sum(a.stars),0)::bigint, count(a.attack_key), avg(a.destruction_percentage),
        coalesce(array_agg(DISTINCT w.war_key ORDER BY w.war_key) FILTER (WHERE a.attack_key IS NOT NULL), ARRAY[]::bigint[])
    FROM guild.cwl_clan_day d JOIN guild.dim_war w USING (war_key)
    LEFT JOIN guild.fact_war_attack a ON a.war_key = w.war_key AND a.attacker_key = p_player
    WHERE d.participation_key = p_participation AND w.war_kind = 'cwl';
$$;
CREATE FUNCTION guild.cwl_next_bench_day(p_incident bigint)
RETURNS smallint LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT coalesce((SELECT a.war_day FROM guild.cwl_bench_assignment a
            JOIN guild.current_cwl_signup chosen ON chosen.participation_key=a.participation_key AND chosen.player_key=i.player_key
            WHERE a.incident_key=i.incident_key AND NOT chosen.withdrawn AND a.war_day=ANY(chosen.war_days)
                AND guild.cwl_day_is_frozen(a.participation_key,a.war_day)
                AND guild.cwl_registration_status(a.participation_key,i.player_key)<>'not_registered'),
        (SELECT min(d.war_day)::smallint FROM guild.cwl_clan_day d
            JOIN guild.cwl_clan_day source_day ON source_day.participation_key=d.participation_key AND source_day.war_key=i.war_key
            JOIN guild.current_cwl_signup s ON s.participation_key=d.participation_key AND s.player_key=i.player_key
            WHERE d.participation_key=i.participation_key AND d.war_day>source_day.war_day AND NOT s.withdrawn
                AND d.war_day=ANY(s.war_days) AND NOT guild.cwl_day_is_frozen(d.participation_key,d.war_day)
                AND guild.cwl_registration_status(d.participation_key,i.player_key)<>'not_registered'))
    FROM guild.fact_cwl_bench_incident i JOIN guild.cwl_participating_clan p USING(participation_key)
    JOIN guild.cwl_cycle c USING(cycle_key)
    WHERE i.incident_key=p_incident AND c.state<>'ended'
        AND NOT EXISTS(SELECT FROM guild.fact_cwl_bench_resolution r WHERE r.incident_key=i.incident_key);
$$;
CREATE FUNCTION guild.cwl_validate_war_reference() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE p guild.cwl_participating_clan;
BEGIN
    SELECT * INTO p FROM guild.cwl_participating_clan WHERE participation_key = NEW.participation_key;
    IF NEW.war_key IS NOT NULL AND NOT EXISTS (SELECT FROM guild.dim_war w WHERE w.war_key = NEW.war_key
        AND w.war_kind = 'cwl' AND p.clan_key IN (w.clan_a_key,w.clan_b_key) AND w.team_size = p.lineup_size
        AND EXISTS(SELECT FROM guild.cwl_round_war_reference r JOIN guild.fact_cwl_group_observation g USING(group_observation_key)
            JOIN guild.fact_cwl_registered_clan rc USING(group_observation_key)
            WHERE r.war_key=w.war_key AND r.round_ordinal=NEW.war_day AND g.cycle_key=p.cycle_key AND rc.clan_key=p.clan_key)) THEN
        RAISE EXCEPTION 'CWL day requires the correct clan, format and conformed CWL war' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER cwl_day_war BEFORE INSERT OR UPDATE ON guild.cwl_clan_day FOR EACH ROW EXECUTE FUNCTION guild.cwl_validate_war_reference();
CREATE FUNCTION guild.cwl_validate_bench_incident() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE p guild.cwl_participating_clan; w guild.dim_war; reported integer; observed integer;
BEGIN
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan WHERE participation_key = NEW.participation_key;
    SELECT * INTO STRICT w FROM guild.dim_war WHERE war_key = NEW.war_key;
    IF NOT EXISTS(SELECT FROM guild.war_participant WHERE war_key=NEW.war_key AND player_key=NEW.player_key AND clan_key=p.clan_key) THEN
        RAISE EXCEPTION 'Bench incident account must actually belong to this war side' USING ERRCODE='23514';
    END IF;
    IF w.war_kind <> 'cwl' OR NOT EXISTS (SELECT FROM guild.cwl_clan_day
        WHERE participation_key = p.participation_key AND war_key = w.war_key) THEN
        RAISE EXCEPTION 'Bench incidents require this cycle clan CWL war' USING ERRCODE = '23514';
    END IF;
    IF NEW.incident_kind = 'poor_attack' THEN
        IF NOT EXISTS (SELECT FROM guild.fact_war_attack a WHERE a.attack_key = NEW.attack_key
            AND a.war_key = NEW.war_key AND a.attacker_key = NEW.player_key AND a.stars <= 1) THEN
            RAISE EXCEPTION 'Poor attack incident requires this account zero/one-star attack' USING ERRCODE = '23514';
        END IF;
    ELSE
        SELECT attacks INTO reported FROM guild.fact_war_clan_observation
        WHERE war_key = w.war_key AND clan_key = p.clan_key AND observed_at = NEW.source_observed_at AND state = 'warEnded';
        SELECT count(*) INTO observed FROM guild.fact_war_attack a JOIN guild.war_participant r
            ON r.war_key = a.war_key AND r.player_key = a.attacker_key
            WHERE a.war_key = w.war_key AND r.clan_key = p.clan_key;
        IF reported IS NULL OR reported <> observed OR NOT EXISTS (SELECT FROM guild.war_participant
            WHERE war_key = w.war_key AND clan_key = p.clan_key AND player_key = NEW.player_key)
            OR (SELECT count(*) FROM guild.fact_war_roster_observation
                WHERE war_key = w.war_key AND clan_key = p.clan_key AND observed_at = NEW.source_observed_at) <> w.team_size
            OR EXISTS (SELECT FROM guild.fact_war_attack WHERE war_key = w.war_key AND attacker_key = NEW.player_key) THEN
            RAISE EXCEPTION 'Missed attack requires complete ended roster and reconciled attack evidence' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER cwl_bench_incident_evidence BEFORE INSERT ON guild.fact_cwl_bench_incident FOR EACH ROW EXECUTE FUNCTION guild.cwl_validate_bench_incident();
CREATE FUNCTION guild.cwl_validate_assignment() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE plan guild.cwl_plan_revision; p guild.cwl_participating_clan; s guild.current_cwl_signup;
    incident_count integer; blocked boolean;
BEGIN
    SELECT * INTO STRICT plan FROM guild.cwl_plan_revision WHERE plan_key = NEW.plan_key;
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan WHERE participation_key = plan.participation_key;
    IF EXISTS(SELECT FROM guild.cwl_cycle WHERE cycle_key=p.cycle_key AND state='ended') THEN
        RAISE EXCEPTION 'Ended cycle lineups cannot change' USING ERRCODE='23514'; END IF;
    IF plan.source_kind='manual' AND (nullif(current_setting('guild.actor_user_key',true),'') IS NULL
        OR NOT guild.has_bound_role(nullif(current_setting('guild.actor_user_key',true),'')::bigint,ARRAY['co_leader','admin'])) THEN
        RAISE EXCEPTION 'Manual assignments require a current staff command actor' USING ERRCODE='42501';
    END IF;
    IF plan.published_at IS NOT NULL THEN RAISE EXCEPTION 'Published plan assignments are immutable' USING ERRCODE = '23514'; END IF;
    IF NEW.slot_number > p.lineup_size THEN RAISE EXCEPTION 'Slot exceeds selected 15/30 format' USING ERRCODE = '23514'; END IF;
    IF plan.source_kind='automatic' AND guild.cwl_day_is_frozen(p.participation_key,NEW.war_day)
        AND EXISTS(SELECT FROM guild.cwl_plan_assignment old_a JOIN guild.cwl_plan_revision old_r USING(plan_key)
            WHERE old_r.plan_key=(SELECT plan_key FROM guild.cwl_plan_revision WHERE participation_key=p.participation_key
                AND published_at IS NOT NULL ORDER BY revision DESC LIMIT 1)
                AND old_a.war_day=NEW.war_day AND old_a.slot_number=NEW.slot_number AND old_a.player_key=NEW.player_key) THEN
        RETURN NEW;
    END IF;
    SELECT * INTO s FROM guild.current_cwl_signup WHERE participation_key = p.participation_key AND player_key = NEW.player_key;
    IF NOT FOUND OR s.withdrawn OR NOT NEW.war_day = ANY(s.war_days)
        OR guild.cwl_registration_status(p.participation_key, NEW.player_key) = 'not_registered' THEN
        RAISE EXCEPTION 'Account must be signed up, available and not excluded from registered pool' USING ERRCODE = '23514';
    END IF;
    IF plan.source_kind = 'automatic' AND guild.cwl_day_is_frozen(p.participation_key, NEW.war_day) THEN
        RAISE EXCEPTION 'Automatic assignment changes are frozen before actual battle start' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT FROM guild.cwl_manual_pin pin WHERE pin.participation_key = p.participation_key
        AND pin.war_day = NEW.war_day AND (pin.slot_number = NEW.slot_number OR pin.player_key = NEW.player_key)
        AND (pin.slot_number <> NEW.slot_number OR pin.player_key <> NEW.player_key)) THEN
        RAISE EXCEPTION 'Assignment conflicts with an explicit manual pin' USING ERRCODE = '23514';
    END IF;
    SELECT count(*), bool_or(guild.cwl_next_bench_day(i.incident_key) = NEW.war_day)
    INTO incident_count, blocked FROM guild.fact_cwl_bench_incident i
    WHERE i.participation_key = p.participation_key AND i.player_key = NEW.player_key
        AND NOT EXISTS (SELECT FROM guild.fact_cwl_bench_resolution r WHERE r.incident_key = i.incident_key);
    IF incident_count > 1 THEN RAISE EXCEPTION 'Multiple pending incidents require explicit staff resolution; stacking policy is unselected' USING ERRCODE = '23514'; END IF;
    IF EXISTS (SELECT FROM guild.fact_cwl_bench_resolution r JOIN guild.fact_cwl_bench_incident i USING(incident_key)
        WHERE i.participation_key=p.participation_key AND i.player_key=NEW.player_key
            AND r.resolution='served' AND r.war_day=NEW.war_day) THEN
        RAISE EXCEPTION 'Served bench day stays excluded; eligibility returns for later days' USING ERRCODE='23514';
    END IF;
    IF blocked THEN RAISE EXCEPTION 'Account must serve the next eligible available war bench' USING ERRCODE = '23514'; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER cwl_assignment_eligibility BEFORE INSERT OR UPDATE ON guild.cwl_plan_assignment FOR EACH ROW EXECUTE FUNCTION guild.cwl_validate_assignment();

CREATE FUNCTION guild.cwl_begin_plan(p_participation bigint, p_algorithm text,
    p_phase text DEFAULT 'initial_th_availability') RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE result bigint; s record; perf record;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('cwl-plan'), hashtext(p_participation::text));
    IF NOT EXISTS (SELECT FROM guild.cwl_participating_clan p JOIN guild.cwl_cycle c USING(cycle_key)
        WHERE p.participation_key=p_participation AND c.state<>'ended') THEN
        RAISE EXCEPTION 'Unknown participating clan' USING ERRCODE = '23503';
    END IF;
    INSERT INTO guild.cwl_plan_revision (participation_key, revision, source_kind, algorithm_version, phase)
    VALUES (p_participation, coalesce((SELECT max(revision) FROM guild.cwl_plan_revision WHERE participation_key = p_participation),0)+1,
        'automatic',p_algorithm,p_phase) RETURNING plan_key INTO result;
    FOR s IN SELECT * FROM guild.current_cwl_signup WHERE participation_key = p_participation LOOP
        SELECT * INTO perf FROM guild.cwl_current_performance(p_participation,s.player_key);
        INSERT INTO guild.fact_cwl_plan_input (plan_key,player_key,signup_revision_key,current_season_stars,
            current_season_attacks,average_destruction,source_war_keys,observed_at)
        VALUES (result,s.player_key,s.signup_revision_key,perf.stars,perf.attacks,
            perf.average_destruction,perf.source_war_keys,clock_timestamp());
    END LOOP;
    RETURN result;
END;
$$;
CREATE FUNCTION guild.cwl_close_signups(p_cycle bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE c guild.cwl_cycle; p record;
BEGIN
    SELECT * INTO STRICT c FROM guild.cwl_cycle WHERE cycle_key = p_cycle FOR UPDATE;
    IF statement_timestamp() < c.signup_closes_at THEN RAISE EXCEPTION 'Signup deadline has not arrived' USING ERRCODE = '23514'; END IF;
    IF c.state <> 'signups' THEN RETURN; END IF;
    UPDATE guild.cwl_cycle SET state = 'planning' WHERE cycle_key = p_cycle;
    FOR p IN SELECT participation_key FROM guild.cwl_participating_clan WHERE cycle_key = p_cycle LOOP
        PERFORM guild.cwl_begin_plan(p.participation_key,'initial-input-snapshot-v1');
        INSERT INTO guild.cwl_replan_request (participation_key,reason) VALUES (p.participation_key,'signup_close');
    END LOOP;
END;
$$;
COMMENT ON FUNCTION guild.cwl_close_signups IS
    'Immediate seven-day provisional planning artifact/input snapshot plus durable planning work. '
    'An external optimizer fills assignments; no optimal lineup is fabricated by this storage function.';
CREATE FUNCTION guild.cwl_publish_plan(p_plan bigint, p_require_complete boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE plan guild.cwl_plan_revision; p guild.cwl_participating_clan; complete_plan boolean;
BEGIN
    SELECT * INTO STRICT plan FROM guild.cwl_plan_revision WHERE plan_key = p_plan FOR UPDATE;
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan WHERE participation_key = plan.participation_key;
    IF plan.published_at IS NOT NULL THEN RETURN; END IF;
    SELECT count(*) = 7 AND min(n) = p.lineup_size INTO complete_plan FROM (
        SELECT d.war_day,count(a.player_key) n FROM guild.cwl_plan_day d
        LEFT JOIN guild.cwl_plan_assignment a USING (plan_key,war_day)
        WHERE d.plan_key = p_plan GROUP BY d.war_day
    ) days;
    IF p_require_complete AND (NOT coalesce(complete_plan,false) OR EXISTS(SELECT FROM guild.cwl_plan_assignment a
        WHERE a.plan_key=p_plan AND guild.cwl_registration_status(p.participation_key,a.player_key)<>'registered')) THEN
        RAISE EXCEPTION 'Strict availability/eligibility leaves an incomplete seven-day lineup' USING ERRCODE = '23514';
    END IF;
    UPDATE guild.cwl_plan_revision SET published_at = clock_timestamp(),
        quality = CASE WHEN NOT coalesce(complete_plan,false) THEN 'incomplete'
            WHEN EXISTS(SELECT FROM guild.cwl_plan_assignment a WHERE a.plan_key=p_plan
                AND guild.cwl_registration_status(p.participation_key,a.player_key)<>'registered') THEN 'provisional'
            ELSE 'complete' END WHERE plan_key = p_plan;
    INSERT INTO guild.cwl_export_revision (participation_key,resource_kind,plan_key) VALUES (p.participation_key,'lineups',p_plan);
END;
$$;
CREATE FUNCTION guild.cwl_assign_bench(p_incident bigint) RETURNS smallint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE i guild.fact_cwl_bench_incident; target smallint;
BEGIN
    SELECT * INTO STRICT i FROM guild.fact_cwl_bench_incident WHERE incident_key=p_incident FOR UPDATE;
    IF (SELECT count(*) FROM guild.fact_cwl_bench_incident b WHERE b.participation_key=i.participation_key
        AND b.player_key=i.player_key AND NOT EXISTS(SELECT FROM guild.fact_cwl_bench_resolution r WHERE r.incident_key=b.incident_key))>1 THEN
        RAISE EXCEPTION 'Multiple unserved incidents require explicit staff resolution; no stacking rule selected' USING ERRCODE='23514';
    END IF;
    target:=guild.cwl_next_bench_day(p_incident);
    IF target IS NULL THEN RETURN NULL; END IF;
    INSERT INTO guild.cwl_bench_assignment(incident_key,participation_key,war_day)
        VALUES(p_incident,i.participation_key,target) ON CONFLICT(incident_key) DO UPDATE
        SET war_day=EXCLUDED.war_day,assigned_at=clock_timestamp();
    INSERT INTO guild.cwl_replan_request(participation_key,reason) VALUES(i.participation_key,'mandatory_bench');
    RETURN target;
END;
$$;
CREATE FUNCTION guild.cwl_record_bench_service(p_incident bigint,p_day smallint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE i guild.fact_cwl_bench_incident; p guild.cwl_participating_clan; w guild.dim_war; final_observed timestamptz;
BEGIN
    SELECT * INTO STRICT i FROM guild.fact_cwl_bench_incident WHERE incident_key=p_incident FOR UPDATE;
    IF EXISTS(SELECT FROM guild.fact_cwl_bench_resolution WHERE incident_key=p_incident) THEN RETURN; END IF;
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan WHERE participation_key=i.participation_key;
    IF NOT EXISTS(SELECT FROM guild.cwl_bench_assignment WHERE incident_key=p_incident AND war_day=p_day)
        OR p_day IS DISTINCT FROM guild.cwl_next_bench_day(p_incident) THEN
        RAISE EXCEPTION 'Bench service needs its assigned next available eligible day' USING ERRCODE='23514';
    END IF;
    IF NOT EXISTS(SELECT FROM guild.current_cwl_signup WHERE participation_key=p.participation_key
        AND player_key=i.player_key AND NOT withdrawn AND p_day=ANY(war_days)) THEN
        RAISE EXCEPTION 'An unavailable day cannot consume a bench' USING ERRCODE='23514';
    END IF;
    SELECT source_war.* INTO w FROM guild.cwl_clan_day d JOIN guild.dim_war source_war USING(war_key)
        WHERE d.participation_key=p.participation_key AND d.war_day=p_day;
    SELECT max(observed_at) INTO final_observed FROM guild.fact_war_clan_observation
        WHERE war_key=w.war_key AND clan_key=p.clan_key AND state='warEnded';
    IF w.war_key IS NULL OR w.ends_at>statement_timestamp() OR final_observed IS NULL
        OR (SELECT count(*) FROM guild.fact_war_roster_observation WHERE war_key=w.war_key
            AND clan_key=p.clan_key AND observed_at=final_observed)<>w.team_size
        OR EXISTS(SELECT FROM guild.fact_war_roster_observation WHERE war_key=w.war_key
            AND clan_key=p.clan_key AND observed_at=final_observed AND player_key=i.player_key) THEN
        RAISE EXCEPTION 'Served bench requires complete ended actual roster confirming the account skipped that war' USING ERRCODE='23514';
    END IF;
    INSERT INTO guild.fact_cwl_bench_resolution(incident_key,resolution,war_day,reason)
        VALUES(p_incident,'served',p_day,'One available eligible war skipped in completed game evidence');
END;
$$;
CREATE FUNCTION guild.cwl_end_cycle(p_cycle bigint, p_ended_at timestamptz) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF p_ended_at IS NULL OR p_ended_at > statement_timestamp() OR EXISTS(SELECT FROM guild.cwl_clan_day d
        JOIN guild.cwl_participating_clan p USING(participation_key) JOIN guild.dim_war w USING(war_key)
        WHERE p.cycle_key=p_cycle AND w.ends_at>p_ended_at) THEN
        RAISE EXCEPTION 'Cycle end must be observed, not future or before its known wars end' USING ERRCODE='23514'; END IF;
    UPDATE guild.cwl_cycle SET state = 'ended', ended_at = p_ended_at WHERE cycle_key = p_cycle;
    INSERT INTO guild.fact_cwl_bench_resolution (incident_key,resolution,reason)
    SELECT i.incident_key,'season_expiry','Unserved bench expires at season end'
    FROM guild.fact_cwl_bench_incident i JOIN guild.cwl_participating_clan p USING (participation_key)
    WHERE p.cycle_key = p_cycle AND NOT EXISTS (SELECT FROM guild.fact_cwl_bench_resolution r WHERE r.incident_key = i.incident_key);
END;
$$;
CREATE FUNCTION guild.cwl_validate_input_snapshot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE p bigint; perf record;
BEGIN
    SELECT participation_key INTO STRICT p FROM guild.cwl_plan_revision WHERE plan_key = NEW.plan_key;
    IF NOT EXISTS (SELECT FROM guild.fact_cwl_signup_revision r JOIN guild.cwl_signup s USING (signup_key)
        WHERE r.signup_revision_key = NEW.signup_revision_key AND s.participation_key = p AND s.player_key = NEW.player_key) THEN
        RAISE EXCEPTION 'Plan input must reference this clan account signup revision' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO perf FROM guild.cwl_current_performance(p,NEW.player_key);
    IF (NEW.current_season_stars,NEW.current_season_attacks,NEW.average_destruction,NEW.source_war_keys)
        IS DISTINCT FROM (perf.stars,perf.attacks,perf.average_destruction,perf.source_war_keys) THEN
        RAISE EXCEPTION 'Performance snapshot must equal current-cycle conformed CWL evidence only' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER cwl_input_current_season BEFORE INSERT ON guild.fact_cwl_plan_input FOR EACH ROW EXECUTE FUNCTION guild.cwl_validate_input_snapshot();
CREATE FUNCTION guild.cwl_validate_resolution() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE i guild.fact_cwl_bench_incident; p guild.cwl_participating_clan;
BEGIN
    SELECT * INTO STRICT i FROM guild.fact_cwl_bench_incident WHERE incident_key = NEW.incident_key;
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan WHERE participation_key = i.participation_key;
    IF NEW.resolution = 'staff_override' AND NOT guild.has_bound_role(NEW.actor_user_key,ARRAY['co_leader','admin']) THEN
        RAISE EXCEPTION 'Current Co-leader/Admin role required to override bench' USING ERRCODE = '42501';
    END IF;
    IF NEW.resolution = 'season_expiry' AND NOT EXISTS (SELECT FROM guild.cwl_cycle WHERE cycle_key = p.cycle_key AND state = 'ended') THEN
        RAISE EXCEPTION 'Unserved bench expires only when this cycle ends' USING ERRCODE = '23514';
    END IF;
    IF NEW.resolution = 'served' THEN
        IF NOT EXISTS(SELECT FROM guild.cwl_bench_assignment a WHERE a.incident_key=i.incident_key AND a.war_day=NEW.war_day) OR
            (SELECT count(*) FROM guild.fact_cwl_bench_incident b
                WHERE b.participation_key = i.participation_key AND b.player_key = i.player_key
                    AND NOT EXISTS (SELECT FROM guild.fact_cwl_bench_resolution r WHERE r.incident_key = b.incident_key)) > 1 THEN
            RAISE EXCEPTION 'Bench service requires the one next eligible day; incident stacking remains unselected' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER cwl_bench_resolution_valid BEFORE INSERT ON guild.fact_cwl_bench_resolution FOR EACH ROW EXECUTE FUNCTION guild.cwl_validate_resolution();
CREATE FUNCTION guild.cwl_validate_pin() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE p guild.cwl_participating_clan; s guild.current_cwl_signup;
BEGIN
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan WHERE participation_key = NEW.participation_key;
    IF EXISTS(SELECT FROM guild.cwl_cycle WHERE cycle_key=p.cycle_key AND state='ended') THEN
        RAISE EXCEPTION 'Ended cycle pins cannot change' USING ERRCODE='23514'; END IF;
    IF NOT guild.has_bound_role(NEW.actor_user_key,ARRAY['co_leader','admin']) THEN
        RAISE EXCEPTION 'Current Co-leader/Admin role required for a manual pin' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO s FROM guild.current_cwl_signup WHERE participation_key = p.participation_key AND player_key = NEW.player_key;
    IF NOT FOUND OR s.withdrawn OR NOT NEW.war_day = ANY(s.war_days) OR NEW.slot_number > p.lineup_size
        OR guild.cwl_registration_status(p.participation_key,NEW.player_key) = 'not_registered' THEN
        RAISE EXCEPTION 'Manual selection must respect account availability, format and registration' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT FROM guild.fact_cwl_bench_incident i WHERE i.participation_key = p.participation_key
        AND i.player_key = NEW.player_key AND guild.cwl_next_bench_day(i.incident_key) = NEW.war_day)
        OR EXISTS (SELECT FROM guild.fact_cwl_bench_resolution r JOIN guild.fact_cwl_bench_incident i USING (incident_key)
            WHERE i.participation_key = p.participation_key AND i.player_key = NEW.player_key AND r.resolution = 'served' AND r.war_day = NEW.war_day) THEN
        RAISE EXCEPTION 'A manual pin does not implicitly override a bench' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER cwl_pin_eligibility BEFORE INSERT OR UPDATE ON guild.cwl_manual_pin FOR EACH ROW EXECUTE FUNCTION guild.cwl_validate_pin();
CREATE FUNCTION guild.custom_validate_war_association() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.war_key IS NOT NULL THEN
            RAISE EXCEPTION 'Custom event war association is retained indefinitely' USING ERRCODE = '23514';
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.war_key IS NOT NULL
        AND (NEW.event_key, NEW.war_key, NEW.associated_by,
            NEW.association_operation_id, NEW.association_reason)
        IS DISTINCT FROM (OLD.event_key, OLD.war_key, OLD.associated_by,
            OLD.association_operation_id, OLD.association_reason) THEN
        RAISE EXCEPTION 'Custom event war association is write-once' USING ERRCODE = '23514';
    END IF;
    IF NEW.war_key IS NOT NULL AND NOT EXISTS (
        SELECT FROM guild.dim_war WHERE war_key = NEW.war_key AND war_kind = 'custom') THEN
        RAISE EXCEPTION 'Custom event association requires a conformed custom war' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER custom_war_kind BEFORE INSERT OR UPDATE OR DELETE ON guild.custom_event
FOR EACH ROW EXECUTE FUNCTION guild.custom_validate_war_association();

-- Activity commands: one typed function per action. They share retry
-- identity and actor scope through the helpers below and never grant runtime
-- an arbitrary table write. The stored arguments are the typed arguments,
-- never API tokens or request bodies.

-- A replay of a completed operation returns its stored result before any
-- authorization check: losing a role later must not turn a retry into an error.
CREATE FUNCTION guild.activity_replay(p_actor bigint, p_operation uuid, p_action text,
    p_arguments jsonb, OUT replayed boolean, OUT result_key bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    op guild.activity_command_operation;
BEGIN
    IF p_actor IS NULL OR p_operation IS NULL THEN
        RAISE EXCEPTION 'Actor and stable operation UUID required' USING ERRCODE = '23514';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('activity-operation'), hashtext(p_operation::text));
    SELECT * INTO op FROM guild.activity_command_operation WHERE operation_id = p_operation;
    replayed := FOUND;
    IF replayed AND (op.actor_user_key, op.action, op.arguments)
        IS DISTINCT FROM (p_actor, p_action, p_arguments) THEN
        RAISE EXCEPTION 'Operation identity reused with different arguments' USING ERRCODE = '23514';
    END IF;
    result_key := op.result_key;
END;
$$;

-- Records the operation and opens the actor scope. cwl_validate_assignment
-- reads the actor to check that a manual lineup comes from staff.
CREATE FUNCTION guild.activity_start(p_actor bigint, p_operation uuid, p_action text,
    p_arguments jsonb, p_reason text)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    INSERT INTO guild.activity_command_operation (operation_id, actor_user_key, action, arguments)
    VALUES (p_operation, p_actor, p_action, p_arguments);
    RETURN guild.begin_command_scope(p_actor,
        coalesce(nullif(btrim(p_reason), ''), 'Activity command: ' || p_action));
END;
$$;

CREATE FUNCTION guild.activity_finish(p_operation uuid, p_result bigint, p_previous text[])
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    UPDATE guild.activity_command_operation SET result_key = p_result
    WHERE operation_id = p_operation;
    PERFORM guild.end_command_scope(p_previous);
    RETURN p_result;
END;
$$;

CREATE FUNCTION guild.activity_require_staff(p_actor bigint)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF NOT guild.has_bound_role(p_actor, ARRAY['co_leader', 'admin']) THEN
        RAISE EXCEPTION 'Current Co-leader/Admin role required' USING ERRCODE = '42501';
    END IF;
END;
$$;

-- A member acts for their own linked account; staff act for any account.
-- Returns whether the actor is staff.
CREATE FUNCTION guild.activity_require_account(p_actor bigint, p_player bigint)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    staff boolean := guild.has_bound_role(p_actor, ARRAY['co_leader', 'admin']);
BEGIN
    IF NOT staff AND NOT EXISTS (SELECT FROM guild.account_link WHERE user_key = p_actor
        AND player_key = p_player AND unlinked_at IS NULL) THEN
        RAISE EXCEPTION 'Own linked account or Co-leader/Admin role required'
            USING ERRCODE = '42501';
    END IF;
    RETURN staff;
END;
$$;

CREATE FUNCTION guild.cwl_create_cycle(p_actor bigint, p_operation uuid,
    p_calendar_month date)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('calendar_month', p_calendar_month);
    prior record;
    previous text[];
    result bigint;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'create_cycle', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    IF NOT guild.can_configure(p_actor) THEN
        RAISE EXCEPTION 'Configuration permission required' USING ERRCODE = '42501';
    END IF;
    previous := guild.activity_start(p_actor, p_operation, 'create_cycle', args, NULL);
    INSERT INTO guild.cwl_cycle (calendar_month) VALUES (p_calendar_month)
    RETURNING cycle_key INTO result;
    RETURN guild.activity_finish(p_operation, result, previous);
END;
$$;

CREATE FUNCTION guild.cwl_select_clan(p_actor bigint, p_operation uuid,
    p_cycle_key bigint, p_clan_key bigint, p_lineup_size integer)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('cycle_key', p_cycle_key, 'clan_key', p_clan_key,
        'lineup_size', p_lineup_size);
    prior record;
    previous text[];
    c guild.cwl_cycle;
    result bigint;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'select_clan', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    IF NOT guild.has_bound_role(p_actor, ARRAY['leadership', 'co_leader', 'admin']) THEN
        RAISE EXCEPTION 'Leadership role required to select participating clans'
            USING ERRCODE = '42501';
    END IF;
    previous := guild.activity_start(p_actor, p_operation, 'select_clan', args, NULL);
    SELECT * INTO STRICT c FROM guild.cwl_cycle WHERE cycle_key = p_cycle_key;
    IF c.state <> 'signups' OR statement_timestamp() >= c.signup_closes_at THEN
        RAISE EXCEPTION 'Participating clans are selected before signup close'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.clan_collection_settings
        WHERE clan_key = p_clan_key AND enabled) THEN
        RAISE EXCEPTION 'Participating clan must be an enabled tracked clan'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.cwl_participating_clan (cycle_key, clan_key, lineup_size, selected_by)
    VALUES (c.cycle_key, p_clan_key, p_lineup_size, p_actor)
    RETURNING participation_key INTO result;
    INSERT INTO guild.cwl_clan_day SELECT result, d, NULL FROM generate_series(1, 7) d;
    RETURN guild.activity_finish(p_operation, result, previous);
END;
$$;

CREATE FUNCTION guild.cwl_signup(p_actor bigint, p_operation uuid,
    p_participation_key bigint, p_player_key bigint, p_war_days integer[],
    p_town_hall_level integer, p_withdrawn boolean)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('participation_key', p_participation_key,
        'player_key', p_player_key, 'war_days', to_jsonb(p_war_days),
        'town_hall_level', p_town_hall_level, 'withdrawn', p_withdrawn);
    prior record;
    previous text[];
    staff boolean;
    p guild.cwl_participating_clan;
    c guild.cwl_cycle;
    s guild.cwl_signup;
    days smallint[];
    rev integer;
    result bigint;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'signup', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    staff := guild.activity_require_account(p_actor, p_player_key);
    previous := guild.activity_start(p_actor, p_operation, 'signup', args, NULL);
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan
    WHERE participation_key = p_participation_key;
    SELECT * INTO STRICT c FROM guild.cwl_cycle WHERE cycle_key = p.cycle_key;
    IF c.state = 'ended' OR (NOT staff
        AND (statement_timestamp() >= c.signup_closes_at OR c.state <> 'signups')) THEN
        RAISE EXCEPTION 'Only Co-leader/Admin staff may add or edit after close'
            USING ERRCODE = '42501';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('cwl-signup'),
        hashtext(c.cycle_key::text || ':' || p_player_key::text));
    SELECT array_agg(d::smallint ORDER BY d) INTO days FROM unnest(p_war_days) d;
    SELECT * INTO s FROM guild.cwl_signup WHERE cycle_key = c.cycle_key AND player_key = p_player_key;
    IF FOUND AND s.participation_key <> p.participation_key THEN
        RAISE EXCEPTION 'Account already signs up to another target clan in this cycle'
            USING ERRCODE = '23514';
    END IF;
    IF NOT FOUND THEN
        INSERT INTO guild.cwl_signup (participation_key, cycle_key, player_key)
        VALUES (p.participation_key, c.cycle_key, p_player_key) RETURNING * INTO s;
    END IF;
    SELECT coalesce(max(revision), 0) + 1 INTO rev FROM guild.fact_cwl_signup_revision
    WHERE signup_key = s.signup_key;
    INSERT INTO guild.fact_cwl_signup_revision (signup_key, revision, war_days,
        town_hall_level, withdrawn, actor_user_key, operation_id)
    VALUES (s.signup_key, rev, days, p_town_hall_level, coalesce(p_withdrawn, false),
        p_actor, p_operation)
    RETURNING signup_revision_key INTO result;
    INSERT INTO guild.cwl_export_revision (participation_key, resource_kind, signup_revision_key)
    VALUES (p.participation_key, 'signups', result);
    INSERT INTO guild.cwl_replan_request (participation_key, reason)
    VALUES (p.participation_key, 'signup_revision');
    RETURN guild.activity_finish(p_operation, result, previous);
END;
$$;

CREATE FUNCTION guild.cwl_manual_plan(p_actor bigint, p_operation uuid,
    p_participation_key bigint, p_algorithm_version text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('participation_key', p_participation_key,
        'algorithm_version', p_algorithm_version);
    prior record;
    previous text[];
    p guild.cwl_participating_clan;
    result bigint;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'manual_plan', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_staff(p_actor);
    previous := guild.activity_start(p_actor, p_operation, 'manual_plan', args, NULL);
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan
    WHERE participation_key = p_participation_key;
    result := guild.cwl_begin_plan(p.participation_key,
        coalesce(p_algorithm_version, 'staff-selection'), 'current_season_performance');
    UPDATE guild.cwl_plan_revision SET source_kind = 'manual', actor_user_key = p_actor
    WHERE plan_key = result;
    RETURN guild.activity_finish(p_operation, result, previous);
END;
$$;

CREATE FUNCTION guild.cwl_set_assignment(p_actor bigint, p_operation uuid,
    p_plan_key bigint, p_war_day integer, p_slot_number integer, p_player_key bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('plan_key', p_plan_key, 'war_day', p_war_day,
        'slot_number', p_slot_number, 'player_key', p_player_key);
    prior record;
    previous text[];
    plan bigint;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'set_assignment', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_staff(p_actor);
    previous := guild.activity_start(p_actor, p_operation, 'set_assignment', args, NULL);
    SELECT r.plan_key INTO STRICT plan FROM guild.cwl_plan_revision r
    WHERE r.plan_key = p_plan_key AND r.source_kind = 'manual';
    INSERT INTO guild.cwl_plan_assignment VALUES (plan, p_war_day, p_slot_number, p_player_key);
    RETURN guild.activity_finish(p_operation, plan, previous);
END;
$$;

CREATE FUNCTION guild.cwl_pin(p_actor bigint, p_operation uuid, p_participation_key bigint,
    p_war_day integer, p_slot_number integer, p_player_key bigint, p_reason text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('participation_key', p_participation_key,
        'war_day', p_war_day, 'slot_number', p_slot_number, 'player_key', p_player_key,
        'reason', p_reason);
    prior record;
    previous text[];
    p guild.cwl_participating_clan;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'pin', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_staff(p_actor);
    previous := guild.activity_start(p_actor, p_operation, 'pin', args, p_reason);
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan
    WHERE participation_key = p_participation_key;
    IF nullif(btrim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'Manual selection reason required' USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.cwl_manual_pin (participation_key, war_day, slot_number, player_key,
        actor_user_key, reason, operation_id)
    VALUES (p.participation_key, p_war_day, p_slot_number, p_player_key, p_actor, p_reason,
        p_operation)
    ON CONFLICT (participation_key, war_day, slot_number) DO UPDATE
    SET player_key = EXCLUDED.player_key, actor_user_key = EXCLUDED.actor_user_key,
        reason = EXCLUDED.reason, operation_id = EXCLUDED.operation_id;
    INSERT INTO guild.cwl_replan_request (participation_key, reason)
    VALUES (p.participation_key, 'manual_pin');
    RETURN guild.activity_finish(p_operation, p.participation_key, previous);
END;
$$;

CREATE FUNCTION guild.cwl_unpin(p_actor bigint, p_operation uuid, p_participation_key bigint,
    p_war_day integer, p_slot_number integer, p_reason text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('participation_key', p_participation_key,
        'war_day', p_war_day, 'slot_number', p_slot_number, 'reason', p_reason);
    prior record;
    previous text[];
    p guild.cwl_participating_clan;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'unpin', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_staff(p_actor);
    previous := guild.activity_start(p_actor, p_operation, 'unpin', args, p_reason);
    SELECT * INTO STRICT p FROM guild.cwl_participating_clan
    WHERE participation_key = p_participation_key;
    DELETE FROM guild.cwl_manual_pin WHERE participation_key = p.participation_key
        AND war_day = p_war_day AND slot_number = p_slot_number;
    INSERT INTO guild.cwl_replan_request (participation_key, reason)
    VALUES (p.participation_key, 'manual_unpin');
    RETURN guild.activity_finish(p_operation, p.participation_key, previous);
END;
$$;

CREATE FUNCTION guild.cwl_override_bench(p_actor bigint, p_operation uuid,
    p_incident_key bigint, p_reason text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('incident_key', p_incident_key, 'reason', p_reason);
    prior record;
    previous text[];
    incident guild.fact_cwl_bench_incident;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'override_bench', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_staff(p_actor);
    previous := guild.activity_start(p_actor, p_operation, 'override_bench', args, p_reason);
    SELECT i.* INTO STRICT incident FROM guild.fact_cwl_bench_incident i
    WHERE i.incident_key = p_incident_key;
    INSERT INTO guild.fact_cwl_bench_resolution (incident_key, resolution, actor_user_key,
        reason, operation_id)
    VALUES (incident.incident_key, 'staff_override', p_actor, p_reason, p_operation);
    RETURN guild.activity_finish(p_operation, incident.incident_key, previous);
END;
$$;

CREATE FUNCTION guild.custom_event_create(p_actor bigint, p_operation uuid, p_event_name text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('event_name', p_event_name);
    prior record;
    previous text[];
    result bigint;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'custom_create', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_staff(p_actor);
    previous := guild.activity_start(p_actor, p_operation, 'custom_create', args, NULL);
    INSERT INTO guild.custom_event (event_name, created_by) VALUES (p_event_name, p_actor)
    RETURNING event_key INTO result;
    RETURN guild.activity_finish(p_operation, result, previous);
END;
$$;

CREATE FUNCTION guild.custom_event_signup(p_actor bigint, p_operation uuid,
    p_event_key bigint, p_player_key bigint, p_withdrawn boolean)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('event_key', p_event_key, 'player_key', p_player_key,
        'withdrawn', p_withdrawn);
    prior record;
    previous text[];
    event guild.custom_event;
    result bigint;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'custom_signup', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_account(p_actor, p_player_key);
    previous := guild.activity_start(p_actor, p_operation, 'custom_signup', args, NULL);
    SELECT * INTO STRICT event FROM guild.custom_event WHERE event_key = p_event_key;
    IF event.state = 'completed' THEN
        RAISE EXCEPTION 'Completed event signup history is closed' USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.custom_event_signup (event_key, player_key, actor_user_key, withdrawn,
        operation_id)
    VALUES (event.event_key, p_player_key, p_actor, coalesce(p_withdrawn, false), p_operation)
    ON CONFLICT (event_key, player_key) DO UPDATE
    SET withdrawn = EXCLUDED.withdrawn, actor_user_key = EXCLUDED.actor_user_key,
        operation_id = EXCLUDED.operation_id
    RETURNING signup_key INTO result;
    RETURN guild.activity_finish(p_operation, result, previous);
END;
$$;

CREATE FUNCTION guild.custom_event_roster(p_actor bigint, p_operation uuid,
    p_event_key bigint, p_player_keys bigint[], p_reason text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('event_key', p_event_key,
        'player_keys', to_jsonb(p_player_keys), 'reason', p_reason);
    prior record;
    previous text[];
    event guild.custom_event;
    rev integer;
    player bigint;
    input_signup bigint;
    result bigint;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'custom_roster', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_staff(p_actor);
    previous := guild.activity_start(p_actor, p_operation, 'custom_roster', args, p_reason);
    SELECT * INTO STRICT event FROM guild.custom_event WHERE event_key = p_event_key FOR UPDATE;
    IF event.state = 'completed' THEN
        RAISE EXCEPTION 'Completed event roster cannot be rewritten' USING ERRCODE = '23514';
    END IF;
    SELECT coalesce(max(revision), 0) + 1 INTO rev FROM guild.custom_roster_revision
    WHERE event_key = event.event_key;
    INSERT INTO guild.custom_roster_revision (event_key, revision, actor_user_key, reason,
        operation_id)
    VALUES (event.event_key, rev, p_actor, p_reason, p_operation)
    RETURNING roster_key INTO result;
    FOREACH player IN ARRAY coalesce(p_player_keys, ARRAY[]::bigint[]) LOOP
        SELECT signup_key INTO STRICT input_signup FROM guild.custom_event_signup
        WHERE event_key = event.event_key AND player_key = player AND NOT withdrawn;
        INSERT INTO guild.custom_roster_account
        VALUES (result, event.event_key, player, input_signup);
    END LOOP;
    UPDATE guild.custom_event SET state = 'roster' WHERE event_key = event.event_key;
    RETURN guild.activity_finish(p_operation, result, previous);
END;
$$;

CREATE FUNCTION guild.custom_event_result(p_actor bigint, p_operation uuid,
    p_event_key bigint, p_war_key bigint, p_reason text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('event_key', p_event_key, 'war_key', p_war_key,
        'reason', p_reason);
    prior record;
    previous text[];
    event guild.custom_event;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'custom_result', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_staff(p_actor);
    previous := guild.activity_start(p_actor, p_operation, 'custom_result', args, p_reason);
    SELECT * INTO STRICT event FROM guild.custom_event WHERE event_key = p_event_key;
    IF event.war_key IS NOT NULL THEN
        RAISE EXCEPTION 'Custom event already has a game-war association'
            USING ERRCODE = '23514';
    END IF;
    UPDATE guild.custom_event SET war_key = p_war_key, associated_by = p_actor,
        association_operation_id = p_operation, association_reason = p_reason
    WHERE event_key = event.event_key;
    RETURN guild.activity_finish(p_operation, event.event_key, previous);
END;
$$;

CREATE FUNCTION guild.custom_event_complete(p_actor bigint, p_operation uuid,
    p_event_key bigint, p_reason text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    args jsonb := jsonb_build_object('event_key', p_event_key, 'reason', p_reason);
    prior record;
    previous text[];
    event guild.custom_event;
BEGIN
    SELECT * INTO prior FROM guild.activity_replay(p_actor, p_operation, 'custom_complete', args);
    IF prior.replayed THEN RETURN prior.result_key; END IF;
    PERFORM guild.activity_require_staff(p_actor);
    previous := guild.activity_start(p_actor, p_operation, 'custom_complete', args, p_reason);
    SELECT * INTO STRICT event FROM guild.custom_event WHERE event_key = p_event_key;
    UPDATE guild.custom_event SET state = 'completed' WHERE event_key = event.event_key;
    RETURN guild.activity_finish(p_operation, event.event_key, previous);
END;
$$;

-- Append-only evidence and frozen historical revisions. Mutable signup, pin and
-- event projections keep their history in these facts, not in a change ledger.
DO $$
DECLARE tab text;
BEGIN
    FOREACH tab IN ARRAY ARRAY['fact_cwl_group_observation','fact_cwl_registered_clan','fact_cwl_registered_player',
        'fact_cwl_signup_revision','fact_cwl_plan_input','fact_cwl_bench_incident',
        'fact_cwl_bench_resolution','fact_cwl_export_attempt','custom_roster_revision','custom_roster_account'] LOOP
        EXECUTE format('CREATE TRIGGER reject_history_mutation BEFORE UPDATE OR DELETE ON guild.%I '
            ||'FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation()',tab);
    END LOOP;
END;
$$;
CREATE FUNCTION guild.cwl_pending_war_reference() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND ((NEW.group_observation_key,NEW.round_ordinal,NEW.source_war_tag)
        IS DISTINCT FROM (OLD.group_observation_key,OLD.round_ordinal,OLD.source_war_tag)
        OR (OLD.war_key IS NOT NULL AND NEW.war_key IS DISTINCT FROM OLD.war_key)) THEN
        RAISE EXCEPTION 'Source round/tag history is immutable; only resolve a pending war key' USING ERRCODE='23514';
    END IF;
    IF NEW.war_key IS NOT NULL AND NOT EXISTS(SELECT FROM guild.dim_war WHERE war_key=NEW.war_key AND war_kind='cwl') THEN
        RAISE EXCEPTION 'League round requires a conformed CWL war' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER cwl_pending_reference BEFORE INSERT OR UPDATE ON guild.cwl_round_war_reference
FOR EACH ROW EXECUTE FUNCTION guild.cwl_pending_war_reference();
CREATE TRIGGER cwl_reference_no_delete BEFORE DELETE ON guild.cwl_round_war_reference
FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation();
CREATE FUNCTION guild.cwl_project_export_attempt() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF NEW.export_format='google_sheets' AND NOT EXISTS(SELECT FROM guild.fact_cwl_export_attempt a
        WHERE a.export_revision_key=NEW.export_revision_key AND a.export_format='google_sheets' AND a.attempt_number>NEW.attempt_number) THEN
        UPDATE guild.cwl_export_revision SET sheets_state=NEW.outcome WHERE export_revision_key=NEW.export_revision_key;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER cwl_export_outcome AFTER INSERT ON guild.fact_cwl_export_attempt
FOR EACH ROW EXECUTE FUNCTION guild.cwl_project_export_attempt();
CREATE FUNCTION guild.cwl_validate_plan_publication() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE previous_plan bigint; day_row record;
BEGIN
    IF (NEW.participation_key,NEW.revision) IS DISTINCT FROM (OLD.participation_key,OLD.revision)
        OR (OLD.published_at IS NOT NULL AND NEW IS DISTINCT FROM OLD) THEN
        RAISE EXCEPTION 'Published revisions and plan identity cannot be rewritten' USING ERRCODE='23514';
    END IF;
    IF NEW.published_at IS NULL THEN RETURN NEW; END IF;
    SELECT plan_key INTO previous_plan FROM guild.cwl_plan_revision WHERE participation_key=NEW.participation_key
        AND published_at IS NOT NULL ORDER BY revision DESC LIMIT 1;
    IF NEW.source_kind='automatic' THEN
        FOR day_row IN SELECT war_day FROM guild.cwl_clan_day WHERE participation_key=NEW.participation_key LOOP
            IF guild.cwl_day_is_frozen(NEW.participation_key,day_row.war_day) AND (
                EXISTS(SELECT slot_number,player_key FROM guild.cwl_plan_assignment WHERE plan_key=NEW.plan_key AND war_day=day_row.war_day
                    EXCEPT SELECT slot_number,player_key FROM guild.cwl_plan_assignment WHERE plan_key=previous_plan AND war_day=day_row.war_day)
                OR EXISTS(SELECT slot_number,player_key FROM guild.cwl_plan_assignment WHERE plan_key=previous_plan AND war_day=day_row.war_day
                    EXCEPT SELECT slot_number,player_key FROM guild.cwl_plan_assignment WHERE plan_key=NEW.plan_key AND war_day=day_row.war_day)) THEN
                RAISE EXCEPTION 'Automatic publication cannot change a lineup frozen since draft creation' USING ERRCODE='23514';
            END IF;
        END LOOP;
    ELSIF NOT guild.has_bound_role(NEW.actor_user_key,ARRAY['co_leader','admin']) THEN
        RAISE EXCEPTION 'Manual publication requires its staff actor still hold the current role' USING ERRCODE='42501';
    END IF;
    IF EXISTS(SELECT FROM guild.cwl_plan_assignment a
        LEFT JOIN guild.current_cwl_signup s ON s.participation_key=NEW.participation_key AND s.player_key=a.player_key
        JOIN guild.fact_cwl_plan_input input ON input.plan_key=a.plan_key AND input.player_key=a.player_key
        WHERE a.plan_key=NEW.plan_key
            AND NOT (NEW.source_kind='automatic' AND guild.cwl_day_is_frozen(NEW.participation_key,a.war_day))
            AND (s.signup_key IS NULL OR s.withdrawn OR NOT a.war_day=ANY(s.war_days)
                OR input.signup_revision_key<>s.signup_revision_key
                OR guild.cwl_registration_status(NEW.participation_key,a.player_key)='not_registered'
                OR EXISTS(SELECT FROM guild.fact_cwl_bench_incident i
                    WHERE i.participation_key=NEW.participation_key AND i.player_key=a.player_key
                        AND guild.cwl_next_bench_day(i.incident_key)=a.war_day)
                OR EXISTS(SELECT FROM guild.fact_cwl_bench_resolution r JOIN guild.fact_cwl_bench_incident i USING(incident_key)
                    WHERE i.participation_key=NEW.participation_key AND i.player_key=a.player_key AND r.resolution='served' AND r.war_day=a.war_day))) THEN
        RAISE EXCEPTION 'Publication must revalidate current signup, registration, input revision and bench evidence' USING ERRCODE='23514';
    END IF;
    IF EXISTS(SELECT FROM guild.cwl_manual_pin pin WHERE pin.participation_key=NEW.participation_key
        AND NOT EXISTS(SELECT FROM guild.cwl_plan_assignment a WHERE a.plan_key=NEW.plan_key AND a.war_day=pin.war_day
            AND a.slot_number=pin.slot_number AND a.player_key=pin.player_key)) THEN
        RAISE EXCEPTION 'Published plan must preserve all explicit manual pins' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER cwl_plan_publication BEFORE UPDATE ON guild.cwl_plan_revision
FOR EACH ROW EXECUTE FUNCTION guild.cwl_validate_plan_publication();
