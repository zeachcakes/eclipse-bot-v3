-- Persistence and worker contracts only: no Kafka publisher, gRPC server, or
-- Discord client is implemented here. Java owns these records; Node uses Java
-- RPCs, never PostgreSQL. Every external adapter must honor the send permit and
-- disable automatic ping resends, including HTTP/client and gRPC retries.

CREATE TABLE guild.notification_report (
    report_key uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    logical_report_key text NOT NULL CHECK (logical_report_key ~ '^[A-Za-z0-9_:./-]{1,200}$'),
    report_kind text NOT NULL CHECK (report_kind IN ('clan_games_report', 'raid_report', 'cwl_roster', 'cwl_signups')),
    channel_key bigint NOT NULL,
    audience text NOT NULL CHECK (audience IN ('members', 'leadership')),
    discord_message_id guild.discord_snowflake,
    message_confirmed_at timestamptz,
    latest_revision bigint NOT NULL DEFAULT 0 CHECK (latest_revision >= 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (logical_report_key),
    FOREIGN KEY (channel_key) REFERENCES guild.dim_discord_channel (channel_key),
    CHECK ((discord_message_id IS NULL) = (message_confirmed_at IS NULL))
);
COMMENT ON TABLE guild.notification_report IS
    'A report is one Discord message that is edited in place. Each revision of its content is one '
    'notification operation, numbered by latest_revision. Only the latest revision is sent: it '
    'creates the message when discord_message_id is unknown and edits that message otherwise.';

CREATE TABLE guild.notification_role_target (
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0),
    PRIMARY KEY (user_key)
);
CREATE TABLE guild.notification_role_source_requirement (
    user_key bigint NOT NULL,
    source_key text NOT NULL CHECK (source_key ~ '^[A-Za-z0-9_:./-]{1,200}$'),
    role_key bigint NOT NULL,
    PRIMARY KEY (user_key, source_key, role_key),
    FOREIGN KEY (user_key) REFERENCES guild.notification_role_target,
    FOREIGN KEY (role_key) REFERENCES guild.dim_discord_role (role_key)
);
CREATE TABLE guild.notification_managed_role (
    user_key bigint NOT NULL,
    role_key bigint NOT NULL,
    PRIMARY KEY (user_key, role_key),
    FOREIGN KEY (user_key) REFERENCES guild.notification_role_target,
    FOREIGN KEY (role_key) REFERENCES guild.dim_discord_role (role_key)
);
CREATE TABLE guild.notification_role_generation (
    user_key bigint NOT NULL,
    generation bigint NOT NULL CHECK (generation > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (user_key, generation),
    FOREIGN KEY (user_key) REFERENCES guild.notification_role_target
);
CREATE TABLE guild.notification_role_generation_requirement (
    user_key bigint NOT NULL,
    generation bigint NOT NULL,
    role_key bigint NOT NULL,
    is_desired boolean NOT NULL,
    PRIMARY KEY (user_key, generation, role_key),
    FOREIGN KEY (user_key, generation) REFERENCES guild.notification_role_generation,
    FOREIGN KEY (role_key) REFERENCES guild.dim_discord_role (role_key)
);
COMMENT ON TABLE guild.notification_role_generation_requirement IS
    'Only these managed role IDs may be reconciled. is_desired=false withdraws a managed '
    'requirement; unrelated manually held Discord roles must be preserved.';

CREATE TABLE guild.notification_operation (
    operation_key uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    logical_key text NOT NULL CHECK (logical_key ~ '^[A-Za-z0-9_:./-]{1,200}$'),
    operation_kind text NOT NULL CHECK (operation_kind IN ('ping', 'role_reconcile', 'report_create', 'report_edit')),
    notification_kind text NOT NULL CHECK (notification_kind IN
        ('welcome', 'war_reminder', 'war_catchup', 'clan_games_report', 'raid_start',
            'raid_report', 'moderation', 'role_reconcile', 'cwl_leadership', 'cwl_roster', 'cwl_signups')),
    channel_key bigint,
    audience text NOT NULL CHECK (audience IN ('members', 'leadership')),
    due_at timestamptz NOT NULL,
    expires_at timestamptz,
    war_key bigint REFERENCES guild.dim_war,
    clan_key bigint REFERENCES guild.dim_clan,
    checkpoint_offset_seconds integer CHECK (checkpoint_offset_seconds > 0),
    remaining_seconds integer CHECK (remaining_seconds >= 0),
    target_user_key bigint REFERENCES guild.dim_discord_user,
    role_generation bigint,
    report_key uuid,
    report_revision bigint CHECK (report_revision > 0),
    status text NOT NULL DEFAULT 'pending' CHECK (status IN
        ('pending', 'in_flight', 'delivered', 'failed', 'uncertain', 'expired', 'superseded')),
    current_fence uuid,
    outbox_key uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    event_version integer NOT NULL DEFAULT 1 CHECK (event_version = 1),
    publication_state text NOT NULL DEFAULT 'pending' CHECK (publication_state IN ('pending', 'leased', 'published')),
    publication_fence uuid,
    publication_lease_expires_at timestamptz,
    publication_worker_key text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (logical_key),
    UNIQUE (report_key, report_revision),
    FOREIGN KEY (channel_key) REFERENCES guild.dim_discord_channel (channel_key),
    FOREIGN KEY (target_user_key, role_generation)
        REFERENCES guild.notification_role_generation (user_key, generation),
    FOREIGN KEY (report_key) REFERENCES guild.notification_report (report_key),
    CHECK (expires_at IS NULL OR expires_at > due_at),
    CHECK ((operation_kind = 'role_reconcile') = (target_user_key IS NOT NULL AND role_generation IS NOT NULL)),
    CHECK ((operation_kind = 'role_reconcile') = (channel_key IS NULL)),
    CHECK ((notification_kind IN ('war_reminder', 'war_catchup')) = (war_key IS NOT NULL AND clan_key IS NOT NULL)),
    CHECK (notification_kind <> 'raid_start' OR clan_key IS NOT NULL),
    CHECK ((notification_kind = 'war_reminder') = (checkpoint_offset_seconds IS NOT NULL)),
    CHECK ((operation_kind IN ('report_create', 'report_edit')) = (report_key IS NOT NULL)),
    CHECK ((report_key IS NULL) = (report_revision IS NULL))
);
COMMENT ON COLUMN guild.notification_operation.operation_kind IS
    'For a report revision, report_create or report_edit is the action of its latest dispatch '
    'authorization. Until the first authorization it is the action expected when the revision was queued. '
    'Each authorization keeps its own action in fact_notification_dispatch_attempt.dispatch_action.';
CREATE UNIQUE INDEX notification_war_checkpoint ON guild.notification_operation
    (war_key, clan_key, checkpoint_offset_seconds) WHERE notification_kind = 'war_reminder';
-- Each outage may queue its own catch-up (DEC-14, NOTIFY-011), but a war and
-- clan have at most one unfinished catch-up at a time. Each missed reminder
-- still feeds at most one catch-up (notification_catchup_input).
CREATE UNIQUE INDEX notification_war_catchup ON guild.notification_operation
    (war_key, clan_key) WHERE notification_kind = 'war_catchup' AND status IN ('pending', 'in_flight');
CREATE INDEX notification_due ON guild.notification_operation (due_at) WHERE status = 'pending';
-- The outbox publisher scans for work that is not yet published.
CREATE INDEX notification_unpublished ON guild.notification_operation (created_at)
    WHERE publication_state <> 'published';
COMMENT ON COLUMN guild.notification_operation.clan_key IS
    'The clan of war work, and of a raid_start announcement, which pings each clan separately.';

-- The roles and members that an operation mentions, fixed when it is queued
-- (NOTIFY-014). Delivery mentions exactly these and nobody else.
CREATE TABLE guild.notification_mention_role (
    operation_key uuid NOT NULL REFERENCES guild.notification_operation,
    role_key bigint NOT NULL REFERENCES guild.dim_discord_role,
    PRIMARY KEY (operation_key, role_key)
);
CREATE TABLE guild.notification_mention_user (
    operation_key uuid NOT NULL REFERENCES guild.notification_operation,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    PRIMARY KEY (operation_key, user_key)
);

-- Publication is one-to-one with the logical operation. The familiar worker
-- projection remains updatable without a second persisted row or write path.
CREATE VIEW guild.notification_outbox AS
SELECT outbox_key, operation_key, event_version, publication_state,
    publication_fence, publication_lease_expires_at AS lease_expires_at,
    publication_worker_key AS worker_key, created_at
FROM guild.notification_operation;
CREATE TABLE guild.fact_notification_publication_attempt (
    publication_attempt_key uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    outbox_key uuid NOT NULL REFERENCES guild.notification_operation (outbox_key),
    publication_fence uuid NOT NULL UNIQUE,
    outcome text NOT NULL CHECK (outcome IN ('published', 'failed', 'uncertain')),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    kafka_topic text CHECK (kafka_topic ~ '^[A-Za-z0-9_.-]{1,200}$'),
    kafka_partition integer CHECK (kafka_partition >= 0),
    kafka_offset bigint CHECK (kafka_offset >= 0),
    error_code text CHECK (error_code ~ '^[A-Za-z0-9_.:-]{1,100}$'),
    CHECK (outcome <> 'published' OR (kafka_topic IS NOT NULL AND kafka_partition IS NOT NULL AND kafka_offset IS NOT NULL))
);
CREATE TABLE guild.notification_kafka_receipt (
    receipt_key uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_key uuid NOT NULL,
    consumer_group text NOT NULL CHECK (consumer_group ~ '^[A-Za-z0-9_.-]{1,200}$'),
    kafka_topic text NOT NULL CHECK (kafka_topic ~ '^[A-Za-z0-9_.-]{1,200}$'),
    kafka_partition integer NOT NULL CHECK (kafka_partition >= 0),
    kafka_offset bigint NOT NULL CHECK (kafka_offset >= 0),
    received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    is_first_for_operation boolean NOT NULL,
    UNIQUE (consumer_group, kafka_topic, kafka_partition, kafka_offset),
    FOREIGN KEY (operation_key) REFERENCES guild.notification_operation (operation_key)
);
CREATE UNIQUE INDEX notification_first_consumption
    ON guild.notification_kafka_receipt (consumer_group, operation_key) WHERE is_first_for_operation;
CREATE VIEW guild.notification_consumer_seen AS
SELECT consumer_group, operation_key, receipt_key AS first_receipt_key
FROM guild.notification_kafka_receipt WHERE is_first_for_operation;

CREATE TABLE guild.fact_notification_dispatch_attempt (
    dispatch_key uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    operation_key uuid NOT NULL,
    fence uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    attempt_number integer NOT NULL CHECK (attempt_number > 0),
    is_ping boolean NOT NULL,
    dispatch_action text NOT NULL
        CHECK (dispatch_action IN ('ping', 'role_reconcile', 'report_create', 'report_edit')),
    requested_message_id guild.discord_snowflake,
    replaced_dispatch_key uuid,
    worker_key text NOT NULL CHECK (worker_key ~ '^[A-Za-z0-9_.:-]{1,100}$'),
    authorized_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_expires_at timestamptz NOT NULL,
    started_at timestamptz,
    finished_at timestamptz,
    outcome text CHECK (outcome IN ('succeeded', 'failed', 'uncertain')),
    recorded_at timestamptz,
    discord_message_id guild.discord_snowflake,
    http_status integer CHECK (http_status BETWEEN 100 AND 599),
    error_code text CHECK (error_code ~ '^[A-Za-z0-9_.:-]{1,100}$'),
    UNIQUE (operation_key, attempt_number),
    UNIQUE (operation_key, dispatch_key),
    FOREIGN KEY (operation_key) REFERENCES guild.notification_operation (operation_key),
    CONSTRAINT notification_dispatch_replaced_fkey FOREIGN KEY (operation_key, replaced_dispatch_key)
        REFERENCES guild.fact_notification_dispatch_attempt (operation_key, dispatch_key),
    CHECK (is_ping = (dispatch_action = 'ping')),
    CHECK ((dispatch_action = 'report_edit') = (requested_message_id IS NOT NULL)),
    CHECK (replaced_dispatch_key IS NULL OR dispatch_action = 'report_create'),
    CHECK (replaced_dispatch_key IS DISTINCT FROM dispatch_key),
    CHECK (dispatch_action <> 'report_edit' OR outcome IS DISTINCT FROM 'succeeded'
        OR (discord_message_id IS NOT NULL AND discord_message_id = requested_message_id)),
    CHECK (lease_expires_at > authorized_at),
    CHECK ((outcome IS NULL) = (finished_at IS NULL)),
    CHECK ((outcome IS NULL) = (recorded_at IS NULL)),
    CHECK (outcome IS NOT NULL OR (discord_message_id IS NULL AND http_status IS NULL AND error_code IS NULL)),
    CHECK (outcome <> 'succeeded' OR (started_at IS NOT NULL AND http_status IS NOT NULL AND http_status BETWEEN 200 AND 299))
);
CREATE UNIQUE INDEX notification_one_ping_attempt
    ON guild.fact_notification_dispatch_attempt (operation_key) WHERE is_ping;
COMMENT ON COLUMN guild.fact_notification_dispatch_attempt.dispatch_action IS
    'The action this authorization was allowed to take, fixed when it was granted. A report '
    'revision can be edited, find its message missing, and be created again; each attempt keeps '
    'its own action.';
COMMENT ON COLUMN guild.fact_notification_dispatch_attempt.requested_message_id IS
    'The message an edit authorization targeted, separate from the discord_message_id of the '
    'response. A succeeded edit returns this message.';
COMMENT ON COLUMN guild.fact_notification_dispatch_attempt.replaced_dispatch_key IS
    'For a create that replaces a missing report message: the earlier edit attempt of the same '
    'operation that found the message missing.';
CREATE VIEW guild.fact_notification_dispatch_authorization AS
SELECT dispatch_key, operation_key, fence, attempt_number, is_ping, dispatch_action,
    requested_message_id, replaced_dispatch_key, worker_key, authorized_at, lease_expires_at
FROM guild.fact_notification_dispatch_attempt;
CREATE VIEW guild.notification_dispatch_state AS
SELECT dispatch_key, started_at, finished_at FROM guild.fact_notification_dispatch_attempt;
CREATE VIEW guild.fact_notification_dispatch_outcome AS
SELECT dispatch_key, outcome, recorded_at, discord_message_id, http_status, error_code
FROM guild.fact_notification_dispatch_attempt WHERE outcome IS NOT NULL;
-- Why work was never sent (NOTIFY-016). An operation is expired or
-- superseded at most once; this row keeps when, why and, for a supersession,
-- what replaced it. It is written with the status change.
CREATE TABLE guild.fact_notification_disposition (
    operation_key uuid PRIMARY KEY REFERENCES guild.notification_operation,
    disposition text NOT NULL CHECK (disposition IN ('expired', 'superseded')),
    cause text NOT NULL CHECK (cause IN ('expiry_passed', 'war_inactive', 'newer_report_revision',
        'coalesced_into_catchup', 'role_generation_replaced', 'member_absent', 'no_unused_attacks',
        'schedule_changed')),
    superseded_by_operation_key uuid,
    occurred_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT notification_disposition_superseded_by_fkey FOREIGN KEY (superseded_by_operation_key)
        REFERENCES guild.notification_operation (operation_key),
    -- no_unused_attacks: a war reminder or catch-up found no roster account with
    -- an unused attack when its send began, so it is not sent (WAR-005).
    -- schedule_changed: staff rescheduled the signups of a CWL cycle before its
    -- leadership prompt was attempted, so the prompt of the earlier schedule is
    -- not sent (CWL-018).
    CHECK ((disposition = 'expired') = (cause IN ('expiry_passed', 'war_inactive', 'no_unused_attacks'))),
    CHECK (cause NOT IN ('newer_report_revision', 'coalesced_into_catchup')
        OR superseded_by_operation_key IS NOT NULL),
    CHECK (superseded_by_operation_key IS NULL OR disposition = 'superseded'),
    CHECK (superseded_by_operation_key IS DISTINCT FROM operation_key)
);
COMMENT ON TABLE guild.fact_notification_disposition IS
    'When and why the service expired or superseded an operation, and the operation that replaced '
    'it. notification_operation.status shows only the latest state; this row is the suppression '
    'evidence. Attempts and their results stay in fact_notification_dispatch_attempt.';
CREATE TABLE guild.notification_catchup_input (
    catchup_operation_key uuid NOT NULL REFERENCES guild.notification_operation,
    source_operation_key uuid NOT NULL UNIQUE REFERENCES guild.notification_operation,
    PRIMARY KEY (catchup_operation_key, source_operation_key),
    CHECK (catchup_operation_key <> source_operation_key)
);

-- Delivery analytics is a projection of the one authorized attempt and its
-- write-once result, never another independently insertable receipt ledger.
CREATE VIEW guild.fact_notification_delivery_attempt AS
SELECT a.dispatch_key AS delivery_attempt_key, n.channel_key,
    n.logical_key AS logical_delivery_key, a.attempt_number,
    CASE WHEN n.notification_kind = 'war_catchup' THEN 'war_reminder'
        ELSE n.notification_kind END AS notification_kind,
    a.recorded_at AS attempted_at, a.outcome, a.discord_message_id, a.error_code,
    a.operation_key, a.dispatch_key
FROM guild.fact_notification_dispatch_attempt a
JOIN guild.notification_operation n USING (operation_key)
WHERE a.outcome IS NOT NULL AND n.channel_key IS NOT NULL;

-- Typed source context keeps rendering independent of logical-key parsing.
-- A leadership prompt belongs to one schedule revision of its cycle, so a
-- rescheduled cycle can prompt again for its new close (CWL-018). A roster
-- operation names a plan and a War Day instead.
CREATE TABLE guild.notification_cwl_context (
    operation_key uuid PRIMARY KEY REFERENCES guild.notification_operation,
    cycle_key bigint NOT NULL,
    schedule_revision_key bigint,
    participation_key bigint,
    plan_key bigint,
    war_day smallint CHECK (war_day BETWEEN 1 AND 7),
    FOREIGN KEY (cycle_key) REFERENCES guild.cwl_cycle (cycle_key),
    FOREIGN KEY (schedule_revision_key, cycle_key)
        REFERENCES guild.fact_cwl_cycle_schedule_revision (schedule_revision_key, cycle_key),
    FOREIGN KEY (participation_key, cycle_key)
        REFERENCES guild.cwl_participating_clan (participation_key, cycle_key),
    FOREIGN KEY (plan_key, participation_key)
        REFERENCES guild.cwl_plan_revision (plan_key, participation_key),
    CHECK ((schedule_revision_key IS NOT NULL AND participation_key IS NULL AND plan_key IS NULL
            AND war_day IS NULL)
        OR (schedule_revision_key IS NULL AND participation_key IS NOT NULL AND plan_key IS NOT NULL
            AND war_day IS NOT NULL))
);
CREATE UNIQUE INDEX notification_cwl_prompt ON guild.notification_cwl_context(schedule_revision_key)
WHERE plan_key IS NULL;
CREATE UNIQUE INDEX notification_cwl_plan_day ON guild.notification_cwl_context(plan_key,war_day)
WHERE plan_key IS NOT NULL;

-- What a moderation message is about (MOD-006, MOD-007): exactly one source
-- record, so rendering never parses the logical key.
CREATE TABLE guild.notification_moderation_context (
    operation_key uuid PRIMARY KEY REFERENCES guild.notification_operation,
    context_kind text NOT NULL CHECK (context_kind IN
        ('warning_issued', 'warning_revoked', 'kick_transition', 'kick_attempt', 'rejoin_notice')),
    warning_key bigint REFERENCES guild.warning,
    revoked_warning_key bigint REFERENCES guild.warning_revocation,
    moderation_transition_key bigint REFERENCES guild.fact_moderation_action_transition,
    moderation_attempt_key bigint REFERENCES guild.fact_moderation_action_attempt,
    moderation_notice_key bigint REFERENCES guild.fact_moderation_notice,
    CHECK (num_nonnulls(warning_key, revoked_warning_key, moderation_transition_key,
        moderation_attempt_key, moderation_notice_key) = 1),
    CHECK ((context_kind = 'warning_issued') = (warning_key IS NOT NULL)),
    CHECK ((context_kind = 'warning_revoked') = (revoked_warning_key IS NOT NULL)),
    CHECK ((context_kind = 'kick_transition') = (moderation_transition_key IS NOT NULL)),
    CHECK ((context_kind = 'kick_attempt') = (moderation_attempt_key IS NOT NULL)),
    CHECK ((context_kind = 'rejoin_notice') = (moderation_notice_key IS NOT NULL))
);
-- A raid_start announcement names the weekend it announces (RAID-001).
CREATE TABLE guild.notification_raid_start_context (
    operation_key uuid PRIMARY KEY REFERENCES guild.notification_operation,
    raid_weekend_key bigint NOT NULL UNIQUE REFERENCES guild.dim_raid_weekend
);

-- A raid report revision shows one weekend as of its latest observation, so an
-- old report is never presented as freshly verified (RAID-003).
CREATE TABLE guild.notification_raid_report_context (
    operation_key uuid PRIMARY KEY REFERENCES guild.notification_operation,
    raid_weekend_key bigint NOT NULL REFERENCES guild.dim_raid_weekend,
    observed_through timestamptz NOT NULL,
    raid_poll_key bigint NOT NULL,
    FOREIGN KEY (raid_poll_key, raid_weekend_key, observed_through)
        REFERENCES guild.raid_poll (raid_poll_key, raid_weekend_key, observed_at)
);
COMMENT ON COLUMN guild.notification_raid_report_context.observed_through IS
    'The observed_at of the latest successful raid poll of the weekend that the revision shows '
    '(GAP-11). Member totals are the latest stored at or before it.';
-- A Clan Games report revision belongs to one event and lists the member
-- assessment versions that it publishes, if any (CG-019, CG-020).
CREATE TABLE guild.notification_clan_games_report_context (
    operation_key uuid PRIMARY KEY REFERENCES guild.notification_operation,
    event_key bigint NOT NULL REFERENCES guild.dim_clan_games_event,
    UNIQUE (operation_key, event_key)
);
CREATE TABLE guild.notification_clan_games_report_assessment (
    operation_key uuid NOT NULL,
    event_key bigint NOT NULL,
    member_assessment_key bigint NOT NULL,
    checkpoint_kind text NOT NULL,
    PRIMARY KEY (operation_key, member_assessment_key),
    FOREIGN KEY (operation_key, event_key)
        REFERENCES guild.notification_clan_games_report_context (operation_key, event_key),
    FOREIGN KEY (member_assessment_key, event_key, checkpoint_kind)
        REFERENCES guild.fact_clan_games_member_assessment (member_assessment_key, event_key, checkpoint_kind)
);
-- A public points revision names, for each account it shows, the progress row
-- it published, so the revision can be rendered again without newer progress
-- (DEC-16, CG-018, CG-020).
CREATE TABLE guild.notification_clan_games_report_progress (
    operation_key uuid NOT NULL,
    event_key bigint NOT NULL,
    player_key bigint NOT NULL,
    progress_key bigint NOT NULL,
    PRIMARY KEY (operation_key, player_key),
    FOREIGN KEY (operation_key, event_key)
        REFERENCES guild.notification_clan_games_report_context (operation_key, event_key),
    FOREIGN KEY (progress_key, event_key, player_key)
        REFERENCES guild.fact_clan_games_progress (progress_key, event_key, player_key)
);
-- A CWL signup-list revision posts one clan's signups as frozen by a signup
-- export revision, whose inputs name each listed signup revision (GAP-08,
-- CWL-016).
CREATE TABLE guild.notification_cwl_signups_context (
    operation_key uuid PRIMARY KEY REFERENCES guild.notification_operation,
    export_revision_key bigint NOT NULL UNIQUE,
    resource_kind text NOT NULL DEFAULT 'signups' CHECK (resource_kind = 'signups'),
    FOREIGN KEY (export_revision_key, resource_kind)
        REFERENCES guild.cwl_export_revision (export_revision_key, resource_kind)
);
COMMENT ON TABLE guild.notification_clan_games_report_progress IS
    'One account shown by a public Clan Games points revision and the exact progress row it '
    'published. Rows never change.';
