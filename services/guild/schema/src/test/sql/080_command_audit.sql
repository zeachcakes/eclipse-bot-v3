BEGIN;

DO $$
DECLARE guild bigint; clan bigint; player bigint; moderator bigint; role_id bigint; poll bigint;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (799080) RETURNING guild_key INTO guild;
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (799081), (799082), (799083), (799084);
    SELECT user_key INTO moderator FROM guild.dim_discord_user WHERE discord_user_id = 799083;
    INSERT INTO guild.fact_discord_membership_event (guild_key, user_key, event_kind, occurred_at)
    SELECT guild, user_key, 'join', '2026-11-01 00:00:00+00'::timestamptz
    FROM guild.dim_discord_user;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#C0P') RETURNING clan_key INTO clan;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y') RETURNING player_key INTO player;
    INSERT INTO guild.clan_collection_settings (guild_key, clan_key) VALUES (guild, clan);
    INSERT INTO guild.clan_membership_poll
        (guild_key, clan_key, source_correlation_id, observed_at, outcome)
    VALUES (guild, clan, 'command-actor-poll', '2026-11-01 00:00:00+00', 'complete')
    RETURNING poll_key INTO poll;
    INSERT INTO guild.fact_clan_member_observation (poll_key, player_key) VALUES (poll, player);
    INSERT INTO guild.observed_clan_membership_period
        (guild_key, player_key, clan_key, observed_since, confirmed_through,
            boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (guild, player, clan, '2026-11-01 00:00:00+00', '2026-11-01 00:00:00+00',
        'observed', 'adequate', poll, poll);
    INSERT INTO guild.dim_discord_role (guild_key, discord_role_id, role_name)
    VALUES (guild, 799085, 'Co-leader') RETURNING role_key INTO role_id;
    INSERT INTO guild.server_role_binding (guild_key, purpose, role_key) VALUES (guild, 'co_leader', role_id);
    INSERT INTO guild.fact_role_change
        (guild_key, user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (guild, moderator, role_id, 'add', '2026-11-01 01:00:00+00', 'manual');
END;
$$;

SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    guild bigint;
    alice bigint;
    bob bigint;
    moderator bigint;
    collector bigint;
    player bigint;
    proof bigint;
    transfer_id bigint;
    warning_id bigint;
    count_functions bigint;
    rejected boolean := false;
BEGIN
    SELECT guild_key INTO STRICT guild FROM guild.dim_guild;
    SELECT user_key INTO alice FROM guild.dim_discord_user WHERE discord_user_id = 799081;
    SELECT user_key INTO bob FROM guild.dim_discord_user WHERE discord_user_id = 799082;
    SELECT user_key INTO moderator FROM guild.dim_discord_user WHERE discord_user_id = 799083;
    SELECT user_key INTO collector FROM guild.dim_discord_user WHERE discord_user_id = 799084;
    SELECT player_key INTO player FROM guild.dim_player_account WHERE player_tag = '#P0Y';
    PERFORM set_config('guild.actor_user_key', collector::text, true);
    PERFORM set_config('guild.change_source', 'collector', true);

    proof := guild.record_player_verification(guild, alice, player, 'verified');
    PERFORM guild.link_player_account(guild, alice, player, proof);
    PERFORM guild.set_primary_account(guild, alice, player);
    proof := guild.record_player_verification(guild, bob, player, 'verified');
    transfer_id := guild.request_account_transfer(guild, bob, player, proof);
    PERFORM guild.decide_account_transfer(transfer_id, moderator, true);
    PERFORM guild.link_player_account(guild, bob, player, proof, false, transfer_id);
    warning_id := guild.issue_warning(guild, bob, moderator, 'actor issuance');
    PERFORM guild.revoke_warning(warning_id, moderator, 'actor revocation');
    PERFORM guild.unlink_player_account(guild, bob, player);
    IF current_setting('guild.actor_user_key') <> collector::text
        OR current_setting('guild.change_source') <> 'collector' THEN
        RAISE EXCEPTION 'command context leaked over the previous collector context';
    END IF;
    BEGIN
        PERFORM guild.issue_warning(guild, bob, alice, 'no moderation role');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'wrapper bypassed command authorization'; END IF;
    IF current_setting('guild.actor_user_key') <> collector::text
        OR current_setting('guild.change_source') <> 'collector' THEN
        RAISE EXCEPTION 'failed command leaked its actor context';
    END IF;
    SELECT count(*) INTO count_functions FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'guild' AND p.proname LIKE '\_command\_%'
        AND has_function_privilege('guild_runtime', p.oid, 'EXECUTE');
    IF count_functions <> 0 THEN RAISE EXCEPTION 'runtime could bypass a command wrapper'; END IF;
    rejected := false;
    BEGIN
        PERFORM guild._command_issue_warning(guild, bob, moderator, 'private bypass');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'private implementation remained callable'; END IF;
    PERFORM set_config('guild.actor_user_key', '', true);
    PERFORM set_config('guild.change_source', '', true);
END;
$$;
RESET ROLE;

DO $$
DECLARE alice bigint; bob bigint; moderator bigint;
BEGIN
    SELECT user_key INTO alice FROM guild.dim_discord_user WHERE discord_user_id = 799081;
    SELECT user_key INTO bob FROM guild.dim_discord_user WHERE discord_user_id = 799082;
    SELECT user_key INTO moderator FROM guild.dim_discord_user WHERE discord_user_id = 799083;
    IF NOT EXISTS (SELECT FROM guild.fact_change_audit WHERE entity_type = 'account_link'
        AND operation = 'UPDATE' AND source = 'command' AND actor_user_key = bob
        AND (previous_value ->> 'user_key')::bigint = alice
        AND previous_value ->> 'unlinked_at' IS NULL AND new_value ->> 'unlinked_at' IS NOT NULL) THEN
        RAISE EXCEPTION 'transfer closure was not attributed to the requesting recipient';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.fact_change_audit WHERE entity_type = 'account_transfer_request'
        AND source = 'command' AND actor_user_key = moderator AND new_value ->> 'status' = 'approved') THEN
        RAISE EXCEPTION 'transfer approval lost its staff actor';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.fact_change_audit WHERE entity_type = 'account_link'
        AND operation = 'INSERT' AND source = 'command' AND actor_user_key = alice) THEN
        RAISE EXCEPTION 'initial link lost its member actor';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.fact_change_audit WHERE entity_type = 'warning'
        AND source = 'command' AND actor_user_key = moderator)
        OR NOT EXISTS (SELECT FROM guild.fact_change_audit WHERE entity_type = 'warning_revocation'
            AND source = 'command' AND actor_user_key = moderator) THEN
        RAISE EXCEPTION 'warning issuance/revocation lost its moderator actor';
    END IF;
END;
$$;
ROLLBACK;
