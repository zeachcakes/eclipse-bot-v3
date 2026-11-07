-- Discord utility stars and their transactional current-state projections.
-- XP v1 deliberately uses fixed UTC minutes. This is a provisional physical
-- implementation, not a decision about rolling limits, ranks, or leaderboard
-- eligibility. No rank thresholds or departed-user visibility policy is added.

CREATE FUNCTION guild.discord_reject_history_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Discord history is append-only' USING ERRCODE = '23514';
END;
$$;

CREATE TABLE guild.fact_discord_membership_event (
    membership_event_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    event_kind text NOT NULL CHECK (event_kind IN ('join', 'departure')),
    occurred_at timestamptz NOT NULL,
    new_joinee_policy_days integer CHECK (new_joinee_policy_days > 0),
    new_joinee_expires_at timestamptz GENERATED ALWAYS AS
        ((occurred_at AT TIME ZONE 'UTC' + make_interval(days => new_joinee_policy_days))
            AT TIME ZONE 'UTC') STORED,
    observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((event_kind = 'join') = (new_joinee_policy_days IS NOT NULL))
);
CREATE INDEX discord_membership_user_history ON guild.fact_discord_membership_event
    (guild_key, user_key, occurred_at DESC, membership_event_key DESC);

CREATE TABLE guild.discord_member_state (
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    is_present boolean NOT NULL,
    last_membership_event_key bigint NOT NULL REFERENCES guild.fact_discord_membership_event,
    last_event_at timestamptz NOT NULL,
    PRIMARY KEY (guild_key, user_key)
);

CREATE FUNCTION guild.capture_discord_join_policy() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.event_kind = 'join' AND NEW.new_joinee_policy_days IS NULL THEN
        SELECT coalesce((SELECT new_joinee_days FROM guild.guild_settings
            WHERE guild_key = NEW.guild_key), 7) INTO NEW.new_joinee_policy_days;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER capture_discord_join_policy BEFORE INSERT
    ON guild.fact_discord_membership_event FOR EACH ROW
    EXECUTE FUNCTION guild.capture_discord_join_policy();

CREATE FUNCTION guild.project_discord_membership() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO guild.discord_member_state
        (guild_key, user_key, is_present, last_membership_event_key, last_event_at)
    VALUES (NEW.guild_key, NEW.user_key, NEW.event_kind = 'join',
            NEW.membership_event_key, NEW.occurred_at)
    ON CONFLICT (guild_key, user_key) DO UPDATE
    SET is_present = EXCLUDED.is_present,
        last_membership_event_key = EXCLUDED.last_membership_event_key,
        last_event_at = EXCLUDED.last_event_at
    WHERE (EXCLUDED.last_event_at, EXCLUDED.last_membership_event_key)
        > (discord_member_state.last_event_at, discord_member_state.last_membership_event_key);
    RETURN NEW;
END;
$$;
CREATE TRIGGER project_discord_membership AFTER INSERT
    ON guild.fact_discord_membership_event FOR EACH ROW
    EXECUTE FUNCTION guild.project_discord_membership();

CREATE TABLE guild.fact_role_change (
    role_event_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    role_key bigint NOT NULL,
    change_kind text NOT NULL CHECK (change_kind IN ('add', 'remove')),
    changed_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    provenance_kind text NOT NULL CHECK (provenance_kind IN
        ('manual', 'onboarding', 'clan_membership', 'town_hall', 'war_roster',
            'new_joinee_expiry', 'reconciliation')),
    origin_join_event_key bigint REFERENCES guild.fact_discord_membership_event,
    expires_at timestamptz,
    FOREIGN KEY (guild_key, role_key) REFERENCES guild.dim_discord_role (guild_key, role_key),
    CHECK (expires_at IS NULL OR origin_join_event_key IS NOT NULL)
);
CREATE INDEX discord_role_history ON guild.fact_role_change
    (guild_key, user_key, role_key, changed_at DESC, role_event_key DESC);

-- Confirmed held roles only. Desired roles and pending Discord operations must
-- not grant authority. Role names are labels; authorization uses stable keys.
CREATE TABLE guild.discord_member_role (
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    role_key bigint NOT NULL,
    assigned_at timestamptz NOT NULL,
    last_role_event_key bigint NOT NULL REFERENCES guild.fact_role_change,
    expires_at timestamptz,
    PRIMARY KEY (guild_key, user_key, role_key),
    FOREIGN KEY (guild_key, role_key) REFERENCES guild.dim_discord_role (guild_key, role_key)
);

