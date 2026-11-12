BEGIN;

-- This file walks the collector and worker paths with only the runtime
-- role's privileges, and checks what that role is refused.
DO $$
DECLARE
    g bigint; member_id bigint; developer_id bigint; role_id bigint; channel_id bigint;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (9500000000000000001) RETURNING guild_key INTO g;
    INSERT INTO guild.guild_settings (guild_key) VALUES (g);
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9500000000000000011)
    RETURNING user_key INTO member_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9500000000000000012)
    RETURNING user_key INTO developer_id;
    INSERT INTO guild.developer_allowlist (user_key) VALUES (developer_id);
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9500000000000000021, 'Eclipse') RETURNING role_key INTO role_id;
    INSERT INTO guild.chat_xp_eligibility_role (role_key) VALUES (role_id);
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (9500000000000000031, 'general') RETURNING channel_key INTO channel_id;
END;
$$;

SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    g bigint; member_id bigint; role_id bigint; channel_id bigint;
    clan_a bigint; clan_b bigint; attacker bigint; defender bigint;
    poll bigint; war bigint; achievement bigint; fetch_id bigint; raid bigint;
    operation uuid; fence uuid; dispatch uuid; award bigint;
    seen timestamptz := clock_timestamp() - interval '1 hour';
    entity text; rejected boolean;
