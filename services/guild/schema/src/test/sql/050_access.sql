BEGIN;

-- Operator bootstrap; runtime commands cannot bootstrap their own developer.
DO $$
DECLARE
    guild bigint;
    member_id bigint;
    developer_id bigint;
    role_id bigint;
    player_id bigint;
    verification_id bigint;
    attribution_id bigint;
    event_id bigint;
    item record;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (9700000000000000001)
    RETURNING guild_key INTO guild;
    INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (9700000000000000011), (9700000000000000012), (9700000000000000013),
        (9700000000000000014), (9700000000000000015);
    SELECT user_key INTO member_id FROM guild.dim_discord_user WHERE discord_user_id = 9700000000000000011;
    SELECT user_key INTO developer_id FROM guild.dim_discord_user WHERE discord_user_id = 9700000000000000013;
    INSERT INTO guild.developer_allowlist (user_key) VALUES (developer_id);
    FOR item IN SELECT * FROM (VALUES
        ('admin', 9700000000000000012::numeric, 9700000000000000021::numeric),
        ('leadership', 9700000000000000014::numeric, 9700000000000000022::numeric),
        ('co_leader', 9700000000000000015::numeric, 9700000000000000023::numeric)
    ) AS roles(purpose, user_id, role_snowflake) LOOP
        INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
        VALUES (item.role_snowflake, item.purpose) RETURNING role_key INTO role_id;
        INSERT INTO guild.server_role_binding (purpose, role_key)
        VALUES (item.purpose, role_id);
        INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
        SELECT user_key, role_id, 'add', clock_timestamp(), 'manual'
        FROM guild.dim_discord_user WHERE discord_user_id = item.user_id;
    END LOOP;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y') RETURNING player_key INTO player_id;
    verification_id := guild.record_player_verification(member_id, player_id, 'verified');
    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at, include_prelink_history)
    VALUES (member_id, player_id, clock_timestamp(), true)
    RETURNING attribution_key INTO attribution_id;
    INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, is_primary)
    VALUES (member_id, player_id, verification_id, attribution_id, true);
    INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source, source_correlation_id)
    VALUES ('2026-11-22 08:00:00+00', '2026-11-28 08:00:00+00', 4000,
        'manual', 'access-test') RETURNING event_key INTO event_id;
    INSERT INTO guild.fact_clan_games_member_assessment
        (event_key, user_key, checkpoint_kind, calculation_version, attribution_policy,
            attribution_status, evidence_note)
    VALUES (event_id, member_id, 'final', 1, 'unresolved', 'insufficient_data', 'No fabricated result');
END;
$$;

SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    guild bigint;
    member_id bigint;
    admin_id bigint;
    developer_id bigint;
    leadership_id bigint;
    coleader_id bigint;
    player_id bigint;
    count_rows bigint;
    warning_id bigint;
    fetch_id bigint;
    entity text;
    rejected boolean;
