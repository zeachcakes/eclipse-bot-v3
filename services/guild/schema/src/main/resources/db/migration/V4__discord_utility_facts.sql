-- Discord utility stars and their current-state projections. The guild service
-- keeps each projection in step with its facts in the same transaction.

CREATE TABLE guild.fact_discord_membership_event (
    membership_event_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    event_kind text NOT NULL CHECK (event_kind IN ('join', 'departure')),
    event_source text NOT NULL DEFAULT 'gateway_event'
        CHECK (event_source IN ('gateway_event', 'member_list_sync')),
    occurred_at timestamptz NOT NULL,
    new_joinee_policy_days integer CHECK (new_joinee_policy_days > 0),
    new_joinee_expires_at timestamptz GENERATED ALWAYS AS
        ((occurred_at AT TIME ZONE 'UTC' + make_interval(days => new_joinee_policy_days))
            AT TIME ZONE 'UTC') STORED,
    observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((event_kind = 'join') = (new_joinee_policy_days IS NOT NULL)),
    UNIQUE (user_key, membership_event_key)
);
CREATE INDEX discord_membership_user_history ON guild.fact_discord_membership_event
    (user_key, occurred_at DESC, membership_event_key DESC);
COMMENT ON COLUMN guild.fact_discord_membership_event.event_source IS
    'gateway_event: Discord delivered the join or the departure. member_list_sync: the collector '
    'found the change by comparing the gateway member list with the stored presence, at startup '
    'or after a reconnect, so no gateway event exists for it (CFG-010).';
COMMENT ON COLUMN guild.fact_discord_membership_event.occurred_at IS
    'The source time: the time of the gateway event, or the joined_at of the member for a '
    'member_list_sync join. A member_list_sync departure has no source time. Its occurred_at is '
    'the latest time at which the member can have left: the joined_at of the join that follows '
    'it, or the time of the sync. It is an upper bound, never an observed departure time.';

-- A join that the member list sync finds may be old: the first sync of an
-- existing server finds every member. Such a join is welcomed only when the
-- member joined at most this long before the sync (DEC-18, MEM-010).
ALTER TABLE guild.guild_settings
    ADD COLUMN welcome_sync_max_age_seconds integer NOT NULL DEFAULT 86400
        CHECK (welcome_sync_max_age_seconds > 0);
COMMENT ON COLUMN guild.guild_settings.welcome_sync_max_age_seconds IS
    'A member_list_sync join sends the welcome only when its occurred_at, the joined_at of the '
    'member, is at most this many seconds before its observed_at, the time of the sync. A '
    'gateway_event join always sends it.';

CREATE TABLE guild.discord_member_state (
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    is_present boolean NOT NULL,
    last_membership_event_key bigint NOT NULL REFERENCES guild.fact_discord_membership_event,
    last_event_at timestamptz NOT NULL,
    PRIMARY KEY (user_key)
);

CREATE TABLE guild.fact_role_change (
    role_event_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    role_key bigint NOT NULL,
    change_kind text NOT NULL CHECK (change_kind IN ('add', 'remove')),
    changed_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    provenance_kind text NOT NULL CHECK (provenance_kind IN
        ('manual', 'onboarding', 'clan_membership', 'town_hall', 'war_roster',
            'new_joinee_expiry', 'reconciliation', 'chat_rank', 'cwl_roster')),
    origin_join_event_key bigint REFERENCES guild.fact_discord_membership_event,
    expires_at timestamptz,
    FOREIGN KEY (role_key) REFERENCES guild.dim_discord_role (role_key),
    CHECK (expires_at IS NULL OR origin_join_event_key IS NOT NULL)
);
CREATE INDEX discord_role_history ON guild.fact_role_change
    (user_key, role_key, changed_at DESC, role_event_key DESC);

-- Confirmed held roles only. Desired roles and pending Discord operations must
-- not grant authority. Role names are labels; authorization uses stable keys.
CREATE TABLE guild.discord_member_role (
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    role_key bigint NOT NULL,
    assigned_at timestamptz NOT NULL,
    last_role_event_key bigint NOT NULL REFERENCES guild.fact_role_change,
    expires_at timestamptz,
    PRIMARY KEY (user_key, role_key),
    FOREIGN KEY (role_key) REFERENCES guild.dim_discord_role (role_key)
);

