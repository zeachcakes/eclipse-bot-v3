-- Game observations do not depend on a Discord link. These intervals describe
-- actual links; attribution episodes separately preserve metric continuity.
CREATE TABLE guild.player_verification (
    verification_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    status text NOT NULL CHECK (status IN ('verified', 'rejected', 'error')),
    checked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    source_request_id uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    source_fetch_key bigint REFERENCES guild.fact_api_fetch_attempt,
    UNIQUE (verification_key, guild_key, user_key, player_key, status)
);
COMMENT ON TABLE guild.player_verification IS
    'Trusted backend verification outcome only. Never retain the supplied or echoed API token.';

CREATE TABLE guild.metric_attribution_episode (
    attribution_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    first_link_at timestamptz NOT NULL,
    closed_at timestamptz,
    include_prelink_history boolean NOT NULL DEFAULT false,
    UNIQUE (attribution_key, guild_key, user_key, player_key),
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
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    verification_key bigint NOT NULL UNIQUE,
    verification_status text GENERATED ALWAYS AS ('verified'::text) STORED,
    attribution_key bigint NOT NULL,
    linked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    unlinked_at timestamptz,
    is_primary boolean NOT NULL DEFAULT false,
    UNIQUE (link_key, guild_key, user_key, player_key),
    FOREIGN KEY (verification_key, guild_key, user_key, player_key, verification_status)
        REFERENCES guild.player_verification (
            verification_key, guild_key, user_key, player_key, status
        ),
    FOREIGN KEY (attribution_key, guild_key, user_key, player_key)
        REFERENCES guild.metric_attribution_episode (
            attribution_key, guild_key, user_key, player_key
        ),
    CHECK (unlinked_at IS NULL OR unlinked_at > linked_at),
    EXCLUDE USING gist (
        player_key WITH =, tstzrange(linked_at, unlinked_at, '[)') WITH &&
    )
);
CREATE UNIQUE INDEX account_link_one_current_owner
ON guild.account_link (player_key) WHERE unlinked_at IS NULL;
CREATE UNIQUE INDEX account_link_one_current_primary
ON guild.account_link (guild_key, user_key) WHERE unlinked_at IS NULL AND is_primary;
CREATE INDEX account_link_member_history
ON guild.account_link (guild_key, user_key, linked_at DESC);

CREATE TABLE guild.account_transfer_request (
    transfer_request_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint NOT NULL REFERENCES guild.dim_guild,
    player_key bigint NOT NULL REFERENCES guild.dim_player_account,
    from_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    to_user_key bigint NOT NULL REFERENCES guild.dim_discord_user,
    source_link_key bigint NOT NULL,
    verification_key bigint NOT NULL,
    verification_status text GENERATED ALWAYS AS ('verified'::text) STORED,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'rejected', 'consumed')),
    decided_by bigint REFERENCES guild.dim_discord_user,
    decided_at timestamptz,
    consumed_at timestamptz,
    FOREIGN KEY (source_link_key, guild_key, from_user_key, player_key)
        REFERENCES guild.account_link (link_key, guild_key, user_key, player_key),
    FOREIGN KEY (verification_key, guild_key, to_user_key, player_key, verification_status)
        REFERENCES guild.player_verification (
            verification_key, guild_key, user_key, player_key, status
        ),
    UNIQUE (transfer_request_key, guild_key, to_user_key, player_key),
    CHECK (from_user_key <> to_user_key),
    CHECK (
        (status = 'pending' AND decided_by IS NULL AND decided_at IS NULL AND consumed_at IS NULL)
        OR (status IN ('approved', 'rejected') AND decided_by IS NOT NULL
            AND decided_at IS NOT NULL AND decided_at >= requested_at AND consumed_at IS NULL)
        OR (status = 'consumed' AND decided_by IS NOT NULL AND decided_at IS NOT NULL
            AND consumed_at IS NOT NULL AND decided_at >= requested_at AND consumed_at >= decided_at)
    )
);
ALTER TABLE guild.account_link ADD COLUMN transfer_request_key bigint;
ALTER TABLE guild.account_link ADD CONSTRAINT account_link_transfer_request
FOREIGN KEY (transfer_request_key, guild_key, user_key, player_key)
REFERENCES guild.account_transfer_request (
    transfer_request_key, guild_key, to_user_key, player_key
);
CREATE UNIQUE INDEX account_link_transfer_used_once
ON guild.account_link (transfer_request_key) WHERE transfer_request_key IS NOT NULL;
CREATE UNIQUE INDEX account_transfer_one_pending_recipient
ON guild.account_transfer_request (source_link_key, to_user_key) WHERE status = 'pending';

