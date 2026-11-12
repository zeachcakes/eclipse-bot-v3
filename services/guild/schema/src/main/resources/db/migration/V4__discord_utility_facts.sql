-- Discord utility stars and their transactional current-state projections.
-- XP decisions use the server processing clock after the member lock. Source
-- message time remains separate for reporting; delayed messages cannot bypass
-- the rolling earning limit by supplying an earlier timestamp.

CREATE FUNCTION guild.discord_reject_history_mutation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    RAISE EXCEPTION 'Discord history is append-only' USING ERRCODE = '23514';
END;
$$;

CREATE TABLE guild.fact_discord_membership_event (
    membership_event_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    event_kind text NOT NULL CHECK (event_kind IN ('join', 'departure')),
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

CREATE TABLE guild.discord_member_state (
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    is_present boolean NOT NULL,
    last_membership_event_key bigint NOT NULL REFERENCES guild.fact_discord_membership_event,
    last_event_at timestamptz NOT NULL,
    PRIMARY KEY (user_key)
);

CREATE FUNCTION guild.capture_discord_join_policy() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF NEW.event_kind = 'join' AND NEW.new_joinee_policy_days IS NULL THEN
        SELECT coalesce((SELECT new_joinee_days FROM guild.guild_settings), 7)
        INTO NEW.new_joinee_policy_days;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER capture_discord_join_policy BEFORE INSERT
    ON guild.fact_discord_membership_event FOR EACH ROW
    EXECUTE FUNCTION guild.capture_discord_join_policy();

-- A Discord departure invalidates held-role authority, not identity, XP,
-- account links, or immutable observations. The source occurrence time governs
-- projection order, so delayed gateway events cannot revive an old staff role.
CREATE FUNCTION guild.project_discord_membership() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    accepted_user bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('discord-membership'),
        hashtext(NEW.user_key::text));
    INSERT INTO guild.discord_member_state
        (user_key, is_present, last_membership_event_key, last_event_at)
    VALUES (NEW.user_key, NEW.event_kind = 'join',
        NEW.membership_event_key, NEW.occurred_at)
    ON CONFLICT (user_key) DO UPDATE
    SET is_present = EXCLUDED.is_present,
        last_membership_event_key = EXCLUDED.last_membership_event_key,
        last_event_at = EXCLUDED.last_event_at
    WHERE (EXCLUDED.last_event_at, EXCLUDED.last_membership_event_key)
        > (discord_member_state.last_event_at, discord_member_state.last_membership_event_key)
    RETURNING user_key INTO accepted_user;
    IF accepted_user IS NULL THEN RETURN NEW; END IF;

    DELETE FROM guild.discord_member_role
    WHERE user_key = NEW.user_key;
    IF NEW.event_kind = 'join' THEN
        -- Fresh role confirmations can arrive before the join event itself.
        -- Rebuild only from this occurrence's source-time/provenance window;
        -- never synthesize add events for roles held during an earlier stay.
        INSERT INTO guild.discord_member_role
            (user_key, role_key, assigned_at, last_role_event_key, expires_at)
        SELECT user_key, role_key, changed_at, role_event_key, expires_at
        FROM (
            SELECT DISTINCT ON (role_key) *
            FROM guild.fact_role_change
            WHERE user_key = NEW.user_key
                AND changed_at >= NEW.occurred_at
                AND (origin_join_event_key IS NULL OR origin_join_event_key = NEW.membership_event_key)
            ORDER BY role_key, changed_at DESC, role_event_key DESC
        ) AS latest
        WHERE change_kind = 'add';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER project_discord_membership AFTER INSERT
    ON guild.fact_discord_membership_event FOR EACH ROW
    EXECUTE FUNCTION guild.project_discord_membership();

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

CREATE FUNCTION guild.project_discord_role() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    join_event guild.fact_discord_membership_event%ROWTYPE;
    member_state guild.discord_member_state%ROWTYPE;
    latest_key bigint;
BEGIN
    -- The same member lock is acquired by membership changes. Otherwise a
    -- concurrent departure could clear roles before this trigger restores one.
    PERFORM pg_advisory_xact_lock(hashtext('discord-membership'),
        hashtext(NEW.user_key::text));
    IF NEW.origin_join_event_key IS NOT NULL THEN
        SELECT * INTO STRICT join_event FROM guild.fact_discord_membership_event
        WHERE membership_event_key = NEW.origin_join_event_key;
        IF join_event.event_kind <> 'join' OR join_event.user_key <> NEW.user_key THEN
            RAISE EXCEPTION 'role provenance must reference this member join' USING ERRCODE = '23514';
        END IF;
        IF NEW.expires_at IS NOT NULL AND NEW.expires_at <> join_event.new_joinee_expires_at THEN
            RAISE EXCEPTION 'New Joinee expiry must match the selected join policy snapshot'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    SELECT * INTO member_state FROM guild.discord_member_state
    WHERE user_key = NEW.user_key;
    IF FOUND AND (
        NOT member_state.is_present
        OR NEW.changed_at < member_state.last_event_at
        OR (NEW.origin_join_event_key IS NOT NULL
            AND NEW.origin_join_event_key <> member_state.last_membership_event_key)
    ) THEN
        RETURN NEW;
    END IF;
    SELECT role_event_key INTO latest_key FROM guild.fact_role_change
    WHERE user_key = NEW.user_key AND role_key = NEW.role_key
        AND (member_state.user_key IS NULL OR (
            changed_at >= member_state.last_event_at
            AND (origin_join_event_key IS NULL OR origin_join_event_key = member_state.last_membership_event_key)
        ))
    ORDER BY changed_at DESC, role_event_key DESC LIMIT 1;
    IF latest_key <> NEW.role_event_key THEN RETURN NEW; END IF;
    IF NEW.change_kind = 'remove' THEN
        DELETE FROM guild.discord_member_role
        WHERE user_key = NEW.user_key AND role_key = NEW.role_key;
    ELSE
        INSERT INTO guild.discord_member_role
            (user_key, role_key, assigned_at, last_role_event_key, expires_at)
        VALUES (NEW.user_key, NEW.role_key, NEW.changed_at,
            NEW.role_event_key, NEW.expires_at)
        ON CONFLICT (user_key, role_key) DO UPDATE
        SET assigned_at = EXCLUDED.assigned_at, last_role_event_key = EXCLUDED.last_role_event_key,
            expires_at = EXCLUDED.expires_at;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER project_discord_role AFTER INSERT ON guild.fact_role_change
    FOR EACH ROW EXECUTE FUNCTION guild.project_discord_role();

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
    'agreed version, and rows are append-only. A new version needs a migration that widens '
    'the checks and the XP sampler together; guild_settings then selects it by key.';
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
CREATE TRIGGER reject_award_view_mutation
    INSTEAD OF INSERT OR UPDATE OR DELETE ON guild.fact_chat_xp_award
    FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation();
