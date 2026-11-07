-- The SQL caller is a trusted backend, not an end-user SQL session. The backend
-- authenticates Discord IDs before calling these actor-aware entry points.
-- Runtime credentials cannot read private ledgers or directly edit control state.

CREATE OR REPLACE FUNCTION guild.has_bound_role(
    p_guild_key bigint, p_user_key bigint, p_purposes text[]
) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
BEGIN
    RETURN EXISTS (
        SELECT FROM guild.server_role_binding b
        JOIN guild.discord_member_role r
            ON r.guild_key = b.guild_key AND r.role_key = b.role_key
        JOIN guild.dim_discord_role d ON d.role_key = r.role_key
        WHERE r.guild_key = p_guild_key AND r.user_key = p_user_key
            AND b.purpose = ANY (p_purposes) AND d.deleted_at IS NULL
            AND (r.expires_at IS NULL OR r.expires_at > statement_timestamp())
            AND NOT EXISTS (SELECT FROM guild.discord_member_state s
                WHERE s.guild_key = p_guild_key AND s.user_key = p_user_key AND NOT s.is_present)
    );
END;
$$;

ALTER TABLE guild.guild_settings ADD COLUMN chat_xp_policy_key text NOT NULL
    DEFAULT 'provisional_fixed_utc_minute_v1' REFERENCES guild.chat_xp_policy;
CREATE OR REPLACE FUNCTION guild.credit_chat_xp(p_guild bigint, p_user bigint, p_channel bigint,
    p_message numeric, p_sent_at timestamptz) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    award guild.fact_chat_xp_award%ROWTYPE;
    selected_policy guild.chat_xp_policy%ROWTYPE;
    violated_constraint text;
BEGIN
    SELECT p.* INTO STRICT selected_policy FROM guild.chat_xp_policy p
    WHERE p.policy_key = coalesce((SELECT chat_xp_policy_key FROM guild.guild_settings
        WHERE guild_key = p_guild), 'provisional_fixed_utc_minute_v1');
    INSERT INTO guild.fact_chat_xp_award
        (guild_key, user_key, channel_key, discord_message_id, message_sent_at, policy_key, xp)
    VALUES (p_guild, p_user, p_channel, p_message, p_sent_at,
        selected_policy.policy_key, selected_policy.xp_per_message)
    ON CONFLICT (discord_message_id) DO NOTHING RETURNING * INTO award;
    IF award.xp_award_key IS NULL THEN
        SELECT * INTO STRICT award FROM guild.fact_chat_xp_award WHERE discord_message_id = p_message;
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

CREATE TABLE guild.fact_change_audit (
    change_audit_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    guild_key bigint REFERENCES guild.dim_guild,
    actor_user_key bigint REFERENCES guild.dim_discord_user,
    source text NOT NULL CHECK (source IN ('command', 'collector', 'operator')),
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    transaction_id bigint NOT NULL DEFAULT txid_current(),
    entity_type text NOT NULL,
    operation text NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    previous_value jsonb,
    new_value jsonb,
    CHECK (previous_value IS NOT NULL OR new_value IS NOT NULL)
);
CREATE INDEX change_audit_guild_time ON guild.fact_change_audit (guild_key, changed_at DESC);
ALTER TABLE guild.fact_configuration_change ADD COLUMN transaction_id bigint NOT NULL DEFAULT txid_current();

CREATE FUNCTION guild.audit_stored_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, guild AS $$
DECLARE
    before_row jsonb;
    after_row jsonb;
    row_data jsonb;
    guild_id bigint;
    actor_id bigint;
    source_kind text;
BEGIN
    IF TG_OP <> 'INSERT' THEN before_row := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN after_row := to_jsonb(NEW); END IF;
    row_data := coalesce(after_row, before_row);
    guild_id := coalesce((row_data ->> 'guild_key')::bigint,
        (SELECT guild_key FROM guild.dim_guild LIMIT 1));
    actor_id := nullif(current_setting('guild.actor_user_key', true), '')::bigint;
    source_kind := coalesce(nullif(current_setting('guild.change_source', true), ''),
        CASE WHEN current_setting('role', true) = 'guild_runtime'
            OR pg_has_role(session_user, 'guild_runtime', 'MEMBER')
            THEN 'collector' ELSE 'operator' END);
    INSERT INTO guild.fact_change_audit
        (guild_key, actor_user_key, source, entity_type, operation, previous_value, new_value)
    VALUES (guild_id, actor_id, source_kind, TG_TABLE_NAME, TG_OP, before_row, after_row);
    RETURN NULL;
