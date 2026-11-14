-- Activity-specific CWL and custom-event stars and constrained workflow state.
-- The guild service records the decisions and evidence; the CoC and Sheets
-- clients are separate.

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
    UNIQUE (cycle_key, clan_key), UNIQUE (participation_key, cycle_key)
);
COMMENT ON TABLE guild.cwl_participating_clan IS
    'The identity of one tracked clan in one cycle. Its selection, lineup size and withdrawal '
    'are revisions in fact_cwl_participation_revision.';
-- Selecting a clan, correcting its lineup size, withdrawing it and selecting
-- it again are revisions with their actor and operation (CWL-001, CWL-005,
-- CWL-017). The first revision is the selection. The guild service accepts a
-- revision only while signups are open.
CREATE TABLE guild.fact_cwl_participation_revision (
    participation_revision_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participation_key bigint NOT NULL REFERENCES guild.cwl_participating_clan,
    revision integer NOT NULL CHECK (revision > 0),
    lineup_size smallint NOT NULL CHECK (lineup_size IN (15, 30)),
    withdrawn boolean NOT NULL DEFAULT false,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    operation_id uuid NOT NULL UNIQUE REFERENCES guild.activity_command_operation,
    UNIQUE (participation_key, revision),
    CHECK (revision > 1 OR NOT withdrawn)
);
CREATE VIEW guild.current_cwl_participation AS
SELECT DISTINCT ON (p.participation_key) p.participation_key, p.cycle_key, p.clan_key,
    r.participation_revision_key, r.revision, r.lineup_size, r.withdrawn, r.actor_user_key,
    r.recorded_at
FROM guild.cwl_participating_clan p
JOIN guild.fact_cwl_participation_revision r USING (participation_key)
ORDER BY p.participation_key, r.revision DESC;
COMMENT ON VIEW guild.current_cwl_participation IS
    'The latest revision of each participating clan. A clan without a revision has not been '
    'selected yet.';
CREATE TABLE guild.cwl_clan_day (
    participation_key bigint NOT NULL REFERENCES guild.cwl_participating_clan,
    war_day smallint NOT NULL CHECK (war_day BETWEEN 1 AND 7),
    war_key bigint REFERENCES guild.dim_war,
    PRIMARY KEY (participation_key, war_day), UNIQUE (participation_key, war_key),
    UNIQUE (participation_key, war_day, war_key)
);
-- A War Day freezes once its war is known and the time is at or after the
-- war's start minus the clan's cutoff. The first time a freeze applies, the
-- guild service records it with the cutoff it used, so a later cutoff change
-- cannot unfreeze the day (CWL-017). The day's war cannot change after that.
CREATE TABLE guild.fact_cwl_day_freeze (
    participation_key bigint NOT NULL,
    war_day smallint NOT NULL,
    war_key bigint NOT NULL,
    automatic_freeze_minutes integer NOT NULL CHECK (automatic_freeze_minutes >= 0),
    frozen_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (participation_key, war_day),
    FOREIGN KEY (participation_key, war_day, war_key)
        REFERENCES guild.cwl_clan_day (participation_key, war_day, war_key)
);
COMMENT ON COLUMN guild.fact_cwl_day_freeze.frozen_at IS
    'When the freeze took effect: the actual start of the war minus automatic_freeze_minutes.';
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
-- One account has one signup per cycle. Its target clan is part of each
-- revision, so moving the signup to another participating clan of the cycle is
-- a revision too (CWL-002, CWL-004).
CREATE TABLE guild.cwl_signup (
    signup_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cycle_key bigint NOT NULL REFERENCES guild.cwl_cycle,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    UNIQUE (cycle_key, player_key), UNIQUE (signup_key, cycle_key)
);
CREATE TABLE guild.fact_cwl_signup_revision (
    signup_revision_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    signup_key bigint NOT NULL,
    cycle_key bigint NOT NULL,
    participation_key bigint NOT NULL,
    revision integer NOT NULL CHECK (revision > 0),
    -- One to seven War Days, each from 1 to 7; a null element fails the
    -- containment test. The guild service stores them distinct and sorted.
    war_days smallint[] NOT NULL CHECK (
        array_ndims(war_days) = 1 AND cardinality(war_days) BETWEEN 1 AND 7
        AND war_days <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::smallint[]
    ),
    town_hall_level smallint NOT NULL CHECK (town_hall_level > 0),
    withdrawn boolean NOT NULL DEFAULT false,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    operation_id uuid NOT NULL UNIQUE REFERENCES guild.activity_command_operation,
    UNIQUE (signup_key, revision),
    UNIQUE (signup_revision_key, participation_key),
    UNIQUE (signup_revision_key, signup_key),
    FOREIGN KEY (signup_key, cycle_key) REFERENCES guild.cwl_signup (signup_key, cycle_key),
    FOREIGN KEY (participation_key, cycle_key)
        REFERENCES guild.cwl_participating_clan (participation_key, cycle_key)
);
COMMENT ON COLUMN guild.fact_cwl_signup_revision.participation_key IS
    'The target clan of this revision. It may differ from the account''s current clan and from '
    'the target of the previous revision.';