CREATE INDEX chat_xp_member_processing_time ON guild.fact_chat_xp_decision
    (user_key, decided_at) WHERE outcome = 'credited';
CREATE INDEX chat_xp_member_source_time ON guild.fact_chat_xp_decision
    (user_key, message_sent_at) WHERE outcome = 'credited';
-- Period leaderboards range over every member's awards by source time.
CREATE INDEX chat_xp_source_time ON guild.fact_chat_xp_decision
    (message_sent_at) INCLUDE (user_key, xp) WHERE outcome = 'credited';

-- A UUIDv4's first byte is cryptographically random (its version bits occur in
-- another byte). Rejection sampling avoids modulo bias: 253 = 23 * 11.
CREATE FUNCTION guild.sample_chat_xp() RETURNS integer
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE sample_byte integer;
BEGIN
    LOOP
        sample_byte := get_byte(uuid_send(gen_random_uuid()), 0);
        IF sample_byte < 253 THEN RETURN 15 + sample_byte % 11; END IF;
    END LOOP;
END;
$$;

CREATE FUNCTION guild.enforce_chat_xp_policy() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE policy guild.chat_xp_policy%ROWTYPE;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('discord-membership'),
        hashtext(NEW.user_key::text));
    SELECT * INTO STRICT policy FROM guild.chat_xp_policy WHERE policy_key = NEW.policy_key;
    IF (SELECT count(*) FROM guild.fact_chat_xp_decision
        WHERE user_key = NEW.user_key AND outcome = 'credited'
            AND decided_at > NEW.decided_at - make_interval(secs => policy.window_seconds)
            AND decided_at <= NEW.decided_at) >= policy.credited_messages_per_window THEN
        RAISE EXCEPTION 'XP rolling allowance exhausted'
            USING ERRCODE = '23514', CONSTRAINT = 'chat_xp_rolling_allowance';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER enforce_chat_xp_policy BEFORE INSERT ON guild.fact_chat_xp_decision
    FOR EACH ROW WHEN (NEW.outcome = 'credited')
    EXECUTE FUNCTION guild.enforce_chat_xp_policy();

CREATE FUNCTION guild.credit_chat_xp(p_user bigint, p_channel bigint,
    p_message guild.discord_snowflake, p_sent_at timestamptz) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    decision guild.fact_chat_xp_decision%ROWTYPE;
    selected_policy guild.chat_xp_policy%ROWTYPE;
    processing_time timestamptz;
    eligible_role bigint;
    decision_outcome text;
    awarded_xp integer;
    result_key bigint;
BEGIN
    -- Share the membership lock with role/departure projection. Serialize the
    -- global message identity too, including conflicting retries by another user.
    PERFORM pg_advisory_xact_lock(hashtext('discord-membership'),
        hashtext(p_user::text));
    PERFORM pg_advisory_xact_lock(hashtext('chat-xp-message'), hashtext(p_message::text));
    SELECT * INTO decision FROM guild.fact_chat_xp_decision WHERE discord_message_id = p_message;
    IF FOUND THEN
        IF (decision.user_key, decision.channel_key, decision.message_sent_at)
            IS DISTINCT FROM (p_user, p_channel, p_sent_at) THEN
            RAISE EXCEPTION 'message identity conflicts with its existing XP decision'
                USING ERRCODE = '23514';
        END IF;
        RETURN decision.xp_award_key;
    END IF;

    processing_time := clock_timestamp();
    SELECT p.* INTO STRICT selected_policy FROM guild.chat_xp_policy p
    WHERE p.policy_key = coalesce((SELECT chat_xp_policy_key FROM guild.guild_settings),
        'rolling_60s_v1');
    IF NOT EXISTS (SELECT FROM guild.discord_member_state
        WHERE user_key = p_user AND is_present) THEN
        decision_outcome := 'not_present';
    ELSE
        SELECT r.role_key INTO eligible_role FROM guild.discord_member_role r
        JOIN guild.chat_xp_eligibility_role e USING (role_key)
        JOIN guild.dim_discord_role d USING (role_key)
        WHERE r.user_key = p_user AND d.deleted_at IS NULL
            AND (r.expires_at IS NULL OR r.expires_at > processing_time)
        ORDER BY r.role_key LIMIT 1;
        IF eligible_role IS NULL THEN
            decision_outcome := 'missing_eligible_role';
        ELSIF (SELECT count(*) FROM guild.fact_chat_xp_award
            WHERE user_key = p_user
                AND earned_at > processing_time - make_interval(secs => selected_policy.window_seconds))
            >= selected_policy.credited_messages_per_window THEN
            decision_outcome := 'rate_limited';
        ELSE
            decision_outcome := 'credited';
            awarded_xp := guild.sample_chat_xp();
        END IF;
    END IF;
    INSERT INTO guild.fact_chat_xp_decision
        (user_key, channel_key, discord_message_id, message_sent_at,
            decided_at, policy_key, outcome, eligibility_role_key, xp)
    VALUES (p_user, p_channel, p_message, p_sent_at, processing_time,
        selected_policy.policy_key, decision_outcome, eligible_role, awarded_xp)
    RETURNING xp_award_key INTO result_key;
    RETURN result_key;
