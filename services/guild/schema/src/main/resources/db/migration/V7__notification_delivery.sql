-- Persistence and worker contracts only: no Kafka publisher, gRPC server, or
-- Discord client is implemented here. Java owns these records; Node uses Java
-- RPCs, never PostgreSQL. Every external adapter must honor the send permit and
-- disable automatic ping resends, including HTTP/client and gRPC retries.

CREATE TABLE guild.notification_report (
    report_key uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    logical_report_key text NOT NULL CHECK (logical_report_key ~ '^[A-Za-z0-9_:./-]{1,200}$'),
    report_kind text NOT NULL CHECK (report_kind IN ('clan_games_report', 'raid_report', 'cwl_roster')),
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
            'raid_report', 'moderation', 'role_reconcile', 'cwl_leadership', 'cwl_roster')),
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
    CHECK ((notification_kind = 'war_reminder') = (checkpoint_offset_seconds IS NOT NULL)),
    CHECK ((operation_kind IN ('report_create', 'report_edit')) = (report_key IS NOT NULL)),
    CHECK ((report_key IS NULL) = (report_revision IS NULL))
);
COMMENT ON COLUMN guild.notification_operation.operation_kind IS
    'For a report revision, report_create or report_edit is the action of its latest dispatch '
    'authorization. Until the first authorization it is the action expected when the revision was queued.';
CREATE UNIQUE INDEX notification_war_checkpoint ON guild.notification_operation
    (war_key, clan_key, checkpoint_offset_seconds) WHERE notification_kind = 'war_reminder';
CREATE UNIQUE INDEX notification_war_catchup ON guild.notification_operation
    (war_key, clan_key) WHERE notification_kind = 'war_catchup';
CREATE INDEX notification_due ON guild.notification_operation (due_at) WHERE status = 'pending';
-- The outbox publisher scans for work that is not yet published.
CREATE INDEX notification_unpublished ON guild.notification_operation (created_at)
    WHERE publication_state <> 'published';

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
    FOREIGN KEY (operation_key) REFERENCES guild.notification_operation (operation_key),
    CHECK (lease_expires_at > authorized_at),
    CHECK ((outcome IS NULL) = (finished_at IS NULL)),
    CHECK ((outcome IS NULL) = (recorded_at IS NULL)),
    CHECK (outcome IS NOT NULL OR (discord_message_id IS NULL AND http_status IS NULL AND error_code IS NULL)),
    CHECK (outcome <> 'succeeded' OR (started_at IS NOT NULL AND http_status IS NOT NULL AND http_status BETWEEN 200 AND 299))
);
CREATE UNIQUE INDEX notification_one_ping_attempt
    ON guild.fact_notification_dispatch_attempt (operation_key) WHERE is_ping;
CREATE VIEW guild.fact_notification_dispatch_authorization AS
SELECT dispatch_key, operation_key, fence, attempt_number, is_ping,
    worker_key, authorized_at, lease_expires_at
FROM guild.fact_notification_dispatch_attempt;
CREATE VIEW guild.notification_dispatch_state AS
SELECT dispatch_key, started_at, finished_at FROM guild.fact_notification_dispatch_attempt;
CREATE VIEW guild.fact_notification_dispatch_outcome AS
SELECT dispatch_key, outcome, recorded_at, discord_message_id, http_status, error_code
FROM guild.fact_notification_dispatch_attempt WHERE outcome IS NOT NULL;
CREATE TABLE guild.notification_catchup_input (
    catchup_operation_key uuid NOT NULL REFERENCES guild.notification_operation,
    source_operation_key uuid NOT NULL UNIQUE REFERENCES guild.notification_operation,
    PRIMARY KEY (catchup_operation_key, source_operation_key),
    CHECK (catchup_operation_key <> source_operation_key)
);

CREATE FUNCTION guild.guard_notification_authorization() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE kind text;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF (NEW.dispatch_key, NEW.operation_key, NEW.fence,
            NEW.attempt_number, NEW.is_ping, NEW.worker_key, NEW.authorized_at, NEW.lease_expires_at)
            IS DISTINCT FROM (OLD.dispatch_key, OLD.operation_key, OLD.fence,
                OLD.attempt_number, OLD.is_ping, OLD.worker_key, OLD.authorized_at, OLD.lease_expires_at)
            OR OLD.outcome IS NOT NULL
            OR (OLD.started_at IS NOT NULL AND NEW.started_at IS DISTINCT FROM OLD.started_at)
            OR (NEW.outcome = 'succeeded' AND OLD.started_at IS NULL) THEN
            RAISE EXCEPTION 'dispatch authorization, consumed permit and terminal outcome are write-once'
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    SELECT operation_kind INTO STRICT kind FROM guild.notification_operation WHERE operation_key = NEW.operation_key;
    IF NEW.is_ping IS DISTINCT FROM (kind = 'ping') OR NEW.started_at IS NOT NULL
        OR NEW.finished_at IS NOT NULL OR NEW.outcome IS NOT NULL THEN
        RAISE EXCEPTION 'authorization must retain the operation send policy' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER notification_authorization_policy BEFORE INSERT OR UPDATE ON guild.fact_notification_dispatch_attempt
FOR EACH ROW EXECUTE FUNCTION guild.guard_notification_authorization();
CREATE TRIGGER notification_dispatch_history BEFORE DELETE ON guild.fact_notification_dispatch_attempt
FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation();
CREATE TRIGGER notification_receipt_history BEFORE UPDATE OR DELETE ON guild.notification_kafka_receipt
FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation();