CREATE FUNCTION guild.project_discord_role() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    join_event guild.fact_discord_membership_event%ROWTYPE;
    latest_key bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('discord-role'),
        hashtext(NEW.guild_key::text || ':' || NEW.user_key::text || ':' || NEW.role_key::text));
    IF NEW.origin_join_event_key IS NOT NULL THEN
        SELECT * INTO STRICT join_event FROM guild.fact_discord_membership_event
        WHERE membership_event_key = NEW.origin_join_event_key;
        IF join_event.event_kind <> 'join' OR join_event.guild_key <> NEW.guild_key
            OR join_event.user_key <> NEW.user_key THEN
            RAISE EXCEPTION 'role provenance must reference this member join' USING ERRCODE = '23514';
        END IF;
        IF NEW.expires_at IS NOT NULL
            AND NEW.expires_at <> join_event.new_joinee_expires_at THEN
            RAISE EXCEPTION 'New Joinee expiry must match the selected join policy snapshot'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    SELECT role_event_key INTO latest_key FROM guild.fact_role_change
    WHERE guild_key = NEW.guild_key AND user_key = NEW.user_key AND role_key = NEW.role_key
    ORDER BY changed_at DESC, role_event_key DESC LIMIT 1;
    IF latest_key <> NEW.role_event_key THEN RETURN NEW; END IF;
    IF NEW.change_kind = 'remove' THEN
        DELETE FROM guild.discord_member_role
        WHERE guild_key = NEW.guild_key AND user_key = NEW.user_key AND role_key = NEW.role_key;
    ELSE
        INSERT INTO guild.discord_member_role
            (guild_key, user_key, role_key, assigned_at, last_role_event_key, expires_at)
        VALUES (NEW.guild_key, NEW.user_key, NEW.role_key, NEW.changed_at,
                NEW.role_event_key, NEW.expires_at)
        ON CONFLICT (guild_key, user_key, role_key) DO UPDATE
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
    xp_per_message integer NOT NULL CHECK (xp_per_message > 0),
    credited_messages_per_minute integer NOT NULL CHECK (credited_messages_per_minute > 0),
    window_kind text NOT NULL CHECK (window_kind = 'fixed_utc_minute'),
    is_provisional boolean NOT NULL DEFAULT true
);
INSERT INTO guild.chat_xp_policy VALUES ('provisional_fixed_utc_minute_v1', 20, 5,
    'fixed_utc_minute', true);

CREATE TABLE guild.fact_chat_xp_award (
    xp_award_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    channel_key bigint NOT NULL,
    discord_message_id guild.discord_snowflake NOT NULL UNIQUE,
    message_sent_at timestamptz NOT NULL,
    minute_utc timestamp GENERATED ALWAYS AS
        (date_trunc('minute', message_sent_at AT TIME ZONE 'UTC')) STORED,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    policy_key text NOT NULL DEFAULT 'provisional_fixed_utc_minute_v1'
        REFERENCES guild.chat_xp_policy,
    xp integer NOT NULL DEFAULT 20 CHECK (xp > 0),
    FOREIGN KEY (guild_key, channel_key)
        REFERENCES guild.dim_discord_channel (guild_key, channel_key)
);
CREATE INDEX chat_xp_member_time ON guild.fact_chat_xp_award
    (guild_key, user_key, message_sent_at);
CREATE TABLE guild.chat_xp_minute_usage (
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    minute_utc timestamp NOT NULL,
    credited_messages integer NOT NULL CHECK (credited_messages > 0),
    PRIMARY KEY (guild_key, user_key, minute_utc)
);

CREATE FUNCTION guild.enforce_chat_xp_policy() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    policy guild.chat_xp_policy%ROWTYPE;
    usage_count integer;
BEGIN
    SELECT * INTO STRICT policy FROM guild.chat_xp_policy WHERE policy_key = NEW.policy_key;
    IF NEW.xp <> policy.xp_per_message THEN
        RAISE EXCEPTION 'XP award must match its policy version' USING ERRCODE = '23514';
    END IF;
    -- The usage row serializes awards across every channel for this member.
    INSERT INTO guild.chat_xp_minute_usage (guild_key, user_key, minute_utc, credited_messages)
    VALUES (NEW.guild_key, NEW.user_key, NEW.minute_utc, 1)
    ON CONFLICT (guild_key, user_key, minute_utc) DO UPDATE
    SET credited_messages = chat_xp_minute_usage.credited_messages + 1
    RETURNING credited_messages INTO usage_count;
    IF usage_count > policy.credited_messages_per_minute THEN
        RAISE EXCEPTION 'XP minute allowance exhausted'
            USING ERRCODE = '23514', CONSTRAINT = 'chat_xp_minute_allowance';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER enforce_chat_xp_policy AFTER INSERT ON guild.fact_chat_xp_award
    FOR EACH ROW EXECUTE FUNCTION guild.enforce_chat_xp_policy();