END;
$$;
COMMENT ON FUNCTION guild.credit_chat_xp(bigint, bigint, guild.discord_snowflake, timestamptz) IS
    'Uses processing time after the member lock for the rolling (now-60s, now] window; message time is reporting evidence only. Both accepted and rejected message decisions are final on replay.';

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
CREATE FUNCTION guild.project_chat_rank() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    prior_rank smallint;
    next_rank smallint;
    next_total bigint;
BEGIN
    SELECT rank_key, cumulative_xp INTO prior_rank, next_total FROM guild.chat_member_rank_state
    WHERE user_key = NEW.user_key;
    next_total := coalesce(next_total, 0) + NEW.xp;
    SELECT rank_key INTO STRICT next_rank FROM guild.chat_rank_tier
    WHERE minimum_cumulative_xp <= next_total ORDER BY minimum_cumulative_xp DESC LIMIT 1;
    INSERT INTO guild.chat_member_rank_state
        (user_key, cumulative_xp, rank_key, last_award_key, updated_at)
    VALUES (NEW.user_key, next_total, next_rank, NEW.xp_award_key, NEW.decided_at)
    ON CONFLICT (user_key) DO UPDATE
    SET cumulative_xp = EXCLUDED.cumulative_xp, rank_key = EXCLUDED.rank_key,
        last_award_key = EXCLUDED.last_award_key, updated_at = EXCLUDED.updated_at;
    IF prior_rank IS DISTINCT FROM next_rank THEN
        INSERT INTO guild.fact_chat_rank_change
            (user_key, previous_rank_key, rank_key, cumulative_xp, trigger_award_key, decided_at)
        VALUES (NEW.user_key, prior_rank, next_rank, next_total,
            NEW.xp_award_key, NEW.decided_at);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER project_chat_rank AFTER INSERT ON guild.fact_chat_xp_decision
    FOR EACH ROW WHEN (NEW.outcome = 'credited')
    EXECUTE FUNCTION guild.project_chat_rank();

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
CREATE TRIGGER reject_warning_history_view_mutation
    INSTEAD OF INSERT OR UPDATE OR DELETE ON guild.fact_warning_event
    FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation();

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
    'The token of the latest claim. record_moderation_attempt accepts one report, and only with '
    'this token. Recording the report clears it and the next claim replaces it, so a worker whose '
    'claim was taken over cannot report. A cancellation keeps it: the worker that held the kick '
    'may still report what happened.';
CREATE INDEX moderation_work_due ON guild.moderation_action (next_attempt_at)
    WHERE next_attempt_at IS NOT NULL;
-- The kick worker needs the decisions that still owe an attempt and nothing
-- else from the private warning and moderation ledgers. A row is ready when
-- next_attempt_at has passed and no lease is active; claim it before kicking.
CREATE VIEW guild.pending_moderation_action AS
SELECT moderation_action_key, subject_user_key, action_kind,
    warning_month_gmt, decided_at, status, attempts_remaining, next_attempt_at, lease_expires_at
FROM guild.moderation_action WHERE next_attempt_at IS NOT NULL;
CREATE TABLE guild.fact_moderation_action_attempt (
    moderation_attempt_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    moderation_action_key bigint NOT NULL REFERENCES guild.moderation_action,
    attempt_number integer NOT NULL CHECK (attempt_number > 0),
    claim_token uuid NOT NULL UNIQUE,
    attempted_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    outcome text NOT NULL CHECK (outcome IN ('succeeded', 'failed', 'uncertain')),
    http_status integer CHECK (http_status BETWEEN 100 AND 599),
    -- A bounded diagnostic identifier, never an HTTP body, token, or freeform payload.
    diagnostic_code text CHECK (diagnostic_code ~ '^[A-Za-z0-9_.:-]{1,100}$'),
    UNIQUE (moderation_action_key, attempt_number),
    UNIQUE (moderation_action_key, moderation_attempt_key),
    CHECK (outcome <> 'succeeded' OR http_status IS NULL OR http_status BETWEEN 200 AND 299)
);

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

-- Record which joins actually won the membership projection. This preserves
-- accepted-join evidence for a successful kick receipt arriving later, without
-- treating stale gateway joins as rejoin evidence or changing the projection.
CREATE TABLE guild.fact_discord_accepted_join (
    membership_event_key bigint PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    FOREIGN KEY (user_key, membership_event_key)
        REFERENCES guild.fact_discord_membership_event (user_key, membership_event_key)
);
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

CREATE FUNCTION guild.validate_moderation_notice() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    kick guild.fact_moderation_action_attempt%ROWTYPE;
    manual guild.fact_manual_moderation_action%ROWTYPE;
    joined guild.fact_discord_membership_event%ROWTYPE;
    issued guild.warning%ROWTYPE;
    removed_at timestamptz;