CREATE FUNCTION guild._enqueue_notification(p_logical text, p_kind text,
    p_notification text, p_channel bigint, p_audience text, p_due timestamptz, p_expires timestamptz,
    p_war bigint DEFAULT NULL, p_clan bigint DEFAULT NULL, p_offset integer DEFAULT NULL,
    p_user bigint DEFAULT NULL, p_generation bigint DEFAULT NULL, p_report uuid DEFAULT NULL,
    p_revision bigint DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE existing guild.notification_operation; result uuid;
BEGIN
    INSERT INTO guild.notification_operation
        (logical_key, operation_kind, notification_kind, channel_key, audience,
            due_at, expires_at, war_key, clan_key, checkpoint_offset_seconds,
            target_user_key, role_generation, report_key, report_revision)
    VALUES (p_logical, p_kind, p_notification, p_channel, p_audience,
        p_due, p_expires, p_war, p_clan, p_offset, p_user, p_generation, p_report, p_revision)
    ON CONFLICT (logical_key) DO NOTHING RETURNING operation_key INTO result;
    IF result IS NULL THEN
        SELECT * INTO STRICT existing FROM guild.notification_operation
        WHERE logical_key = p_logical;
        IF (existing.operation_kind, existing.notification_kind, existing.channel_key,
            existing.audience, existing.due_at, existing.expires_at, existing.war_key,
            existing.clan_key, existing.checkpoint_offset_seconds, existing.target_user_key,
            existing.role_generation, existing.report_key) IS DISTINCT FROM
            (p_kind, p_notification, p_channel, p_audience, p_due, p_expires,
                p_war, p_clan, p_offset, p_user, p_generation, p_report) THEN
            RAISE EXCEPTION 'logical notification identity conflicts with its immutable decision' USING ERRCODE = '23514';
        END IF;
        RETURN existing.operation_key;
    END IF;
    RETURN result;
END;
$$;

CREATE FUNCTION guild.queue_notification_ping(p_logical text, p_notification text,
    p_channel bigint, p_due timestamptz, p_expires timestamptz, p_audience text DEFAULT 'members')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF p_notification NOT IN ('welcome', 'raid_start', 'moderation', 'clan_games_report', 'raid_report') THEN
        RAISE EXCEPTION 'specialized notification requires its specialized workflow' USING ERRCODE = '23514';
    END IF;
    RETURN guild._enqueue_notification(p_logical, 'ping', p_notification,
        p_channel, p_audience, p_due, p_expires);
END;
$$;

CREATE FUNCTION guild.claim_notification_publication(p_operation uuid, p_worker text,
    p_lease_seconds integer DEFAULT 30) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_outbox; token uuid := gen_random_uuid();
BEGIN
    IF p_lease_seconds IS NULL OR p_worker IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 300
        OR p_worker !~ '^[A-Za-z0-9_.:-]{1,100}$' THEN
        RAISE EXCEPTION 'bounded publication lease and worker identity required' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT item FROM guild.notification_outbox WHERE operation_key = p_operation FOR UPDATE;
    IF item.publication_state = 'published' OR (item.publication_state = 'leased'
        AND item.lease_expires_at > clock_timestamp()) THEN RETURN NULL; END IF;
    UPDATE guild.notification_outbox SET publication_state = 'leased', publication_fence = token,
        worker_key = p_worker, lease_expires_at = clock_timestamp() + make_interval(secs => p_lease_seconds)
    WHERE operation_key = p_operation;
    RETURN token;
END;
$$;
CREATE FUNCTION guild.finish_notification_publication(p_operation uuid, p_fence uuid, p_outcome text,
    p_topic text DEFAULT NULL, p_partition integer DEFAULT NULL, p_offset bigint DEFAULT NULL,
    p_error_code text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_outbox;
BEGIN
    SELECT * INTO STRICT item FROM guild.notification_outbox WHERE operation_key = p_operation FOR UPDATE;
    IF item.publication_state <> 'leased' OR item.publication_fence IS DISTINCT FROM p_fence
        OR item.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'stale publication fence' USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.fact_notification_publication_attempt
        (outbox_key, publication_fence, outcome, kafka_topic, kafka_partition, kafka_offset, error_code)
    VALUES (item.outbox_key, p_fence, p_outcome, p_topic, p_partition, p_offset, p_error_code);
    UPDATE guild.notification_outbox SET
        publication_state = CASE WHEN p_outcome = 'published' THEN 'published' ELSE 'pending' END,
        publication_fence = NULL, lease_expires_at = NULL, worker_key = NULL
    WHERE operation_key = p_operation;
END;
$$;
CREATE FUNCTION guild.record_notification_consumption(p_operation uuid, p_group text,
    p_topic text, p_partition integer, p_offset bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE receipt uuid; receipt_operation uuid; first_receipt boolean;
BEGIN
    -- Serialize first-receipt selection with dispatch and competing Kafka
    -- deliveries. Keep every distinct coordinate, including logical replays.
    PERFORM FROM guild.notification_operation WHERE operation_key = p_operation FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'notification operation does not exist' USING ERRCODE = '23503'; END IF;
    first_receipt := NOT EXISTS (SELECT FROM guild.notification_kafka_receipt
        WHERE consumer_group = p_group AND operation_key = p_operation AND is_first_for_operation);
    INSERT INTO guild.notification_kafka_receipt
        (operation_key, consumer_group, kafka_topic, kafka_partition, kafka_offset, is_first_for_operation)
    VALUES (p_operation, p_group, p_topic, p_partition, p_offset, first_receipt)
    ON CONFLICT (consumer_group, kafka_topic, kafka_partition, kafka_offset) DO NOTHING
    RETURNING receipt_key INTO receipt;
    IF receipt IS NULL THEN
        SELECT receipt_key, operation_key INTO STRICT receipt, receipt_operation
        FROM guild.notification_kafka_receipt WHERE consumer_group = p_group AND kafka_topic = p_topic
            AND kafka_partition = p_partition AND kafka_offset = p_offset;
        IF receipt_operation <> p_operation THEN
            RAISE EXCEPTION 'Kafka coordinate conflicts with operation identity' USING ERRCODE = '23514';
        END IF;
        RETURN false;
    END IF;
    RETURN first_receipt;
END;
$$;

CREATE FUNCTION guild._notification_war_active(p_war bigint, p_clan bigint) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
    SELECT EXISTS (SELECT FROM guild.dim_war w WHERE w.war_key = p_war
        AND p_clan IN (w.clan_a_key, w.clan_b_key)
        AND w.started_at <= statement_timestamp() AND w.ends_at > statement_timestamp()
        AND coalesce((SELECT o.state <> 'warEnded' FROM guild.fact_war_clan_observation o
            WHERE o.war_key = p_war AND o.clan_key = p_clan ORDER BY observed_at DESC LIMIT 1), true))
$$;

CREATE FUNCTION guild._close_notification_dispatch(p_dispatch uuid, p_outcome text,
    p_message guild.discord_snowflake DEFAULT NULL, p_http integer DEFAULT NULL, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE auth guild.fact_notification_dispatch_authorization;
BEGIN
    SELECT * INTO STRICT auth FROM guild.fact_notification_dispatch_authorization WHERE dispatch_key = p_dispatch;
    UPDATE guild.fact_notification_dispatch_attempt
    SET outcome = p_outcome, discord_message_id = p_message, http_status = p_http,
        error_code = p_error, recorded_at = clock_timestamp(), finished_at = clock_timestamp()
    WHERE dispatch_key = p_dispatch;
END;
$$;

CREATE FUNCTION guild.claim_notification_dispatch(p_operation uuid, p_worker text,
    p_lease_seconds integer DEFAULT 30) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_operation; previous guild.fact_notification_dispatch_authorization;
    auth guild.fact_notification_dispatch_authorization; latest bigint;
    report guild.notification_report;
BEGIN
    IF p_lease_seconds IS NULL OR p_worker IS NULL OR p_lease_seconds NOT BETWEEN 1 AND 300
        OR p_worker !~ '^[A-Za-z0-9_.:-]{1,100}$' THEN
        RAISE EXCEPTION 'bounded dispatch lease and worker identity required' USING ERRCODE = '23514';
    END IF;
    -- Lock order for role work is member target, then operation. The desired
    -- state writer takes the same order; reversing it can deadlock a worker.
    -- Lock order for report work is report, then operation, in every function.
    SELECT * INTO STRICT item FROM guild.notification_operation WHERE operation_key = p_operation;
    IF item.operation_kind = 'role_reconcile' THEN
        PERFORM 1 FROM guild.notification_role_target
        WHERE user_key = item.target_user_key FOR UPDATE;
    END IF;
    IF item.report_key IS NOT NULL THEN
        SELECT * INTO STRICT report FROM guild.notification_report
        WHERE report_key = item.report_key FOR UPDATE;
    END IF;
    SELECT * INTO STRICT item FROM guild.notification_operation WHERE operation_key = p_operation FOR UPDATE;
    IF item.status IN ('expired', 'superseded')
        OR (item.status = 'delivered' AND item.operation_kind <> 'role_reconcile') THEN RETURN NULL; END IF;
    SELECT * INTO previous FROM guild.fact_notification_dispatch_authorization
    WHERE operation_key = p_operation ORDER BY attempt_number DESC LIMIT 1;
    IF FOUND AND item.operation_kind = 'ping' THEN
        IF item.status = 'in_flight' AND previous.lease_expires_at <= clock_timestamp() THEN
            IF NOT EXISTS (SELECT FROM guild.fact_notification_dispatch_outcome WHERE dispatch_key = previous.dispatch_key) THEN
                PERFORM guild._close_notification_dispatch(previous.dispatch_key, 'uncertain', NULL, NULL, 'lease_expired');
            END IF;
            UPDATE guild.notification_operation SET status = 'uncertain' WHERE operation_key = p_operation;
        END IF;
        RETURN NULL;
    END IF;
    IF item.expires_at <= clock_timestamp() OR (item.war_key IS NOT NULL
        AND NOT guild._notification_war_active(item.war_key, item.clan_key)) THEN
        UPDATE guild.notification_operation SET status = 'expired' WHERE operation_key = p_operation;
        RETURN NULL;
    END IF;
    IF item.operation_kind = 'role_reconcile' THEN
        IF EXISTS (SELECT FROM guild.discord_member_state
            WHERE user_key = item.target_user_key AND NOT is_present) THEN
            UPDATE guild.notification_operation SET status = 'superseded' WHERE operation_key = p_operation;
            RETURN NULL;
        END IF;
        SELECT generation INTO latest FROM guild.notification_role_target
        WHERE user_key = item.target_user_key FOR UPDATE;
        IF latest <> item.role_generation THEN
            UPDATE guild.notification_operation SET status = 'superseded' WHERE operation_key = p_operation;
            RETURN NULL;
        END IF;
    END IF;
    SELECT * INTO previous FROM guild.fact_notification_dispatch_authorization
    WHERE operation_key = p_operation ORDER BY attempt_number DESC LIMIT 1;
    IF FOUND THEN
        IF previous.lease_expires_at > clock_timestamp() AND item.status = 'in_flight' THEN RETURN NULL; END IF;
        IF NOT EXISTS (SELECT FROM guild.fact_notification_dispatch_outcome WHERE dispatch_key = previous.dispatch_key) THEN
            PERFORM guild._close_notification_dispatch(previous.dispatch_key, 'uncertain', NULL, NULL, 'lease_expired');
        END IF;
        IF item.operation_kind = 'ping' THEN
            UPDATE guild.notification_operation SET status = CASE WHEN status = 'failed' THEN 'failed' ELSE 'uncertain' END
            WHERE operation_key = p_operation;
            RETURN NULL;
        END IF;
    END IF;
    IF item.report_key IS NOT NULL THEN
        -- A report shows only its latest revision. An older revision is never
        -- sent after a newer one exists, so it cannot overwrite newer content.
        IF item.report_revision < report.latest_revision THEN
            UPDATE guild.notification_operation SET status = 'superseded' WHERE operation_key = p_operation;
            RETURN NULL;
        END IF;
        -- One revision of a report is sent at a time. A second create while the
        -- first is in flight would post a second message.
        IF EXISTS (SELECT FROM guild.notification_operation other
            JOIN guild.fact_notification_dispatch_authorization held ON held.fence = other.current_fence
            WHERE other.report_key = item.report_key AND other.operation_key <> p_operation
                AND other.status = 'in_flight' AND held.lease_expires_at > clock_timestamp()) THEN
            RETURN NULL;
        END IF;
    END IF;
    IF item.due_at > clock_timestamp() OR NOT EXISTS (SELECT FROM guild.notification_consumer_seen
        WHERE operation_key = p_operation) THEN RETURN NULL; END IF;
    INSERT INTO guild.fact_notification_dispatch_authorization
        (operation_key, attempt_number, is_ping, worker_key, lease_expires_at)
    VALUES (p_operation, coalesce(previous.attempt_number, 0) + 1,
        item.operation_kind = 'ping', p_worker, clock_timestamp() + make_interval(secs => p_lease_seconds))
    RETURNING * INTO auth;
    -- The action of a report revision is decided here, not when it was queued:
    -- create the message when none is known, otherwise edit the known message.
    UPDATE guild.notification_operation SET status = 'in_flight', current_fence = auth.fence,
        operation_kind = CASE WHEN report_key IS NULL THEN operation_kind
            WHEN report.discord_message_id IS NULL THEN 'report_create' ELSE 'report_edit' END
    WHERE operation_key = p_operation;
    RETURN auth.fence;
END;
$$;
COMMENT ON FUNCTION guild.claim_notification_dispatch IS
    'Worker interface: returns a fence when the operation may be sent now, otherwise NULL. Pings get '
    'one authorization. Role and report work may be claimed again after a failed, uncertain or expired '
    'attempt. For a report revision, read operation_kind after the claim: report_create posts a new '
    'message, report_edit edits notification_report.discord_message_id. An older revision of a report '
    'becomes superseded, and a revision waits while another revision of its report is in flight.';

CREATE FUNCTION guild.begin_notification_send(p_operation uuid, p_fence uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_operation; auth guild.fact_notification_dispatch_authorization;
    latest bigint; changed integer;
BEGIN
    SELECT * INTO STRICT item FROM guild.notification_operation WHERE operation_key = p_operation;
    IF item.operation_kind = 'role_reconcile' THEN
        PERFORM 1 FROM guild.notification_role_target
        WHERE user_key = item.target_user_key FOR UPDATE;
    END IF;
    SELECT * INTO STRICT item FROM guild.notification_operation WHERE operation_key = p_operation FOR UPDATE;
    IF item.status <> 'in_flight' OR item.current_fence IS DISTINCT FROM p_fence THEN RETURN false; END IF;
    SELECT * INTO STRICT auth FROM guild.fact_notification_dispatch_authorization WHERE fence = p_fence;
    IF auth.lease_expires_at <= clock_timestamp() OR item.expires_at <= clock_timestamp()
        OR (item.war_key IS NOT NULL AND NOT guild._notification_war_active(item.war_key, item.clan_key)) THEN RETURN false; END IF;
    IF EXISTS (SELECT FROM guild.notification_dispatch_state
        WHERE dispatch_key = auth.dispatch_key AND started_at IS NOT NULL) THEN RETURN false; END IF;
    IF item.operation_kind = 'role_reconcile' THEN
        IF EXISTS (SELECT FROM guild.discord_member_state
            WHERE user_key = item.target_user_key AND NOT is_present) THEN
            UPDATE guild.notification_operation SET status = 'superseded' WHERE operation_key = p_operation;
            RETURN false;
        END IF;
        SELECT generation INTO latest FROM guild.notification_role_target
        WHERE user_key = item.target_user_key;
        IF latest <> item.role_generation THEN RETURN false; END IF;
    END IF;
    UPDATE guild.notification_dispatch_state SET started_at = clock_timestamp()
    WHERE dispatch_key = auth.dispatch_key AND started_at IS NULL AND finished_at IS NULL;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed = 1 AND item.war_key IS NOT NULL THEN
        UPDATE guild.notification_operation SET remaining_seconds = greatest(0, floor(extract(epoch FROM
            (SELECT ends_at FROM guild.dim_war WHERE war_key = item.war_key) - clock_timestamp())))::integer
        WHERE operation_key = p_operation;
    END IF;
    RETURN changed = 1;
END;
$$;
COMMENT ON FUNCTION guild.begin_notification_send IS
    'One-use permit: Node must call Discord only when Java returns true, then disable all automatic '
    'ping resends. A permit is not evidence that the external request happened or succeeded.';

CREATE FUNCTION guild.record_notification_result(p_operation uuid, p_fence uuid, p_outcome text,
    p_message guild.discord_snowflake DEFAULT NULL, p_http integer DEFAULT NULL, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_operation; auth guild.fact_notification_dispatch_authorization;
BEGIN
    SELECT * INTO STRICT item FROM guild.notification_operation WHERE operation_key = p_operation;
    IF item.report_key IS NOT NULL THEN
        PERFORM 1 FROM guild.notification_report WHERE report_key = item.report_key FOR UPDATE;
    END IF;
    SELECT * INTO STRICT item FROM guild.notification_operation WHERE operation_key = p_operation FOR UPDATE;
    IF item.status <> 'in_flight' OR item.current_fence IS DISTINCT FROM p_fence THEN
        RAISE EXCEPTION 'stale dispatch fence or terminal operation' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT auth FROM guild.fact_notification_dispatch_authorization WHERE fence = p_fence;
    IF auth.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'dispatch lease expired' USING ERRCODE = '23514';
    END IF;
    IF p_outcome = 'succeeded' AND (p_http IS NULL OR p_http NOT BETWEEN 200 AND 299
        OR (item.channel_key IS NOT NULL AND p_message IS NULL)
        OR NOT EXISTS (SELECT FROM guild.notification_dispatch_state
            WHERE dispatch_key = auth.dispatch_key AND started_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'delivery success requires send authorization and an explicit Discord API acknowledgment'
            USING ERRCODE = '23514';
    END IF;
    PERFORM guild._close_notification_dispatch(auth.dispatch_key, p_outcome, p_message, p_http, p_error);
    -- A delivered report revision confirms the message of its report in the
    -- same transaction: a create records it, an edit must return the known one.
    IF p_outcome = 'succeeded' AND item.report_key IS NOT NULL THEN
        PERFORM guild.record_notification_report_message(item.report_key, p_message);
    END IF;
    UPDATE guild.notification_operation SET status = CASE WHEN p_outcome = 'succeeded' THEN 'delivered' ELSE p_outcome END
    WHERE operation_key = p_operation;
END;
$$;

CREATE FUNCTION guild.set_notification_desired_roles(p_user bigint,
    p_roles bigint[], p_source text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE current_generation bigint; desired bigint[]; previous bigint[]; new_generation bigint;
BEGIN
    IF p_source IS NULL OR p_source !~ '^[A-Za-z0-9_:./-]{1,200}$' OR p_roles IS NULL
        OR array_position(p_roles, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'role source and explicit role set required' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT FROM unnest(p_roles) r WHERE NOT EXISTS (SELECT FROM guild.dim_discord_role
        WHERE role_key = r AND deleted_at IS NULL)) THEN
        RAISE EXCEPTION 'desired roles must belong to this guild and exist' USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.notification_role_target (user_key) VALUES (p_user)
    ON CONFLICT (user_key) DO NOTHING;
    SELECT generation INTO current_generation FROM guild.notification_role_target
    WHERE user_key = p_user FOR UPDATE;
    DELETE FROM guild.notification_role_source_requirement
    WHERE user_key = p_user AND source_key = p_source;
    INSERT INTO guild.notification_role_source_requirement (user_key, source_key, role_key)
    SELECT p_user, p_source, r FROM (SELECT DISTINCT unnest(p_roles) r) roles;
    INSERT INTO guild.notification_managed_role (user_key, role_key)
    SELECT p_user, r FROM (SELECT DISTINCT unnest(p_roles) r) roles
    ON CONFLICT DO NOTHING;
    SELECT coalesce(array_agg(DISTINCT role_key ORDER BY role_key), ARRAY[]::bigint[]) INTO desired
    FROM guild.notification_role_source_requirement WHERE user_key = p_user;
    SELECT coalesce(array_agg(role_key ORDER BY role_key) FILTER (WHERE is_desired), ARRAY[]::bigint[]) INTO previous
    FROM guild.notification_role_generation_requirement
    WHERE user_key = p_user AND generation = current_generation;
    -- An unchanged role set reuses its generation only while the operation of
    -- that generation can still apply it. An operation that was superseded
    -- because the member was absent, or delivered before the member's latest
    -- join, never applies the roles to the returned member, so the same role
    -- set gets a new generation and a new operation.
    IF current_generation > 0 AND desired = previous AND EXISTS (
        SELECT FROM guild.notification_operation o
        WHERE o.target_user_key = p_user
            AND o.operation_kind = 'role_reconcile' AND o.role_generation = current_generation
            AND o.status NOT IN ('superseded', 'expired')
            AND NOT (o.status = 'delivered' AND coalesce(
                (SELECT max(a.finished_at) FROM guild.fact_notification_dispatch_attempt a
                    WHERE a.operation_key = o.operation_key AND a.outcome = 'succeeded')
                < (SELECT m.last_event_at FROM guild.discord_member_state m
                    WHERE m.user_key = p_user AND m.is_present), false))
    ) THEN RETURN current_generation; END IF;
    new_generation := current_generation + 1;
    INSERT INTO guild.notification_role_generation VALUES (p_user, new_generation, clock_timestamp());
    INSERT INTO guild.notification_role_generation_requirement
        (user_key, generation, role_key, is_desired)
    SELECT p_user, new_generation, role_key, role_key = ANY (desired)
    FROM guild.notification_managed_role WHERE user_key = p_user;
    UPDATE guild.notification_role_target SET generation = new_generation
    WHERE user_key = p_user;
    UPDATE guild.notification_operation SET status = 'superseded'
    WHERE target_user_key = p_user AND operation_kind = 'role_reconcile'
        AND status IN ('pending', 'in_flight', 'failed', 'uncertain');
    PERFORM guild._enqueue_notification('role:' || p_user || ':' || new_generation,
        'role_reconcile', 'role_reconcile', NULL, 'members', clock_timestamp(), NULL,
        NULL, NULL, NULL, p_user, new_generation);
    RETURN new_generation;
END;
$$;

CREATE FUNCTION guild.schedule_war_reminders(p_war bigint, p_clan bigint) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE war guild.dim_war; destination bigint; offset_row record; created integer := 0;
BEGIN
    SELECT * INTO STRICT war FROM guild.dim_war WHERE war_key = p_war FOR UPDATE;
    IF p_clan NOT IN (war.clan_a_key, war.clan_b_key) OR NOT EXISTS (
        SELECT FROM guild.clan_collection_settings WHERE clan_key = p_clan AND enabled) THEN
        RAISE EXCEPTION 'reminders require a tracked war clan' USING ERRCODE = '23514';
    END IF;
    SELECT channel_key INTO STRICT destination FROM guild.channel_binding
    WHERE purpose = 'war' AND clan_key = p_clan;
    FOR offset_row IN SELECT seconds_before_end FROM guild.war_reminder_setting
        WHERE clan_key = p_clan LOOP
        PERFORM guild._enqueue_notification(
            'war:' || p_war || ':clan:' || p_clan || ':offset:' || offset_row.seconds_before_end,
            'ping', 'war_reminder', destination, 'members',
            war.ends_at - make_interval(secs => offset_row.seconds_before_end), war.ends_at,
            p_war, p_clan, offset_row.seconds_before_end);
        created := created + 1;
    END LOOP;
    RETURN created;
END;
$$;

CREATE FUNCTION guild.coalesce_missed_war_reminders(p_war bigint, p_clan bigint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE source guild.notification_operation; catchup guild.notification_operation; result uuid;
    war guild.dim_war; current_time_at timestamptz := clock_timestamp();
BEGIN
    SELECT * INTO STRICT war FROM guild.dim_war WHERE war_key = p_war FOR UPDATE;
    IF NOT guild._notification_war_active(p_war, p_clan) THEN
        UPDATE guild.notification_operation SET status = 'expired'
        WHERE war_key = p_war AND clan_key = p_clan AND status = 'pending';
        RETURN NULL;
    END IF;
    SELECT * INTO catchup FROM guild.notification_operation
    WHERE war_key = p_war AND clan_key = p_clan AND notification_kind = 'war_catchup';
    IF FOUND AND (catchup.status <> 'pending' OR EXISTS (
        SELECT FROM guild.fact_notification_dispatch_authorization WHERE operation_key = catchup.operation_key)) THEN
        RETURN NULL;
    END IF;
    FOR source IN SELECT * FROM guild.notification_operation n
        WHERE n.war_key = p_war AND n.clan_key = p_clan
            AND n.notification_kind = 'war_reminder' AND n.status = 'pending' AND n.due_at < current_time_at
            AND NOT EXISTS (SELECT FROM guild.fact_notification_dispatch_authorization a WHERE a.operation_key = n.operation_key)
        ORDER BY n.due_at FOR UPDATE LOOP
        IF result IS NULL THEN
            IF catchup.operation_key IS NOT NULL THEN result := catchup.operation_key;
            ELSE
                result := guild._enqueue_notification('war:' || p_war || ':clan:' || p_clan || ':catchup',
                    'ping', 'war_catchup', source.channel_key, source.audience,
                    current_time_at, war.ends_at, p_war, p_clan);
            END IF;
        END IF;
        INSERT INTO guild.notification_catchup_input VALUES (result, source.operation_key)
        ON CONFLICT DO NOTHING;
        UPDATE guild.notification_operation SET status = 'superseded' WHERE operation_key = source.operation_key;
    END LOOP;
    IF result IS NOT NULL THEN
        UPDATE guild.notification_operation SET remaining_seconds = floor(extract(epoch FROM war.ends_at - current_time_at))::integer
        WHERE operation_key = result;
    END IF;
    RETURN coalesce(result, catchup.operation_key);
END;
$$;
COMMENT ON FUNCTION guild.coalesce_missed_war_reminders IS
    'Recovery phase: call before resuming dispatch. SQL cannot infer downtime from lateness alone. '
    'Only never-authorized missed checkpoints can be absorbed; one catch-up identity per clan/war.';

CREATE FUNCTION guild.register_notification_report(p_logical text,
    p_kind text, p_channel bigint, p_audience text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_report; result uuid;
BEGIN
    INSERT INTO guild.notification_report (logical_report_key, report_kind, channel_key, audience)
    VALUES (p_logical, p_kind, p_channel, p_audience)
    ON CONFLICT (logical_report_key) DO NOTHING RETURNING report_key INTO result;
    IF result IS NOT NULL THEN RETURN result; END IF;
    SELECT * INTO STRICT item FROM guild.notification_report WHERE logical_report_key = p_logical;
    IF (item.report_kind, item.channel_key, item.audience) IS DISTINCT FROM (p_kind, p_channel, p_audience) THEN
        RAISE EXCEPTION 'report identity conflicts with its destination or audience' USING ERRCODE = '23514';
    END IF;
    RETURN item.report_key;
END;
$$;
CREATE FUNCTION guild.record_notification_report_message(p_report uuid, p_message guild.discord_snowflake)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_report;
BEGIN
    SELECT * INTO STRICT item FROM guild.notification_report WHERE report_key = p_report FOR UPDATE;
    IF p_message IS NULL THEN
        RAISE EXCEPTION 'report message identity required' USING ERRCODE = '23514';
    END IF;
    IF item.discord_message_id IS NOT NULL AND item.discord_message_id <> p_message THEN
        RAISE EXCEPTION 'a report keeps one Discord message and every revision edits it in place'
            USING ERRCODE = '23514';
    END IF;
    IF item.discord_message_id IS NULL THEN
        UPDATE guild.notification_report SET discord_message_id = p_message,
            message_confirmed_at = clock_timestamp() WHERE report_key = p_report;
    END IF;
END;
$$;
COMMENT ON FUNCTION guild.record_notification_report_message IS
    'Worker interface: confirms the one Discord message of a report. record_notification_result calls '
    'it for a delivered revision. Call it directly only to adopt a message found after an uncertain '
    'create. The first message is kept; the same message is accepted again; another one is rejected.';

CREATE FUNCTION guild.record_notification_report_missing(p_operation uuid, p_fence uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_operation; auth guild.fact_notification_dispatch_authorization;
BEGIN
    SELECT * INTO STRICT item FROM guild.notification_operation WHERE operation_key = p_operation;
    IF item.report_key IS NOT NULL THEN
        PERFORM 1 FROM guild.notification_report WHERE report_key = item.report_key FOR UPDATE;
    END IF;
    SELECT * INTO STRICT item FROM guild.notification_operation WHERE operation_key = p_operation FOR UPDATE;
    IF item.status <> 'in_flight' OR item.current_fence IS DISTINCT FROM p_fence THEN
        RAISE EXCEPTION 'stale dispatch fence or terminal operation' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO STRICT auth FROM guild.fact_notification_dispatch_authorization WHERE fence = p_fence;
    IF auth.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'dispatch lease expired' USING ERRCODE = '23514';
    END IF;
    IF item.operation_kind <> 'report_edit' OR NOT EXISTS (SELECT FROM guild.notification_dispatch_state
        WHERE dispatch_key = auth.dispatch_key AND started_at IS NOT NULL) THEN
        RAISE EXCEPTION 'only an authorized report edit can find its message missing' USING ERRCODE = '23514';
    END IF;
    PERFORM guild._close_notification_dispatch(auth.dispatch_key, 'failed', NULL, 404, 'report_message_missing');
    UPDATE guild.notification_report SET discord_message_id = NULL, message_confirmed_at = NULL
    WHERE report_key = item.report_key;
    UPDATE guild.notification_operation SET status = 'failed' WHERE operation_key = p_operation;
END;
$$;
COMMENT ON FUNCTION guild.record_notification_report_missing IS
    'Worker interface: call when Discord answers a report edit with Unknown Message, because the '
    'message was deleted. The attempt fails and the report forgets its message, so the next claim of '
    'the same revision creates a new message.';

CREATE FUNCTION guild.queue_notification_report(p_report uuid, p_logical text, p_due timestamptz)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_report; existing guild.notification_operation; revision bigint;
BEGIN
    SELECT * INTO STRICT item FROM guild.notification_report WHERE report_key = p_report FOR UPDATE;
    SELECT * INTO existing FROM guild.notification_operation
    WHERE logical_key = p_logical;
    IF FOUND THEN
        IF existing.report_key IS DISTINCT FROM p_report OR existing.due_at IS DISTINCT FROM p_due THEN
            RAISE EXCEPTION 'logical notification identity conflicts with its immutable decision'
                USING ERRCODE = '23514';
        END IF;
        RETURN existing.operation_key;
    END IF;
    revision := item.latest_revision + 1;
    UPDATE guild.notification_report SET latest_revision = revision WHERE report_key = p_report;
    -- An older revision that is not being sent right now will never be sent.
    -- One in flight finishes first; its next claim supersedes it.
    UPDATE guild.notification_operation SET status = 'superseded'
    WHERE report_key = p_report AND status IN ('pending', 'failed', 'uncertain');
    RETURN guild._enqueue_notification(p_logical,
        CASE WHEN item.discord_message_id IS NULL THEN 'report_create' ELSE 'report_edit' END,
        item.report_kind, item.channel_key, item.audience, p_due, NULL,
        NULL, NULL, NULL, NULL, NULL, p_report, revision);
END;
$$;
COMMENT ON FUNCTION guild.queue_notification_report IS
    'Queues one revision of a report under its own logical key; the same key returns the same '
    'operation. A new revision supersedes the older revisions that are waiting, failed or uncertain.';

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
CREATE TABLE guild.notification_cwl_context (
    operation_key uuid PRIMARY KEY REFERENCES guild.notification_operation,
    cycle_key bigint NOT NULL,
    participation_key bigint,
    plan_key bigint,
    war_day smallint CHECK (war_day BETWEEN 1 AND 7),
    FOREIGN KEY (cycle_key) REFERENCES guild.cwl_cycle (cycle_key),
    FOREIGN KEY (participation_key, cycle_key)
        REFERENCES guild.cwl_participating_clan (participation_key, cycle_key),
    FOREIGN KEY (plan_key, participation_key)
        REFERENCES guild.cwl_plan_revision (plan_key, participation_key),
    CHECK ((participation_key IS NULL AND plan_key IS NULL AND war_day IS NULL)
        OR (participation_key IS NOT NULL AND plan_key IS NOT NULL AND war_day IS NOT NULL))
);
CREATE UNIQUE INDEX notification_cwl_prompt ON guild.notification_cwl_context(cycle_key)
WHERE plan_key IS NULL;
CREATE UNIQUE INDEX notification_cwl_plan_day ON guild.notification_cwl_context(plan_key,war_day)
WHERE plan_key IS NOT NULL;
CREATE FUNCTION guild.validate_notification_cwl_context() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE item guild.notification_operation;
BEGIN
    SELECT * INTO STRICT item FROM guild.notification_operation WHERE operation_key = NEW.operation_key;
    IF (NEW.plan_key IS NULL AND
            (item.notification_kind <> 'cwl_leadership' OR item.audience <> 'leadership'))
        OR (NEW.plan_key IS NOT NULL AND
            (item.notification_kind <> 'cwl_roster' OR item.audience <> 'members')) THEN
        RAISE EXCEPTION 'CWL context must match the operation type and audience' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER notification_cwl_context_scope BEFORE INSERT ON guild.notification_cwl_context
FOR EACH ROW EXECUTE FUNCTION guild.validate_notification_cwl_context();
CREATE TRIGGER notification_cwl_context_history BEFORE UPDATE OR DELETE ON guild.notification_cwl_context
FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation();

CREATE FUNCTION guild.queue_cwl_leadership_prompt(p_cycle bigint,
    p_due timestamptz DEFAULT NULL, p_expires timestamptz DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE cycle guild.cwl_cycle; destination bigint; result uuid;
BEGIN
    SELECT * INTO STRICT cycle FROM guild.cwl_cycle WHERE cycle_key = p_cycle;
    SELECT channel_key INTO destination FROM guild.channel_binding
    WHERE purpose = 'leadership_notifications';
    IF destination IS NULL THEN
        RAISE EXCEPTION 'Configure the leadership notification channel first' USING ERRCODE = '23514';
    END IF;
    result := guild._enqueue_notification('cwl:leadership:'||p_cycle,
        'ping','cwl_leadership',destination,'leadership',
        coalesce(p_due,cycle.signup_closes_at-interval '168 hours'),
        coalesce(p_expires,cycle.signup_closes_at));
    INSERT INTO guild.notification_cwl_context(operation_key,cycle_key)
        VALUES(result,p_cycle) ON CONFLICT(operation_key) DO NOTHING;
    RETURN result;
END;
$$;
COMMENT ON FUNCTION guild.queue_cwl_leadership_prompt IS
    'Worker interface: the initial prompt defaults to seven days before the GMT '
    'planning-cycle boundary. Explicit schedule instants may be supplied from configuration.';

CREATE FUNCTION guild.queue_cwl_roster_report(p_plan bigint,p_day smallint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE plan guild.cwl_plan_revision; participation guild.cwl_participating_clan;
    destination bigint; report uuid; result uuid;
BEGIN
    SELECT * INTO STRICT plan FROM guild.cwl_plan_revision WHERE plan_key = p_plan;
    -- All plans of one participation and War Day share one report, so they
    -- are queued one at a time.
    PERFORM pg_advisory_xact_lock(hashtext('cwl-roster-output'),
        hashtext(plan.participation_key::text || ':' || p_day::text));
    SELECT operation_key INTO result FROM guild.notification_cwl_context
        WHERE plan_key = p_plan AND war_day = p_day;
    IF result IS NOT NULL THEN RETURN result; END IF;
    SELECT * INTO STRICT participation FROM guild.cwl_participating_clan
        WHERE participation_key = plan.participation_key;
    IF plan.published_at IS NULL OR NOT EXISTS(SELECT FROM guild.cwl_plan_day
        WHERE plan_key=p_plan AND war_day=p_day) THEN
        RAISE EXCEPTION 'Output requires a published plan and its War Day' USING ERRCODE = '23514';
    END IF;
    SELECT channel_key INTO destination FROM guild.channel_binding
        WHERE clan_key=participation.clan_key
            AND purpose='cwl_roster' AND war_day=p_day;
    IF destination IS NULL THEN
        RAISE EXCEPTION 'Configure this clan and War Day roster channel first' USING ERRCODE = '23514';
    END IF;
    -- Report revisions are numbered in the order they are queued. A plan that
    -- is older than one already queued for this day must not become the
    -- latest revision, or it would replace the newer roster.
    IF EXISTS (SELECT FROM guild.notification_cwl_context queued
        JOIN guild.cwl_plan_revision newer USING (plan_key)
        WHERE queued.participation_key = plan.participation_key AND queued.war_day = p_day
            AND newer.revision > plan.revision) THEN
        RETURN NULL;
    END IF;
    report := guild.register_notification_report(
        'cwl:roster:'||participation.participation_key||':'||p_day,
        'cwl_roster',destination,'members');
    result := guild.queue_notification_report(report,'cwl:plan:'||p_plan||':'||p_day,
        plan.created_at);
    INSERT INTO guild.notification_cwl_context(operation_key,cycle_key,
        participation_key,plan_key,war_day)
        VALUES(result,participation.cycle_key,
            participation.participation_key,p_plan,p_day);
    RETURN result;
END;
$$;
COMMENT ON FUNCTION guild.queue_cwl_roster_report IS
    'Worker interface: queues the roster of one published plan and War Day as a revision of the '
    'report for that clan and day. The same plan and day return the same operation. Returns NULL '
    'and queues nothing when a newer plan revision is already queued for that day.';