BEGIN
    SELECT guild_key INTO STRICT g FROM guild.dim_guild;
    SELECT user_key INTO STRICT member_id FROM guild.dim_discord_user
    WHERE discord_user_id = 9500000000000000011;
    SELECT role_key INTO STRICT role_id FROM guild.dim_discord_role;
    SELECT channel_key INTO STRICT channel_id FROM guild.dim_discord_channel;

    -- Collector: dimensions, membership evidence and game observations.
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#2PP') RETURNING clan_key INTO clan_a;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#2QQ') RETURNING clan_key INTO clan_b;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#2YY') RETURNING player_key INTO attacker;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#2LL') RETURNING player_key INTO defender;
    UPDATE guild.dim_player_account SET player_name = 'Renamed' WHERE player_key = attacker;
    rejected := false;
    BEGIN
        INSERT INTO guild.clan_collection_settings (clan_key) VALUES (clan_a);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'runtime configured a tracked clan directly'; END IF;
    RESET ROLE;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (clan_a);
    SET LOCAL ROLE guild_runtime;

    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_a, 'runtime:poll', seen, 'complete') RETURNING poll_key INTO poll;
    -- Member state goes through the entry point, which stores it on change only.
    IF has_table_privilege(current_user, 'guild.fact_clan_member_observation', 'INSERT')
        OR NOT guild.record_clan_member_observation(poll, attacker, 'member', 25, 10)
        OR guild.record_clan_member_observation(poll, attacker, 'member', 25, 10) THEN
        RAISE EXCEPTION 'runtime member state did not go through its entry point exactly once';
    END IF;
    INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
    VALUES (poll, clan_a, attacker, 'observed_join', seen);
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since, confirmed_through, boundary_policy,
            coverage_status, first_poll_key, last_poll_key)
    VALUES (attacker, clan_a, seen, seen, 'runtime-test', 'adequate', poll, poll);
    IF NOT EXISTS (SELECT FROM guild.current_observed_clan_member WHERE player_key = attacker) THEN
        RAISE EXCEPTION 'runtime could not read the membership it recorded';
    END IF;
    INSERT INTO guild.fact_player_counter_observation
        (player_key, observed_at, source_correlation_id, town_hall_level, war_stars)
    VALUES (attacker, seen, 'runtime:profile', 16, 1200);
    INSERT INTO guild.dim_achievement (source_name, village) VALUES ('Games Champion', 'home')
    RETURNING achievement_key INTO achievement;
    INSERT INTO guild.fact_player_achievement_observation
        (player_key, achievement_key, observed_at, source_correlation_id, value)
    VALUES (attacker, achievement, seen, 'runtime:achievement', 5000);
    INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
        team_size, attacks_per_member, identity_source)
    VALUES (least(clan_a, clan_b), greatest(clan_a, clan_b), seen - interval '2 days',
        seen - interval '1 day', seen, 15, 2, 'clan_pair_preparation') RETURNING war_key INTO war;
    INSERT INTO guild.war_participant (war_key, clan_key, player_key)
    VALUES (war, clan_a, attacker), (war, clan_b, defender);
    INSERT INTO guild.fact_war_clan_observation
        (war_key, clan_key, observed_at, source_correlation_id, state, stars, attacks, destruction_percentage)
    VALUES (war, clan_a, seen, 'runtime:war', 'warEnded', 3, 1, 100);
    INSERT INTO guild.fact_war_attack (war_key, attacker_key, defender_key, attack_order, stars,
        destruction_percentage, first_observed_at, last_observed_at, source_correlation_id)
    VALUES (war, attacker, defender, 1, 3, 100, seen, seen, 'runtime:attack');
    UPDATE guild.fact_war_attack SET last_observed_at = seen + interval '1 minute' WHERE war_key = war;
    INSERT INTO guild.dim_raid_weekend (clan_key, starts_at, ends_at)
    VALUES (clan_a, seen - interval '3 days', seen) RETURNING raid_weekend_key INTO raid;
    INSERT INTO guild.fact_raid_member_observation
        (raid_weekend_key, player_key, observed_at, source_correlation_id, capital_resources_looted)
    VALUES (raid, attacker, seen, 'runtime:raid', 12000);
    INSERT INTO guild.fact_api_fetch_attempt (player_key, source_correlation_id, endpoint_kind, started_at, outcome)
    VALUES (attacker, 'runtime:fetch', 'player_profile', seen, 'pending')
    RETURNING fetch_key INTO fetch_id;
    UPDATE guild.fact_api_fetch_attempt
    SET outcome = 'succeeded', http_status = 200, completed_at = seen + interval '1 second'
    WHERE fetch_key = fetch_id;
    IF (SELECT position FROM guild.current_clan_lifetime_war_stars WHERE player_key = attacker) <> 1 THEN
        RAISE EXCEPTION 'runtime could not read the lifetime war-star board';
    END IF;

    -- Collector: Discord membership and confirmed roles, then the XP entry point.
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (member_id, 'join', seen);
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (member_id, role_id, 'add', seen + interval '1 minute', 'manual');
    award := guild.credit_chat_xp(member_id, channel_id, 9500000000000000041, clock_timestamp());
    IF award IS NULL THEN RAISE EXCEPTION 'runtime could not credit an eligible message'; END IF;
    IF (SELECT xp_total FROM guild.chat_xp_all_time_totals WHERE user_key = member_id) NOT BETWEEN 15 AND 25 THEN
        RAISE EXCEPTION 'runtime could not read the credited XP total';
    END IF;
    PERFORM guild.ensure_leaderboard_monthly_period();
    IF NOT EXISTS (SELECT FROM guild.current_chat_xp_monthly_leaderboard WHERE user_key = member_id) THEN
        RAISE EXCEPTION 'runtime could not read the current monthly board';
    END IF;

    -- Workers: outbox publication, consumption, one send permit and its result.
    operation := guild.queue_notification_ping('runtime:welcome', 'welcome', channel_id,
        clock_timestamp() - interval '1 minute', clock_timestamp() + interval '1 hour');
    fence := guild.claim_notification_publication(operation, 'runtime-worker');
    PERFORM guild.finish_notification_publication(operation, fence, 'published', 'guild.notifications', 0, 1);
    IF NOT guild.record_notification_consumption(operation, 'delivery', 'guild.notifications', 0, 1) THEN
        RAISE EXCEPTION 'first Kafka receipt was not recognised';
    END IF;
    dispatch := guild.claim_notification_dispatch(operation, 'runtime-worker');
    IF dispatch IS NULL OR NOT guild.begin_notification_send(operation, dispatch) THEN
        RAISE EXCEPTION 'runtime worker could not obtain its send permit';
    END IF;
    PERFORM guild.record_notification_result(operation, dispatch, 'succeeded', 9500000000000000051, 200);
    IF (SELECT status FROM guild.notification_operation WHERE operation_key = operation) <> 'delivered' THEN
        RAISE EXCEPTION 'runtime could not read the delivered operation';
    END IF;
    PERFORM count(*) FROM guild.pending_moderation_action;

    -- None of the above may open the private ledgers or the internals.
    FOREACH entity IN ARRAY ARRAY['warning', 'moderation_action', 'account_link',
        'account_transfer_request', 'fact_configuration_change', 'developer_allowlist'] LOOP
        rejected := false;
        BEGIN EXECUTE format('SELECT FROM guild.%I', entity);
        EXCEPTION WHEN insufficient_privilege THEN rejected := true;
        END;
        IF NOT rejected THEN RAISE EXCEPTION 'runtime read private table %', entity; END IF;
    END LOOP;
    FOREACH entity IN ARRAY ARRAY[
        'UPDATE guild.notification_operation SET status = ''delivered''',
        'INSERT INTO guild.discord_member_role SELECT * FROM guild.discord_member_role',
        'DELETE FROM guild.fact_war_attack',
        'SELECT guild._expire_account_transfers(clock_timestamp())',
        'SELECT guild.account_transfer_expires_at(1)',
        'SELECT guild.cancel_open_account_transfers(1, clock_timestamp())'] LOOP
        rejected := false;
        BEGIN EXECUTE entity;
        EXCEPTION WHEN insufficient_privilege THEN rejected := true;
        END;
        IF NOT rejected THEN RAISE EXCEPTION 'runtime was allowed to run: %', entity; END IF;
    END LOOP;
