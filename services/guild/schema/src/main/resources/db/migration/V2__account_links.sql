-- Game observations do not depend on a Discord link. These intervals describe
-- actual links; attribution episodes separately preserve metric continuity.
CREATE TABLE guild.player_verification (
    verification_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    status text NOT NULL CHECK (status IN ('verified', 'rejected', 'error')),
    checked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_request_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    source_fetch_key bigint REFERENCES guild.fact_api_fetch_attempt,
    UNIQUE (verification_key, user_key, player_key, status)
);
CREATE INDEX player_verification_member_account
    ON guild.player_verification (user_key, player_key, checked_at DESC);
COMMENT ON TABLE guild.player_verification IS
    'Trusted backend verification outcome only. Never retain the supplied or echoed API token.';

-- A successful verification proves control of the account at one moment. It
-- may start a link or a transfer request only for a limited time afterwards.
ALTER TABLE guild.guild_settings
    ADD COLUMN verification_max_age_seconds integer NOT NULL DEFAULT 900
        CHECK (verification_max_age_seconds > 0);
CREATE FUNCTION guild.require_recent_verification(
    p_verification_key bigint, p_used_at timestamptz
) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    v_limit integer;
    v_checked_at timestamptz;
BEGIN
    SELECT verification_max_age_seconds INTO v_limit
    FROM guild.guild_settings;
    SELECT checked_at INTO STRICT v_checked_at
    FROM guild.player_verification WHERE verification_key = p_verification_key;
    IF v_checked_at <= p_used_at - make_interval(secs => coalesce(v_limit, 900)) THEN
        RAISE EXCEPTION 'The account verification is older than the configured limit; verify the account again'
            USING ERRCODE = '23514';
    END IF;
END;
$$;
COMMENT ON FUNCTION guild.require_recent_verification IS
    'Age gate for a verification at the moment it starts a link or a transfer request. '
    'An approved transfer is completed later with the verification its request recorded, '
    'so no verification age is checked again at that point; the transfer limits apply instead.';

CREATE TABLE guild.metric_attribution_episode (
    attribution_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    first_link_at timestamptz NOT NULL,
    closed_at timestamptz,
    include_prelink_history boolean NOT NULL DEFAULT false,
    UNIQUE (attribution_key, user_key, player_key),
    CHECK (closed_at IS NULL OR closed_at > first_link_at),
    EXCLUDE USING gist (
        player_key WITH =, tstzrange(first_link_at, closed_at, '[)') WITH &&
    )
);
CREATE UNIQUE INDEX metric_attribution_one_open_episode
ON guild.metric_attribution_episode (player_key) WHERE closed_at IS NULL;
CREATE UNIQUE INDEX metric_attribution_first_link_backfill
ON guild.metric_attribution_episode (player_key) WHERE include_prelink_history;
COMMENT ON TABLE guild.metric_attribution_episode IS
    'Continuity boundary, not a claim of ownership during unlinked gaps. First-ever link permits '
    'historical backfill; same-member relinks reuse an episode; a different member starts fresh. '
    'Explicit evidence and assessment versions still govern event-level attribution.';

CREATE TABLE guild.account_link (
    link_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    verification_key bigint NOT NULL UNIQUE,
    verification_status text GENERATED ALWAYS AS ('verified'::text) STORED,
    attribution_key bigint NOT NULL,
    linked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    unlinked_at timestamptz,
    is_primary boolean NOT NULL DEFAULT false,
    transfer_boundary_read_key bigint,
    UNIQUE (link_key, user_key, player_key),
    FOREIGN KEY (verification_key, user_key, player_key, verification_status)
        REFERENCES guild.player_verification (verification_key, user_key, player_key, status),
    FOREIGN KEY (attribution_key, user_key, player_key)
        REFERENCES guild.metric_attribution_episode (attribution_key, user_key, player_key),
    CHECK (unlinked_at IS NULL OR unlinked_at > linked_at),
    EXCLUDE USING gist (
        player_key WITH =, tstzrange(linked_at, unlinked_at, '[)') WITH &&
    )
);
CREATE UNIQUE INDEX account_link_one_current_owner
ON guild.account_link (player_key) WHERE unlinked_at IS NULL;
CREATE UNIQUE INDEX account_link_one_current_primary
ON guild.account_link (user_key) WHERE unlinked_at IS NULL AND is_primary;
CREATE INDEX account_link_member_history
ON guild.account_link (user_key, linked_at DESC);

