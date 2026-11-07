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
    INSERT INTO guild.developer_allowlist (guild_key, user_key) VALUES (guild, developer_id);
    FOR item IN SELECT * FROM (VALUES
        ('admin', 9700000000000000012::numeric, 9700000000000000021::numeric),
        ('leadership', 9700000000000000014::numeric, 9700000000000000022::numeric),
        ('co_leader', 9700000000000000015::numeric, 9700000000000000023::numeric)
    ) AS roles(purpose, user_id, role_snowflake) LOOP
        INSERT INTO guild.dim_discord_role (guild_key, discord_role_id, role_name)
        VALUES (guild, item.role_snowflake, item.purpose) RETURNING role_key INTO role_id;
        INSERT INTO guild.server_role_binding (guild_key, purpose, role_key)
        VALUES (guild, item.purpose, role_id);
        INSERT INTO guild.fact_role_change
            (guild_key, user_key, role_key, change_kind, changed_at, provenance_kind)
        SELECT guild, user_key, role_id, 'add', clock_timestamp(), 'manual'
        FROM guild.dim_discord_user WHERE discord_user_id = item.user_id;
    END LOOP;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y') RETURNING player_key INTO player_id;
    verification_id := guild.record_player_verification(guild, member_id, player_id, 'verified');
    INSERT INTO guild.metric_attribution_episode
        (guild_key, user_key, player_key, first_link_at, include_prelink_history)
    VALUES (guild, member_id, player_id, clock_timestamp(), true)
    RETURNING attribution_key INTO attribution_id;
    INSERT INTO guild.account_link
        (guild_key, user_key, player_key, verification_key, attribution_key, is_primary)
    VALUES (guild, member_id, player_id, verification_id, attribution_id, true);
    INSERT INTO guild.dim_clan_games_event
        (guild_key, starts_at, ends_at, account_points_cap, schedule_source, source_correlation_id)
    VALUES (guild, '2026-11-22 08:00:00+00', '2026-11-28 08:00:00+00', 4000,
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

    FOREACH entity IN ARRAY ARRAY['fact_configuration_change', 'fact_change_audit',
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

    PERFORM guild.configure_setting(guild, admin_id, 'guild_settings',
        '{"new_joinee_days":14}'::jsonb, 'Admin configuration test');
    IF (SELECT new_joinee_days FROM guild.guild_settings WHERE guild_key = guild) <> 14 THEN
        RAISE EXCEPTION 'authorized Admin command did not configure typed row';
    END IF;
    rejected := false;
    BEGIN PERFORM guild.configure_setting(guild, member_id, 'guild_settings',
        '{"new_joinee_days":1}'::jsonb, 'unauthorized');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'ordinary member configured settings'; END IF;
    rejected := false;
    BEGIN PERFORM 1 FROM guild.configuration_audit_for(guild, admin_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Admin configuration permission exposed developer audit'; END IF;
    SELECT count(*) INTO count_rows FROM guild.configuration_audit_for(guild, developer_id);
    IF count_rows = 0 THEN RAISE EXCEPTION 'developer could not read configuration audit'; END IF;
    rejected := false;
    BEGIN PERFORM guild.manage_developer(guild, admin_id, admin_id, true, 'self escalation');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Admin escalated to developer'; END IF;
    PERFORM guild.manage_developer(guild, developer_id, member_id, true, 'delegation test');
    PERFORM guild.manage_developer(guild, developer_id, member_id, false, 'delegation removed');
    rejected := false;
    BEGIN UPDATE guild.guild_settings SET new_joinee_days = 2 WHERE guild_key = guild;
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'runtime bypassed configuration helper'; END IF;

    SELECT count(*) INTO count_rows FROM guild.account_link_history_for(guild, coleader_id, player_id);
    IF count_rows <> 1 THEN RAISE EXCEPTION 'Co-leader could not read account history'; END IF;
    rejected := false;
    BEGIN PERFORM 1 FROM guild.account_link_history_for(guild, developer_id, player_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'developer alone could read account-link history'; END IF;
    SELECT count(*) INTO count_rows FROM guild.change_audit_for(guild, developer_id)
    WHERE entity_type IN ('account_link', 'player_verification', 'metric_attribution_episode',
        'fact_clan_games_member_assessment');
    IF count_rows <> 0 THEN RAISE EXCEPTION 'general audit bypassed link or assessment visibility'; END IF;
    SELECT count(*) INTO count_rows FROM guild.clan_games_results_for(guild, leadership_id);
    IF count_rows <> 1 THEN RAISE EXCEPTION 'Leadership could not read member assessment'; END IF;
    rejected := false;
    BEGIN PERFORM 1 FROM guild.clan_games_results_for(guild, admin_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Admin alone bypassed configured Leadership gate'; END IF;

    PERFORM guild.request_player_refresh(guild, member_id, player_id);
    rejected := false;
    BEGIN PERFORM guild.request_player_refresh(guild, admin_id, player_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'staff refreshed another member account'; END IF;
    rejected := false;
    BEGIN INSERT INTO guild.fact_api_fetch_attempt
        (guild_key, player_key, requested_by, source_correlation_id, endpoint_kind, outcome)
    VALUES (guild, player_id, developer_id, 'bad-direct-request', 'player_profile', 'pending');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'collector manual fetch bypassed ownership trigger'; END IF;
    -- Verification is allowed before linking, and stores metadata rather than a token.
    PERFORM guild.record_player_verification(guild, developer_id, player_id, 'rejected');

    warning_id := guild.issue_warning(guild, member_id, admin_id, 'runtime moderation');
    SELECT count(*) INTO count_rows FROM guild.warning_history(guild, member_id, member_id);
    IF count_rows <> 1 THEN RAISE EXCEPTION 'member could not read own warning through runtime helper'; END IF;
    rejected := false;
    BEGIN PERFORM guild.issue_warning(guild, member_id, developer_id, 'developer is not a moderator');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'developer bypassed moderation role requirement'; END IF;

    INSERT INTO guild.fact_discord_membership_event
        (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, admin_id, 'departure', clock_timestamp());
    IF guild.can_configure(guild, admin_id) OR guild.can_moderate(guild, admin_id) THEN
        RAISE EXCEPTION 'departed user retained authority from stale role projection';
    END IF;
END;
$$;
RESET ROLE;

DO $$
DECLARE rejected boolean := false;
BEGIN
    IF NOT EXISTS (SELECT FROM guild.fact_configuration_change
        WHERE source = 'command' AND reason = 'Admin configuration test') THEN
        RAISE EXCEPTION 'configuration command audit evidence missing';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.fact_change_audit
        WHERE entity_type = 'warning' AND operation = 'INSERT') THEN
        RAISE EXCEPTION 'system/domain stored changes were not audited';
    END IF;
    BEGIN UPDATE guild.fact_change_audit SET source = 'operator';
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'common audit was mutable'; END IF;
END;
$$;
ROLLBACK;