CREATE VIEW guild.current_cwl_signup AS
SELECT DISTINCT ON (s.signup_key) s.*, r.participation_key, r.signup_revision_key, r.war_days,
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
    plan_key bigint NOT NULL,
    participation_key bigint NOT NULL,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    signup_revision_key bigint NOT NULL,
    current_season_stars bigint NOT NULL CHECK (current_season_stars >= 0),
    current_season_attacks bigint NOT NULL CHECK (current_season_attacks >= 0),
    average_destruction numeric,
    source_war_keys bigint[] NOT NULL,
    rating numeric,
    rating_method text,
    observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (plan_key, player_key),
    FOREIGN KEY (plan_key, participation_key)
        REFERENCES guild.cwl_plan_revision (plan_key, participation_key),
    FOREIGN KEY (signup_revision_key, participation_key)
        REFERENCES guild.fact_cwl_signup_revision (signup_revision_key, participation_key),
    CHECK (average_destruction IS NULL OR average_destruction BETWEEN 0 AND 100),
    CHECK ((rating IS NULL) = (rating_method IS NULL))
);
COMMENT ON COLUMN guild.fact_cwl_plan_input.signup_revision_key IS
    'The signup revision that made the account a candidate of this plan''s clan. For an account '
    'kept only to carry a frozen assignment forward, it is the earlier revision that targeted this '
    'clan, even when the signup has since moved to another clan.';
CREATE TABLE guild.cwl_plan_assignment (
    plan_key bigint NOT NULL REFERENCES guild.cwl_plan_revision,
    war_day smallint NOT NULL CHECK (war_day BETWEEN 1 AND 7),
    slot_number smallint NOT NULL CHECK (slot_number BETWEEN 1 AND 30),
    player_key bigint NOT NULL,
    PRIMARY KEY (plan_key, war_day, slot_number), UNIQUE (plan_key, war_day, player_key),
    FOREIGN KEY (plan_key, player_key) REFERENCES guild.fact_cwl_plan_input
);
-- A pin or an unpin is a revision of one slot of one War Day, with its actor,
-- reason and operation (CWL-017). A revision without an account unpins the
-- slot. One command may write several revisions, such as moving an account.
CREATE TABLE guild.fact_cwl_manual_pin_revision (
    pin_revision_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participation_key bigint NOT NULL,
    war_day smallint NOT NULL,
    slot_number smallint NOT NULL CHECK (slot_number BETWEEN 1 AND 30),
    revision integer NOT NULL CHECK (revision > 0),
    player_key bigint REFERENCES guild.dim_player_account,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    operation_id uuid NOT NULL REFERENCES guild.activity_command_operation,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (participation_key, war_day, slot_number, revision),
    FOREIGN KEY (participation_key, war_day) REFERENCES guild.cwl_clan_day
);
CREATE VIEW guild.current_cwl_manual_pin AS
SELECT participation_key, war_day, slot_number, player_key, actor_user_key, reason, operation_id,
    recorded_at AS pinned_at, pin_revision_key, revision
FROM (
    SELECT DISTINCT ON (participation_key, war_day, slot_number) *
    FROM guild.fact_cwl_manual_pin_revision
    ORDER BY participation_key, war_day, slot_number, revision DESC
) latest
WHERE player_key IS NOT NULL;
COMMENT ON VIEW guild.current_cwl_manual_pin IS
    'The latest revision of each pinned slot. The guild service keeps an account in at most '
    'one current pin per War Day.';
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
    -- Order of this clan's exports of one kind (GAP-19, CWL-016). A Sheet never
    -- shows a lower sequence after a higher one.
    export_sequence bigint NOT NULL CHECK (export_sequence > 0),
    -- The destination selected for this export, not today's setting. No
    -- document means no Sheets attempt.
    sheet_document_id text CHECK (sheet_document_id IS NULL OR btrim(sheet_document_id) <> ''),
    sheet_tab text CHECK (sheet_tab IS NULL OR btrim(sheet_tab) <> ''),
    UNIQUE (participation_key, signup_revision_key), UNIQUE (plan_key),
    UNIQUE (participation_key, resource_kind, export_sequence),
    UNIQUE (export_revision_key, resource_kind),
    CHECK ((resource_kind = 'signups') = (signup_revision_key IS NOT NULL)),
    CHECK ((resource_kind = 'lineups') = (plan_key IS NOT NULL)),
    CHECK ((sheet_document_id IS NULL) = (sheet_tab IS NULL))
);
COMMENT ON TABLE guild.cwl_export_revision IS
    'One export of one clan''s signups or lineups. A signup revision that moves a signup is '
    'exported for the clan it leaves and for the clan it joins.';
