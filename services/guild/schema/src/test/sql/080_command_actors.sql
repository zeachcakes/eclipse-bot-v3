BEGIN;

DO $$
DECLARE guild bigint; clan bigint; player bigint; moderator bigint; role_id bigint; poll bigint;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (799080) RETURNING guild_key INTO guild;
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (799081), (799082), (799083), (799084);
    SELECT user_key INTO moderator FROM guild.dim_discord_user WHERE discord_user_id = 799083;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    SELECT user_key, 'join', '2026-11-01 00:00:00+00'::timestamptz
    FROM guild.dim_discord_user;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#C0P') RETURNING clan_key INTO clan;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y') RETURNING player_key INTO player;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (clan);
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan, 'command-actor-poll', '2026-11-01 00:00:00+00', 'complete')
    RETURNING poll_key INTO poll;
    INSERT INTO guild.fact_clan_member_observation (poll_key, player_key) VALUES (poll, player);
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since, confirmed_through,
            boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (player, clan, '2026-11-01 00:00:00+00', '2026-11-01 00:00:00+00',
        'observed', 'adequate', poll, poll);
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (799085, 'Co-leader') RETURNING role_key INTO role_id;
    INSERT INTO guild.server_role_binding (purpose, role_key) VALUES ('co_leader', role_id);
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (moderator, role_id, 'add', '2026-11-01 01:00:00+00', 'manual');
END;
$$;

SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    guild bigint;
    alice bigint;
    bob bigint;
    moderator bigint;
    player bigint;
    proof bigint;
    transfer_id bigint;
    warning_id bigint;
    rejected boolean := false;
BEGIN
    SELECT guild_key INTO STRICT guild FROM guild.dim_guild;
    SELECT user_key INTO alice FROM guild.dim_discord_user WHERE discord_user_id = 799081;
    SELECT user_key INTO bob FROM guild.dim_discord_user WHERE discord_user_id = 799082;
    SELECT user_key INTO moderator FROM guild.dim_discord_user WHERE discord_user_id = 799083;
    SELECT player_key INTO player FROM guild.dim_player_account WHERE player_tag = '#P0Y';

    proof := guild.record_player_verification(alice, player, 'verified');
    PERFORM guild.link_player_account(alice, player, proof);
    PERFORM guild.set_primary_account(alice, player);
    proof := guild.record_player_verification(bob, player, 'verified');
    transfer_id := guild.request_account_transfer(bob, player, proof);
    PERFORM guild.decide_account_transfer(transfer_id, moderator, true);
    PERFORM guild.link_player_account(bob, player, proof, false, transfer_id);
    warning_id := guild.issue_warning(bob, moderator, 'actor issuance');
    PERFORM guild.revoke_warning(warning_id, moderator, 'actor revocation');
    PERFORM guild.unlink_player_account(bob, player);
    BEGIN
        PERFORM guild.issue_warning(bob, alice, 'no moderation role');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'a member without the moderation role issued a warning'; END IF;
    -- Member commands touch no configuration table, so they set no command
    -- actor for the configuration change history.
    IF nullif(current_setting('guild.actor_user_key', true), '') IS NOT NULL THEN
        RAISE EXCEPTION 'a member command left a configuration actor behind';
    END IF;
END;
$$;
RESET ROLE;

DO $$
DECLARE alice bigint; bob bigint; moderator bigint;
BEGIN
    SELECT user_key INTO alice FROM guild.dim_discord_user WHERE discord_user_id = 799081;
    SELECT user_key INTO bob FROM guild.dim_discord_user WHERE discord_user_id = 799082;
    SELECT user_key INTO moderator FROM guild.dim_discord_user WHERE discord_user_id = 799083;
    -- No change ledger copies these rows. Each activity row names its own actor.
    IF NOT EXISTS (SELECT FROM guild.account_transfer_request
        WHERE to_user_key = bob AND from_user_key = alice AND status = 'consumed'
            AND decided_by = moderator AND decided_at IS NOT NULL AND consumed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'transfer lost its recipient, previous owner or deciding staff member';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.account_link l
        JOIN guild.account_transfer_request t USING (transfer_request_key)
        WHERE l.user_key = bob AND t.to_user_key = bob)
        OR NOT EXISTS (SELECT FROM guild.account_link
            WHERE user_key = alice AND unlinked_at IS NOT NULL AND transfer_request_key IS NULL) THEN
        RAISE EXCEPTION 'link history lost the initial owner or the transfer that replaced it';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.warning WHERE subject_user_key = bob
        AND issued_by_user_key = moderator AND reason = 'actor issuance')
        OR NOT EXISTS (SELECT FROM guild.warning_revocation
            WHERE revoked_by_user_key = moderator AND reason = 'actor revocation') THEN
        RAISE EXCEPTION 'warning issuance/revocation lost its moderator actor';
    END IF;
    IF EXISTS (SELECT FROM guild.fact_configuration_change
        WHERE entity_type IN ('account_link', 'account_transfer_request', 'warning',
            'warning_revocation')) THEN
        RAISE EXCEPTION 'a member command was copied into the configuration change history';
    END IF;
END;
$$;
ROLLBACK;