END;
$$;

CREATE FUNCTION guild.audit_configuration_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, guild AS $$
DECLARE
    before_row jsonb;
    after_row jsonb;
    row_data jsonb;
    identity_data jsonb;
    guild_id bigint;
    actor_id bigint;
    change_source text;
    change_reason text;
BEGIN
    IF TG_OP <> 'INSERT' THEN before_row := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN after_row := to_jsonb(NEW); END IF;
    row_data := coalesce(after_row, before_row);
    guild_id := coalesce((row_data ->> 'guild_key')::bigint,
        (SELECT guild_key FROM guild.dim_guild LIMIT 1));
    actor_id := nullif(current_setting('guild.actor_user_key', true), '')::bigint;
    change_source := CASE WHEN current_setting('guild.change_source', true) = 'command'
        THEN 'command' ELSE 'operator' END;
    change_reason := coalesce(nullif(btrim(current_setting('guild.change_reason', true)), ''),
        'Migration/operator configuration change');
    SELECT jsonb_object_agg(a.attname, row_data -> a.attname) INTO identity_data
    FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
    WHERE i.indrelid = TG_RELID AND i.indisprimary;
    INSERT INTO guild.fact_configuration_change
        (guild_key, actor_user_key, source, entity_type, entity_identity,
            previous_value, new_value, reason)
    VALUES (guild_id, actor_id, change_source, TG_TABLE_NAME, coalesce(identity_data, '{}'::jsonb),
        before_row, after_row, change_reason);
    RETURN NULL;
END;
$$;