CREATE TABLE guild.chat_xp_policy (
    policy_key text PRIMARY KEY,
    minimum_xp integer NOT NULL CHECK (minimum_xp = 15),
    maximum_xp integer NOT NULL CHECK (maximum_xp = 25),
    credited_messages_per_window integer NOT NULL CHECK (credited_messages_per_window = 5),
    window_seconds integer NOT NULL CHECK (window_seconds = 60),
    window_kind text NOT NULL CHECK (window_kind = 'rolling_processing_time'),
    is_provisional boolean NOT NULL DEFAULT false CHECK (NOT is_provisional)
);
INSERT INTO guild.chat_xp_policy VALUES ('rolling_60s_v1', 15, 25, 5, 60,
    'rolling_processing_time', false);
COMMENT ON TABLE guild.chat_xp_policy IS
    'Catalog of agreed XP policy versions, not an editable setting. The checks pin the one '
    'agreed version, and the runtime role cannot write it. A new version needs a migration '
    'that widens the checks, released with the matching guild service; guild_settings then '
    'selects it by key.';
ALTER TABLE guild.guild_settings ADD COLUMN chat_xp_policy_key text NOT NULL
    DEFAULT 'rolling_60s_v1' REFERENCES guild.chat_xp_policy;

CREATE TABLE guild.chat_xp_eligibility_role (
    role_key bigint NOT NULL,
    PRIMARY KEY (role_key),
    FOREIGN KEY (role_key) REFERENCES guild.dim_discord_role (role_key)
);
COMMENT ON TABLE guild.chat_xp_eligibility_role IS
    'OR eligibility across configured roles. Initially configure two real Discord role IDs; no CoC link is required.';

CREATE TABLE guild.chat_rank_tier (
    rank_key smallint PRIMARY KEY CHECK (rank_key BETWEEN 1 AND 10),
    rank_name text NOT NULL UNIQUE,
    minimum_cumulative_xp bigint NOT NULL UNIQUE CHECK (minimum_cumulative_xp >= 0)
);
INSERT INTO guild.chat_rank_tier VALUES
    (1, 'Stardust', 0), (2, 'Stargazer', 4000), (3, 'Orbiter', 12000),
    (4, 'Lunar Drift', 28000), (5, 'Solar Wanderer', 60000), (6, 'Penumbra', 120000),
    (7, 'Corona', 240000), (8, 'Umbra', 400000), (9, 'Totality', 650000),
    (10, 'Eclipse Ascendant', 1000000);
CREATE TABLE guild.chat_rank_role_binding (
    rank_key smallint NOT NULL REFERENCES guild.chat_rank_tier,
    role_key bigint NOT NULL,
    PRIMARY KEY (rank_key),
    UNIQUE (role_key),
    FOREIGN KEY (role_key) REFERENCES guild.dim_discord_role (role_key)
);

CREATE TABLE guild.fact_chat_xp_decision (
    xp_decision_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    channel_key bigint NOT NULL,
    discord_message_id guild.discord_snowflake NOT NULL UNIQUE,
    message_sent_at timestamptz NOT NULL,
    decided_at timestamptz NOT NULL,
    policy_key text NOT NULL REFERENCES guild.chat_xp_policy,
    outcome text NOT NULL CHECK (outcome IN
        ('credited', 'not_present', 'missing_eligible_role', 'rate_limited')),
    eligibility_role_key bigint,
    xp integer CHECK (xp BETWEEN 15 AND 25),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    xp_award_key bigint GENERATED ALWAYS AS
        (CASE WHEN outcome = 'credited' THEN xp_decision_key END) STORED,
    UNIQUE (user_key, xp_award_key),
    FOREIGN KEY (channel_key)
        REFERENCES guild.dim_discord_channel (channel_key),
    FOREIGN KEY (eligibility_role_key)
        REFERENCES guild.dim_discord_role (role_key),
    CHECK ((outcome = 'credited') = (xp IS NOT NULL)),
    CHECK (outcome <> 'credited' OR eligibility_role_key IS NOT NULL)
);
CREATE INDEX chat_xp_decision_member_time ON guild.fact_chat_xp_decision
    (user_key, decided_at);

-- Awards are the credited subset of durable decisions, not a second write.
-- The generated nullable award key also lets rank evidence reference only
-- credited decisions through a real foreign key.
CREATE VIEW guild.fact_chat_xp_award AS
SELECT xp_award_key, xp_decision_key, user_key, channel_key,
    discord_message_id, message_sent_at, decided_at AS earned_at, recorded_at,
    policy_key, xp