-- A first link, primary replacement, and old-primary demotion are one
-- transaction. The deferred check also protects callers using SQL directly.
CREATE FUNCTION guild.require_one_primary_account() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_owner record;
    v_active bigint;
    v_primary bigint;
BEGIN
    FOR v_owner IN
        SELECT DISTINCT owner.guild_key, owner.user_key
        FROM (
            SELECT NEW.guild_key, NEW.user_key WHERE TG_OP <> 'DELETE'
            UNION ALL
            SELECT OLD.guild_key, OLD.user_key WHERE TG_OP <> 'INSERT'
        ) AS owner
    LOOP
        SELECT count(*), count(*) FILTER (WHERE is_primary)
        INTO v_active, v_primary
        FROM guild.account_link
        WHERE guild_key = v_owner.guild_key AND user_key = v_owner.user_key
            AND unlinked_at IS NULL;
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
    p_guild_key bigint, p_to_user_key bigint, p_player_key bigint,
    p_verification_key bigint, p_requested_at timestamptz DEFAULT clock_timestamp()
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
DECLARE
    v_source guild.account_link%ROWTYPE;
    v_request_key bigint;
BEGIN
    PERFORM FROM guild.dim_player_account WHERE player_key = p_player_key FOR UPDATE;
    SELECT * INTO v_source FROM guild.account_link
    WHERE player_key = p_player_key AND unlinked_at IS NULL;
    IF NOT FOUND OR v_source.guild_key <> p_guild_key OR v_source.user_key = p_to_user_key THEN
        RAISE EXCEPTION 'Transfer requires an account currently linked to another member'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT FROM guild.player_verification
        WHERE verification_key = p_verification_key AND guild_key = p_guild_key
            AND user_key = p_to_user_key AND player_key = p_player_key
            AND status = 'verified' AND checked_at <= p_requested_at
    ) THEN
        RAISE EXCEPTION 'A matching successful account verification is required'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.account_transfer_request (
        guild_key, player_key, from_user_key, to_user_key, source_link_key,
        verification_key, requested_at
    ) VALUES (
        p_guild_key, p_player_key, v_source.user_key, p_to_user_key,
        v_source.link_key, p_verification_key, p_requested_at
    ) RETURNING transfer_request_key INTO v_request_key;
    RETURN v_request_key;
END;
$$;