BEGIN
    SELECT guild_key INTO STRICT guild FROM guild.dim_guild;
    SELECT user_key INTO member_id FROM guild.dim_discord_user WHERE discord_user_id = 9700000000000000011;
    SELECT user_key INTO admin_id FROM guild.dim_discord_user WHERE discord_user_id = 9700000000000000012;
    SELECT user_key INTO developer_id FROM guild.dim_discord_user WHERE discord_user_id = 9700000000000000013;
    SELECT user_key INTO leadership_id FROM guild.dim_discord_user WHERE discord_user_id = 9700000000000000014;
    SELECT user_key INTO coleader_id FROM guild.dim_discord_user WHERE discord_user_id = 9700000000000000015;
    SELECT player_key INTO player_id FROM guild.dim_player_account WHERE player_tag = '#P0Y';

    FOREACH entity IN ARRAY ARRAY['fact_configuration_change',
        'account_link', 'player_verification', 'fact_warning_event', 'warning',
        'fact_clan_games_account_assessment', 'fact_clan_games_member_assessment',
        'clan_games_member_result'] LOOP
        rejected := false;
        BEGIN EXECUTE format('SELECT * FROM guild.%I', entity);
        EXCEPTION WHEN insufficient_privilege THEN rejected := true;
        END;
        IF NOT rejected THEN RAISE EXCEPTION 'runtime could read private entity % directly', entity; END IF;
    END LOOP;
    SELECT count(*) INTO count_rows FROM guild.current_account_link;
    IF count_rows <> 1 THEN RAISE EXCEPTION 'public current links were not readable'; END IF;

    PERFORM guild.set_new_joinee_days(admin_id, 14, 'Admin configuration test');
    IF (SELECT new_joinee_days FROM guild.guild_settings WHERE guild_key = guild) <> 14 THEN
        RAISE EXCEPTION 'authorized Admin command did not configure typed row';
    END IF;
    rejected := false;
    BEGIN PERFORM guild.set_new_joinee_days(member_id, 1, 'unauthorized');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'ordinary member configured settings'; END IF;
    rejected := false;
    BEGIN PERFORM guild.set_new_joinee_days(admin_id, 3, ' ');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'configuration accepted a blank reason'; END IF;
    rejected := false;
    BEGIN PERFORM 1 FROM guild.configuration_audit_for(admin_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Admin configuration permission exposed developer audit'; END IF;
    SELECT count(*) INTO count_rows FROM guild.configuration_audit_for(developer_id);
    IF count_rows = 0 THEN RAISE EXCEPTION 'developer could not read configuration audit'; END IF;
    rejected := false;
    BEGIN PERFORM guild.manage_developer(admin_id, admin_id, true, 'self escalation');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Admin escalated to developer'; END IF;
    PERFORM guild.manage_developer(developer_id, member_id, true, 'delegation test');
    PERFORM guild.manage_developer(developer_id, member_id, false, 'delegation removed');
    rejected := false;
    BEGIN UPDATE guild.guild_settings SET new_joinee_days = 2 WHERE guild_key = guild;
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'runtime bypassed configuration helper'; END IF;

    SELECT count(*) INTO count_rows FROM guild.account_link_history_for(coleader_id, player_id);
    IF count_rows <> 1 THEN RAISE EXCEPTION 'Co-leader could not read account history'; END IF;
    rejected := false;
    BEGIN PERFORM 1 FROM guild.account_link_history_for(developer_id, player_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'developer alone could read account-link history'; END IF;
    SELECT count(*) INTO count_rows FROM guild.configuration_audit_for(developer_id)
    WHERE entity_type IN ('account_link', 'player_verification', 'metric_attribution_episode',
        'fact_clan_games_member_assessment');
    IF count_rows <> 0 THEN RAISE EXCEPTION 'configuration history exposed link or assessment rows'; END IF;
    SELECT count(*) INTO count_rows FROM guild.clan_games_results_for(leadership_id);
    IF count_rows <> 1 THEN RAISE EXCEPTION 'Leadership could not read member assessment'; END IF;
    rejected := false;
    BEGIN PERFORM 1 FROM guild.clan_games_results_for(admin_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Admin alone bypassed configured Leadership gate'; END IF;

    fetch_id := guild.request_player_refresh(member_id, player_id);
    rejected := false;
    BEGIN PERFORM guild.request_player_refresh(admin_id, player_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'staff refreshed another member account'; END IF;
    rejected := false;
    BEGIN INSERT INTO guild.fact_api_fetch_attempt (player_key, requested_by, source_correlation_id, endpoint_kind, outcome)
    VALUES (player_id, developer_id, 'bad-direct-request', 'player_profile', 'pending');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'collector manual fetch bypassed ownership trigger'; END IF;
    -- Verification is allowed before linking, and stores metadata rather than a token.
    PERFORM guild.record_player_verification(developer_id, player_id, 'rejected');

    warning_id := guild.issue_warning(member_id, admin_id, 'runtime moderation');
    SELECT count(*) INTO count_rows FROM guild.warning_history(member_id, member_id);
    IF count_rows <> 1 THEN RAISE EXCEPTION 'member could not read own warning through runtime helper'; END IF;
    rejected := false;
    BEGIN PERFORM guild.issue_warning(member_id, developer_id, 'developer is not a moderator');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'developer bypassed moderation role requirement'; END IF;

    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (admin_id, 'departure', clock_timestamp());
    IF guild.can_configure(admin_id) OR guild.can_moderate(admin_id) THEN
        RAISE EXCEPTION 'departed user retained authority from stale role projection';
    END IF;

    -- A refresh that was requested while the account was linked can still be
    -- finished after the member unlinks it. Its identity stays protected.
    PERFORM guild.unlink_player_account(member_id, player_id);
    rejected := false;
    BEGIN UPDATE guild.fact_api_fetch_attempt SET requested_by = developer_id
        WHERE fetch_key = fetch_id;
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'a refresh request was moved to another requester'; END IF;
    UPDATE guild.fact_api_fetch_attempt
    SET outcome = 'failed', http_status = 503, completed_at = clock_timestamp()
    WHERE fetch_key = fetch_id;
    IF NOT EXISTS (SELECT FROM guild.fact_api_fetch_attempt
        WHERE fetch_key = fetch_id AND outcome = 'failed' AND requested_by = member_id) THEN
        RAISE EXCEPTION 'the collector could not finish a refresh after the account was unlinked';
    END IF;
    rejected := false;
    BEGIN PERFORM guild.request_player_refresh(member_id, player_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'a refresh was requested for an unlinked account'; END IF;
END;
$$;
RESET ROLE;

DO $$
DECLARE
    rejected boolean := false;
    guild bigint;
    developer_id bigint;
    unclassified text;
BEGIN
    SELECT guild_key INTO STRICT guild FROM guild.dim_guild;
    SELECT user_key INTO developer_id FROM guild.dim_discord_user WHERE discord_user_id = 9700000000000000013;

    -- Change history covers the configuration tables and nothing else. Game
    -- and Discord activity is kept by its own fact tables, not copied.
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO unclassified
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_trigger t ON t.tgrelid = c.oid AND t.tgname = 'record_configuration_change'
    WHERE n.nspname = 'guild';
    IF unclassified IS DISTINCT FROM 'channel_binding, chat_rank_role_binding, '
        'chat_xp_eligibility_role, chat_xp_policy, clan_collection_settings, developer_allowlist, '
        'dim_clan_games_event, guild_settings, leaderboard_calendar_policy, '
        'leaderboard_metric_definition, role_binding, war_reminder_setting' THEN
        RAISE EXCEPTION 'configuration change history is attached to: %', unclassified;
    END IF;
    -- Each trigger carries its table's primary-key columns as arguments.
    -- They must match the catalog, or recorded identities would silently drift.
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO unclassified
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_trigger t ON t.tgrelid = c.oid AND t.tgname = 'record_configuration_change'
    CROSS JOIN LATERAL (
        SELECT string_to_array(encode(t.tgargs, 'escape'), '\000') AS args
    ) trigger_args
    WHERE n.nspname = 'guild'
        AND trigger_args.args[1:t.tgnargs] IS DISTINCT FROM (
            SELECT array_agg(a.attname::text ORDER BY array_position(i.indkey::smallint[], a.attnum))
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
            WHERE i.indrelid = c.oid AND i.indisprimary);
    IF unclassified IS NOT NULL THEN
        RAISE EXCEPTION 'configuration trigger out of step with the primary key on: %', unclassified;
    END IF;
    IF NOT EXISTS (SELECT FROM guild.fact_configuration_change
        WHERE entity_type = 'developer_allowlist'
            AND entity_identity = jsonb_build_object('user_key', developer_id)) THEN
        RAISE EXCEPTION 'recorded identity did not hold exactly the composite primary key';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.fact_configuration_change
        WHERE source = 'command' AND reason = 'Admin configuration test'
            AND entity_type = 'guild_settings'
            AND (previous_value ->> 'new_joinee_days') IS DISTINCT FROM '14'
            AND new_value ->> 'new_joinee_days' = '14') THEN
        RAISE EXCEPTION 'configuration command evidence missing its values before and after';
    END IF;
    -- The fixture issued a warning and linked an account. Neither is configuration.
    IF NOT EXISTS (SELECT FROM guild.warning)
        OR EXISTS (SELECT FROM guild.fact_configuration_change
            WHERE entity_type IN ('warning', 'account_link', 'player_verification',
                'fact_api_fetch_attempt', 'fact_discord_membership_event')) THEN
        RAISE EXCEPTION 'an activity row was copied into the configuration change history';
    END IF;
    BEGIN UPDATE guild.fact_configuration_change SET source = 'operator';
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'configuration change history was mutable'; END IF;
END;
$$;
ROLLBACK;