-- JSON is command transport into a whitelist of existing typed tables. It is
-- not EAV storage, dynamic DDL, or an unrestricted table/column SQL interface.
CREATE FUNCTION guild.configure_setting(p_guild bigint, p_actor bigint,
    p_entity text, p_row jsonb, p_reason text, p_delete boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
DECLARE
    keys text[];
    input_row jsonb;
    column_list text;
    value_list text;
    update_list text;
    key_list text;
    predicate text;
    provided_key text;
    old_actor text := current_setting('guild.actor_user_key', true);
    old_source text := current_setting('guild.change_source', true);
    old_reason text := current_setting('guild.change_reason', true);
BEGIN
    IF p_actor IS NULL OR NOT guild.can_configure(p_guild, p_actor) THEN
        RAISE EXCEPTION 'configured Admin role or developer required' USING ERRCODE = '42501';
    END IF;
    IF p_row IS NULL OR jsonb_typeof(p_row) <> 'object' OR p_reason IS NULL
        OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'typed configuration object and reason required' USING ERRCODE = '23514';
    END IF;
    keys := CASE p_entity
        WHEN 'guild_settings' THEN ARRAY['guild_key']
        WHEN 'server_role_binding' THEN ARRAY['guild_key', 'purpose']
        WHEN 'clan_role_binding' THEN ARRAY['guild_key', 'clan_key', 'purpose']
        WHEN 'town_hall_role_binding' THEN ARRAY['guild_key', 'town_hall_level']
        WHEN 'channel_binding' THEN ARRAY['guild_key', 'purpose', 'clan_key']
        WHEN 'clan_collection_settings' THEN ARRAY['guild_key', 'clan_key']
        WHEN 'war_reminder_setting' THEN ARRAY['guild_key', 'clan_key', 'seconds_before_end']
        WHEN 'clan_games_schedule' THEN ARRAY['guild_key']
        WHEN 'chat_xp_policy' THEN ARRAY['policy_key']
        ELSE NULL END;
    IF keys IS NULL THEN
        RAISE EXCEPTION 'unsupported configuration entity' USING ERRCODE = '42501';
    END IF;
    IF p_row ? 'guild_key' AND (p_row ->> 'guild_key')::bigint IS DISTINCT FROM p_guild THEN
        RAISE EXCEPTION 'configuration guild mismatch' USING ERRCODE = '23514';
    END IF;
    input_row := CASE WHEN p_entity = 'chat_xp_policy' THEN p_row
        ELSE p_row || jsonb_build_object('guild_key', p_guild) END;
    IF p_entity = 'guild_settings' THEN
        input_row := input_row || jsonb_build_object('updated_at', clock_timestamp());
    END IF;
    -- Channel purpose bindings deliberately permit a NULL clan key.
    IF p_entity = 'channel_binding' AND NOT input_row ? 'clan_key' THEN
        input_row := input_row || '{"clan_key":null}'::jsonb;
    END IF;
    FOREACH provided_key IN ARRAY keys LOOP
        IF NOT input_row ? provided_key THEN
            RAISE EXCEPTION 'missing configuration identity column: %', provided_key
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    FOR provided_key IN SELECT jsonb_object_keys(input_row) LOOP
        IF NOT EXISTS (SELECT FROM pg_attribute
            WHERE attrelid = format('guild.%I', p_entity)::regclass
                AND attname = provided_key AND attnum > 0 AND NOT attisdropped
                AND attidentity = '' AND attgenerated = '') THEN
            RAISE EXCEPTION 'unsupported configuration column: %', provided_key
                USING ERRCODE = '23514';
        END IF;
    END LOOP;
    SELECT string_agg(format('%I', k), ', ' ORDER BY k),
        string_agg(format('r.%I', k), ', ' ORDER BY k),
        string_agg(format('%I = EXCLUDED.%I', k, k), ', ' ORDER BY k)
            FILTER (WHERE NOT k = ANY (keys))
    INTO column_list, value_list, update_list FROM jsonb_object_keys(input_row) AS k;
    SELECT string_agg(format('%I', k), ', '),
        string_agg(format('t.%I IS NOT DISTINCT FROM r.%I', k, k), ' AND ')
    INTO key_list, predicate FROM unnest(keys) AS k;
    PERFORM set_config('guild.actor_user_key', p_actor::text, true);
    PERFORM set_config('guild.change_source', 'command', true);
    PERFORM set_config('guild.change_reason', p_reason, true);
    IF p_delete THEN
        EXECUTE format('DELETE FROM guild.%I t USING '
            || 'jsonb_populate_record(NULL::guild.%I, $1) r WHERE %s',
            p_entity, p_entity, predicate) USING input_row;
    ELSE
        EXECUTE format('INSERT INTO guild.%I (%s) SELECT %s '
            || 'FROM jsonb_populate_record(NULL::guild.%I, $1) r '
            || 'ON CONFLICT (%s) DO %s', p_entity, column_list, value_list, p_entity,
            key_list, CASE WHEN update_list IS NULL THEN 'NOTHING'
                ELSE 'UPDATE SET ' || update_list END) USING input_row;
    END IF;
    PERFORM set_config('guild.actor_user_key', coalesce(old_actor, ''), true);
    PERFORM set_config('guild.change_source', coalesce(old_source, ''), true);
    PERFORM set_config('guild.change_reason', coalesce(old_reason, ''), true);
END;
$$;

CREATE FUNCTION guild.manage_developer(p_guild bigint, p_actor bigint,
    p_target bigint, p_allow boolean, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, guild AS $$
DECLARE
    old_actor text := current_setting('guild.actor_user_key', true);
    old_source text := current_setting('guild.change_source', true);
    old_reason text := current_setting('guild.change_reason', true);
BEGIN
    IF p_actor IS NULL OR NOT guild.is_developer(p_guild, p_actor) THEN
        RAISE EXCEPTION 'existing developer required to edit developer allowlist' USING ERRCODE = '42501';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' OR p_allow IS NULL THEN
        RAISE EXCEPTION 'allowlist decision and reason required' USING ERRCODE = '23514';
    END IF;
    PERFORM set_config('guild.actor_user_key', p_actor::text, true);
    PERFORM set_config('guild.change_source', 'command', true);
    PERFORM set_config('guild.change_reason', p_reason, true);
    IF p_allow THEN
        INSERT INTO guild.developer_allowlist (guild_key, user_key, added_by)
        VALUES (p_guild, p_target, p_actor) ON CONFLICT (guild_key, user_key) DO NOTHING;
    ELSE
        DELETE FROM guild.developer_allowlist WHERE guild_key = p_guild AND user_key = p_target;
    END IF;
    PERFORM set_config('guild.actor_user_key', coalesce(old_actor, ''), true);
    PERFORM set_config('guild.change_source', coalesce(old_source, ''), true);
    PERFORM set_config('guild.change_reason', coalesce(old_reason, ''), true);
END;
$$;
COMMENT ON FUNCTION guild.manage_developer IS
    'Provisional least-privilege boundary pending allowlist-management policy: only an existing '
    'developer may edit it through runtime commands; migration operators bootstrap/recover it.';

CREATE FUNCTION guild.configuration_audit_for(p_guild bigint, p_actor bigint)
RETURNS SETOF guild.fact_configuration_change LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
BEGIN
    IF p_actor IS NULL OR NOT guild.is_developer(p_guild, p_actor) THEN
        RAISE EXCEPTION 'developer-only configuration audit' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT * FROM guild.fact_configuration_change WHERE guild_key = p_guild;
END;
$$;
CREATE FUNCTION guild.change_audit_for(p_guild bigint, p_actor bigint)
RETURNS SETOF guild.fact_change_audit LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild AS $$
BEGIN
    IF p_actor IS NULL OR NOT guild.is_developer(p_guild, p_actor) THEN
        RAISE EXCEPTION 'developer-only aggregate audit' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT a.* FROM guild.fact_change_audit a WHERE a.guild_key = p_guild
        AND CASE
            WHEN a.entity_type IN ('account_link', 'account_transfer_request',
                'metric_attribution_episode', 'player_verification')
                THEN guild.can_manage_links(p_guild, p_actor)
            WHEN a.entity_type IN ('fact_clan_games_account_assessment',
                'fact_clan_games_member_assessment', 'clan_games_member_account_input')
                THEN guild.has_bound_role(p_guild, p_actor, ARRAY['leadership'])
            WHEN a.entity_type IN ('warning', 'warning_revocation', 'fact_warning_event')
                THEN guild.can_moderate(p_guild, p_actor)
                    OR coalesce(a.new_value ->> 'subject_user_key',
                        a.previous_value ->> 'subject_user_key')::bigint = p_actor
            WHEN a.entity_type IN ('moderation_action', 'fact_moderation_action_attempt')
                THEN guild.can_moderate(p_guild, p_actor)
            ELSE true END;
END;
$$;
CREATE FUNCTION guild.clan_games_results_for(p_guild bigint, p_actor bigint,
    p_event bigint DEFAULT NULL) RETURNS SETOF guild.clan_games_member_result
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, guild AS $$
BEGIN
    IF p_actor IS NULL OR NOT guild.has_bound_role(p_guild, p_actor, ARRAY['leadership']) THEN
        RAISE EXCEPTION 'configured Leadership role required' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY SELECT r.* FROM guild.clan_games_member_result r
    JOIN guild.dim_clan_games_event e USING (event_key)
    WHERE e.guild_key = p_guild AND (p_event IS NULL OR r.event_key = p_event);
END;
$$;

CREATE FUNCTION guild.require_manual_fetch_ownership() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.requested_by IS NOT NULL THEN
        IF NEW.player_key IS NULL OR (NEW.endpoint_kind <> 'verify_player' AND NOT EXISTS (
            SELECT FROM guild.account_link WHERE guild_key = NEW.guild_key
                AND user_key = NEW.requested_by AND player_key = NEW.player_key
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

CREATE FUNCTION guild.request_player_refresh(p_guild bigint, p_user bigint, p_player bigint,
    p_correlation text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, guild AS $$
DECLARE result bigint;
BEGIN
    IF p_user IS NULL OR NOT EXISTS (SELECT FROM guild.account_link
        WHERE guild_key = p_guild AND user_key = p_user AND player_key = p_player
            AND unlinked_at IS NULL) THEN
        RAISE EXCEPTION 'manual refresh requires the requester current linked account'
            USING ERRCODE = '42501';
    END IF;
    INSERT INTO guild.fact_api_fetch_attempt
        (guild_key, player_key, requested_by, source_correlation_id, endpoint_kind, outcome)
    VALUES (p_guild, p_player, p_user, coalesce(p_correlation, 'manual:' || gen_random_uuid()::text),
        'player_profile', 'pending') RETURNING fetch_key INTO result;
    RETURN result;
END;
$$;
CREATE FUNCTION guild.record_player_verification(p_guild bigint, p_user bigint,
    p_player bigint, p_status text, p_source_fetch bigint DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, guild AS $$
DECLARE result bigint;
BEGIN
    IF p_source_fetch IS NOT NULL AND NOT EXISTS (
        SELECT FROM guild.fact_api_fetch_attempt WHERE fetch_key = p_source_fetch
            AND guild_key = p_guild AND player_key = p_player AND requested_by = p_user
            AND endpoint_kind = 'verify_player'
            AND (p_status <> 'verified' OR outcome = 'succeeded')
    ) THEN
        RAISE EXCEPTION 'verification fetch does not support this player/user outcome'
            USING ERRCODE = '23514';
    END IF;
    INSERT INTO guild.player_verification (guild_key, user_key, player_key, status, source_fetch_key)
    VALUES (p_guild, p_user, p_player, p_status, p_source_fetch)
    RETURNING verification_key INTO result;
    RETURN result;
END;
$$;

CREATE VIEW guild.public_clan_games_progress AS
SELECT event_key, player_key, observed_at, points, evidence_status, measurement_method
FROM guild.latest_clan_games_progress;

-- Audit configuration and every other persisted row change, including changes
-- to operational projections. Exclude audit ledgers and Flyway history itself.
DO $$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['guild_settings', 'server_role_binding',
        'clan_role_binding', 'town_hall_role_binding', 'channel_binding',
        'clan_collection_settings', 'war_reminder_setting', 'clan_games_schedule',
        'chat_xp_policy', 'developer_allowlist'] LOOP
        EXECUTE format('CREATE TRIGGER audit_configuration AFTER INSERT OR UPDATE OR DELETE '
            || 'ON guild.%I FOR EACH ROW EXECUTE FUNCTION guild.audit_configuration_change()', table_name);
    END LOOP;
    FOR table_name IN SELECT tablename FROM pg_tables WHERE schemaname = 'guild'
        AND tablename NOT IN ('fact_change_audit', 'fact_configuration_change', 'flyway_schema_history') LOOP
        EXECUTE format('CREATE TRIGGER audit_row_change AFTER INSERT OR UPDATE OR DELETE '
            || 'ON guild.%I FOR EACH ROW EXECUTE FUNCTION guild.audit_stored_change()', table_name);
    END LOOP;
END;
$$;
CREATE TRIGGER reject_change_audit_mutation BEFORE UPDATE OR DELETE ON guild.fact_change_audit
FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation();
CREATE TRIGGER reject_configuration_audit_mutation BEFORE UPDATE OR DELETE ON guild.fact_configuration_change
FOR EACH ROW EXECUTE FUNCTION guild.discord_reject_history_mutation();

REVOKE ALL ON ALL TABLES IN SCHEMA guild FROM PUBLIC, guild_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA guild FROM PUBLIC, guild_runtime;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA guild FROM PUBLIC, guild_runtime;
REVOKE ALL ON SCHEMA guild FROM PUBLIC, guild_runtime;
GRANT USAGE ON SCHEMA guild TO guild_runtime;

-- Collector writes are trusted ingestion, not Discord command authorization.
-- No collector privilege permits raw writes to account links, verification,
-- configuration, warnings, current-role projections, or audit ledgers.
GRANT SELECT ON guild.dim_guild, guild.dim_discord_user, guild.dim_player_account,
    guild.dim_clan, guild.dim_discord_role, guild.dim_discord_channel, guild.dim_date,
    guild.guild_settings, guild.server_role_binding, guild.clan_role_binding,
    guild.town_hall_role_binding, guild.channel_binding, guild.clan_collection_settings,
    guild.war_reminder_setting, guild.clan_games_schedule, guild.chat_xp_policy,
    guild.current_account_link, guild.current_observed_clan_member,
    guild.latest_player_counter, guild.current_clan_lifetime_war_stars,
    guild.latest_raid_member_total, guild.public_clan_games_progress,
    guild.chat_xp_all_time_totals, guild.chat_xp_monthly_totals_utc
TO guild_runtime;
GRANT INSERT, UPDATE ON guild.dim_discord_user, guild.dim_player_account,
    guild.dim_clan, guild.dim_discord_role, guild.dim_discord_channel, guild.dim_date
TO guild_runtime;
GRANT INSERT ON guild.clan_membership_poll, guild.fact_clan_member_observation,
    guild.fact_clan_membership_change, guild.observed_clan_membership_period,
    guild.dim_war, guild.fact_war_observation, guild.war_participant,
    guild.fact_war_roster_observation, guild.fact_war_clan_observation,
    guild.fact_war_attack, guild.fact_player_counter_observation,
    guild.dim_achievement, guild.fact_player_achievement_observation,
    guild.fact_clan_games_progress, guild.fact_clan_games_account_assessment,
    guild.fact_clan_games_member_assessment, guild.clan_games_member_account_input,
    guild.dim_raid_weekend, guild.fact_raid_member_observation,
    guild.fact_discord_membership_event, guild.fact_role_change,
    guild.fact_api_fetch_attempt, guild.fact_notification_delivery_attempt
TO guild_runtime;
GRANT UPDATE ON guild.observed_clan_membership_period, guild.fact_war_attack,
    guild.fact_api_fetch_attempt TO guild_runtime;
GRANT SELECT ON guild.clan_membership_poll, guild.fact_clan_member_observation,
    guild.fact_clan_membership_change, guild.observed_clan_membership_period,
    guild.dim_war, guild.fact_war_observation, guild.war_participant,
    guild.fact_war_roster_observation, guild.fact_war_clan_observation,
    guild.fact_war_attack, guild.fact_player_counter_observation,
    guild.dim_achievement, guild.fact_player_achievement_observation,
    guild.fact_clan_games_progress, guild.dim_clan_games_event,
    guild.dim_raid_weekend, guild.fact_raid_member_observation,
    guild.fact_discord_membership_event, guild.fact_role_change,
    guild.discord_member_state, guild.discord_member_role,
    guild.fact_api_fetch_attempt, guild.fact_notification_delivery_attempt
TO guild_runtime;
GRANT SELECT (account_assessment_key) ON guild.fact_clan_games_account_assessment TO guild_runtime;
GRANT SELECT (member_assessment_key) ON guild.fact_clan_games_member_assessment TO guild_runtime;

-- Identity sequences do not expose private row contents. Grant only sequences
-- backing tables where the collector can INSERT; definer functions own others.
DO $$
DECLARE item record;
BEGIN
    FOR item IN SELECT c.oid, c.relname, a.attname FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attidentity <> ''
        WHERE n.nspname = 'guild' AND has_table_privilege('guild_runtime', c.oid, 'INSERT') LOOP
        EXECUTE format('GRANT USAGE ON SEQUENCE %s TO guild_runtime',
            pg_get_serial_sequence(format('guild.%I', item.relname), item.attname));
    END LOOP;
    FOR item IN SELECT p.oid, p.proname, p.prorettype FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'guild' LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = pg_catalog, guild', item.oid::regprocedure);
        IF item.prorettype = 'trigger'::regtype OR item.proname = ANY (ARRAY[
            'is_developer', 'has_bound_role', 'can_configure', 'can_moderate', 'can_manage_links',
            'request_account_transfer', 'decide_account_transfer', 'link_player_account',
            'set_primary_account', 'unlink_player_account', 'account_link_history_for',
            'credit_chat_xp', 'issue_warning', 'revoke_warning', 'warning_history',
            'record_moderation_attempt', 'configure_setting', 'manage_developer',
            'configuration_audit_for', 'change_audit_for', 'clan_games_results_for',
            'record_player_verification', 'request_player_refresh', 'create_scheduled_clan_games',
            'clan_games_observed_target']) THEN
            EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER', item.oid::regprocedure);
        END IF;
        IF item.proname = ANY (ARRAY[
            'is_developer', 'has_bound_role', 'can_configure', 'can_moderate', 'can_manage_links',
            'request_account_transfer', 'decide_account_transfer', 'link_player_account',
            'set_primary_account', 'unlink_player_account', 'account_link_history_for',
            'credit_chat_xp', 'issue_warning', 'revoke_warning', 'warning_history',
            'record_moderation_attempt', 'configure_setting', 'manage_developer',
            'configuration_audit_for', 'change_audit_for', 'clan_games_results_for',
            'record_player_verification', 'request_player_refresh', 'create_scheduled_clan_games',
            'clan_games_observed_target']) THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO guild_runtime', item.oid::regprocedure);
        END IF;
    END LOOP;
END;
$$;