CREATE FUNCTION guild.decide_account_transfer(
    p_transfer_request_key bigint, p_actor_user_key bigint, p_approve boolean,
    p_decided_at timestamptz DEFAULT clock_timestamp()
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
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
    IF NOT guild.can_manage_links(v_request.guild_key, p_actor_user_key) THEN
        RAISE EXCEPTION 'Co-leader or Admin role is required to decide an account transfer'
            USING ERRCODE = '42501';
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
    p_guild_key bigint, p_user_key bigint, p_player_key bigint,
    p_verification_key bigint, p_make_primary boolean DEFAULT false,
    p_transfer_request_key bigint DEFAULT NULL,
    p_linked_at timestamptz DEFAULT clock_timestamp()
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
DECLARE
    v_existing guild.account_link%ROWTYPE;
    v_episode guild.metric_attribution_episode%ROWTYPE;
    v_request guild.account_transfer_request%ROWTYPE;
    v_user bigint;
    v_link_key bigint;
    v_attribution_key bigint;
    v_has_accounts boolean;
BEGIN
    PERFORM FROM guild.dim_player_account WHERE player_key = p_player_key FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Player account not found' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_existing FROM guild.account_link
    WHERE player_key = p_player_key AND unlinked_at IS NULL;
    IF v_existing.link_key IS NOT NULL AND v_existing.guild_key = p_guild_key
        AND v_existing.user_key = p_user_key THEN
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
            'guild.account-primary:' || p_guild_key || ':' || v_user, 0
        ));
    END LOOP;
    IF NOT guild.is_currently_tracked_player(p_guild_key, p_player_key) THEN
        RAISE EXCEPTION 'New links require current membership in a tracked clan'
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT FROM guild.player_verification
        WHERE verification_key = p_verification_key AND guild_key = p_guild_key
            AND user_key = p_user_key AND player_key = p_player_key
            AND status = 'verified' AND checked_at <= p_linked_at
    ) THEN
        RAISE EXCEPTION 'A matching successful account verification is required'
            USING ERRCODE = '23514';
    END IF;
    IF v_existing.link_key IS NOT NULL THEN
        SELECT * INTO v_request FROM guild.account_transfer_request
        WHERE transfer_request_key = p_transfer_request_key FOR UPDATE;
        IF NOT FOUND OR v_request.status <> 'approved'
            OR v_request.guild_key <> p_guild_key OR v_request.to_user_key <> p_user_key
            OR v_request.player_key <> p_player_key
            OR v_request.source_link_key <> v_existing.link_key
            OR v_request.verification_key <> p_verification_key THEN
            RAISE EXCEPTION 'An approved matching transfer request is required'
                USING ERRCODE = '42501';
        END IF;
        IF v_existing.is_primary AND EXISTS (
            SELECT FROM guild.account_link
            WHERE guild_key = v_existing.guild_key AND user_key = v_existing.user_key
                AND unlinked_at IS NULL AND link_key <> v_existing.link_key
        ) THEN
            RAISE EXCEPTION 'The current owner must choose a replacement primary before transfer'
                USING ERRCODE = '23514';
        END IF;
        UPDATE guild.account_link SET unlinked_at = p_linked_at
        WHERE link_key = v_existing.link_key;
    ELSIF p_transfer_request_key IS NOT NULL THEN
        RAISE EXCEPTION 'Transfer approval does not match a current link'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO v_episode FROM guild.metric_attribution_episode
    WHERE player_key = p_player_key AND closed_at IS NULL FOR UPDATE;
    IF v_episode.attribution_key IS NOT NULL AND v_episode.guild_key = p_guild_key
        AND v_episode.user_key = p_user_key THEN
        v_attribution_key := v_episode.attribution_key;
    ELSE
        IF v_episode.attribution_key IS NOT NULL THEN
            UPDATE guild.metric_attribution_episode SET closed_at = p_linked_at
            WHERE attribution_key = v_episode.attribution_key;
        END IF;
        INSERT INTO guild.metric_attribution_episode (
            guild_key, user_key, player_key, first_link_at, include_prelink_history
        ) VALUES (
            p_guild_key, p_user_key, p_player_key, p_linked_at,
            NOT EXISTS (
                SELECT FROM guild.metric_attribution_episode WHERE player_key = p_player_key
            )
        ) RETURNING attribution_key INTO v_attribution_key;
    END IF;
    SELECT EXISTS (
        SELECT FROM guild.account_link
        WHERE guild_key = p_guild_key AND user_key = p_user_key AND unlinked_at IS NULL
    ) INTO v_has_accounts;
    IF p_make_primary THEN
        UPDATE guild.account_link SET is_primary = false
        WHERE guild_key = p_guild_key AND user_key = p_user_key
            AND unlinked_at IS NULL AND is_primary;
    END IF;
    INSERT INTO guild.account_link (
        guild_key, user_key, player_key, verification_key, attribution_key,
        linked_at, is_primary, transfer_request_key
    ) VALUES (
        p_guild_key, p_user_key, p_player_key, p_verification_key, v_attribution_key,
        p_linked_at, p_make_primary OR NOT v_has_accounts, p_transfer_request_key
    ) RETURNING link_key INTO v_link_key;
    IF p_transfer_request_key IS NOT NULL THEN
        UPDATE guild.account_transfer_request SET status = 'consumed', consumed_at = p_linked_at
        WHERE transfer_request_key = p_transfer_request_key;
    END IF;
    RETURN v_link_key;
