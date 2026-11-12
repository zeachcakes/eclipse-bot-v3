-- The SQL caller is a trusted backend, not an end-user SQL session. The backend
-- authenticates Discord IDs before calling these actor-aware entry points.
-- Runtime credentials cannot read private ledgers or directly edit control state.
-- Configuration-change triggers and every runtime grant are in the final migration.

-- Change history is kept for configuration only: a settings change overwrites
-- the old value, so this ledger is the only place that keeps it. Game and
-- Discord activity is recorded by its own fact tables, which are the activity
-- history. No second copy of their rows is kept.
CREATE TABLE guild.fact_configuration_change (
    configuration_change_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    source text NOT NULL CHECK (source IN ('command', 'operator')),
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    entity_type text NOT NULL,
    entity_identity jsonb NOT NULL CHECK (jsonb_typeof(entity_identity) = 'object'),
    previous_value jsonb,
    new_value jsonb,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    transaction_id bigint NOT NULL DEFAULT txid_current(),
    CHECK (previous_value IS NOT NULL OR new_value IS NOT NULL),
    CHECK (source <> 'command' OR actor_user_key IS NOT NULL)
);
CREATE INDEX configuration_change_time
    ON guild.fact_configuration_change (changed_at DESC);
COMMENT ON TABLE guild.fact_configuration_change IS
    'Developer-only, immutable history of configuration changes with the values before and '
    'after. An insert has no previous_value and a delete has no new_value.';
COMMENT ON COLUMN guild.fact_configuration_change.source IS
    'command is a change through a command entry point, with its actor. operator is any other '
    'change: a migration, an operator session, or an automatic maintenance function.';

-- Trigger arguments: the table's primary-key column names. The final
-- migration attaches the trigger to every configuration table; a table whose
-- primary key changes must have its trigger recreated.
CREATE FUNCTION guild.record_configuration_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    before_row jsonb;
    after_row jsonb;
    row_data jsonb;
    identity_data jsonb;
BEGIN
    IF TG_OP <> 'INSERT' THEN before_row := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN after_row := to_jsonb(NEW); END IF;
    row_data := coalesce(after_row, before_row);
    -- A Clan Games event is configuration only when staff created it by hand.
    IF TG_TABLE_NAME = 'dim_clan_games_event'
        AND NOT coalesce(row_data ->> 'schedule_source' = 'manual', false) THEN
        RETURN NULL;
    END IF;
    -- The trigger passes the table's primary-key columns, so no catalog
    -- lookup runs for each recorded row.
    SELECT jsonb_object_agg(TG_ARGV[n], row_data -> TG_ARGV[n]) INTO identity_data
    FROM generate_series(0, TG_NARGS - 1) AS n;
    INSERT INTO guild.fact_configuration_change
        (actor_user_key, source, entity_type, entity_identity,
            previous_value, new_value, reason)
    VALUES (nullif(current_setting('guild.actor_user_key', true), '')::bigint,
        CASE WHEN current_setting('guild.change_source', true) = 'command'
            THEN 'command' ELSE 'operator' END,
        TG_TABLE_NAME, coalesce(identity_data, '{}'::jsonb), before_row, after_row,
        coalesce(nullif(btrim(current_setting('guild.change_reason', true)), ''),
            'Migration/operator configuration change'));
    RETURN NULL;
END;
$$;

-- A command entry point records who acted and why in transaction-local
-- settings, which the configuration change trigger reads. The previous values
-- are restored afterwards, so a human actor never leaks into later collector
-- statements of the same transaction.
CREATE FUNCTION guild.begin_command_scope(p_actor bigint, p_reason text)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := ARRAY[current_setting('guild.actor_user_key', true),
        current_setting('guild.change_source', true),
        current_setting('guild.change_reason', true)];
BEGIN
    PERFORM set_config('guild.actor_user_key', p_actor::text, true);
    PERFORM set_config('guild.change_source', 'command', true);
    PERFORM set_config('guild.change_reason', p_reason, true);
    RETURN previous;
END;
$$;