CREATE TABLE guild.account_transfer_request (
    transfer_request_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    from_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    to_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    source_link_key bigint NOT NULL,
    verification_key bigint NOT NULL,
    verification_status text GENERATED ALWAYS AS ('verified'::text) STORED,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'awaiting_points', 'rejected', 'consumed',
            'cancelled', 'expired')),
    decided_by bigint REFERENCES guild.dim_discord_user,
    decided_at timestamptz,
    consumed_at timestamptz,
    cancelled_at timestamptz,
    expired_at timestamptz,
    FOREIGN KEY (source_link_key, from_user_key, player_key)
        REFERENCES guild.account_link (link_key, user_key, player_key),
    FOREIGN KEY (verification_key, to_user_key, player_key, verification_status)
        REFERENCES guild.player_verification (verification_key, user_key, player_key, status),
    UNIQUE (transfer_request_key, to_user_key, player_key),
    CHECK (from_user_key <> to_user_key),
    CHECK (
        (status = 'pending' AND decided_by IS NULL AND decided_at IS NULL
            AND consumed_at IS NULL AND cancelled_at IS NULL)
        OR (status IN ('approved', 'awaiting_points', 'rejected') AND decided_by IS NOT NULL
            AND decided_at IS NOT NULL AND decided_at >= requested_at
            AND consumed_at IS NULL AND cancelled_at IS NULL)
        OR (status = 'consumed' AND decided_by IS NOT NULL AND decided_at IS NOT NULL
            AND consumed_at IS NOT NULL AND decided_at >= requested_at
            AND consumed_at >= decided_at AND cancelled_at IS NULL)
        OR (status = 'cancelled' AND cancelled_at IS NOT NULL AND consumed_at IS NULL
            AND (decided_by IS NULL) = (decided_at IS NULL))
        OR (status = 'expired' AND consumed_at IS NULL AND cancelled_at IS NULL
            AND (decided_by IS NULL) = (decided_at IS NULL))
    ),
    CHECK ((status = 'expired') = (expired_at IS NOT NULL)),
    CHECK (expired_at IS NULL OR expired_at >= requested_at)
);
COMMENT ON COLUMN guild.account_transfer_request.cancelled_at IS
    'Set when the source link ended before this request was consumed. A cancelled request '
    'keeps any earlier decision as history and can never be decided or consumed.';
COMMENT ON COLUMN guild.account_transfer_request.expired_at IS
    'The moment the request passed its configured limit without a decision, or its approval '
    'passed its limit without being used. An expired request keeps any earlier decision as '
    'history and can never be decided or consumed; the recipient must request the transfer again.';
-- The scheduler looks for open requests.
CREATE INDEX account_transfer_open ON guild.account_transfer_request (requested_at)
    WHERE status IN ('pending', 'approved', 'awaiting_points');

-- An open request ends on a clock. A request that staff did not decide lapses
-- after the pending limit, and an approval the recipient did not use lapses
-- after the approval limit. Both limits are guild settings.
ALTER TABLE guild.guild_settings
    ADD COLUMN transfer_pending_max_age_seconds integer NOT NULL DEFAULT 172800
        CHECK (transfer_pending_max_age_seconds > 0),
    ADD COLUMN transfer_approval_max_age_seconds integer NOT NULL DEFAULT 86400
        CHECK (transfer_approval_max_age_seconds > 0);
CREATE FUNCTION guild.account_transfer_expires_at(p_transfer_request_key bigint)
RETURNS timestamptz LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    v_request guild.account_transfer_request%ROWTYPE;
    v_pending interval;
    v_approval interval;
BEGIN
    SELECT * INTO v_request FROM guild.account_transfer_request
    WHERE transfer_request_key = p_transfer_request_key;
    IF NOT FOUND THEN RETURN NULL; END IF;
    SELECT make_interval(secs => transfer_pending_max_age_seconds),
        make_interval(secs => transfer_approval_max_age_seconds)
    INTO v_pending, v_approval
    FROM guild.guild_settings;
    v_pending := coalesce(v_pending, interval '2 days');
    v_approval := coalesce(v_approval, interval '1 day');
    RETURN CASE v_request.status
        WHEN 'pending' THEN v_request.requested_at + v_pending
        WHEN 'approved' THEN v_request.decided_at + v_approval
        -- The recipient has done their part and the request waits for a Clan
        -- Games boundary read. The limit does not run while that read is
        -- pending, and it restarts when the read arrives.
        WHEN 'awaiting_points' THEN greatest(v_request.decided_at,
            guild.clan_games_transfer_wait_until(p_transfer_request_key)) + v_approval
        END;
