BEGIN;
SET LOCAL plpgsql.check_asserts = on;

DO $$
DECLARE
    v_guild bigint;
    v_alice bigint;
    v_bob bigint;
    v_staff bigint;
    v_outsider bigint;
    v_clan bigint;
    v_player bigint;
    v_alt bigint;
    v_rejected_player bigint;
    v_untracked bigint;
    v_role bigint;
    v_poll bigint;
    v_verification bigint;
    v_failed_verification bigint;
    v_bob_verification bigint;
    v_transfer bigint;
    v_link bigint;
    v_first_episode bigint;
    v_bob_episode bigint;
    v_return_episode bigint;
    v_dummy_episode bigint;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id)
    VALUES (700020) RETURNING guild_key INTO v_guild;
    INSERT INTO guild.dim_discord_user (discord_user_id, display_name)
    VALUES (700021, 'Alice') RETURNING user_key INTO v_alice;
    INSERT INTO guild.dim_discord_user (discord_user_id, display_name)
    VALUES (700022, 'Bob') RETURNING user_key INTO v_bob;
    INSERT INTO guild.dim_discord_user (discord_user_id, display_name)
    VALUES (700023, 'Co-leader') RETURNING user_key INTO v_staff;
    INSERT INTO guild.dim_discord_user (discord_user_id, display_name)
    VALUES (700024, 'Member') RETURNING user_key INTO v_outsider;
    INSERT INTO guild.fact_discord_membership_event (
        guild_key, user_key, event_kind, occurred_at
    )
    SELECT v_guild, u, 'join', '2026-11-01 00:00:00+00'::timestamptz
    FROM unnest(ARRAY[v_alice, v_bob, v_staff, v_outsider]) AS u;
    INSERT INTO guild.dim_clan (clan_tag)
    VALUES ('#C0P') RETURNING clan_key INTO v_clan;
    INSERT INTO guild.dim_player_account (player_tag)
    VALUES ('#P0Y') RETURNING player_key INTO v_player;
    INSERT INTO guild.dim_player_account (player_tag)
    VALUES ('#Q0L') RETURNING player_key INTO v_alt;
    INSERT INTO guild.dim_player_account (player_tag)
    VALUES ('#R0J') RETURNING player_key INTO v_rejected_player;
    INSERT INTO guild.dim_player_account (player_tag)
    VALUES ('#G0V') RETURNING player_key INTO v_untracked;
    INSERT INTO guild.dim_discord_role (guild_key, discord_role_id, role_name)
    VALUES (v_guild, 700025, 'Co-leader') RETURNING role_key INTO v_role;
    INSERT INTO guild.server_role_binding (guild_key, purpose, role_key)
    VALUES (v_guild, 'co_leader', v_role);
    INSERT INTO guild.fact_role_change (
        guild_key, user_key, role_key, change_kind, changed_at, actor_user_key, provenance_kind
    ) VALUES (
        v_guild, v_staff, v_role, 'add', '2026-11-01 00:00:00+00', v_staff, 'manual'
    );
    INSERT INTO guild.clan_collection_settings (guild_key, clan_key)
    VALUES (v_guild, v_clan);
    INSERT INTO guild.clan_membership_poll (
        guild_key, clan_key, source_correlation_id, observed_at, outcome
    ) VALUES (
        v_guild, v_clan, 'account-link-fixture', '2026-11-01 00:00:00+00', 'complete'
    ) RETURNING poll_key INTO v_poll;
    INSERT INTO guild.fact_clan_member_observation (poll_key, player_key)
    SELECT v_poll, p FROM unnest(ARRAY[v_player, v_alt, v_rejected_player]) AS p;
    INSERT INTO guild.observed_clan_membership_period (
        guild_key, player_key, clan_key, observed_since, confirmed_through,
        boundary_policy, coverage_status, first_poll_key, last_poll_key
    )
    SELECT v_guild, p, v_clan, '2026-11-01 00:00:00+00'::timestamptz,
        '2026-11-01 00:00:00+00'::timestamptz,
        'first-complete-observation', 'adequate', v_poll, v_poll
    FROM unnest(ARRAY[v_player, v_alt, v_rejected_player]) AS p;

    INSERT INTO guild.player_verification (
        guild_key, user_key, player_key, status, checked_at
    ) VALUES (
        v_guild, v_alice, v_player, 'verified', '2026-11-02 00:00:00+00'
    ) RETURNING verification_key INTO v_verification;
    v_link := guild.link_player_account(
        v_guild, v_alice, v_player, v_verification, false, NULL, '2026-11-02 01:00:00+00'
    );
    ASSERT (SELECT is_primary FROM guild.account_link WHERE link_key = v_link),
        'The first linked account must automatically become primary';
    SELECT attribution_key INTO v_first_episode
    FROM guild.account_link WHERE link_key = v_link;
    ASSERT (SELECT include_prelink_history FROM guild.metric_attribution_episode
        WHERE attribution_key = v_first_episode), 'First-ever link must permit collected-history backfill';

    INSERT INTO guild.player_verification (
        guild_key, user_key, player_key, status, checked_at
    ) VALUES (
        v_guild, v_alice, v_alt, 'verified', '2026-11-02 02:00:00+00'
    ) RETURNING verification_key INTO v_verification;
    PERFORM guild.link_player_account(
        v_guild, v_alice, v_alt, v_verification, false, NULL, '2026-11-02 03:00:00+00'
    );
    ASSERT (SELECT count(*) = 1 FROM guild.account_link
        WHERE guild_key = v_guild AND user_key = v_alice AND is_primary AND unlinked_at IS NULL),
        'Adding an alt must not replace or duplicate the primary';

    INSERT INTO guild.player_verification (
        guild_key, user_key, player_key, status, checked_at
    ) VALUES (
        v_guild, v_alice, v_rejected_player, 'rejected', '2026-11-02 00:00:00+00'
    ) RETURNING verification_key INTO v_failed_verification;
    BEGIN
        PERFORM guild.link_player_account(
            v_guild, v_alice, v_rejected_player, v_failed_verification
        );
        RAISE EXCEPTION 'Rejected verification unexpectedly linked an account';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.player_verification (
        guild_key, user_key, player_key, status, checked_at
    ) VALUES (
        v_guild, v_alice, v_untracked, 'verified', '2026-11-02 00:00:00+00'
    ) RETURNING verification_key INTO v_verification;
    BEGIN
        PERFORM guild.link_player_account(v_guild, v_alice, v_untracked, v_verification);
        RAISE EXCEPTION 'An untracked account unexpectedly linked';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    SELECT verification_key INTO v_verification
    FROM guild.account_link WHERE player_key = v_player AND unlinked_at IS NULL;
    BEGIN
        PERFORM guild.link_player_account(
            v_guild, v_bob, v_player, v_verification, false, NULL, '2026-11-03 01:00:00+00'
        );
        RAISE EXCEPTION 'A member reused a verification proof belonging to another member';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.player_verification (
        guild_key, user_key, player_key, status, checked_at
    ) VALUES (
        v_guild, v_bob, v_player, 'verified', '2026-11-03 00:00:00+00'
    ) RETURNING verification_key INTO v_bob_verification;
    BEGIN
        PERFORM guild.link_player_account(
            v_guild, v_bob, v_player, v_bob_verification, false, NULL, '2026-11-03 01:00:00+00'
        );
        RAISE EXCEPTION 'An account transferred without staff approval';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    v_transfer := guild.request_account_transfer(
        v_guild, v_bob, v_player, v_bob_verification, '2026-11-03 01:00:00+00'
    );
    BEGIN
        PERFORM guild.decide_account_transfer(v_transfer, v_outsider, true);
        RAISE EXCEPTION 'A member without a Co-leader/Admin role approved a transfer';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    PERFORM guild.decide_account_transfer(
        v_transfer, v_staff, true, '2026-11-03 02:00:00+00'
    );
    BEGIN
        PERFORM guild.link_player_account(
            v_guild, v_bob, v_player, v_bob_verification, false, v_transfer, '2026-11-04 00:00:00+00'
        );
        RAISE EXCEPTION 'Transfer left the original member with alts but no primary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    PERFORM guild.set_primary_account(v_guild, v_alice, v_alt);
    v_link := guild.link_player_account(
        v_guild, v_bob, v_player, v_bob_verification, false, v_transfer, '2026-11-04 00:00:00+00'
    );
    SELECT attribution_key INTO v_bob_episode FROM guild.account_link WHERE link_key = v_link;
    ASSERT v_bob_episode <> v_first_episode, 'A transfer must start a new attribution episode';
    ASSERT NOT (SELECT include_prelink_history FROM guild.metric_attribution_episode
        WHERE attribution_key = v_bob_episode), 'A transfer must not inherit the first owner history';
    ASSERT (SELECT closed_at = '2026-11-04 00:00:00+00'::timestamptz
        FROM guild.metric_attribution_episode WHERE attribution_key = v_first_episode),
        'The old attribution episode must end at the transfer boundary';
    ASSERT (SELECT status = 'consumed' FROM guild.account_transfer_request
        WHERE transfer_request_key = v_transfer), 'Transfer approval must be consumed once';
    ASSERT (SELECT count(*) = 1 FROM guild.current_account_link WHERE player_key = v_player),
        'A transferred account must have exactly one current owner';
    BEGIN
        PERFORM guild.set_primary_account(v_guild, v_alice, v_player);
        RAISE EXCEPTION 'A member selected another owner account as primary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        PERFORM guild.account_link_history_for(v_guild, v_alice, v_player);
        RAISE EXCEPTION 'An ordinary member read private account-link history';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    ASSERT (SELECT count(*) = 2 FROM guild.account_link_history_for(v_guild, v_staff, v_player)),
        'Co-leaders must be able to read retained link history';
    BEGIN
        PERFORM guild.unlink_player_account(v_guild, v_alice, v_player);
        RAISE EXCEPTION 'A member unlinked somebody else account';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    PERFORM guild.unlink_player_account(
        v_guild, v_bob, v_player, NULL, '2026-11-05 00:00:00+00'
    );
    INSERT INTO guild.player_verification (
        guild_key, user_key, player_key, status, checked_at
    ) VALUES (
        v_guild, v_bob, v_player, 'verified', '2026-11-06 00:00:00+00'
    ) RETURNING verification_key INTO v_verification;
    v_link := guild.link_player_account(
        v_guild, v_bob, v_player, v_verification, false, NULL, '2026-11-06 01:00:00+00'
    );
    ASSERT (SELECT attribution_key = v_bob_episode FROM guild.account_link WHERE link_key = v_link),
        'Same-member relinking without an intervening owner must preserve metric continuity';
    PERFORM guild.unlink_player_account(
        v_guild, v_bob, v_player, NULL, '2026-11-07 00:00:00+00'
    );
    INSERT INTO guild.player_verification (
        guild_key, user_key, player_key, status, checked_at
    ) VALUES (
        v_guild, v_alice, v_player, 'verified', '2026-11-08 00:00:00+00'
    ) RETURNING verification_key INTO v_verification;
    v_link := guild.link_player_account(
        v_guild, v_alice, v_player, v_verification, false, NULL, '2026-11-08 01:00:00+00'
    );
    SELECT attribution_key INTO v_return_episode FROM guild.account_link WHERE link_key = v_link;
    ASSERT v_return_episode NOT IN (v_first_episode, v_bob_episode),
        'Returning after a different owner must start fresh, not reopen an earlier episode';
    BEGIN
        PERFORM guild.unlink_player_account(
            v_guild, v_alice, v_alt, NULL, '2026-11-09 00:00:00+00'
        );
        RAISE EXCEPTION 'A primary was unlinked without choosing a replacement';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    PERFORM guild.unlink_player_account(
        v_guild, v_alice, v_alt, v_player, '2026-11-09 00:00:00+00'
    );
    ASSERT (SELECT is_primary FROM guild.current_account_link
        WHERE guild_key = v_guild AND user_key = v_alice AND player_key = v_player),
        'The chosen replacement must become primary atomically';

    BEGIN
        UPDATE guild.account_link SET is_primary = false
        WHERE guild_key = v_guild AND user_key = v_alice AND unlinked_at IS NULL;
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Direct SQL left linked accounts without a primary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.player_verification (
        guild_key, user_key, player_key, status, checked_at
    ) VALUES (
        v_guild, v_alice, v_player, 'verified', '2026-11-10 00:00:00+00'
    ) RETURNING verification_key INTO v_verification;
    BEGIN
        INSERT INTO guild.account_link (
            guild_key, user_key, player_key, verification_key, attribution_key, linked_at, is_primary
        ) VALUES (
            v_guild, v_alice, v_player, v_verification, v_return_episode,
            '2026-11-10 01:00:00+00', false
        );
        RAISE EXCEPTION 'Direct SQL created overlapping link intervals';
    EXCEPTION WHEN exclusion_violation OR unique_violation THEN NULL;
    END;
    INSERT INTO guild.metric_attribution_episode (
        guild_key, user_key, player_key, first_link_at, include_prelink_history
    ) VALUES (
        v_guild, v_alice, v_rejected_player, '2026-11-11 00:00:00+00', true
    ) RETURNING attribution_key INTO v_dummy_episode;
    BEGIN
        INSERT INTO guild.account_link (
            guild_key, user_key, player_key, verification_key, attribution_key, linked_at, is_primary
        ) VALUES (
            v_guild, v_alice, v_rejected_player, v_failed_verification, v_dummy_episode,
            '2026-11-11 00:00:00+00', false
        );
        RAISE EXCEPTION 'Direct SQL attached a rejected verification outcome';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    ASSERT NOT EXISTS (
        SELECT FROM information_schema.columns WHERE table_schema = 'guild'
            AND table_name IN ('player_verification', 'account_link', 'account_transfer_request')
            AND column_name LIKE '%token%'
    ), 'Link and verification tables must not have a token column';
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'Account-link verification, primary, transfer, continuity and privacy assertions passed';
END;
$$;

ROLLBACK;