FROM guild.fact_chat_xp_decision WHERE outcome = 'credited';
CREATE INDEX chat_xp_member_processing_time ON guild.fact_chat_xp_decision
    (user_key, decided_at) WHERE outcome = 'credited';
CREATE INDEX chat_xp_member_source_time ON guild.fact_chat_xp_decision
    (user_key, message_sent_at) WHERE outcome = 'credited';
-- Period leaderboards range over every member's awards by source time.
CREATE INDEX chat_xp_source_time ON guild.fact_chat_xp_decision
    (message_sent_at) INCLUDE (user_key, xp) WHERE outcome = 'credited';

CREATE TABLE guild.chat_member_rank_state (
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    cumulative_xp bigint NOT NULL CHECK (cumulative_xp >= 0),
    rank_key smallint NOT NULL REFERENCES guild.chat_rank_tier,
    last_award_key bigint NOT NULL,
    updated_at timestamptz NOT NULL,
    PRIMARY KEY (user_key),
    FOREIGN KEY (user_key, last_award_key)
        REFERENCES guild.fact_chat_xp_decision (user_key, xp_award_key)
);
CREATE TABLE guild.fact_chat_rank_change (
    rank_change_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    previous_rank_key smallint REFERENCES guild.chat_rank_tier,
    rank_key smallint NOT NULL REFERENCES guild.chat_rank_tier,
    cumulative_xp bigint NOT NULL CHECK (cumulative_xp >= 0),
    trigger_award_key bigint NOT NULL UNIQUE,
    decided_at timestamptz NOT NULL,
    FOREIGN KEY (user_key, trigger_award_key)
        REFERENCES guild.fact_chat_xp_decision (user_key, xp_award_key),
    CHECK (previous_rank_key IS NULL OR previous_rank_key < rank_key)
);

-- Rank requirements survive departure and earning-role loss. These views do
-- not claim that Discord currently holds the desired role or authorize a grant
-- while the member is absent. Removal targets only other configured rank roles.
CREATE VIEW guild.desired_chat_rank_role AS
SELECT s.user_key, s.rank_key, b.role_key
FROM guild.chat_member_rank_state s
JOIN guild.chat_rank_role_binding b USING (rank_key);
CREATE VIEW guild.chat_rank_role_removal AS
SELECT s.user_key, r.role_key
FROM guild.chat_member_rank_state s
JOIN guild.discord_member_role r USING (user_key)
JOIN guild.chat_rank_role_binding b ON b.role_key = r.role_key
WHERE b.rank_key <> s.rank_key;

-- Internal, unfiltered aggregates retain departed identities. Calendar-aware
-- public boards apply membership visibility separately.
CREATE VIEW guild.chat_xp_all_time_totals AS
SELECT user_key, sum(xp)::bigint AS xp_total, count(*) AS credited_messages
FROM guild.fact_chat_xp_award GROUP BY user_key;
CREATE VIEW guild.chat_xp_monthly_totals_utc AS
SELECT user_key,
    date_trunc('month', message_sent_at AT TIME ZONE 'UTC')::date AS month_utc,
    sum(xp)::bigint AS xp_total, count(*) AS credited_messages
FROM guild.fact_chat_xp_award GROUP BY user_key, month_utc;

CREATE TABLE guild.warning (
    warning_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    subject_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    issued_by_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    issue_month_gmt date GENERATED ALWAYS AS
        (date_trunc('month', issued_at AT TIME ZONE 'UTC')::date) STORED,
    reason text NOT NULL CHECK (length(btrim(reason)) > 0),
    UNIQUE (subject_user_key, warning_key)
);
CREATE INDEX warning_subject_month ON guild.warning
    (subject_user_key, issue_month_gmt);
CREATE TABLE guild.warning_revocation (
    warning_key bigint PRIMARY KEY REFERENCES guild.warning,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    revoked_by_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    revoked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    reason text NOT NULL CHECK (length(btrim(reason)) > 0)
);
-- Each immutable issuance/revocation already carries its actor, reason, and
-- source/recorded times. Derive their combined history without an event mirror.
-- Positive event keys identify issues; negative keys identify revocations.
CREATE VIEW guild.fact_warning_event AS
SELECT warning_key AS warning_event_key, warning_key, subject_user_key,
    issued_by_user_key AS actor_user_key, 'issued'::text AS event_kind,
    issued_at AS occurred_at, recorded_at, reason
