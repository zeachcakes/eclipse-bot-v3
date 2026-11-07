-- A Discord departure invalidates held-role authority, not identity, XP,
-- account links, or immutable observations. The source occurrence time governs
-- projection order, so delayed gateway events cannot revive an old staff role.
CREATE OR REPLACE FUNCTION guild.project_discord_membership() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    accepted_guild bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('discord-membership'),
        hashtext(NEW.guild_key::text || ':' || NEW.user_key::text));
    INSERT INTO guild.discord_member_state
        (guild_key, user_key, is_present, last_membership_event_key, last_event_at)
    VALUES (NEW.guild_key, NEW.user_key, NEW.event_kind = 'join',
        NEW.membership_event_key, NEW.occurred_at)
    ON CONFLICT (guild_key, user_key) DO UPDATE
    SET is_present = EXCLUDED.is_present,
        last_membership_event_key = EXCLUDED.last_membership_event_key,
        last_event_at = EXCLUDED.last_event_at
    WHERE (EXCLUDED.last_event_at, EXCLUDED.last_membership_event_key)
        > (discord_member_state.last_event_at, discord_member_state.last_membership_event_key)
    RETURNING guild_key INTO accepted_guild;
    IF accepted_guild IS NULL THEN RETURN NEW; END IF;

    DELETE FROM guild.discord_member_role
    WHERE guild_key = NEW.guild_key AND user_key = NEW.user_key;
    IF NEW.event_kind = 'join' THEN
        -- Fresh role confirmations can arrive before the join event itself.
        -- Rebuild only from this occurrence's source-time/provenance window;
        -- never synthesize add events for roles held during an earlier stay.
        INSERT INTO guild.discord_member_role
            (guild_key, user_key, role_key, assigned_at, last_role_event_key, expires_at)
        SELECT guild_key, user_key, role_key, changed_at, role_event_key, expires_at
        FROM (
            SELECT DISTINCT ON (role_key) *
            FROM guild.fact_role_change
            WHERE guild_key = NEW.guild_key AND user_key = NEW.user_key
                AND changed_at >= NEW.occurred_at
                AND (origin_join_event_key IS NULL OR origin_join_event_key = NEW.membership_event_key)
            ORDER BY role_key, changed_at DESC, role_event_key DESC
        ) AS latest
        WHERE change_kind = 'add';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION guild.project_discord_role() RETURNS trigger
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
        hashtext(NEW.guild_key::text || ':' || NEW.user_key::text));
    IF NEW.origin_join_event_key IS NOT NULL THEN
        SELECT * INTO STRICT join_event FROM guild.fact_discord_membership_event
        WHERE membership_event_key = NEW.origin_join_event_key;
        IF join_event.event_kind <> 'join' OR join_event.guild_key <> NEW.guild_key
            OR join_event.user_key <> NEW.user_key THEN
            RAISE EXCEPTION 'role provenance must reference this member join' USING ERRCODE = '23514';
        END IF;
        IF NEW.expires_at IS NOT NULL AND NEW.expires_at <> join_event.new_joinee_expires_at THEN
            RAISE EXCEPTION 'New Joinee expiry must match the selected join policy snapshot'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    SELECT * INTO member_state FROM guild.discord_member_state
    WHERE guild_key = NEW.guild_key AND user_key = NEW.user_key;
    IF FOUND AND (
        NOT member_state.is_present
        OR NEW.changed_at < member_state.last_event_at
        OR (NEW.origin_join_event_key IS NOT NULL
            AND NEW.origin_join_event_key <> member_state.last_membership_event_key)
    ) THEN
        RETURN NEW;
    END IF;
    SELECT role_event_key INTO latest_key FROM guild.fact_role_change
    WHERE guild_key = NEW.guild_key AND user_key = NEW.user_key AND role_key = NEW.role_key
        AND (member_state.guild_key IS NULL OR (
            changed_at >= member_state.last_event_at
            AND (origin_join_event_key IS NULL OR origin_join_event_key = member_state.last_membership_event_key)
        ))
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

-- Repair only mutable projections when upgrading a database with old events.
-- No role observation, member event, account link, or XP award is deleted.
DELETE FROM guild.discord_member_role AS r
USING guild.discord_member_state AS s, guild.fact_role_change AS f
WHERE r.guild_key = s.guild_key AND r.user_key = s.user_key
    AND f.role_event_key = r.last_role_event_key
    AND (
        NOT s.is_present OR r.assigned_at < s.last_event_at
        OR (f.origin_join_event_key IS NOT NULL
            AND f.origin_join_event_key <> s.last_membership_event_key)
    );

-- pg_temp is searched first for relations/types when it is omitted, even when
-- pg_catalog appears explicitly. Keep it explicitly LAST for every function,
-- including private implementations introduced by command-audit wrappers.
DO $$
DECLARE routine record;
BEGIN
    FOR routine IN
        SELECT p.oid FROM pg_catalog.pg_proc AS p
        JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'guild' AND p.prokind = 'f'
    LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = pg_catalog, guild, pg_temp',
            routine.oid::regprocedure);
    END LOOP;
END;
$$;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA guild FROM PUBLIC;

-- PostgreSQL's default PUBLIC EXECUTE is global. A schema-specific REVOKE
-- alone cannot remove it; remove both global and any schema-specific grant.
-- These defaults apply only to functions created by the migration role.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA guild REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