CREATE FUNCTION guild.credit_chat_xp(p_guild bigint, p_user bigint, p_channel bigint,
    p_message numeric, p_sent_at timestamptz) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    award guild.fact_chat_xp_award%ROWTYPE;
    violated_constraint text;
BEGIN
    INSERT INTO guild.fact_chat_xp_award
        (guild_key, user_key, channel_key, discord_message_id, message_sent_at)
    VALUES (p_guild, p_user, p_channel, p_message, p_sent_at)
    ON CONFLICT (discord_message_id) DO NOTHING RETURNING * INTO award;
    IF award.xp_award_key IS NULL THEN
        SELECT * INTO STRICT award FROM guild.fact_chat_xp_award
        WHERE discord_message_id = p_message;
        IF (award.guild_key, award.user_key, award.channel_key, award.message_sent_at)
            IS DISTINCT FROM (p_guild, p_user, p_channel, p_sent_at) THEN
            RAISE EXCEPTION 'message identity conflicts with the existing award' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN award.xp_award_key;
EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS violated_constraint = CONSTRAINT_NAME;
    IF violated_constraint = 'chat_xp_minute_allowance' THEN RETURN NULL; END IF;
    RAISE;
END;
$$;

-- Aggregates intentionally retain departed identities. Visibility/rank policy
-- and the eventual reporting calendar remain application decisions.
CREATE VIEW guild.chat_xp_all_time_totals AS
SELECT guild_key, user_key, sum(xp)::bigint AS xp_total, count(*) AS credited_messages
FROM guild.fact_chat_xp_award GROUP BY guild_key, user_key;
CREATE VIEW guild.chat_xp_monthly_totals_utc AS
SELECT guild_key, user_key,
    date_trunc('month', message_sent_at AT TIME ZONE 'UTC')::date AS month_utc,
    sum(xp)::bigint AS xp_total, count(*) AS credited_messages
FROM guild.fact_chat_xp_award GROUP BY guild_key, user_key, month_utc;

CREATE TABLE guild.warning (
    warning_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    subject_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    issued_by_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    issue_month_gmt date GENERATED ALWAYS AS
        (date_trunc('month', issued_at AT TIME ZONE 'UTC')::date) STORED,
    reason text NOT NULL CHECK (length(btrim(reason)) > 0),
    UNIQUE (guild_key, subject_user_key, warning_key)
);
CREATE INDEX warning_subject_month ON guild.warning
    (guild_key, subject_user_key, issue_month_gmt);
CREATE TABLE guild.warning_revocation (
    warning_key bigint PRIMARY KEY REFERENCES guild.warning,
    revoked_by_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    revoked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    reason text NOT NULL CHECK (length(btrim(reason)) > 0)
);
CREATE TABLE guild.fact_warning_event (
    warning_event_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    warning_key bigint NOT NULL,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    subject_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    actor_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    event_kind text NOT NULL CHECK (event_kind IN ('issued', 'revoked')),
    occurred_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    reason text NOT NULL CHECK (length(btrim(reason)) > 0),
    UNIQUE (warning_key, event_kind),
    FOREIGN KEY (guild_key, subject_user_key, warning_key)
        REFERENCES guild.warning (guild_key, subject_user_key, warning_key)
);

-- A durable decision is not evidence of a successful Discord kick. This initial
-- policy emits at most one automatic kick per subject/original issue month;
-- repeat threshold crossing/rejoin rules remain deliberately unimplemented.
CREATE TABLE guild.moderation_action (
    moderation_action_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    subject_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    action_kind text NOT NULL DEFAULT 'kick' CHECK (action_kind = 'kick'),
    warning_month_gmt date NOT NULL,
    trigger_warning_key bigint NOT NULL,
    decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'leased', 'succeeded', 'failed', 'uncertain')),
    next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_expires_at timestamptz,
    UNIQUE (guild_key, subject_user_key, action_kind, warning_month_gmt),
    FOREIGN KEY (guild_key, subject_user_key, trigger_warning_key)
        REFERENCES guild.warning (guild_key, subject_user_key, warning_key)
);
CREATE INDEX moderation_work_due ON guild.moderation_action (next_attempt_at)
    WHERE status IN ('pending', 'failed');