END;
$$;

CREATE FUNCTION guild.set_primary_account(
    p_guild_key bigint, p_user_key bigint, p_player_key bigint
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'guild.account-primary:' || p_guild_key || ':' || p_user_key, 0
    ));
    IF NOT EXISTS (
        SELECT FROM guild.account_link WHERE guild_key = p_guild_key
            AND user_key = p_user_key AND player_key = p_player_key AND unlinked_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Primary must be one of the member''s current linked accounts'
            USING ERRCODE = '23514';
    END IF;
    UPDATE guild.account_link SET is_primary = false
    WHERE guild_key = p_guild_key AND user_key = p_user_key AND unlinked_at IS NULL AND is_primary;
    UPDATE guild.account_link SET is_primary = true
    WHERE guild_key = p_guild_key AND user_key = p_user_key
        AND player_key = p_player_key AND unlinked_at IS NULL;
END;
$$;

CREATE FUNCTION guild.unlink_player_account(
    p_guild_key bigint, p_user_key bigint, p_player_key bigint,
    p_replacement_player_key bigint DEFAULT NULL,
    p_unlinked_at timestamptz DEFAULT clock_timestamp()
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
DECLARE
    v_link guild.account_link%ROWTYPE;
    v_has_other_accounts boolean;
BEGIN
    PERFORM FROM guild.dim_player_account WHERE player_key = p_player_key FOR UPDATE;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'guild.account-primary:' || p_guild_key || ':' || p_user_key, 0
    ));
    SELECT * INTO v_link FROM guild.account_link
    WHERE guild_key = p_guild_key AND user_key = p_user_key
        AND player_key = p_player_key AND unlinked_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Members can only unlink their own linked accounts'
            USING ERRCODE = '42501';
    END IF;
    SELECT EXISTS (
        SELECT FROM guild.account_link
        WHERE guild_key = p_guild_key AND user_key = p_user_key
            AND unlinked_at IS NULL AND link_key <> v_link.link_key
    ) INTO v_has_other_accounts;
    IF v_link.is_primary AND v_has_other_accounts THEN
        IF p_replacement_player_key IS NULL OR p_replacement_player_key = p_player_key
            OR NOT EXISTS (
                SELECT FROM guild.account_link
                WHERE guild_key = p_guild_key AND user_key = p_user_key
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
    IF v_link.is_primary AND v_has_other_accounts THEN
        UPDATE guild.account_link SET is_primary = true
        WHERE guild_key = p_guild_key AND user_key = p_user_key
            AND player_key = p_replacement_player_key AND unlinked_at IS NULL;
    END IF;
END;
$$;

CREATE VIEW guild.current_account_link AS
SELECT link_key, guild_key, user_key, player_key, is_primary
FROM guild.account_link WHERE unlinked_at IS NULL;

CREATE FUNCTION guild.account_link_history_for(
    p_guild_key bigint, p_actor_user_key bigint, p_player_key bigint
) RETURNS SETOF guild.account_link LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
BEGIN
    IF NOT guild.can_manage_links(p_guild_key, p_actor_user_key) THEN
        RAISE EXCEPTION 'Co-leader or Admin role is required to view account-link history'
            USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT l.* FROM guild.account_link l
    WHERE l.guild_key = p_guild_key AND l.player_key = p_player_key
    ORDER BY l.linked_at, l.link_key;
END;
$$;