FROM guild.warning
UNION ALL
SELECT -w.warning_key AS warning_event_key, w.warning_key,
    w.subject_user_key, r.revoked_by_user_key AS actor_user_key,
    'revoked'::text AS event_kind, r.revoked_at AS occurred_at, r.recorded_at, r.reason
FROM guild.warning w JOIN guild.warning_revocation r USING (warning_key);

-- Record which joins actually won the membership projection. This preserves
-- accepted-join evidence for a successful kick receipt arriving later, without
-- treating stale gateway joins as rejoin evidence or changing the projection.
-- A kick attempt targets one accepted join, the stay it may end.
CREATE TABLE guild.fact_discord_accepted_join (
    membership_event_key bigint PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (user_key, membership_event_key),
    FOREIGN KEY (user_key, membership_event_key)
        REFERENCES guild.fact_discord_membership_event (user_key, membership_event_key)
);

-- A kick that Discord refused, or that got no answer, is tried again a limited
-- number of times. Both limits are guild settings.
ALTER TABLE guild.guild_settings
    ADD COLUMN kick_max_attempts integer NOT NULL DEFAULT 3 CHECK (kick_max_attempts > 0),
    ADD COLUMN kick_retry_seconds integer NOT NULL DEFAULT 300 CHECK (kick_retry_seconds > 0);

-- A durable decision is not evidence of a successful Discord kick. Counting
-- uses the original warning month; kick/rejoin notices use the confirmed
-- execution month. Never create a second automatic kick for one warning month.
CREATE TABLE guild.moderation_action (
    moderation_action_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subject_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    action_kind text NOT NULL DEFAULT 'kick' CHECK (action_kind = 'kick'),
    warning_month_gmt date NOT NULL,
    trigger_warning_key bigint NOT NULL,
    decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'succeeded', 'failed', 'uncertain', 'cancelled')),
    attempts_remaining integer NOT NULL DEFAULT 3 CHECK (attempts_remaining >= 0),
    next_attempt_at timestamptz DEFAULT clock_timestamp(),
    lease_owner text,
    lease_expires_at timestamptz,
    claim_token uuid UNIQUE,
    cancelled_at timestamptz,
    UNIQUE (subject_user_key, action_kind, warning_month_gmt),
    UNIQUE (subject_user_key, moderation_action_key),
    FOREIGN KEY (subject_user_key, trigger_warning_key)
        REFERENCES guild.warning (subject_user_key, warning_key),
    CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
    CHECK (next_attempt_at IS NULL OR status IN ('pending', 'failed', 'uncertain')),
    CHECK (status <> 'pending' OR next_attempt_at IS NOT NULL),
    CHECK (next_attempt_at IS NULL OR attempts_remaining > 0),
    CHECK ((lease_owner IS NULL) = (lease_expires_at IS NULL))
);
COMMENT ON TABLE guild.moderation_action IS
    'The current state of one month''s kick decision. Its history is append-only: decisions, '
    'cancellations and rearming in fact_moderation_action_transition, and authorized attempts '
    'with their results in fact_moderation_action_attempt.';
COMMENT ON COLUMN guild.moderation_action.status IS
    'pending has no recorded attempt. succeeded, failed and uncertain are the outcome of the '
    'latest attempt. cancelled means a revoked warning took the member below five active '
    'warnings before the kick took place; a fifth active warning in the same month arms it again.';
COMMENT ON COLUMN guild.moderation_action.attempts_remaining IS
    'Automatic attempts still allowed for this decision. Set from kick_max_attempts when the '
    'kick is decided or armed again, so a later settings change does not alter an open decision.';
COMMENT ON COLUMN guild.moderation_action.next_attempt_at IS
    'When a worker may make the next automatic attempt. NULL when none is owed: the kick '
    'succeeded, was cancelled, or used all its attempts.';
COMMENT ON COLUMN guild.moderation_action.lease_owner IS
    'The worker that claimed the next attempt, until lease_expires_at. Recording an attempt '
    'releases it. A lease that expired without a recorded attempt leaves the outcome unknown.';
COMMENT ON COLUMN guild.moderation_action.claim_token IS
    'The token of the latest claim. The guild service accepts one report, and only with this '
    'token. Recording the report clears it and the next claim replaces it, so a worker whose '
    'claim was taken over cannot report. A cancellation keeps it: the worker that held the kick '
    'may still report what happened.';
