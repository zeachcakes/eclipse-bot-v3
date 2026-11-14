-- Guild owns both operational control state and the CoC activity stars.
-- A collection timestamp is evidence, not the time an in-game action occurred.

CREATE TABLE guild.clan_collection_settings (
    clan_key bigint PRIMARY KEY REFERENCES guild.dim_clan,
    enabled boolean NOT NULL DEFAULT true,
    membership_poll_seconds integer NOT NULL DEFAULT 120 CHECK (membership_poll_seconds > 0),
    -- Collection cadences agreed as defaults on 2026-11-14 (DEC-04, CFG-001).
    war_poll_seconds integer NOT NULL DEFAULT 120 CHECK (war_poll_seconds > 0),
    player_profile_seconds integer NOT NULL DEFAULT 3600 CHECK (player_profile_seconds > 0),
    cwl_group_poll_seconds integer NOT NULL DEFAULT 900 CHECK (cwl_group_poll_seconds > 0),
    cwl_war_poll_seconds integer NOT NULL DEFAULT 120 CHECK (cwl_war_poll_seconds > 0),
    raid_poll_seconds integer NOT NULL DEFAULT 900 CHECK (raid_poll_seconds > 0),
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
    'A row is stored only when the state changed; the guild service decides. '
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
    -- Overlap is excluded only within one clan. Two clans poll on their own
    -- cycles, so a move can be observed in the new clan before the old clan
    -- observes the departure; both real boundaries are kept.
    EXCLUDE USING gist (player_key WITH =, clan_key WITH =,
        tstzrange(observed_since, observed_until, '[)') WITH &&)
);

-- The guild service closes a period only with an observed_departure from a
-- complete poll at exactly that boundary; failed or incomplete polls never
-- produce a departure. This index finds that evidence.
CREATE INDEX membership_departure_boundary
ON guild.fact_clan_membership_change (clan_key, player_key, observed_at)
WHERE change_kind = 'observed_departure';

COMMENT ON TABLE guild.observed_clan_membership_period IS
    'Derived observation-based intervals, not exact game join times. Closing requires a matching '
    'observed_departure from a complete poll at observed_until. confirmed_through remains the '
    'last positive coverage boundary and may precede closing evidence; it must not rewind. '
    'An API failure or incomplete response must not close a current period. Periods of one '
    'account in different clans may overlap: a move is observed on two independent poll cycles.';
CREATE VIEW guild.current_observed_clan_member AS
SELECT DISTINCT ON (player_key) player_key, clan_key, observed_since, confirmed_through,
    coverage_status
FROM guild.observed_clan_membership_period WHERE observed_until IS NULL
ORDER BY player_key, confirmed_through DESC, observed_since DESC, membership_period_key DESC;
COMMENT ON VIEW guild.current_observed_clan_member IS
    'At most one current clan per account. When open periods in two clans overlap because the '
    'old clan has not yet observed the departure, the period with the latest positive '
    'observation (confirmed_through) wins, then the later observed_since. Historical presence '
    'uses the union of all periods instead.';

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
    'One game season, named by the month in which it ends. The guild service creates a row from '
    'the calendar rule. The seasons are the same for every guild.';

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

-- Every war poll of a tracked clan has one row, which proves that the poll
-- ran, whatever it returned. The war, roster and clan observations below are
-- stored only when they changed since the latest stored one (WAR-006); each
-- names the poll that saw it.
CREATE TABLE guild.war_poll (
    war_poll_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clan_key bigint NOT NULL REFERENCES guild.clan_collection_settings,
    endpoint_kind text NOT NULL CHECK (endpoint_kind IN ('current_war', 'cwl_war')),
    source_correlation_id text NOT NULL UNIQUE CHECK (btrim(source_correlation_id) <> ''),
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    outcome text NOT NULL CHECK (outcome IN ('war', 'not_in_war', 'failed')),
    war_key bigint REFERENCES guild.dim_war,
    failure_code text,
    UNIQUE (war_poll_key, war_key, observed_at),
    CHECK ((outcome = 'war') = (war_key IS NOT NULL)),
    CHECK ((outcome = 'failed') = (failure_code IS NOT NULL))
);
CREATE INDEX war_poll_recent ON guild.war_poll (clan_key, observed_at DESC);
COMMENT ON COLUMN guild.war_poll.outcome IS
    'war: the response identified war_key. not_in_war: the clan had no war. failed: no usable '
    'response; it is no evidence about the war.';