END;
$$;
RESET ROLE;

DO $$
DECLARE
    g bigint; developer_id bigint; cycle bigint; replayed bigint; rejected boolean := false;
BEGIN
    SELECT guild_key INTO STRICT g FROM guild.dim_guild;
    SELECT user_key INTO STRICT developer_id FROM guild.dim_discord_user
    WHERE discord_user_id = 9500000000000000012;

    -- A replayed command returns its stored result even after the actor lost
    -- the permission that the first attempt needed.
    cycle := guild.cwl_create_cycle(developer_id, '00000000-0000-4000-8000-000000001501',
        '2027-03-01');
    DELETE FROM guild.developer_allowlist WHERE user_key = developer_id;
    replayed := guild.cwl_create_cycle(developer_id, '00000000-0000-4000-8000-000000001501',
        '2027-03-01');
    IF replayed IS DISTINCT FROM cycle THEN
        RAISE EXCEPTION 'command replay returned % instead of its stored result %', replayed, cycle;
    END IF;
    BEGIN
        PERFORM guild.cwl_create_cycle(developer_id, '00000000-0000-4000-8000-000000001502',
            '2027-04-01');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'a new command ran without its permission'; END IF;

    -- The schedule cannot name a day that some months do not have, and a
    -- disabled schedule is reported as such.
    rejected := false;
    BEGIN UPDATE guild.guild_settings SET clan_games_start_day = 29 WHERE guild_key = g;
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'a start day missing from February was accepted'; END IF;
    PERFORM guild.create_scheduled_clan_games(2027, 2);
    UPDATE guild.guild_settings SET clan_games_enabled = false WHERE guild_key = g;
    rejected := false;
    BEGIN PERFORM guild.create_scheduled_clan_games(2027, 3);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'a disabled schedule did not report a clear error'; END IF;

    -- The XP policy catalog is not an editable setting: no runtime entry point
    -- writes it or selects another policy.
    IF EXISTS (SELECT FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'guild' AND p.proname LIKE '%xp_policy%'
            AND has_function_privilege('guild_runtime', p.oid, 'EXECUTE')) THEN
        RAISE EXCEPTION 'the XP policy catalog was offered as a setting';
    END IF;

    -- No function is executable by PUBLIC, and new ones start private.
    IF EXISTS (SELECT FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'guild' AND has_function_privilege('public', p.oid, 'EXECUTE')) THEN
        RAISE EXCEPTION 'a guild function is executable by PUBLIC';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_default_acl d
        JOIN pg_catalog.pg_namespace n ON n.nspname = 'guild' AND n.nspowner = d.defaclrole
        WHERE d.defaclnamespace = 0 AND d.defaclobjtype = 'f'
            AND NOT EXISTS (SELECT FROM aclexplode(d.defaclacl) a WHERE a.grantee = 0)) THEN
        RAISE EXCEPTION 'the schema owner still grants EXECUTE on new functions to PUBLIC';
    END IF;
END;
$$;
ROLLBACK;