CREATE INDEX moderation_work_due ON guild.moderation_action (next_attempt_at)
    WHERE next_attempt_at IS NOT NULL;
-- The kick worker reads the decisions that still owe an attempt. A row is
-- ready when next_attempt_at has passed and no lease is active; claim it before
-- kicking.
CREATE VIEW guild.pending_moderation_action AS
SELECT moderation_action_key, subject_user_key, action_kind,
    warning_month_gmt, decided_at, status, attempts_remaining, next_attempt_at, lease_expires_at
FROM guild.moderation_action WHERE next_attempt_at IS NOT NULL;
-- Each change of the decision is kept: the first decision, a cancellation
-- after a revocation, and rearming after another fifth warning (MOD-009).
CREATE TABLE guild.fact_moderation_action_transition (
    transition_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    moderation_action_key bigint NOT NULL,
    subject_user_key bigint NOT NULL,
    transition_kind text NOT NULL CHECK (transition_kind IN ('decided', 'cancelled', 'rearmed')),
    trigger_warning_key bigint,
    revoked_warning_key bigint REFERENCES guild.warning_revocation,
    origin text NOT NULL CHECK (origin IN ('system', 'staff')),
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    attempts_granted integer CHECK (attempts_granted > 0),
    occurred_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (subject_user_key, moderation_action_key)
        REFERENCES guild.moderation_action (subject_user_key, moderation_action_key),
    CONSTRAINT moderation_transition_trigger_warning_fkey
        FOREIGN KEY (subject_user_key, trigger_warning_key)
        REFERENCES guild.warning (subject_user_key, warning_key),
    CONSTRAINT moderation_transition_revoked_warning_fkey
        FOREIGN KEY (subject_user_key, revoked_warning_key)
        REFERENCES guild.warning (subject_user_key, warning_key),
    CHECK ((transition_kind = 'cancelled') = (revoked_warning_key IS NOT NULL)),
    CHECK ((transition_kind = 'cancelled') = (trigger_warning_key IS NULL)),
    CHECK ((transition_kind = 'cancelled') = (attempts_granted IS NULL)),
    CHECK ((origin = 'staff') = (actor_user_key IS NOT NULL))
);
CREATE UNIQUE INDEX moderation_action_one_decision
    ON guild.fact_moderation_action_transition (moderation_action_key)
    WHERE transition_kind = 'decided';
CREATE INDEX moderation_action_transition_history
    ON guild.fact_moderation_action_transition (moderation_action_key, occurred_at, transition_key);
COMMENT ON TABLE guild.fact_moderation_action_transition IS
    'Append-only history of a kick decision. decided and rearmed name the warning that made five '
    'active warnings and the attempts granted from kick_max_attempts; cancelled names the revoked '
    'warning that took the member below five. origin system is the automatic decision; staff names '
    'the moderator whose revocation caused the transition.';

-- One row per authorized kick attempt, inserted when a worker claims the
-- decision and before any call to Discord. started_at is set, in its own
-- committed transaction, just before the call: a worker never calls Discord
-- for an authorization without it, and never reuses one that has it. The
-- result columns are set once. A late result for an authorization whose claim
-- was taken over is still recorded here; the service does not let it change
-- moderation_action.
CREATE TABLE guild.fact_moderation_action_attempt (
    moderation_attempt_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    moderation_action_key bigint NOT NULL,
    subject_user_key bigint NOT NULL,
    attempt_number integer NOT NULL CHECK (attempt_number > 0),
    claim_token uuid NOT NULL UNIQUE,
    worker_key text NOT NULL CHECK (worker_key ~ '^[A-Za-z0-9_.:-]{1,100}$'),
    target_membership_event_key bigint NOT NULL,
    authorized_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_expires_at timestamptz NOT NULL,
    started_at timestamptz,
    attempted_at timestamptz,
    recorded_at timestamptz,
    outcome text CHECK (outcome IN ('succeeded', 'failed', 'uncertain')),
    http_status integer CHECK (http_status BETWEEN 100 AND 599),
    -- A bounded diagnostic identifier, never an HTTP body, token, or freeform payload.
    diagnostic_code text CHECK (diagnostic_code ~ '^[A-Za-z0-9_.:-]{1,100}$'),
    UNIQUE (moderation_action_key, attempt_number),
    UNIQUE (moderation_action_key, moderation_attempt_key),
    UNIQUE (moderation_attempt_key, outcome),
    FOREIGN KEY (subject_user_key, moderation_action_key)
        REFERENCES guild.moderation_action (subject_user_key, moderation_action_key),
    FOREIGN KEY (subject_user_key, target_membership_event_key)
        REFERENCES guild.fact_discord_accepted_join (user_key, membership_event_key),
    CHECK (lease_expires_at > authorized_at),
    CHECK (started_at IS NULL OR started_at >= authorized_at),
    CHECK ((outcome IS NULL) = (attempted_at IS NULL)),
    CHECK ((outcome IS NULL) = (recorded_at IS NULL)),
    CHECK (outcome IS NULL OR started_at IS NOT NULL),
    CHECK (outcome IS NOT NULL OR (http_status IS NULL AND diagnostic_code IS NULL)),
    CHECK (outcome <> 'succeeded' OR (http_status IS NOT NULL AND http_status BETWEEN 200 AND 299))
);
COMMENT ON COLUMN guild.fact_moderation_action_attempt.target_membership_event_key IS
    'The accepted join whose stay this attempt may end. A later join is a new stay: the service '
    'never repeats this attempt against it.';