BEGIN
    SELECT * INTO STRICT joined FROM guild.fact_discord_membership_event
    WHERE membership_event_key = NEW.membership_event_key;
    IF NEW.manual_action_key IS NOT NULL THEN
        SELECT * INTO STRICT manual FROM guild.fact_manual_moderation_action
        WHERE manual_action_key = NEW.manual_action_key;
        IF manual.action_kind IS DISTINCT FROM (CASE NEW.notice_kind
            WHEN 'manual_kick_rejoin' THEN 'kick' WHEN 'unban_rejoin' THEN 'unban' END) THEN
            RAISE EXCEPTION 'manual moderation notice requires a kick or an unban of its kind'
                USING ERRCODE = '23514';
        END IF;
        removed_at := manual.occurred_at;
    ELSE
        SELECT * INTO STRICT kick FROM guild.fact_moderation_action_attempt
        WHERE moderation_attempt_key = NEW.confirmed_attempt_key;
        IF kick.outcome = 'succeeded' THEN removed_at := kick.attempted_at; END IF;
    END IF;
    IF removed_at IS NULL OR joined.event_kind <> 'join'
        OR joined.user_key IS DISTINCT FROM NEW.subject_user_key
        OR joined.occurred_at < removed_at
        OR date_trunc('month', removed_at AT TIME ZONE 'UTC')::date <> NEW.kick_month_gmt
        OR date_trunc('month', joined.occurred_at AT TIME ZONE 'UTC')::date <> NEW.kick_month_gmt THEN
        RAISE EXCEPTION 'moderation notice requires a confirmed kick and accepted same-month rejoin'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.notice_kind <> 'post_rejoin_warning' AND NEW.occurred_at <> joined.occurred_at THEN
        RAISE EXCEPTION 'rejoin notice time must match its accepted join' USING ERRCODE = '23514';
    END IF;
    IF NEW.warning_key IS NOT NULL THEN
        SELECT * INTO STRICT issued FROM guild.warning WHERE warning_key = NEW.warning_key;
        IF issued.issue_month_gmt <> NEW.kick_month_gmt OR issued.issued_at < joined.occurred_at
            OR NEW.occurred_at <> issued.issued_at THEN
            RAISE EXCEPTION 'post-rejoin warning notice must match its original warning month/time'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER validate_moderation_notice BEFORE INSERT ON guild.fact_moderation_notice
    FOR EACH ROW EXECUTE FUNCTION guild.validate_moderation_notice();

CREATE FUNCTION guild.record_moderation_rejoin_notices(p_user bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE inserted_count integer; warning_count integer; manual_count integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('discord-membership'),
        hashtext(p_user::text));
    -- A kick or an unban that a person made, followed by an accepted join in
    -- the same month. For each join and kind the latest such action counts.
    INSERT INTO guild.fact_moderation_notice
        (subject_user_key, notice_kind, manual_action_key,
            membership_event_key, kick_month_gmt, occurred_at)
    SELECT p_user,
        CASE kind.action_kind WHEN 'kick' THEN 'manual_kick_rejoin' ELSE 'unban_rejoin' END,
        removal.manual_action_key, j.membership_event_key,
        date_trunc('month', removal.occurred_at AT TIME ZONE 'UTC')::date, j.occurred_at
    FROM guild.fact_discord_accepted_join accepted
    JOIN guild.fact_discord_membership_event j USING (membership_event_key)
    CROSS JOIN (VALUES ('kick'), ('unban')) AS kind(action_kind)
    CROSS JOIN LATERAL (
        SELECT m.manual_action_key, m.occurred_at
        FROM guild.fact_manual_moderation_action m
        WHERE m.subject_user_key = p_user
            AND m.action_kind = kind.action_kind AND m.occurred_at <= j.occurred_at
            AND date_trunc('month', m.occurred_at AT TIME ZONE 'UTC')
                = date_trunc('month', j.occurred_at AT TIME ZONE 'UTC')
        ORDER BY m.occurred_at DESC, m.manual_action_key DESC LIMIT 1
    ) removal
    WHERE accepted.user_key = p_user
    ON CONFLICT (moderation_action_key, membership_event_key, notice_kind, warning_key) DO NOTHING;
    GET DIAGNOSTICS manual_count = ROW_COUNT;
    INSERT INTO guild.fact_moderation_notice
        (subject_user_key, notice_kind, moderation_action_key,
            confirmed_attempt_key, membership_event_key, kick_month_gmt, occurred_at)
    SELECT p_user, 'kick_rejoin', kick.moderation_action_key,
        kick.moderation_attempt_key, j.membership_event_key,
        date_trunc('month', kick.attempted_at AT TIME ZONE 'UTC')::date, j.occurred_at
    FROM guild.fact_discord_accepted_join accepted
    JOIN guild.fact_discord_membership_event j USING (membership_event_key)
    CROSS JOIN LATERAL (
        SELECT a.moderation_action_key, attempt.moderation_attempt_key, attempt.attempted_at
        FROM guild.moderation_action a
        JOIN guild.fact_moderation_action_attempt attempt USING (moderation_action_key)
        WHERE a.subject_user_key = p_user
            AND attempt.outcome = 'succeeded' AND attempt.attempted_at <= j.occurred_at
            AND date_trunc('month', attempt.attempted_at AT TIME ZONE 'UTC')
                = date_trunc('month', j.occurred_at AT TIME ZONE 'UTC')
        ORDER BY attempt.attempted_at DESC, attempt.moderation_attempt_key DESC LIMIT 1
    ) kick
    WHERE accepted.user_key = p_user
    ON CONFLICT (moderation_action_key, membership_event_key, notice_kind, warning_key) DO NOTHING;
    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    -- A warning or the join can arrive before a successful execution receipt.
    -- Recover its notice from source chronology without rewriting warning/action
    -- history or inventing a failed/uncertain-action rollback policy.
    INSERT INTO guild.fact_moderation_notice
        (subject_user_key, notice_kind, moderation_action_key,
            confirmed_attempt_key, membership_event_key, warning_key, kick_month_gmt, occurred_at)
    SELECT p_user, 'post_rejoin_warning', rejoined.moderation_action_key,
        rejoined.confirmed_attempt_key, rejoined.membership_event_key,
        w.warning_key, rejoined.kick_month_gmt, w.issued_at
    FROM guild.warning w
    CROSS JOIN LATERAL (
        SELECT n.* FROM guild.fact_moderation_notice n
        WHERE n.subject_user_key = p_user
            AND n.notice_kind = 'kick_rejoin' AND n.kick_month_gmt = w.issue_month_gmt
            AND n.occurred_at <= w.issued_at
        ORDER BY n.occurred_at DESC, n.moderation_notice_key DESC LIMIT 1
    ) rejoined
    WHERE w.subject_user_key = p_user
    ON CONFLICT (warning_key) WHERE warning_key IS NOT NULL DO NOTHING;
    GET DIAGNOSTICS warning_count = ROW_COUNT;
    RETURN inserted_count + warning_count + manual_count;