-- A signup-list export lists exactly these revisions: the selected revision of
-- every signup it includes, frozen when the export is created (GAP-19).
CREATE TABLE guild.cwl_export_signup_input (
    export_revision_key bigint NOT NULL,
    resource_kind text NOT NULL DEFAULT 'signups' CHECK (resource_kind = 'signups'),
    signup_key bigint NOT NULL,
    signup_revision_key bigint NOT NULL,
    PRIMARY KEY (export_revision_key, signup_key),
    FOREIGN KEY (export_revision_key, resource_kind)
        REFERENCES guild.cwl_export_revision (export_revision_key, resource_kind),
    FOREIGN KEY (signup_revision_key, signup_key)
        REFERENCES guild.fact_cwl_signup_revision (signup_revision_key, signup_key)
);
-- One writer at a time per clan and export kind. A writer holds the lease and
-- its fence, writes only a sequence above confirmed_sequence, and never starts
-- a write that could outlast its lease (SR-CWL-17).
CREATE TABLE guild.cwl_sheet_destination (
    participation_key bigint NOT NULL REFERENCES guild.cwl_participating_clan,
    resource_kind text NOT NULL CHECK (resource_kind IN ('signups', 'lineups')),
    lease_owner text CHECK (lease_owner ~ '^[A-Za-z0-9_.:-]{1,100}$'),
    lease_expires_at timestamptz,
    fence uuid,
    confirmed_sequence bigint NOT NULL DEFAULT 0 CHECK (confirmed_sequence >= 0),
    PRIMARY KEY (participation_key, resource_kind),
    CHECK ((lease_owner IS NULL) = (lease_expires_at IS NULL)),
    CHECK ((lease_owner IS NULL) = (fence IS NULL))
);
CREATE TABLE guild.fact_cwl_export_attempt (
    export_attempt_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    export_revision_key bigint NOT NULL REFERENCES guild.cwl_export_revision,
    export_format text NOT NULL CHECK (export_format IN ('csv', 'google_sheets')),
    attempt_number integer NOT NULL CHECK (attempt_number > 0),
    -- A Sheets attempt is authorized before the write, with the destination
    -- fence; its outcome is recorded once afterwards. CSV records it at once.
    fence uuid UNIQUE,
    lease_expires_at timestamptz,
    outcome text CHECK (outcome IN ('succeeded', 'failed', 'uncertain')),
    artifact_reference text,
    error_code text,
    attempted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    UNIQUE (export_revision_key, export_format, attempt_number),
    CHECK ((export_format = 'google_sheets') = (fence IS NOT NULL)),
    CHECK ((fence IS NULL) = (lease_expires_at IS NULL)),
    CHECK (lease_expires_at IS NULL OR lease_expires_at > attempted_at),
    CHECK (export_format = 'google_sheets' OR outcome IS NOT NULL),
    CHECK ((outcome IS NULL) = (completed_at IS NULL)),
    CHECK (completed_at IS NULL OR completed_at >= attempted_at),
    CHECK (outcome IS NOT NULL OR (artifact_reference IS NULL AND error_code IS NULL))
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
    UNIQUE (event_key, player_key), UNIQUE (signup_key, event_key, player_key)
);
-- Every signup change is a revision with its actor and operation (CUSTOM-006),
-- as CWL signups are.
CREATE TABLE guild.fact_custom_event_signup_revision (
    signup_revision_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    signup_key bigint NOT NULL REFERENCES guild.custom_event_signup,
    revision integer NOT NULL CHECK (revision > 0),
    withdrawn boolean NOT NULL DEFAULT false,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    operation_id uuid NOT NULL UNIQUE REFERENCES guild.activity_command_operation,
    UNIQUE (signup_key, revision)
);
CREATE VIEW guild.current_custom_event_signup AS
SELECT DISTINCT ON (s.signup_key) s.*, r.signup_revision_key, r.withdrawn, r.actor_user_key,
    r.operation_id, r.revision
FROM guild.custom_event_signup s JOIN guild.fact_custom_event_signup_revision r USING (signup_key)
ORDER BY s.signup_key, r.revision DESC;
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