COMMENT ON COLUMN guild.fact_moderation_action_attempt.started_at IS
    'The send permission was consumed: Discord may have been called. NULL after the lease '
    'expired proves that this authorization never called Discord.';
COMMENT ON COLUMN guild.fact_moderation_action_attempt.outcome IS
    'The result the worker reported. succeeded needs a 2xx Discord response. Absence of the '
    'member is never a result: it can be a voluntary departure or a manual kick.';

-- Later kick-specific evidence for an uncertain attempt. Success needs the
-- bot's own audit log entry for the kick; failure needs the member still
-- present in the targeted stay after the attempt. Nothing else resolves it.
CREATE TABLE guild.fact_moderation_attempt_resolution (
    moderation_attempt_key bigint PRIMARY KEY,
    unresolved_outcome text GENERATED ALWAYS AS ('uncertain'::text) STORED,
    resolved_outcome text NOT NULL CHECK (resolved_outcome IN ('succeeded', 'failed')),
    evidence_kind text NOT NULL CHECK (evidence_kind IN ('audit_log', 'member_present_same_join')),
    discord_audit_log_entry_id guild.discord_snowflake UNIQUE,
    observed_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (moderation_attempt_key, unresolved_outcome)
        REFERENCES guild.fact_moderation_action_attempt (moderation_attempt_key, outcome),
    CHECK ((resolved_outcome = 'succeeded') = (evidence_kind = 'audit_log')),
    CHECK ((evidence_kind = 'audit_log') = (discord_audit_log_entry_id IS NOT NULL))
);

-- Bot kicks that Discord confirmed, by its response or by its audit log.
CREATE VIEW guild.confirmed_moderation_kick AS
SELECT a.moderation_attempt_key, a.moderation_action_key, a.subject_user_key,
    a.target_membership_event_key, a.attempted_at AS confirmed_at,
    'discord_response'::text AS evidence_kind,
    NULL::guild.discord_snowflake AS discord_audit_log_entry_id
FROM guild.fact_moderation_action_attempt a
WHERE a.outcome = 'succeeded'
UNION ALL
SELECT a.moderation_attempt_key, a.moderation_action_key, a.subject_user_key,
    a.target_membership_event_key, r.observed_at, r.evidence_kind, r.discord_audit_log_entry_id
FROM guild.fact_moderation_action_attempt a
JOIN guild.fact_moderation_attempt_resolution r USING (moderation_attempt_key)
WHERE r.resolved_outcome = 'succeeded';

-- What a leader does by hand in Discord: kicks, bans, unbans and timeouts.
-- The collector reads these from Discord's audit log. The bot's own kicks
-- also appear there; they are moderation_action rows, so the collector
-- leaves out every entry whose executor is the bot's own user.
CREATE TABLE guild.fact_manual_moderation_action (
    manual_action_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    discord_audit_log_entry_id guild.discord_snowflake NOT NULL,
    action_kind text NOT NULL CHECK (action_kind IN ('kick', 'ban', 'unban', 'timeout')),
    subject_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    occurred_at timestamptz NOT NULL,
    reason text CHECK (btrim(reason) <> '' AND length(reason) <= 512),
    timeout_until timestamptz,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (discord_audit_log_entry_id),
    UNIQUE (subject_user_key, manual_action_key),
    CHECK ((action_kind = 'timeout') = (timeout_until IS NOT NULL)),
    CHECK (timeout_until IS NULL OR timeout_until > occurred_at)
);
COMMENT ON TABLE guild.fact_manual_moderation_action IS
    'One audit log entry of Discord for a kick, ban, unban or timeout that a person made. '
    'actor_user_key is the executor of the entry. reason is the audit log reason, when one was given.';