CREATE TABLE guild.fact_war_observation (
    war_key bigint NOT NULL REFERENCES guild.dim_war,
    observed_at timestamptz NOT NULL,
    war_poll_key bigint NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    source_payload jsonb NOT NULL CHECK (jsonb_typeof(source_payload) = 'object'),
    PRIMARY KEY (war_key, observed_at),
    FOREIGN KEY (war_poll_key, war_key, observed_at)
        REFERENCES guild.war_poll (war_poll_key, war_key, observed_at),
    CHECK (NOT jsonb_path_exists(source_payload, '$.**.token'))
);
COMMENT ON TABLE guild.fact_war_observation IS
    'Complete sanitized war response for retaining available fields beyond typed projections, '
    'stored when it differs from the latest stored response of the war. '
    'Never persist verification request/response tokens.';
CREATE TABLE guild.war_participant (
    war_key bigint NOT NULL REFERENCES guild.dim_war,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    PRIMARY KEY (war_key, player_key),
    UNIQUE (war_key, clan_key, player_key)
);
CREATE TABLE guild.fact_war_roster_observation (
    war_key bigint NOT NULL,
    clan_key bigint NOT NULL,
    player_key bigint NOT NULL,
    observed_at timestamptz NOT NULL,
    war_poll_key bigint NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    player_name text NOT NULL,
    town_hall_level smallint NOT NULL CHECK (town_hall_level > 0),
    map_position smallint NOT NULL CHECK (map_position > 0),
    opponent_attacks smallint CHECK (opponent_attacks >= 0),
    PRIMARY KEY (war_key, player_key, observed_at),
    FOREIGN KEY (war_key, clan_key, player_key) REFERENCES guild.war_participant (war_key, clan_key, player_key),
    FOREIGN KEY (war_poll_key, war_key, observed_at)
        REFERENCES guild.war_poll (war_poll_key, war_key, observed_at)
);
CREATE TABLE guild.fact_war_clan_observation (
    war_key bigint NOT NULL REFERENCES guild.dim_war,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    observed_at timestamptz NOT NULL,
    war_poll_key bigint NOT NULL,
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    state text NOT NULL CHECK (state IN ('preparation', 'inWar', 'warEnded')),
    stars integer NOT NULL CHECK (stars >= 0),
    attacks integer NOT NULL CHECK (attacks >= 0),
    destruction_percentage numeric(8,5) NOT NULL CHECK (destruction_percentage BETWEEN 0 AND 100),
    PRIMARY KEY (war_key, clan_key, observed_at),
    FOREIGN KEY (war_poll_key, war_key, observed_at)
        REFERENCES guild.war_poll (war_poll_key, war_key, observed_at)
);
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
        CHECK (clan_games_refresh_seconds > 0),
    -- How long before the T-24h checkpoint its read may be taken (DEC-03,
    -- 2026-11-14). The window must open after the event starts.
    ADD COLUMN clan_games_checkpoint_tolerance_seconds integer NOT NULL DEFAULT 1800
        CHECK (clan_games_checkpoint_tolerance_seconds > 0),
    ADD CONSTRAINT clan_games_checkpoint_window_inside_event
        CHECK (clan_games_checkpoint_tolerance_seconds < clan_games_event_seconds - 86400);
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