CREATE FUNCTION guild.end_command_scope(p_previous text[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    PERFORM set_config('guild.actor_user_key', coalesce(p_previous[1], ''), true);
    PERFORM set_config('guild.change_source', coalesce(p_previous[2], ''), true);
    PERFORM set_config('guild.change_reason', coalesce(p_previous[3], ''), true);
END;
$$;

-- Every configuration command checks the actor and the reason the same way.
CREATE FUNCTION guild.begin_configuration(p_actor bigint, p_reason text)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF p_actor IS NULL OR NOT guild.can_configure(p_actor) THEN
        RAISE EXCEPTION 'configured Admin role or developer required' USING ERRCODE = '42501';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'configuration reason required' USING ERRCODE = '23514';
    END IF;
    RETURN guild.begin_command_scope(p_actor, p_reason);
END;
$$;

-- Typed configuration commands. Each one writes one configuration table with
-- the full set of values it owns, so the generated jOOQ routine carries the
-- argument types. The guild_settings row belongs to the one Discord server;
-- no command names it. The XP policy key and the leaderboard calendar are not
-- set here: the policy has one agreed version, and the calendar has its own
-- versioned command, set_leaderboard_timezone.
CREATE FUNCTION guild.set_new_joinee_days(p_actor bigint, p_days integer, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.guild_settings (guild_key, new_joinee_days)
    VALUES ((SELECT guild_key FROM guild.dim_guild), p_days)
    ON CONFLICT (guild_key) DO UPDATE SET new_joinee_days = EXCLUDED.new_joinee_days,
        updated_at = clock_timestamp();
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_verification_policy(p_actor bigint,
    p_max_age_seconds integer, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.guild_settings (guild_key, verification_max_age_seconds)
    VALUES ((SELECT guild_key FROM guild.dim_guild), p_max_age_seconds)
    ON CONFLICT (guild_key) DO UPDATE
    SET verification_max_age_seconds = EXCLUDED.verification_max_age_seconds,
        updated_at = clock_timestamp();
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_transfer_policy(p_actor bigint,
    p_pending_max_age_seconds integer, p_approval_max_age_seconds integer, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.guild_settings (guild_key, transfer_pending_max_age_seconds,
        transfer_approval_max_age_seconds)
    VALUES ((SELECT guild_key FROM guild.dim_guild), p_pending_max_age_seconds,
        p_approval_max_age_seconds)
    ON CONFLICT (guild_key) DO UPDATE
    SET transfer_pending_max_age_seconds = EXCLUDED.transfer_pending_max_age_seconds,
        transfer_approval_max_age_seconds = EXCLUDED.transfer_approval_max_age_seconds,
        updated_at = clock_timestamp();
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_kick_policy(p_actor bigint,
    p_max_attempts integer, p_retry_seconds integer, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.guild_settings (guild_key, kick_max_attempts, kick_retry_seconds)
    VALUES ((SELECT guild_key FROM guild.dim_guild), p_max_attempts, p_retry_seconds)
    ON CONFLICT (guild_key) DO UPDATE
    SET kick_max_attempts = EXCLUDED.kick_max_attempts,
        kick_retry_seconds = EXCLUDED.kick_retry_seconds, updated_at = clock_timestamp();
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_clan_games_schedule(p_actor bigint, p_enabled boolean,
    p_start_day integer, p_start_time_utc time, p_event_seconds integer,
    p_account_points_cap integer, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.guild_settings (guild_key, clan_games_enabled, clan_games_start_day,
        clan_games_start_time_utc, clan_games_event_seconds, clan_games_account_points_cap)
    VALUES ((SELECT guild_key FROM guild.dim_guild), p_enabled, p_start_day,
        p_start_time_utc, p_event_seconds, p_account_points_cap)
    ON CONFLICT (guild_key) DO UPDATE
    SET clan_games_enabled = EXCLUDED.clan_games_enabled,
        clan_games_start_day = EXCLUDED.clan_games_start_day,
        clan_games_start_time_utc = EXCLUDED.clan_games_start_time_utc,
        clan_games_event_seconds = EXCLUDED.clan_games_event_seconds,
        clan_games_account_points_cap = EXCLUDED.clan_games_account_points_cap,
        updated_at = clock_timestamp();
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_clan_games_refresh(p_actor bigint,
    p_refresh_seconds integer, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.guild_settings (guild_key, clan_games_refresh_seconds)
    VALUES ((SELECT guild_key FROM guild.dim_guild), p_refresh_seconds)
    ON CONFLICT (guild_key) DO UPDATE
    SET clan_games_refresh_seconds = EXCLUDED.clan_games_refresh_seconds,
        updated_at = clock_timestamp();
    PERFORM guild.end_command_scope(previous);
END;
$$;

-- Role bindings share one table. Each scope has its own pair of commands, and
-- a command never reaches a binding of another scope: a clan or town-hall
-- command without its scope value is rejected rather than read as a server
-- binding.
CREATE FUNCTION guild.set_server_role(p_actor bigint, p_purpose text,
    p_role_key bigint, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.role_binding (purpose, role_key) VALUES (p_purpose, p_role_key)
    ON CONFLICT (purpose, clan_key, town_hall_level) DO UPDATE
    SET role_key = EXCLUDED.role_key;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.delete_server_role(p_actor bigint, p_purpose text, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    DELETE FROM guild.role_binding
    WHERE purpose = p_purpose AND clan_key IS NULL AND town_hall_level IS NULL;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_clan_role(p_actor bigint, p_clan_key bigint,
    p_purpose text, p_role_key bigint, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    IF p_clan_key IS NULL THEN
        RAISE EXCEPTION 'clan role binding requires a clan' USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.role_binding (clan_key, purpose, role_key)
    VALUES (p_clan_key, p_purpose, p_role_key)
    ON CONFLICT (purpose, clan_key, town_hall_level) DO UPDATE
    SET role_key = EXCLUDED.role_key;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.delete_clan_role(p_actor bigint, p_clan_key bigint,
    p_purpose text, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    IF p_clan_key IS NULL THEN
        RAISE EXCEPTION 'clan role binding requires a clan' USING ERRCODE = '23514';
    END IF;
    DELETE FROM guild.role_binding
    WHERE clan_key = p_clan_key AND purpose = p_purpose AND town_hall_level IS NULL;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_town_hall_role(p_actor bigint, p_town_hall_level integer,
    p_role_key bigint, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    IF p_town_hall_level IS NULL THEN
        RAISE EXCEPTION 'town hall role binding requires a level' USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.role_binding (town_hall_level, purpose, role_key)
    VALUES (p_town_hall_level, 'town_hall', p_role_key)
    ON CONFLICT (purpose, clan_key, town_hall_level) DO UPDATE
    SET role_key = EXCLUDED.role_key;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.delete_town_hall_role(p_actor bigint, p_town_hall_level integer,
    p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    IF p_town_hall_level IS NULL THEN
        RAISE EXCEPTION 'town hall role binding requires a level' USING ERRCODE = '23514';
    END IF;
    DELETE FROM guild.role_binding
    WHERE town_hall_level = p_town_hall_level AND clan_key IS NULL;
    PERFORM guild.end_command_scope(previous);
END;
$$;

-- The table checks decide which purposes need a clan and a war day.
CREATE FUNCTION guild.set_channel_binding(p_actor bigint, p_purpose text,
    p_clan_key bigint, p_war_day integer, p_channel_key bigint, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.channel_binding (purpose, clan_key, war_day, channel_key)
    VALUES (p_purpose, p_clan_key, p_war_day, p_channel_key)
    ON CONFLICT (purpose, clan_key, war_day) DO UPDATE
    SET channel_key = EXCLUDED.channel_key;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.delete_channel_binding(p_actor bigint, p_purpose text,
    p_clan_key bigint, p_war_day integer, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    DELETE FROM guild.channel_binding
    WHERE purpose = p_purpose AND clan_key IS NOT DISTINCT FROM p_clan_key
        AND war_day IS NOT DISTINCT FROM p_war_day;
    PERFORM guild.end_command_scope(previous);
END;
$$;

-- A tracked clan is switched off with enabled = false, not deleted: its
-- collected facts reference the settings row.
CREATE FUNCTION guild.set_clan_collection(p_actor bigint, p_clan_key bigint,
    p_enabled boolean, p_membership_poll_seconds integer, p_raid_report_seconds integer,
    p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.clan_collection_settings (clan_key, enabled, membership_poll_seconds,
        raid_report_seconds)
    VALUES (p_clan_key, p_enabled, p_membership_poll_seconds, p_raid_report_seconds)
    ON CONFLICT (clan_key) DO UPDATE
    SET enabled = EXCLUDED.enabled,
        membership_poll_seconds = EXCLUDED.membership_poll_seconds,
        raid_report_seconds = EXCLUDED.raid_report_seconds;
    PERFORM guild.end_command_scope(previous);
END;
$$;

-- CWL settings share the clan's collection settings row.
CREATE FUNCTION guild.set_cwl_clan_settings(p_actor bigint, p_clan_key bigint,
    p_automatic_freeze_minutes integer, p_sheet_document_id text, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.clan_collection_settings (clan_key, automatic_freeze_minutes,
        sheet_document_id)
    VALUES (p_clan_key, p_automatic_freeze_minutes, p_sheet_document_id)
    ON CONFLICT (clan_key) DO UPDATE
    SET automatic_freeze_minutes = EXCLUDED.automatic_freeze_minutes,
        sheet_document_id = EXCLUDED.sheet_document_id;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_war_reminder(p_actor bigint, p_clan_key bigint,
    p_seconds_before_end integer, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.war_reminder_setting (clan_key, seconds_before_end)
    VALUES (p_clan_key, p_seconds_before_end) ON CONFLICT DO NOTHING;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.delete_war_reminder(p_actor bigint, p_clan_key bigint,
    p_seconds_before_end integer, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    DELETE FROM guild.war_reminder_setting
    WHERE clan_key = p_clan_key AND seconds_before_end = p_seconds_before_end;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_chat_xp_eligibility_role(p_actor bigint, p_role_key bigint,
    p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.chat_xp_eligibility_role (role_key) VALUES (p_role_key)
    ON CONFLICT DO NOTHING;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.delete_chat_xp_eligibility_role(p_actor bigint, p_role_key bigint,
    p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    DELETE FROM guild.chat_xp_eligibility_role WHERE role_key = p_role_key;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.set_chat_rank_role(p_actor bigint, p_rank_key integer,
    p_role_key bigint, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    INSERT INTO guild.chat_rank_role_binding (rank_key, role_key) VALUES (p_rank_key, p_role_key)
    ON CONFLICT (rank_key) DO UPDATE SET role_key = EXCLUDED.role_key;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.delete_chat_rank_role(p_actor bigint, p_rank_key integer,
    p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    previous text[] := guild.begin_configuration(p_actor, p_reason);
BEGIN
    DELETE FROM guild.chat_rank_role_binding WHERE rank_key = p_rank_key;
    PERFORM guild.end_command_scope(previous);
END;
$$;

CREATE FUNCTION guild.manage_developer(p_actor bigint,
    p_target bigint, p_allow boolean, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE
    old_actor text := current_setting('guild.actor_user_key', true);
    old_source text := current_setting('guild.change_source', true);
    old_reason text := current_setting('guild.change_reason', true);
BEGIN
    IF p_actor IS NULL OR NOT guild.is_developer(p_actor) THEN
        RAISE EXCEPTION 'existing developer required to edit developer allowlist' USING ERRCODE = '42501';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' OR p_allow IS NULL THEN
        RAISE EXCEPTION 'allowlist decision and reason required' USING ERRCODE = '23514';
    END IF;
    PERFORM set_config('guild.actor_user_key', p_actor::text, true);
    PERFORM set_config('guild.change_source', 'command', true);
    PERFORM set_config('guild.change_reason', p_reason, true);
    IF p_allow THEN
        INSERT INTO guild.developer_allowlist (user_key, added_by)
        VALUES (p_target, p_actor) ON CONFLICT (user_key) DO NOTHING;
    ELSE
        DELETE FROM guild.developer_allowlist WHERE user_key = p_target;
    END IF;
    PERFORM set_config('guild.actor_user_key', coalesce(old_actor, ''), true);
    PERFORM set_config('guild.change_source', coalesce(old_source, ''), true);
    PERFORM set_config('guild.change_reason', coalesce(old_reason, ''), true);
END;
$$;
COMMENT ON FUNCTION guild.manage_developer IS
    'Accepted developers-only boundary: only an existing '
    'developer may edit it through runtime commands; migration operators bootstrap/recover it.';

CREATE FUNCTION guild.configuration_audit_for(p_actor bigint)
RETURNS SETOF guild.fact_configuration_change LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF p_actor IS NULL OR NOT guild.is_developer(p_actor) THEN
        RAISE EXCEPTION 'developer-only configuration audit' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT * FROM guild.fact_configuration_change;
END;
$$;
CREATE FUNCTION guild.clan_games_results_for(p_actor bigint,
    p_event bigint DEFAULT NULL) RETURNS SETOF guild.clan_games_member_result
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF p_actor IS NULL OR NOT guild.has_bound_role(p_actor, ARRAY['leadership']) THEN
        RAISE EXCEPTION 'configured Leadership role required' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT r.* FROM guild.clan_games_member_result r
    WHERE p_event IS NULL OR r.event_key = p_event;
END;
$$;

-- Ownership is checked when a request is made and when its identity changes.
-- Recording the outcome is not checked: the collector must be able to finish
-- a request whose member unlinked or transferred the account in the meantime.
CREATE FUNCTION guild.require_manual_fetch_ownership() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF NEW.requested_by IS NOT NULL AND (TG_OP = 'INSERT'
        OR (NEW.requested_by, NEW.player_key, NEW.endpoint_kind)
            IS DISTINCT FROM (OLD.requested_by, OLD.player_key, OLD.endpoint_kind)) THEN
        IF NEW.player_key IS NULL OR (NEW.endpoint_kind <> 'verify_player' AND NOT EXISTS (
            SELECT FROM guild.account_link
            WHERE user_key = NEW.requested_by AND player_key = NEW.player_key
                AND unlinked_at IS NULL
        )) THEN
            RAISE EXCEPTION 'manual refresh is restricted to the requester current linked accounts'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER manual_fetch_owner BEFORE INSERT OR UPDATE ON guild.fact_api_fetch_attempt
FOR EACH ROW EXECUTE FUNCTION guild.require_manual_fetch_ownership();

CREATE FUNCTION guild.request_player_refresh(p_user bigint, p_player bigint,
    p_correlation text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE result bigint;
BEGIN
    IF p_user IS NULL OR NOT EXISTS (SELECT FROM guild.account_link
        WHERE user_key = p_user AND player_key = p_player AND unlinked_at IS NULL) THEN
        RAISE EXCEPTION 'manual refresh requires the requester current linked account'
            USING ERRCODE = '42501';
    END IF;
    INSERT INTO guild.fact_api_fetch_attempt
        (player_key, requested_by, source_correlation_id, endpoint_kind, outcome)
    VALUES (p_player, p_user, coalesce(p_correlation, 'manual:' || gen_random_uuid()::text),
        'player_profile', 'pending') RETURNING fetch_key INTO result;
    RETURN result;
END;
$$;
CREATE FUNCTION guild.record_player_verification(p_user bigint,
    p_player bigint, p_status text, p_source_fetch bigint DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
DECLARE result bigint;
BEGIN
    IF p_source_fetch IS NOT NULL AND NOT EXISTS (
        SELECT FROM guild.fact_api_fetch_attempt WHERE fetch_key = p_source_fetch
            AND player_key = p_player AND requested_by = p_user
            AND endpoint_kind = 'verify_player'
            AND (p_status <> 'verified' OR outcome = 'succeeded')
    ) THEN
        RAISE EXCEPTION 'verification fetch does not support this player/user outcome'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.player_verification (user_key, player_key, status, source_fetch_key)
    VALUES (p_user, p_player, p_status, p_source_fetch)
    RETURNING verification_key INTO result;
    RETURN result;
END;
$$;

CREATE VIEW guild.public_clan_games_progress AS
SELECT event_key, player_key, observed_at, points, evidence_status, measurement_method
FROM guild.latest_clan_games_progress;

CREATE TRIGGER reject_configuration_change_mutation BEFORE UPDATE OR DELETE
ON guild.fact_configuration_change
FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation();