CREATE TABLE guild.fact_moderation_action_attempt (
    moderation_attempt_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    moderation_action_key bigint NOT NULL REFERENCES guild.moderation_action,
    attempt_number integer NOT NULL CHECK (attempt_number > 0),
    attempted_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    outcome text NOT NULL CHECK (outcome IN ('succeeded', 'failed', 'uncertain')),
    http_status integer CHECK (http_status BETWEEN 100 AND 599),
    -- A bounded diagnostic identifier, never an HTTP body, token, or freeform payload.
    diagnostic_code text CHECK (diagnostic_code ~ '^[A-Za-z0-9_.:-]{1,100}$'),
    UNIQUE (moderation_action_key, attempt_number),
    CHECK (outcome <> 'succeeded' OR http_status IS NULL OR http_status BETWEEN 200 AND 299)
);

CREATE FUNCTION guild.project_moderation_attempt() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE latest_outcome text;
BEGIN
    PERFORM 1 FROM guild.moderation_action
    WHERE moderation_action_key = NEW.moderation_action_key FOR NO KEY UPDATE;
    SELECT outcome INTO STRICT latest_outcome FROM guild.fact_moderation_action_attempt
    WHERE moderation_action_key = NEW.moderation_action_key
    ORDER BY attempt_number DESC LIMIT 1;
    UPDATE guild.moderation_action
    SET status = latest_outcome, lease_expires_at = NULL
    WHERE moderation_action_key = NEW.moderation_action_key;
    RETURN NEW;
END;
$$;
CREATE TRIGGER project_moderation_attempt AFTER INSERT
    ON guild.fact_moderation_action_attempt FOR EACH ROW
    EXECUTE FUNCTION guild.project_moderation_attempt();

CREATE FUNCTION guild.record_moderation_attempt(p_action bigint, p_outcome text,
    p_http_status integer DEFAULT NULL, p_diagnostic_code text DEFAULT NULL,
    p_attempted_at timestamptz DEFAULT clock_timestamp()) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE result bigint; current_status text;
BEGIN
    SELECT status INTO current_status FROM guild.moderation_action
    WHERE moderation_action_key = p_action FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'moderation action does not exist' USING ERRCODE = '23503';
    END IF;
    IF current_status = 'succeeded' THEN
        RAISE EXCEPTION 'moderation action already succeeded' USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.fact_moderation_action_attempt
        (moderation_action_key, attempt_number, attempted_at, outcome, http_status, diagnostic_code)
    SELECT p_action, coalesce(max(attempt_number), 0) + 1, p_attempted_at,
        p_outcome, p_http_status, p_diagnostic_code
    FROM guild.fact_moderation_action_attempt WHERE moderation_action_key = p_action
    RETURNING moderation_attempt_key INTO result;
    RETURN result;
END;
$$;

CREATE VIEW guild.active_warning_counts AS
SELECT w.guild_key, w.subject_user_key, w.issue_month_gmt, count(*) AS active_warnings
FROM guild.warning w LEFT JOIN guild.warning_revocation r USING (warning_key)
WHERE r.warning_key IS NULL
GROUP BY w.guild_key, w.subject_user_key, w.issue_month_gmt;

CREATE FUNCTION guild.authorize_warning_issue() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT guild.can_moderate(NEW.guild_key, NEW.issued_by_user_key) THEN
        RAISE EXCEPTION 'configured moderation role required' USING ERRCODE = '42501';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('warnings'),
        hashtext(NEW.guild_key::text || ':' || NEW.subject_user_key::text || ':' ||
            date_trunc('month', NEW.issued_at AT TIME ZONE 'UTC')::date::text));
    RETURN NEW;
END;
$$;
CREATE FUNCTION guild.record_warning_issue() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE valid_count bigint;
BEGIN
    INSERT INTO guild.fact_warning_event
        (warning_key, guild_key, subject_user_key, actor_user_key, event_kind, occurred_at, reason)
    VALUES (NEW.warning_key, NEW.guild_key, NEW.subject_user_key,
        NEW.issued_by_user_key, 'issued', NEW.issued_at, NEW.reason);
    SELECT active_warnings INTO valid_count FROM guild.active_warning_counts
    WHERE guild_key = NEW.guild_key AND subject_user_key = NEW.subject_user_key
        AND issue_month_gmt = NEW.issue_month_gmt;
    IF valid_count >= 5 THEN
        INSERT INTO guild.moderation_action
            (guild_key, subject_user_key, warning_month_gmt, trigger_warning_key)
        VALUES (NEW.guild_key, NEW.subject_user_key, NEW.issue_month_gmt, NEW.warning_key)
        ON CONFLICT (guild_key, subject_user_key, action_kind, warning_month_gmt) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER authorize_warning_issue BEFORE INSERT ON guild.warning
    FOR EACH ROW EXECUTE FUNCTION guild.authorize_warning_issue();