-- Boundary checkpoints are durable rows. The regular read is one moving row per player.
CREATE VIEW guild.clan_games_collection_policy AS
SELECT guild_key, clan_games_refresh_seconds AS refresh_seconds,
    clan_games_checkpoint_tolerance_seconds AS checkpoint_tolerance_seconds
FROM guild.guild_settings;
CREATE TABLE guild.clan_games_read_request (
    request_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_key bigint NOT NULL REFERENCES guild.dim_clan_games_event,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    purpose text NOT NULL CHECK (purpose IN ('baseline', 'regular', 't_minus_24h', 'final', 'transfer')),
    due_at timestamptz NOT NULL,
    collect_from timestamptz NOT NULL,
    transfer_request_key bigint REFERENCES guild.account_transfer_request,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'succeeded', 'missed')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    missed_at timestamptz,
    UNIQUE NULLS NOT DISTINCT (event_key, player_key, purpose, due_at, transfer_request_key),
    UNIQUE (request_key, event_key, player_key),
    CHECK ((purpose = 'transfer') = (transfer_request_key IS NOT NULL)),
    CHECK ((status = 'missed') = (missed_at IS NOT NULL)),
    CHECK (collect_from <= due_at),
    CHECK (purpose IN ('baseline', 't_minus_24h') OR collect_from = due_at)
);
COMMENT ON COLUMN guild.clan_games_read_request.status IS
    'pending is still retryable. missed is terminal: no current response can supply this '
    'checkpoint any more. A missed read is absent evidence, never a zero.';
COMMENT ON COLUMN guild.clan_games_read_request.due_at IS
    'The checkpoint that the read supplies, and part of the request''s identity. A read of a '
    'baseline or T-24h checkpoint must be observed at or before it.';
COMMENT ON COLUMN guild.clan_games_read_request.collect_from IS
    'When the collector may take the request: the opening of its acceptance window. A baseline '
    'opens at the end of the previous event and a T-24h read at the checkpoint minus '
    'clan_games_checkpoint_tolerance_seconds, both before due_at, so the read can finish in time. '
    'Every other purpose opens at due_at.';
-- A regular read has no fixed slot. Each player has at most one pending regular
-- request per event, and the guild service moves its due_at and collect_from
-- together when the latest read or the configured interval changes.
CREATE UNIQUE INDEX clan_games_read_request_pending_regular
    ON guild.clan_games_read_request (event_key, player_key)
    WHERE purpose = 'regular' AND status = 'pending';

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
COMMENT ON TABLE guild.clan_games_participation_evidence IS
    'Inference from historical tracked-clan observations, never an explicit API affiliation claim. '
    'Later changes to current clan tracking settings must not rewrite earlier event participation.';

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
CREATE VIEW guild.latest_clan_games_progress AS
SELECT DISTINCT ON (event_key, player_key) * FROM guild.fact_clan_games_progress
ORDER BY event_key, player_key, observed_at DESC;
CREATE VIEW guild.public_clan_games_progress AS
SELECT event_key, player_key, observed_at, points, evidence_status, measurement_method
FROM guild.latest_clan_games_progress;

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
    'Missing evidence remains explicit. The runtime role cannot remove a row, and the guild service '
    'attaches each slice once.';
COMMENT ON VIEW guild.clan_games_member_result IS
    'Sum unrounded ownership-slice targets across accounts/clans, then ceil the member total to a '
    'multiple of ten once. Inadequate evidence stays insufficient_data, never an exemption.';