CREATE INDEX manual_moderation_member ON guild.fact_manual_moderation_action
    (subject_user_key, occurred_at DESC);

CREATE TABLE guild.fact_moderation_notice (
    moderation_notice_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    subject_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    notice_kind text NOT NULL CHECK (notice_kind IN
        ('kick_rejoin', 'post_rejoin_warning', 'manual_kick_rejoin', 'unban_rejoin')),
    moderation_action_key bigint,
    confirmed_attempt_key bigint,
    manual_action_key bigint,
    membership_event_key bigint NOT NULL REFERENCES guild.fact_discord_accepted_join,
    warning_key bigint,
    kick_month_gmt date NOT NULL CHECK (extract(day FROM kick_month_gmt) = 1),
    occurred_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE NULLS NOT DISTINCT (moderation_action_key, membership_event_key, notice_kind, warning_key),
    FOREIGN KEY (subject_user_key, moderation_action_key)
        REFERENCES guild.moderation_action (subject_user_key, moderation_action_key),
    FOREIGN KEY (moderation_action_key, confirmed_attempt_key)
        REFERENCES guild.fact_moderation_action_attempt
            (moderation_action_key, moderation_attempt_key),
    FOREIGN KEY (subject_user_key, warning_key)
        REFERENCES guild.warning (subject_user_key, warning_key),
    FOREIGN KEY (subject_user_key, manual_action_key)
        REFERENCES guild.fact_manual_moderation_action
            (subject_user_key, manual_action_key),
    CHECK ((notice_kind = 'post_rejoin_warning') = (warning_key IS NOT NULL)),
    CHECK ((notice_kind IN ('manual_kick_rejoin', 'unban_rejoin')) = (manual_action_key IS NOT NULL)),
    CHECK ((manual_action_key IS NULL) = (moderation_action_key IS NOT NULL)),
    CHECK ((moderation_action_key IS NULL) = (confirmed_attempt_key IS NULL))
);
CREATE UNIQUE INDEX moderation_notice_warning ON guild.fact_moderation_notice (warning_key)
    WHERE warning_key IS NOT NULL;
CREATE INDEX moderation_notice_member_month ON guild.fact_moderation_notice
    (subject_user_key, kick_month_gmt, occurred_at DESC);
COMMENT ON TABLE guild.fact_moderation_notice IS
    'Durable leadership notification intent, not delivery evidence. Resolve the leadership_notifications channel binding through the delivery backend; operation_id correlates later outbox work.';
COMMENT ON COLUMN guild.fact_moderation_notice.notice_kind IS
    'kick_rejoin and post_rejoin_warning follow a confirmed kick of the bot. manual_kick_rejoin '
    'and unban_rejoin follow a kick or an unban that a person made, in manual_action_key. Only '
    'kick_rejoin changes how later warnings of the month are handled.';

CREATE VIEW guild.active_warning_counts AS
SELECT w.subject_user_key, w.issue_month_gmt, count(*) AS active_warnings
FROM guild.warning w LEFT JOIN guild.warning_revocation r USING (warning_key)
WHERE r.warning_key IS NULL
GROUP BY w.subject_user_key, w.issue_month_gmt;

-- Kick history is what the bot confirmed and what a person did by hand.
CREATE VIEW guild.fact_moderation_event AS
SELECT a.subject_user_key, a.action_kind, 'bot'::text AS origin,
    NULL::bigint AS actor_user_key, k.confirmed_at AS occurred_at, NULL::text AS reason,
    NULL::timestamptz AS timeout_until, a.moderation_action_key, NULL::bigint AS manual_action_key
FROM guild.moderation_action a
JOIN guild.confirmed_moderation_kick k USING (moderation_action_key)
UNION ALL
SELECT subject_user_key, action_kind, 'manual', actor_user_key, occurred_at, reason,
    timeout_until, NULL, manual_action_key
FROM guild.fact_manual_moderation_action;