CREATE TRIGGER record_warning_issue AFTER INSERT ON guild.warning
    FOR EACH ROW EXECUTE FUNCTION guild.record_warning_issue();

CREATE FUNCTION guild.authorize_warning_revocation() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE issued guild.warning%ROWTYPE;
BEGIN
    SELECT * INTO STRICT issued FROM guild.warning WHERE warning_key = NEW.warning_key;
    IF NOT guild.can_moderate(issued.guild_key, NEW.revoked_by_user_key) THEN
        RAISE EXCEPTION 'configured moderation role required' USING ERRCODE = '42501';
    END IF;
    IF NEW.revoked_at < issued.issued_at THEN
        RAISE EXCEPTION 'revocation cannot precede issuance' USING ERRCODE = '23514';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('warnings'),
        hashtext(issued.guild_key::text || ':' || issued.subject_user_key::text || ':' ||
            issued.issue_month_gmt::text));
    RETURN NEW;
END;
$$;
CREATE FUNCTION guild.record_warning_revocation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO guild.fact_warning_event
        (warning_key, guild_key, subject_user_key, actor_user_key, event_kind, occurred_at, reason)
    SELECT warning_key, guild_key, subject_user_key, NEW.revoked_by_user_key,
        'revoked', NEW.revoked_at, NEW.reason
    FROM guild.warning WHERE warning_key = NEW.warning_key;
    RETURN NEW;
END;
$$;
CREATE TRIGGER authorize_warning_revocation BEFORE INSERT ON guild.warning_revocation
    FOR EACH ROW EXECUTE FUNCTION guild.authorize_warning_revocation();
CREATE TRIGGER record_warning_revocation AFTER INSERT ON guild.warning_revocation
    FOR EACH ROW EXECUTE FUNCTION guild.record_warning_revocation();

CREATE FUNCTION guild.issue_warning(p_guild bigint, p_subject bigint, p_actor bigint,
    p_reason text, p_issued_at timestamptz DEFAULT clock_timestamp()) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE result bigint;
BEGIN
    INSERT INTO guild.warning
        (guild_key, subject_user_key, issued_by_user_key, reason, issued_at)
    VALUES (p_guild, p_subject, p_actor, p_reason, p_issued_at)
    RETURNING warning_key INTO result;
    RETURN result;
END;
$$;
CREATE FUNCTION guild.revoke_warning(p_warning bigint, p_actor bigint, p_reason text,
    p_revoked_at timestamptz DEFAULT clock_timestamp()) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO guild.warning_revocation
        (warning_key, revoked_by_user_key, reason, revoked_at)
    VALUES (p_warning, p_actor, p_reason, p_revoked_at);
END;
$$;

CREATE FUNCTION guild.warning_history(p_guild bigint, p_requester bigint, p_subject bigint)
RETURNS SETOF guild.fact_warning_event
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_requester IS NULL OR (p_requester <> p_subject
        AND NOT guild.can_moderate(p_guild, p_requester)) THEN
        RAISE EXCEPTION 'warning history requires its subject or a configured moderator'
            USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT * FROM guild.fact_warning_event
    WHERE guild_key = p_guild AND subject_user_key = p_subject
    ORDER BY occurred_at, warning_event_key;
END;
$$;

-- Projection/control tables remain mutable; historical facts and policy versions
-- are append-only. Direct history rewrites cannot silently alter counts/roles.
DO $$
DECLARE history_table text;
BEGIN
    FOREACH history_table IN ARRAY ARRAY[
        'fact_discord_membership_event', 'fact_role_change', 'chat_xp_policy',
        'fact_chat_xp_award', 'warning', 'warning_revocation', 'fact_warning_event',
        'fact_moderation_action_attempt']
    LOOP
        EXECUTE format('CREATE TRIGGER reject_history_mutation BEFORE UPDATE OR DELETE ON guild.%I '
            || 'FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation()', history_table);
    END LOOP;
END;
$$;