CREATE TABLE guild.dim_raid_weekend (
    raid_weekend_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clan_key bigint NOT NULL REFERENCES guild.dim_clan,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    UNIQUE (clan_key, starts_at),
    UNIQUE (raid_weekend_key, clan_key),
    CHECK (starts_at < ends_at)
);
-- Every raid collection of a clan, successful or not, so coverage stays
-- identifiable while weekend state and member totals are stored on change
-- (GAP-11, RAID-003, RAID-007).
CREATE TABLE guild.raid_poll (
    raid_poll_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clan_key bigint NOT NULL REFERENCES guild.clan_collection_settings,
    source_correlation_id text NOT NULL UNIQUE CHECK (btrim(source_correlation_id) <> ''),
    observed_at timestamptz NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    outcome text NOT NULL CHECK (outcome IN ('weekend', 'no_weekend', 'failed')),
    raid_weekend_key bigint,
    failure_code text,
    UNIQUE (raid_poll_key, raid_weekend_key, observed_at),
    FOREIGN KEY (raid_weekend_key, clan_key) REFERENCES guild.dim_raid_weekend (raid_weekend_key, clan_key),
    CHECK ((outcome = 'weekend') = (raid_weekend_key IS NOT NULL)),
    CHECK ((outcome = 'failed') = (failure_code IS NOT NULL))
);
CREATE INDEX raid_poll_recent ON guild.raid_poll (clan_key, observed_at DESC);
COMMENT ON COLUMN guild.raid_poll.outcome IS
    'weekend: the response identified raid_weekend_key and its complete member list. no_weekend: '
    'the clan had no current raid weekend. failed: no usable response; it is no evidence about loot.';
-- The weekend's state, stored when it differs from the latest stored state.
CREATE TABLE guild.fact_raid_weekend_observation (
    raid_weekend_key bigint NOT NULL REFERENCES guild.dim_raid_weekend,
    observed_at timestamptz NOT NULL,
    raid_poll_key bigint NOT NULL,
    source_state text NOT NULL CHECK (source_state IN ('ongoing', 'ended')),
    reported_members integer NOT NULL CHECK (reported_members >= 0),
    capital_total_loot bigint NOT NULL CHECK (capital_total_loot >= 0),
    PRIMARY KEY (raid_weekend_key, observed_at),
    FOREIGN KEY (raid_poll_key, raid_weekend_key, observed_at)
        REFERENCES guild.raid_poll (raid_poll_key, raid_weekend_key, observed_at)
);
-- A member total is stored when it differs from the account's latest stored
-- total for the weekend; the weekend's successful polls prove the unchanged
-- values in between.
CREATE TABLE guild.fact_raid_member_observation (
    raid_weekend_key bigint NOT NULL REFERENCES guild.dim_raid_weekend,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    observed_at timestamptz NOT NULL,
    raid_poll_key bigint NOT NULL,
    ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_correlation_id text NOT NULL CHECK (source_correlation_id <> ''),
    capital_resources_looted bigint NOT NULL CHECK (capital_resources_looted >= 0),
    PRIMARY KEY (raid_weekend_key, player_key, observed_at),
    FOREIGN KEY (raid_poll_key, raid_weekend_key, observed_at)
        REFERENCES guild.raid_poll (raid_poll_key, raid_weekend_key, observed_at)
);
-- How far a weekend's evidence reaches: its latest successful poll. A report
-- revision shows the weekend through this time, even when no total changed.
CREATE VIEW guild.raid_weekend_coverage AS
SELECT raid_weekend_key, max(observed_at) AS observed_through, count(*) AS successful_polls
FROM guild.raid_poll WHERE outcome = 'weekend'
GROUP BY raid_weekend_key;
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
-- The collector asks for work whose window has opened, across players. The
-- closer of missed reads asks for checkpoints that have passed.
CREATE INDEX clan_games_read_request_collectable ON guild.clan_games_read_request (collect_from)
    WHERE status = 'pending';
CREATE INDEX clan_games_read_request_due ON guild.clan_games_read_request (due_at)
    WHERE status = 'pending';
-- The transfer limit asks for the reads of one transfer.
CREATE INDEX clan_games_read_request_transfer
    ON guild.clan_games_read_request (transfer_request_key)
    WHERE transfer_request_key IS NOT NULL;
CREATE INDEX clan_games_counter_read_transfer
    ON guild.clan_games_counter_read (transfer_request_key)
    WHERE transfer_request_key IS NOT NULL;