END;
$$;
COMMENT ON FUNCTION guild.account_transfer_expires_at IS
    'The moment an open transfer request lapses: the pending limit after it was requested, or '
    'the approval limit after it was approved. infinity while an approved request waits for a '
    'pending Clan Games boundary read. NULL for a request that is no longer open.';

CREATE FUNCTION guild._expire_account_transfers(
    p_as_of timestamptz, p_source_link_key bigint DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE v_expired integer;
BEGIN
    UPDATE guild.account_transfer_request t
    SET status = 'expired',
        expired_at = guild.account_transfer_expires_at(t.transfer_request_key)
    WHERE t.status IN ('pending', 'approved', 'awaiting_points')
        AND (p_source_link_key IS NULL OR t.source_link_key = p_source_link_key)
        AND guild.account_transfer_expires_at(t.transfer_request_key) <= p_as_of;
    GET DIAGNOSTICS v_expired = ROW_COUNT;
    RETURN v_expired;
END;
$$;
CREATE FUNCTION guild.expire_account_transfers(
    p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF p_as_of IS NULL OR p_as_of > clock_timestamp() THEN
        RAISE EXCEPTION 'A transfer request cannot be declared expired in the future'
            USING ERRCODE = '22023';
    END IF;
    RETURN guild._expire_account_transfers(p_as_of);
END;
$$;
COMMENT ON FUNCTION guild.expire_account_transfers IS
    'Trusted scheduler: mark open transfer requests that passed their limit as expired. The '
    'decide and link commands apply the same limit themselves, so a request that the scheduler '
    'has not reached yet still cannot be used. Idempotent.';

-- A request is bound to one source link. When that link ends, by unlink or by
-- another recipient's completed transfer, every other open request for it can
-- no longer be decided or consumed. Close them instead of leaving them open.
CREATE FUNCTION guild.cancel_open_account_transfers(
    p_source_link_key bigint, p_cancelled_at timestamptz, p_except_request_key bigint DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE v_cancelled integer;
BEGIN
    UPDATE guild.account_transfer_request
    SET status = 'cancelled', cancelled_at = p_cancelled_at
    WHERE source_link_key = p_source_link_key
        AND status IN ('pending', 'approved', 'awaiting_points')
        AND transfer_request_key IS DISTINCT FROM p_except_request_key;
    GET DIAGNOSTICS v_cancelled = ROW_COUNT;
    RETURN v_cancelled;
END;
$$;
ALTER TABLE guild.account_link ADD COLUMN transfer_request_key bigint;
ALTER TABLE guild.account_link ADD CONSTRAINT account_link_transfer_request
FOREIGN KEY (transfer_request_key, user_key, player_key)
REFERENCES guild.account_transfer_request (transfer_request_key, to_user_key, player_key);
CREATE UNIQUE INDEX account_link_transfer_used_once
ON guild.account_link (transfer_request_key) WHERE transfer_request_key IS NOT NULL;
CREATE UNIQUE INDEX account_transfer_one_pending_recipient
ON guild.account_transfer_request (source_link_key, to_user_key) WHERE status = 'pending';

-- A first link, primary replacement, and old-primary demotion are one
-- transaction. The deferred check also protects callers using SQL directly.
CREATE FUNCTION guild.require_one_primary_account() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    v_owner record;
    v_active bigint;
    v_primary bigint;
BEGIN
    FOR v_owner IN
        SELECT DISTINCT owner.user_key
        FROM (
            SELECT NEW.user_key WHERE TG_OP <> 'DELETE'
            UNION ALL
            SELECT OLD.user_key WHERE TG_OP <> 'INSERT'
        ) AS owner
    LOOP
        SELECT count(*), count(*) FILTER (WHERE is_primary)
        INTO v_active, v_primary
        FROM guild.account_link
        WHERE user_key = v_owner.user_key AND unlinked_at IS NULL;
        IF v_active > 0 AND v_primary <> 1 THEN
            RAISE EXCEPTION 'A member with linked accounts must have exactly one primary'
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER account_link_primary_consistency
AFTER INSERT OR UPDATE OR DELETE ON guild.account_link
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
EXECUTE FUNCTION guild.require_one_primary_account();

CREATE FUNCTION guild.request_account_transfer(
    p_to_user_key bigint, p_player_key bigint,
    p_verification_key bigint, p_requested_at timestamptz DEFAULT clock_timestamp()
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    v_source guild.account_link%ROWTYPE;
    v_request_key bigint;
BEGIN
    PERFORM FROM guild.dim_player_account WHERE player_key = p_player_key FOR UPDATE;
    SELECT * INTO v_source FROM guild.account_link
    WHERE player_key = p_player_key AND unlinked_at IS NULL;
    IF NOT FOUND OR v_source.user_key = p_to_user_key THEN
        RAISE EXCEPTION 'Transfer requires an account currently linked to another member'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT FROM guild.player_verification
        WHERE verification_key = p_verification_key
            AND user_key = p_to_user_key AND player_key = p_player_key
            AND status = 'verified' AND checked_at <= p_requested_at
    ) THEN
        RAISE EXCEPTION 'A matching successful account verification is required'
            USING ERRCODE = '23514';
    END IF;
    PERFORM guild.require_recent_verification(p_verification_key, p_requested_at);
    -- A lapsed request for this link must not block the recipient from asking again.
    PERFORM guild._expire_account_transfers(p_requested_at, v_source.link_key);
    INSERT INTO guild.account_transfer_request (
        player_key, from_user_key, to_user_key, source_link_key,
        verification_key, requested_at
    ) VALUES (
        p_player_key, v_source.user_key, p_to_user_key,
        v_source.link_key, p_verification_key, p_requested_at
    ) RETURNING transfer_request_key INTO v_request_key;
    RETURN v_request_key;
END;
$$;

CREATE FUNCTION guild.decide_account_transfer(
    p_transfer_request_key bigint, p_actor_user_key bigint, p_approve boolean,
    p_decided_at timestamptz DEFAULT clock_timestamp()
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    v_request guild.account_transfer_request%ROWTYPE;
BEGIN
    IF p_approve IS NULL THEN
        RAISE EXCEPTION 'A transfer decision is required' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_request FROM guild.account_transfer_request
    WHERE transfer_request_key = p_transfer_request_key FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transfer request not found' USING ERRCODE = '22023';
    END IF;
    IF NOT guild.can_manage_links(p_actor_user_key) THEN
        RAISE EXCEPTION 'Co-leader or Admin role is required to decide an account transfer'
            USING ERRCODE = '42501';
    END IF;
    IF v_request.status = 'expired' OR (v_request.status = 'pending'
        AND guild.account_transfer_expires_at(p_transfer_request_key) <= p_decided_at) THEN
        RAISE EXCEPTION 'Transfer request has expired; the recipient must request the transfer again'
            USING ERRCODE = '23514';
    END IF;
    IF v_request.status <> 'pending' THEN
        RAISE EXCEPTION 'Transfer request has already been decided' USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT FROM guild.account_link WHERE link_key = v_request.source_link_key
            AND unlinked_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Transfer request no longer matches the current link'
            USING ERRCODE = '23514';
    END IF;
    UPDATE guild.account_transfer_request
    SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
        decided_by = p_actor_user_key, decided_at = p_decided_at
    WHERE transfer_request_key = p_transfer_request_key;
END;
$$;

CREATE FUNCTION guild.link_player_account(
    p_user_key bigint, p_player_key bigint,
    p_verification_key bigint, p_make_primary boolean DEFAULT false,
    p_transfer_request_key bigint DEFAULT NULL,
    p_linked_at timestamptz DEFAULT clock_timestamp()
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    v_existing guild.account_link%ROWTYPE;
    v_episode guild.metric_attribution_episode%ROWTYPE;
    v_request guild.account_transfer_request%ROWTYPE;
    v_user bigint;
    v_link_key bigint;
    v_attribution_key bigint;
    v_has_accounts boolean;
    v_boundary_read bigint;
BEGIN
    PERFORM FROM guild.dim_player_account WHERE player_key = p_player_key FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Player account not found' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_existing FROM guild.account_link
    WHERE player_key = p_player_key AND unlinked_at IS NULL;
    IF v_existing.link_key IS NOT NULL AND v_existing.user_key = p_user_key THEN
        RETURN v_existing.link_key;
    END IF;
    -- Serialize primary selection for each involved member, including when
    -- concurrent requests concern different accounts. Consistent order avoids
    -- opposite-direction transfers locking these member resources differently.
    FOR v_user IN
        SELECT DISTINCT x FROM unnest(ARRAY[p_user_key, v_existing.user_key]) AS x
        WHERE x IS NOT NULL ORDER BY x
    LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended(
            'guild.account-primary:' || v_user, 0
        ));
    END LOOP;
    IF NOT guild.is_currently_tracked_player(p_player_key) THEN
        RAISE EXCEPTION 'New links require current membership in a tracked clan'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT FROM guild.player_verification
        WHERE verification_key = p_verification_key
            AND user_key = p_user_key AND player_key = p_player_key
            AND status = 'verified' AND checked_at <= p_linked_at
    ) THEN
        RAISE EXCEPTION 'A matching successful account verification is required'
            USING ERRCODE = '23514';
    END IF;
    -- A transfer was age-checked when it was requested. Staff approval and a
    -- points read come later, within the transfer limits checked below.
    IF v_existing.link_key IS NULL THEN
        PERFORM guild.require_recent_verification(p_verification_key, p_linked_at);
    END IF;
    IF v_existing.link_key IS NOT NULL THEN
        SELECT * INTO v_request FROM guild.account_transfer_request
        WHERE transfer_request_key = p_transfer_request_key FOR UPDATE;
        IF NOT FOUND OR v_request.status NOT IN ('approved', 'awaiting_points')
            OR v_request.to_user_key <> p_user_key
            OR v_request.player_key <> p_player_key
            OR v_request.source_link_key <> v_existing.link_key
            OR v_request.verification_key <> p_verification_key THEN
            RAISE EXCEPTION 'An approved matching transfer request is required'
                USING ERRCODE = '42501';
        END IF;
        IF guild.account_transfer_expires_at(p_transfer_request_key) <= p_linked_at THEN
            RAISE EXCEPTION 'The transfer approval has expired; request the transfer again'
                USING ERRCODE = '23514';
        END IF;
        IF v_existing.is_primary AND EXISTS (
            SELECT FROM guild.account_link
            WHERE user_key = v_existing.user_key
                AND unlinked_at IS NULL AND link_key <> v_existing.link_key
        ) THEN
            RAISE EXCEPTION 'The current owner must choose a replacement primary before transfer'
                USING ERRCODE = '23514';
        END IF;
        v_boundary_read := guild.ensure_clan_games_transfer_read(
            p_transfer_request_key, p_linked_at
        );
        IF v_boundary_read IS NULL THEN
            UPDATE guild.account_transfer_request SET status = 'awaiting_points'
            WHERE transfer_request_key = p_transfer_request_key;
            RETURN NULL;
        END IF;
        UPDATE guild.account_link SET unlinked_at = p_linked_at
        WHERE link_key = v_existing.link_key;
    ELSIF p_transfer_request_key IS NOT NULL THEN
        RAISE EXCEPTION 'Transfer approval does not match a current link'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_episode FROM guild.metric_attribution_episode
    WHERE player_key = p_player_key AND closed_at IS NULL FOR UPDATE;
    IF v_episode.attribution_key IS NOT NULL AND v_episode.user_key = p_user_key THEN
        v_attribution_key := v_episode.attribution_key;
    ELSE
        IF v_episode.attribution_key IS NOT NULL THEN
            UPDATE guild.metric_attribution_episode SET closed_at = p_linked_at
            WHERE attribution_key = v_episode.attribution_key;
        END IF;
        INSERT INTO guild.metric_attribution_episode (
            user_key, player_key, first_link_at, include_prelink_history
        ) VALUES (
            p_user_key, p_player_key, p_linked_at,
            NOT EXISTS (
                SELECT FROM guild.metric_attribution_episode WHERE player_key = p_player_key
            )
        ) RETURNING attribution_key INTO v_attribution_key;
    END IF;
    SELECT EXISTS (
        SELECT FROM guild.account_link
        WHERE user_key = p_user_key AND unlinked_at IS NULL
    ) INTO v_has_accounts;
    IF p_make_primary THEN
        UPDATE guild.account_link SET is_primary = false
        WHERE user_key = p_user_key AND unlinked_at IS NULL AND is_primary;
    END IF;
    INSERT INTO guild.account_link (
        user_key, player_key, verification_key, attribution_key,
        linked_at, is_primary, transfer_request_key, transfer_boundary_read_key
    ) VALUES (
        p_user_key, p_player_key, p_verification_key, v_attribution_key,
        p_linked_at, p_make_primary OR NOT v_has_accounts, p_transfer_request_key,
        nullif(v_boundary_read, 0)
    ) RETURNING link_key INTO v_link_key;
    IF p_transfer_request_key IS NOT NULL THEN
        UPDATE guild.account_transfer_request SET status = 'consumed', consumed_at = p_linked_at
        WHERE transfer_request_key = p_transfer_request_key;
        PERFORM guild.cancel_open_account_transfers(
            v_existing.link_key, p_linked_at, p_transfer_request_key
        );
    END IF;
    RETURN v_link_key;
END;
$$;

CREATE FUNCTION guild.set_primary_account(
    p_user_key bigint, p_player_key bigint
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'guild.account-primary:' || p_user_key, 0
    ));
    IF NOT EXISTS (
        SELECT FROM guild.account_link
            WHERE user_key = p_user_key AND player_key = p_player_key AND unlinked_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Primary must be one of the member''s current linked accounts'
            USING ERRCODE = '23514';
    END IF;
    UPDATE guild.account_link SET is_primary = false
    WHERE user_key = p_user_key AND unlinked_at IS NULL AND is_primary;
    UPDATE guild.account_link SET is_primary = true
    WHERE user_key = p_user_key
        AND player_key = p_player_key AND unlinked_at IS NULL;
END;
$$;

CREATE FUNCTION guild.unlink_player_account(
    p_user_key bigint, p_player_key bigint,
    p_replacement_player_key bigint DEFAULT NULL,
    p_unlinked_at timestamptz DEFAULT clock_timestamp()
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    v_link guild.account_link%ROWTYPE;
    v_has_other_accounts boolean;
BEGIN
    PERFORM FROM guild.dim_player_account WHERE player_key = p_player_key FOR UPDATE;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'guild.account-primary:' || p_user_key, 0
    ));
    SELECT * INTO v_link FROM guild.account_link
    WHERE user_key = p_user_key
        AND player_key = p_player_key AND unlinked_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Members can only unlink their own linked accounts'
            USING ERRCODE = '42501';
    END IF;
    SELECT EXISTS (
        SELECT FROM guild.account_link
        WHERE user_key = p_user_key
            AND unlinked_at IS NULL AND link_key <> v_link.link_key
    ) INTO v_has_other_accounts;
    IF v_link.is_primary AND v_has_other_accounts THEN
        IF p_replacement_player_key IS NULL OR p_replacement_player_key = p_player_key
            OR NOT EXISTS (
                SELECT FROM guild.account_link
                WHERE user_key = p_user_key
                    AND player_key = p_replacement_player_key AND unlinked_at IS NULL
            ) THEN
            RAISE EXCEPTION 'Choose a linked replacement before unlinking the primary'
                USING ERRCODE = '23514';
        END IF;
    ELSIF p_replacement_player_key IS NOT NULL THEN
        RAISE EXCEPTION 'A replacement is only used when unlinking a primary with alts'
            USING ERRCODE = '23514';
    END IF;
    UPDATE guild.account_link SET unlinked_at = p_unlinked_at WHERE link_key = v_link.link_key;
    PERFORM guild.cancel_open_account_transfers(v_link.link_key, p_unlinked_at);
    IF v_link.is_primary AND v_has_other_accounts THEN
        UPDATE guild.account_link SET is_primary = true
        WHERE user_key = p_user_key
            AND player_key = p_replacement_player_key AND unlinked_at IS NULL;
    END IF;
END;
$$;

CREATE VIEW guild.current_account_link AS
SELECT link_key, user_key, player_key, is_primary
FROM guild.account_link WHERE unlinked_at IS NULL;

CREATE FUNCTION guild.account_link_history_for(
    p_actor_user_key bigint, p_player_key bigint
) RETURNS SETOF guild.account_link LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF NOT guild.can_manage_links(p_actor_user_key) THEN
        RAISE EXCEPTION 'Co-leader or Admin role is required to view account-link history'
            USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT l.* FROM guild.account_link l
    WHERE l.player_key = p_player_key
    ORDER BY l.linked_at, l.link_key;
END;
$$;