END;
$$;

-- The audit log is read after the event, so the rejoin may already be
-- recorded when its kick or unban arrives. The notices are derived again here.
CREATE FUNCTION guild.record_manual_moderation_action(
    p_audit_log_entry guild.discord_snowflake, p_action_kind text, p_subject bigint,
    p_actor bigint, p_occurred_at timestamptz, p_reason text DEFAULT NULL,
    p_timeout_until timestamptz DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE result bigint; existing guild.fact_manual_moderation_action%ROWTYPE;
BEGIN
    INSERT INTO guild.fact_manual_moderation_action
        (discord_audit_log_entry_id, action_kind, subject_user_key, actor_user_key,
            occurred_at, reason, timeout_until)
    VALUES (p_audit_log_entry, p_action_kind, p_subject, p_actor,
        p_occurred_at, p_reason, p_timeout_until)
    ON CONFLICT (discord_audit_log_entry_id) DO NOTHING
    RETURNING manual_action_key INTO result;
    IF result IS NULL THEN
        SELECT * INTO STRICT existing FROM guild.fact_manual_moderation_action
        WHERE discord_audit_log_entry_id = p_audit_log_entry;
        IF (existing.action_kind, existing.subject_user_key, existing.actor_user_key,
            existing.occurred_at, existing.reason, existing.timeout_until) IS DISTINCT FROM
            (p_action_kind, p_subject, p_actor, p_occurred_at, p_reason, p_timeout_until) THEN
            RAISE EXCEPTION 'audit log entry conflicts with its recorded moderation action'
                USING ERRCODE = '23514';
        END IF;
        RETURN existing.manual_action_key;
    END IF;
    IF p_action_kind IN ('kick', 'unban') THEN
        PERFORM guild.record_moderation_rejoin_notices(p_subject);
    END IF;
    RETURN result;
END;
$$;
COMMENT ON FUNCTION guild.record_manual_moderation_action IS
    'Collector interface: one kick, ban, unban or timeout from the audit log of Discord. The same '
    'entry returns the same row. Do not record an entry whose executor is the bot itself: the '
    'kicks of the bot are moderation_action rows.';
CREATE FUNCTION guild.record_accepted_join_moderation_notice() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF NEW.event_kind = 'join' AND EXISTS (SELECT FROM guild.discord_member_state
        WHERE user_key = NEW.user_key AND is_present
            AND last_membership_event_key = NEW.membership_event_key) THEN
        INSERT INTO guild.fact_discord_accepted_join (membership_event_key, user_key)
        VALUES (NEW.membership_event_key, NEW.user_key)
        ON CONFLICT (membership_event_key) DO NOTHING;
        PERFORM guild.record_moderation_rejoin_notices(NEW.user_key);
    END IF;
    RETURN NEW;
END;
$$;
-- PostgreSQL orders same-event triggers by name; this must run after the
-- project_discord_membership trigger has accepted or rejected the occurrence.
CREATE TRIGGER zz_record_moderation_rejoin_notice AFTER INSERT
    ON guild.fact_discord_membership_event FOR EACH ROW
    EXECUTE FUNCTION guild.record_accepted_join_moderation_notice();

CREATE VIEW guild.active_warning_counts AS
SELECT w.subject_user_key, w.issue_month_gmt, count(*) AS active_warnings
FROM guild.warning w LEFT JOIN guild.warning_revocation r USING (warning_key)
WHERE r.warning_key IS NULL
GROUP BY w.subject_user_key, w.issue_month_gmt;

-- A kick that still owes an attempt is cancelled when its member no longer has
-- five active warnings in the warning month. An attempt in flight is left to
-- finish: its failure cancels the kick instead of scheduling another attempt.
CREATE FUNCTION guild._cancel_unsupported_moderation_action(
    p_action bigint, p_cancelled_at timestamptz DEFAULT clock_timestamp()
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.moderation_action%ROWTYPE;
BEGIN
    SELECT * INTO item FROM guild.moderation_action
    WHERE moderation_action_key = p_action FOR NO KEY UPDATE;
    IF NOT FOUND OR item.next_attempt_at IS NULL
        OR item.lease_expires_at > clock_timestamp()
        OR coalesce((SELECT active_warnings FROM guild.active_warning_counts c
            WHERE c.subject_user_key = item.subject_user_key
                AND c.issue_month_gmt = item.warning_month_gmt), 0) >= 5 THEN
        RETURN false;
    END IF;
    UPDATE guild.moderation_action
    SET status = 'cancelled', cancelled_at = p_cancelled_at, next_attempt_at = NULL,
        lease_owner = NULL, lease_expires_at = NULL
    WHERE moderation_action_key = p_action;
    RETURN true;
END;
$$;

CREATE FUNCTION guild.project_moderation_attempt() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    item guild.moderation_action%ROWTYPE;
    latest guild.fact_moderation_action_attempt%ROWTYPE;
    remaining integer;
    retry_interval interval;
BEGIN
    SELECT * INTO STRICT item FROM guild.moderation_action
    WHERE moderation_action_key = NEW.moderation_action_key FOR NO KEY UPDATE;
    SELECT * INTO STRICT latest FROM guild.fact_moderation_action_attempt
    WHERE moderation_action_key = NEW.moderation_action_key
    ORDER BY attempt_number DESC LIMIT 1;
    remaining := greatest(item.attempts_remaining - 1, 0);
    SELECT make_interval(secs => coalesce((SELECT kick_retry_seconds FROM guild.guild_settings
        ), 300)) INTO retry_interval;
    -- A confirmed kick is evidence and replaces any other state. A failed or
    -- uncertain report on a cancelled kick is recorded but does not reopen it.
    UPDATE guild.moderation_action
    SET status = CASE WHEN latest.outcome = 'succeeded' OR item.status <> 'cancelled'
            THEN latest.outcome ELSE 'cancelled' END,
        cancelled_at = CASE WHEN latest.outcome = 'succeeded' THEN NULL ELSE cancelled_at END,
        attempts_remaining = remaining,
        next_attempt_at = CASE WHEN latest.outcome <> 'succeeded' AND item.status <> 'cancelled'
            AND remaining > 0 THEN latest.attempted_at + retry_interval END,
        lease_owner = NULL, lease_expires_at = NULL, claim_token = NULL
    WHERE moderation_action_key = NEW.moderation_action_key;
    IF NEW.outcome = 'succeeded' THEN
        PERFORM guild.record_moderation_rejoin_notices(item.subject_user_key);
    ELSE
        PERFORM guild._cancel_unsupported_moderation_action(NEW.moderation_action_key);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER project_moderation_attempt AFTER INSERT
    ON guild.fact_moderation_action_attempt FOR EACH ROW
    EXECUTE FUNCTION guild.project_moderation_attempt();

-- A report belongs to one claim. The token of that claim is accepted once and
-- only while no later claim has replaced it. Without this fence a worker whose
-- claim expired could report late, spend an attempt and release the claim of
-- the worker that took the kick over. An expired claim that nobody took over
-- may still report: the report is the only evidence of that attempt.
CREATE FUNCTION guild.record_moderation_attempt(p_action bigint, p_claim_token uuid,
    p_outcome text, p_http_status integer DEFAULT NULL, p_diagnostic_code text DEFAULT NULL,
    p_attempted_at timestamptz DEFAULT clock_timestamp()) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE result bigint; item guild.moderation_action%ROWTYPE;
BEGIN
    SELECT * INTO item FROM guild.moderation_action
    WHERE moderation_action_key = p_action FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'moderation action does not exist' USING ERRCODE = '23503';
    END IF;
    IF p_claim_token IS NULL OR item.claim_token IS DISTINCT FROM p_claim_token THEN
        RAISE EXCEPTION 'stale or repeated moderation claim' USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.fact_moderation_action_attempt
        (moderation_action_key, attempt_number, claim_token, attempted_at, outcome,
            http_status, diagnostic_code)
    SELECT p_action, coalesce(max(attempt_number), 0) + 1, p_claim_token, p_attempted_at,
        p_outcome, p_http_status, p_diagnostic_code
    FROM guild.fact_moderation_action_attempt WHERE moderation_action_key = p_action
    RETURNING moderation_attempt_key INTO result;
    RETURN result;
END;
$$;
COMMENT ON FUNCTION guild.record_moderation_attempt IS
    'Trusted kick worker: record the result of the attempt that p_claim_token was issued for. '
    'A token that a later claim replaced, or that already has a report, is rejected with 23514.';

-- One worker owns one attempt. The action tells the worker what to do: NULL
-- means the kick is not ready or another worker holds it, 'kick' means kick,
-- and 'check_member' means first check that the member is still in the
-- server, because an earlier attempt may already have removed them. A member
-- who is gone is recorded as a succeeded attempt instead of a second kick.
CREATE FUNCTION guild.claim_moderation_action(p_action bigint, p_worker text,
    p_lease_seconds integer DEFAULT 300, OUT action text, OUT claim_token uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.moderation_action%ROWTYPE; claimed_at timestamptz := clock_timestamp();
    token uuid := gen_random_uuid();
BEGIN
    IF p_lease_seconds IS NULL OR p_worker IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 3600
        OR p_worker !~ '^[A-Za-z0-9_.:-]{1,100}$' THEN
        RAISE EXCEPTION 'bounded moderation lease and worker identity required' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO item FROM guild.moderation_action
    WHERE moderation_action_key = p_action FOR NO KEY UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'moderation action does not exist' USING ERRCODE = '23503';
    END IF;
    IF item.next_attempt_at IS NULL OR item.next_attempt_at > claimed_at
        OR coalesce(item.lease_expires_at > claimed_at, false) THEN
        RETURN;
    END IF;
    -- A revocation that arrived while an earlier claim was held is applied now.
    IF guild._cancel_unsupported_moderation_action(p_action, claimed_at) THEN
        RETURN;
    END IF;
    -- The new token replaces the token of any earlier claim.
    UPDATE guild.moderation_action
    SET lease_owner = p_worker, lease_expires_at = claimed_at + make_interval(secs => p_lease_seconds),
        claim_token = token
    WHERE moderation_action_key = p_action;
    -- An expired lease without a recorded attempt is as unknown as an uncertain one.
    action := CASE WHEN item.status = 'uncertain' OR item.lease_owner IS NOT NULL
        THEN 'check_member' ELSE 'kick' END;
    claim_token := token;
END;
$$;
COMMENT ON FUNCTION guild.claim_moderation_action IS
    'Trusted kick worker: take the next automatic attempt of one kick for a bounded time. '
    'Returns one row. action is NULL, kick or check_member; claim_token is set with the action. '
    'Pass the token to record_moderation_attempt, which releases the claim.';

CREATE FUNCTION guild.authorize_warning_issue() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF NOT guild.can_moderate(NEW.issued_by_user_key) THEN
        RAISE EXCEPTION 'configured moderation role required' USING ERRCODE = '42501';
    END IF;
    -- Serialize warning evaluation with accepted joins and late kick receipts.
    PERFORM pg_advisory_xact_lock(hashtext('discord-membership'),
        hashtext(NEW.subject_user_key::text));
    PERFORM pg_advisory_xact_lock(hashtext('warnings'),
        hashtext(NEW.subject_user_key::text || ':' ||
            date_trunc('month', NEW.issued_at AT TIME ZONE 'UTC')::date::text));
    RETURN NEW;
END;
$$;
CREATE FUNCTION guild.record_warning_issue() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE valid_count bigint; rejoined guild.fact_moderation_notice%ROWTYPE;
BEGIN
    SELECT active_warnings INTO valid_count FROM guild.active_warning_counts
    WHERE subject_user_key = NEW.subject_user_key
        AND issue_month_gmt = NEW.issue_month_gmt;
    SELECT * INTO rejoined FROM guild.fact_moderation_notice
    WHERE subject_user_key = NEW.subject_user_key
        AND notice_kind = 'kick_rejoin' AND kick_month_gmt = NEW.issue_month_gmt
        AND occurred_at <= NEW.issued_at
    ORDER BY occurred_at DESC, moderation_notice_key DESC LIMIT 1;
    IF FOUND THEN
        INSERT INTO guild.fact_moderation_notice
            (subject_user_key, notice_kind, moderation_action_key,
                confirmed_attempt_key, membership_event_key, warning_key, kick_month_gmt, occurred_at)
        VALUES (NEW.subject_user_key, 'post_rejoin_warning',
            rejoined.moderation_action_key, rejoined.confirmed_attempt_key,
            rejoined.membership_event_key, NEW.warning_key, rejoined.kick_month_gmt, NEW.issued_at)
        ON CONFLICT (moderation_action_key, membership_event_key, notice_kind, warning_key) DO NOTHING;
    ELSIF valid_count >= 5 THEN
        -- A kick that a revocation cancelled is armed again by a new fifth
        -- active warning, with a fresh set of attempts. Any other existing
        -- decision for the month stays as it is.
        INSERT INTO guild.moderation_action AS a
            (subject_user_key, warning_month_gmt, trigger_warning_key, attempts_remaining)
        VALUES (NEW.subject_user_key, NEW.issue_month_gmt, NEW.warning_key,
            coalesce((SELECT kick_max_attempts FROM guild.guild_settings
                ), 3))
        ON CONFLICT (subject_user_key, action_kind, warning_month_gmt) DO UPDATE
        SET status = 'pending', cancelled_at = NULL, trigger_warning_key = EXCLUDED.trigger_warning_key,
            decided_at = EXCLUDED.decided_at, attempts_remaining = EXCLUDED.attempts_remaining,
            next_attempt_at = EXCLUDED.next_attempt_at
        WHERE a.status = 'cancelled';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER authorize_warning_issue BEFORE INSERT ON guild.warning
    FOR EACH ROW EXECUTE FUNCTION guild.authorize_warning_issue();
CREATE TRIGGER record_warning_issue AFTER INSERT ON guild.warning
    FOR EACH ROW EXECUTE FUNCTION guild.record_warning_issue();

CREATE FUNCTION guild.authorize_warning_revocation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE issued guild.warning%ROWTYPE;
BEGIN
    SELECT * INTO STRICT issued FROM guild.warning WHERE warning_key = NEW.warning_key;
    IF NOT guild.can_moderate(NEW.revoked_by_user_key) THEN
        RAISE EXCEPTION 'configured moderation role required' USING ERRCODE = '42501';
    END IF;
    IF NEW.revoked_at < issued.issued_at THEN
        RAISE EXCEPTION 'revocation cannot precede issuance' USING ERRCODE = '23514';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('warnings'),
        hashtext(issued.subject_user_key::text || ':' ||
            issued.issue_month_gmt::text));
    RETURN NEW;
END;
$$;
CREATE TRIGGER authorize_warning_revocation BEFORE INSERT ON guild.warning_revocation
    FOR EACH ROW EXECUTE FUNCTION guild.authorize_warning_revocation();
CREATE FUNCTION guild.record_warning_revocation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    PERFORM guild._cancel_unsupported_moderation_action(a.moderation_action_key, NEW.revoked_at)
    FROM guild.warning w
    JOIN guild.moderation_action a ON a.subject_user_key = w.subject_user_key AND a.warning_month_gmt = w.issue_month_gmt
    WHERE w.warning_key = NEW.warning_key;
    RETURN NEW;
END;
$$;
CREATE TRIGGER record_warning_revocation AFTER INSERT ON guild.warning_revocation
    FOR EACH ROW EXECUTE FUNCTION guild.record_warning_revocation();

CREATE FUNCTION guild.issue_warning(p_subject bigint, p_actor bigint,
    p_reason text, p_issued_at timestamptz DEFAULT clock_timestamp()) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE result bigint;
BEGIN
    INSERT INTO guild.warning
        (subject_user_key, issued_by_user_key, reason, issued_at)
    VALUES (p_subject, p_actor, p_reason, p_issued_at)
    RETURNING warning_key INTO result;
    RETURN result;
END;
$$;
-- Canonical command API: the backend supplies a stable operation UUID. The
-- five-argument issue_warning entry point remains for callers without one.
-- NULL means the command omitted an issue time: choose it once, then reuse it.
CREATE FUNCTION guild.issue_warning_command(p_operation_id uuid,
    p_subject bigint, p_actor bigint, p_reason text,
    p_issued_at timestamptz DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    existing guild.warning%ROWTYPE;
    result_key bigint;
BEGIN
    IF p_operation_id IS NULL THEN
        RAISE EXCEPTION 'warning commands require a stable operation UUID' USING ERRCODE = '23514';
    END IF;
    IF NOT guild.can_moderate(p_actor) THEN
        RAISE EXCEPTION 'configured moderation role required' USING ERRCODE = '42501';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('warning-command'), hashtext(p_operation_id::text));
    SELECT * INTO existing FROM guild.warning WHERE operation_id = p_operation_id;
    IF FOUND THEN
        IF (existing.subject_user_key, existing.issued_by_user_key, existing.reason)
                IS DISTINCT FROM (p_subject, p_actor, p_reason)
            OR (p_issued_at IS NOT NULL AND existing.issued_at IS DISTINCT FROM p_issued_at) THEN
            RAISE EXCEPTION 'warning operation identity conflicts with its existing command'
                USING ERRCODE = '23514';
        END IF;
        RETURN existing.warning_key;
    END IF;
    INSERT INTO guild.warning
        (operation_id, subject_user_key, issued_by_user_key, reason, issued_at)
    VALUES (p_operation_id, p_subject, p_actor, p_reason,
        coalesce(p_issued_at, clock_timestamp()))
    RETURNING warning_key INTO result_key;
    RETURN result_key;
END;
$$;

-- NULL means the caller omitted a revocation time: choose it once. A replay
-- that omits the time matches the stored decision by actor and reason, so a
-- retry does not conflict with its own first attempt.
CREATE FUNCTION guild.revoke_warning(p_warning bigint, p_actor bigint, p_reason text,
    p_revoked_at timestamptz DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE existing guild.warning_revocation%ROWTYPE;
BEGIN
    INSERT INTO guild.warning_revocation
        (warning_key, revoked_by_user_key, reason, revoked_at)
    VALUES (p_warning, p_actor, p_reason, coalesce(p_revoked_at, clock_timestamp()))
    ON CONFLICT (warning_key) DO NOTHING;
    IF NOT FOUND THEN
        SELECT * INTO STRICT existing FROM guild.warning_revocation WHERE warning_key = p_warning;
        IF (existing.revoked_by_user_key, existing.reason) IS DISTINCT FROM (p_actor, p_reason)
            OR (p_revoked_at IS NOT NULL AND existing.revoked_at IS DISTINCT FROM p_revoked_at) THEN
            RAISE EXCEPTION 'warning revocation conflicts with its existing decision'
                USING ERRCODE = '23514';
        END IF;
    END IF;
END;
$$;
-- Canonical command API, matching issue_warning_command: the backend supplies
-- a stable operation UUID, and a replay returns without a second decision.
CREATE FUNCTION guild.revoke_warning_command(p_operation_id uuid, p_warning bigint,
    p_actor bigint, p_reason text, p_revoked_at timestamptz DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    existing guild.warning_revocation%ROWTYPE;
BEGIN
    IF p_operation_id IS NULL THEN
        RAISE EXCEPTION 'revocation commands require a stable operation UUID' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.warning WHERE warning_key = p_warning) THEN
        RAISE EXCEPTION 'warning does not exist' USING ERRCODE = '23503';
    END IF;
    IF NOT guild.can_moderate(p_actor) THEN
        RAISE EXCEPTION 'configured moderation role required' USING ERRCODE = '42501';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('warning-command'), hashtext(p_operation_id::text));
    SELECT * INTO existing FROM guild.warning_revocation WHERE operation_id = p_operation_id;
    IF FOUND THEN
        IF (existing.warning_key, existing.revoked_by_user_key, existing.reason)
                IS DISTINCT FROM (p_warning, p_actor, p_reason)
            OR (p_revoked_at IS NOT NULL AND existing.revoked_at IS DISTINCT FROM p_revoked_at) THEN
            RAISE EXCEPTION 'revocation operation identity conflicts with its existing command'
                USING ERRCODE = '23514';
        END IF;
        RETURN;
    END IF;
    IF EXISTS (SELECT FROM guild.warning_revocation WHERE warning_key = p_warning) THEN
        RAISE EXCEPTION 'warning was already revoked by another operation' USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.warning_revocation
        (operation_id, warning_key, revoked_by_user_key, reason, revoked_at)
    VALUES (p_operation_id, p_warning, p_actor, p_reason,
        coalesce(p_revoked_at, clock_timestamp()));
END;
$$;

CREATE FUNCTION guild.warning_history(p_requester bigint, p_subject bigint)
RETURNS SETOF guild.fact_warning_event
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF p_requester IS NULL OR (p_requester <> p_subject
        AND NOT guild.can_moderate(p_requester)) THEN
        RAISE EXCEPTION 'warning history requires its subject or a configured moderator'
            USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT * FROM guild.fact_warning_event
    WHERE subject_user_key = p_subject
    ORDER BY occurred_at, warning_key, event_kind;
END;
$$;

-- Kick history is what the bot confirmed and what a person did by hand.
CREATE VIEW guild.fact_moderation_event AS
SELECT a.subject_user_key, a.action_kind, 'bot'::text AS origin,
    NULL::bigint AS actor_user_key, attempt.attempted_at AS occurred_at, NULL::text AS reason,
    NULL::timestamptz AS timeout_until, a.moderation_action_key, NULL::bigint AS manual_action_key
FROM guild.moderation_action a
JOIN guild.fact_moderation_action_attempt attempt USING (moderation_action_key)
WHERE attempt.outcome = 'succeeded'
UNION ALL
SELECT subject_user_key, action_kind, 'manual', actor_user_key, occurred_at, reason,
    timeout_until, NULL, manual_action_key
FROM guild.fact_manual_moderation_action;
CREATE FUNCTION guild.moderation_history(p_requester bigint, p_subject bigint)
RETURNS SETOF guild.fact_moderation_event
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF p_requester IS NULL OR (p_requester <> p_subject
        AND NOT guild.can_moderate(p_requester)) THEN
        RAISE EXCEPTION 'moderation history requires its subject or a configured moderator'
            USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT * FROM guild.fact_moderation_event
    WHERE subject_user_key = p_subject
    ORDER BY occurred_at, origin;
END;
$$;
COMMENT ON FUNCTION guild.moderation_history IS
    'Kicks that the bot confirmed, and kicks, bans, unbans and timeouts that a person made. The '
    'same rule as warning_history: a member reads their own entries, a moderator reads any member''s.';

-- Projection/control tables remain mutable; historical facts and policy versions
-- are append-only. Direct history rewrites cannot silently alter counts/roles.
DO $$
DECLARE history_table text;
BEGIN
    FOREACH history_table IN ARRAY ARRAY[
        'fact_discord_membership_event', 'fact_discord_accepted_join', 'fact_role_change',
        'chat_xp_policy', 'chat_rank_tier', 'fact_chat_xp_decision',
        'fact_chat_rank_change', 'warning', 'warning_revocation',
        'fact_moderation_action_attempt', 'fact_manual_moderation_action',
        'fact_moderation_notice']
    LOOP
        EXECUTE format('CREATE TRIGGER reject_history_mutation BEFORE UPDATE OR DELETE ON guild.%I '
            || 'FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation()', history_table);
    END LOOP;
END;
$$;
