BEGIN;
SET LOCAL plpgsql.check_asserts = on;

-- The fixtures below run as guild_runtime, the role of the backend. Between
-- RESET ROLE and the next SET LOCAL ROLE the database administrator runs what
-- that role may not: configuration, private-ledger fixtures, and checks that
-- read a private ledger.
SET LOCAL ROLE guild_runtime;
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
    v_other_verification bigint;
    v_competing_transfer bigint;
    v_pending_transfer bigint;
    v_approved_transfer bigint;
BEGIN
    RESET ROLE;
    INSERT INTO guild.dim_guild (discord_guild_id)
    VALUES (700020) RETURNING guild_key INTO v_guild;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_user (discord_user_id, display_name)
    VALUES (700021, 'Alice') RETURNING user_key INTO v_alice;
    INSERT INTO guild.dim_discord_user (discord_user_id, display_name)
    VALUES (700022, 'Bob') RETURNING user_key INTO v_bob;
    INSERT INTO guild.dim_discord_user (discord_user_id, display_name)
    VALUES (700023, 'Co-leader') RETURNING user_key INTO v_staff;
    INSERT INTO guild.dim_discord_user (discord_user_id, display_name)
    VALUES (700024, 'Member') RETURNING user_key INTO v_outsider;
    INSERT INTO guild.fact_discord_membership_event (
        user_key, event_kind, occurred_at
    )
    SELECT u, 'join', '2026-11-01 00:00:00+00'::timestamptz
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
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (700025, 'Co-leader') RETURNING role_key INTO v_role;
    RESET ROLE;
    INSERT INTO guild.server_role_binding (purpose, role_key)
    VALUES ('co_leader', v_role);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_role_change (
        user_key, role_key, change_kind, changed_at, actor_user_key, provenance_kind
    ) VALUES (
        v_staff, v_role, 'add', '2026-11-01 00:00:00+00', v_staff, 'manual'
    );
    RESET ROLE;
    INSERT INTO guild.clan_collection_settings (clan_key)
    VALUES (v_clan);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.clan_membership_poll (
        clan_key, source_correlation_id, observed_at, outcome
    ) VALUES (
        v_clan, 'account-link-fixture', '2026-11-01 00:00:00+00', 'complete'
    ) RETURNING poll_key INTO v_poll;
    PERFORM guild.record_clan_member_observation(v_poll, p, 'member', 0, 0)
    FROM unnest(ARRAY[v_player, v_alt, v_rejected_player]) AS p;
    INSERT INTO guild.observed_clan_membership_period (
        player_key, clan_key, observed_since, confirmed_through,
        boundary_policy, coverage_status, first_poll_key, last_poll_key
    )
    SELECT p, v_clan, '2026-11-01 00:00:00+00'::timestamptz,
        '2026-11-01 00:00:00+00'::timestamptz,
        'first-complete-observation', 'adequate', v_poll, v_poll
    FROM unnest(ARRAY[v_player, v_alt, v_rejected_player]) AS p;

    RESET ROLE;
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_alice, v_player, 'verified', '2026-11-02 00:50:00+00'
    ) RETURNING verification_key INTO v_verification;
    SET LOCAL ROLE guild_runtime;
    v_link := guild.link_player_account(v_alice, v_player, v_verification, false, NULL, '2026-11-02 01:00:00+00'
    );
    RESET ROLE;
    ASSERT (SELECT is_primary FROM guild.account_link WHERE link_key = v_link),
        'The first linked account must automatically become primary';
    SELECT attribution_key INTO v_first_episode
    FROM guild.account_link WHERE link_key = v_link;
    ASSERT (SELECT include_prelink_history FROM guild.metric_attribution_episode
        WHERE attribution_key = v_first_episode), 'First-ever link must permit collected-history backfill';

    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_alice, v_alt, 'verified', '2026-11-02 02:50:00+00'
    ) RETURNING verification_key INTO v_verification;
    SET LOCAL ROLE guild_runtime;
    PERFORM guild.link_player_account(v_alice, v_alt, v_verification, false, NULL, '2026-11-02 03:00:00+00'
    );
    RESET ROLE;
    ASSERT (SELECT count(*) = 1 FROM guild.account_link
        WHERE user_key = v_alice AND is_primary AND unlinked_at IS NULL),
        'Adding an alt must not replace or duplicate the primary';

    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_alice, v_rejected_player, 'rejected', '2026-11-02 00:00:00+00'
    ) RETURNING verification_key INTO v_failed_verification;
    SET LOCAL ROLE guild_runtime;
    BEGIN
        PERFORM guild.link_player_account(v_alice, v_rejected_player, v_failed_verification
        );
        RAISE EXCEPTION 'Rejected verification unexpectedly linked an account';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RESET ROLE;
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_alice, v_untracked, 'verified', '2026-11-02 00:00:00+00'
    ) RETURNING verification_key INTO v_verification;
    SET LOCAL ROLE guild_runtime;
    BEGIN
        PERFORM guild.link_player_account(v_alice, v_untracked, v_verification);
        RAISE EXCEPTION 'An untracked account unexpectedly linked';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    RESET ROLE;
    SELECT verification_key INTO v_verification
    FROM guild.account_link WHERE player_key = v_player AND unlinked_at IS NULL;
    SET LOCAL ROLE guild_runtime;
    BEGIN
        PERFORM guild.link_player_account(v_bob, v_player, v_verification, false, NULL, '2026-11-03 01:00:00+00'
        );
        RAISE EXCEPTION 'A member reused a verification proof belonging to another member';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RESET ROLE;
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_bob, v_player, 'verified', '2026-11-03 00:50:00+00'
    ) RETURNING verification_key INTO v_bob_verification;
    SET LOCAL ROLE guild_runtime;
    BEGIN
        PERFORM guild.link_player_account(v_bob, v_player, v_bob_verification, false, NULL, '2026-11-03 01:00:00+00'
        );
        RAISE EXCEPTION 'An account transferred without staff approval';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    v_transfer := guild.request_account_transfer(v_bob, v_player, v_bob_verification, '2026-11-03 01:00:00+00'
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
        PERFORM guild.link_player_account(v_bob, v_player, v_bob_verification, false, v_transfer, '2026-11-04 00:00:00+00'
        );
        RAISE EXCEPTION 'Transfer left the original member with alts but no primary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    PERFORM guild.set_primary_account(v_alice, v_alt);
    -- A second recipient asks for the same source link before Bob's transfer completes.
    RESET ROLE;
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_outsider, v_player, 'verified', '2026-11-03 02:50:00+00'
    ) RETURNING verification_key INTO v_other_verification;
    SET LOCAL ROLE guild_runtime;
    v_competing_transfer := guild.request_account_transfer(v_outsider, v_player, v_other_verification, '2026-11-03 03:00:00+00'
    );
    v_link := guild.link_player_account(v_bob, v_player, v_bob_verification, false, v_transfer, '2026-11-04 00:00:00+00'
    );
    RESET ROLE;
    ASSERT (SELECT status = 'cancelled' AND cancelled_at = '2026-11-04 00:00:00+00'::timestamptz
            AND decided_by IS NULL
        FROM guild.account_transfer_request WHERE transfer_request_key = v_competing_transfer),
        'A completed transfer must cancel other open requests for the ended source link';
    SET LOCAL ROLE guild_runtime;
    BEGIN
        PERFORM guild.decide_account_transfer(v_competing_transfer, v_staff, true);
        RAISE EXCEPTION 'A cancelled transfer request was decided';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RESET ROLE;
    SELECT attribution_key INTO v_bob_episode FROM guild.account_link WHERE link_key = v_link;
    SET LOCAL ROLE guild_runtime;
    ASSERT v_bob_episode <> v_first_episode, 'A transfer must start a new attribution episode';
    RESET ROLE;
    ASSERT NOT (SELECT include_prelink_history FROM guild.metric_attribution_episode
        WHERE attribution_key = v_bob_episode), 'A transfer must not inherit the first owner history';
    ASSERT (SELECT closed_at = '2026-11-04 00:00:00+00'::timestamptz
        FROM guild.metric_attribution_episode WHERE attribution_key = v_first_episode),
        'The old attribution episode must end at the transfer boundary';
    ASSERT (SELECT status = 'consumed' FROM guild.account_transfer_request
        WHERE transfer_request_key = v_transfer), 'Transfer approval must be consumed once';
    SET LOCAL ROLE guild_runtime;
    ASSERT (SELECT count(*) = 1 FROM guild.current_account_link WHERE player_key = v_player),
        'A transferred account must have exactly one current owner';
    BEGIN
        PERFORM guild.set_primary_account(v_alice, v_player);
        RAISE EXCEPTION 'A member selected another owner account as primary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        PERFORM guild.account_link_history_for(v_alice, v_player);
        RAISE EXCEPTION 'An ordinary member read private account-link history';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    ASSERT (SELECT count(*) = 2 FROM guild.account_link_history_for(v_staff, v_player)),
        'Co-leaders must be able to read retained link history';
    BEGIN
        PERFORM guild.unlink_player_account(v_alice, v_player);
        RAISE EXCEPTION 'A member unlinked somebody else account';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Open requests against Bob's link: one still pending, one already approved.
    RESET ROLE;
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_alice, v_player, 'verified', '2026-11-04 12:50:00+00'
    ) RETURNING verification_key INTO v_verification;
    SET LOCAL ROLE guild_runtime;
    -- The outsider's proof from the day before is too old for a new request.
    BEGIN
        PERFORM guild.request_account_transfer(v_outsider, v_player, v_other_verification, '2026-11-04 13:00:00+00'
        );
        RAISE EXCEPTION 'A stale verification started a transfer request';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RESET ROLE;
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_outsider, v_player, 'verified', '2026-11-04 12:55:00+00'
    ) RETURNING verification_key INTO v_other_verification;
    SET LOCAL ROLE guild_runtime;
    v_pending_transfer := guild.request_account_transfer(v_alice, v_player, v_verification, '2026-11-04 13:00:00+00'
    );
    v_approved_transfer := guild.request_account_transfer(v_outsider, v_player, v_other_verification, '2026-11-04 13:00:00+00'
    );
    PERFORM guild.decide_account_transfer(
        v_approved_transfer, v_staff, true, '2026-11-04 14:00:00+00'
    );
    PERFORM guild.unlink_player_account(v_bob, v_player, NULL, '2026-11-05 00:00:00+00'
    );
    RESET ROLE;
    ASSERT (SELECT count(*) = 2 FROM guild.account_transfer_request
        WHERE transfer_request_key IN (v_pending_transfer, v_approved_transfer)
            AND status = 'cancelled' AND cancelled_at = '2026-11-05 00:00:00+00'::timestamptz),
        'Unlinking must cancel every open transfer request for the ended link';
    ASSERT (SELECT decided_by = v_staff AND decided_at = '2026-11-04 14:00:00+00'::timestamptz
        FROM guild.account_transfer_request WHERE transfer_request_key = v_approved_transfer),
        'Cancellation must keep the earlier approval as history';
    ASSERT NOT EXISTS (SELECT FROM guild.account_transfer_request
        WHERE player_key = v_player AND status IN ('pending', 'approved', 'awaiting_points')),
        'No open transfer request may outlive its source link';
    ASSERT (SELECT status = 'consumed' FROM guild.account_transfer_request
        WHERE transfer_request_key = v_transfer), 'A consumed transfer must never be cancelled';
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_bob, v_player, 'verified', '2026-11-05 23:00:00+00'
    ) RETURNING verification_key INTO v_verification;
    SET LOCAL ROLE guild_runtime;
    -- Two hours is past the default fifteen-minute limit.
    BEGIN
        PERFORM guild.link_player_account(v_bob, v_player, v_verification, false, NULL, '2026-11-06 01:00:00+00'
        );
        RAISE EXCEPTION 'A stale verification created a link';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RESET ROLE;
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_bob, v_player, 'verified', '2026-11-06 00:50:00+00'
    ) RETURNING verification_key INTO v_verification;
    -- The limit is a guild setting: a shorter one rejects this ten-minute-old proof.
    INSERT INTO guild.guild_settings (guild_key, verification_max_age_seconds)
    VALUES (v_guild, 300)
    ON CONFLICT (guild_key) DO UPDATE SET verification_max_age_seconds = 300;
    SET LOCAL ROLE guild_runtime;
    BEGIN
        PERFORM guild.link_player_account(v_bob, v_player, v_verification, false, NULL, '2026-11-06 01:00:00+00'
        );
        RAISE EXCEPTION 'The configured verification limit was ignored';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RESET ROLE;
    UPDATE guild.guild_settings SET verification_max_age_seconds = 900 WHERE guild_key = v_guild;
    SET LOCAL ROLE guild_runtime;
    v_link := guild.link_player_account(v_bob, v_player, v_verification, false, NULL, '2026-11-06 01:00:00+00'
    );
    RESET ROLE;
    ASSERT (SELECT attribution_key = v_bob_episode FROM guild.account_link WHERE link_key = v_link),
        'Same-member relinking without an intervening owner must preserve metric continuity';
    SET LOCAL ROLE guild_runtime;
    PERFORM guild.unlink_player_account(v_bob, v_player, NULL, '2026-11-07 00:00:00+00'
    );
    RESET ROLE;
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_alice, v_player, 'verified', '2026-11-08 00:50:00+00'
    ) RETURNING verification_key INTO v_verification;
    SET LOCAL ROLE guild_runtime;
    v_link := guild.link_player_account(v_alice, v_player, v_verification, false, NULL, '2026-11-08 01:00:00+00'
    );
    RESET ROLE;
    SELECT attribution_key INTO v_return_episode FROM guild.account_link WHERE link_key = v_link;
    SET LOCAL ROLE guild_runtime;
    ASSERT v_return_episode NOT IN (v_first_episode, v_bob_episode),
        'Returning after a different owner must start fresh, not reopen an earlier episode';
    BEGIN
        PERFORM guild.unlink_player_account(v_alice, v_alt, NULL, '2026-11-09 00:00:00+00'
        );
        RAISE EXCEPTION 'A primary was unlinked without choosing a replacement';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    PERFORM guild.unlink_player_account(v_alice, v_alt, v_player, '2026-11-09 00:00:00+00'
    );
    ASSERT (SELECT is_primary FROM guild.current_account_link
        WHERE user_key = v_alice AND player_key = v_player),
        'The chosen replacement must become primary atomically';

    BEGIN
        RESET ROLE;
        UPDATE guild.account_link SET is_primary = false
        WHERE user_key = v_alice AND unlinked_at IS NULL;
        SET LOCAL ROLE guild_runtime;
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Direct SQL left linked accounts without a primary';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RESET ROLE;
    INSERT INTO guild.player_verification (
        user_key, player_key, status, checked_at
    ) VALUES (
        v_alice, v_player, 'verified', '2026-11-10 00:00:00+00'
    ) RETURNING verification_key INTO v_verification;
    SET LOCAL ROLE guild_runtime;
    BEGIN
        RESET ROLE;
        INSERT INTO guild.account_link (
            user_key, player_key, verification_key, attribution_key, linked_at, is_primary
        ) VALUES (
            v_alice, v_player, v_verification, v_return_episode,
            '2026-11-10 01:00:00+00', false
        );
        SET LOCAL ROLE guild_runtime;
        RAISE EXCEPTION 'Direct SQL created overlapping link intervals';
    EXCEPTION WHEN exclusion_violation OR unique_violation THEN NULL;
    END;
    RESET ROLE;
    INSERT INTO guild.metric_attribution_episode (
        user_key, player_key, first_link_at, include_prelink_history
    ) VALUES (
        v_alice, v_rejected_player, '2026-11-11 00:00:00+00', true
    ) RETURNING attribution_key INTO v_dummy_episode;
    SET LOCAL ROLE guild_runtime;
    BEGIN
        RESET ROLE;
        INSERT INTO guild.account_link (
            user_key, player_key, verification_key, attribution_key, linked_at, is_primary
        ) VALUES (
            v_alice, v_rejected_player, v_failed_verification, v_dummy_episode,
            '2026-11-11 00:00:00+00', false
        );
        SET LOCAL ROLE guild_runtime;
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
RESET ROLE;

-- An open transfer request ends on a clock: two days without a decision, or
-- one day after an approval that the recipient did not use. Both limits are
-- guild settings. These dates are in the past, so the scheduler can pass them.
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    v_guild bigint; v_staff bigint; v_clan bigint; v_poll bigint; v_player bigint;
    v_owner bigint; v_recipient bigint; v_second bigint;
    v_verification bigint; v_recipient_verification bigint;
    v_first bigint; v_stale bigint; v_approved bigint; v_unused bigint; v_link bigint;
    v_rejected boolean;
BEGIN
    SELECT guild_key INTO STRICT v_guild FROM guild.dim_guild;
    SELECT user_key INTO STRICT v_staff FROM guild.dim_discord_user WHERE discord_user_id = 700023;
    SELECT clan_key INTO STRICT v_clan FROM guild.dim_clan WHERE clan_tag = '#C0P';
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (700031) RETURNING user_key INTO v_owner;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (700032) RETURNING user_key INTO v_recipient;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (700033) RETURNING user_key INTO v_second;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#L0U') RETURNING player_key INTO v_player;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (v_clan, 'transfer-expiry-fixture', '2025-06-01 00:00:00+00', 'complete')
    RETURNING poll_key INTO v_poll;
    INSERT INTO guild.observed_clan_membership_period (
        player_key, clan_key, observed_since, confirmed_through,
        boundary_policy, coverage_status, first_poll_key, last_poll_key
    ) VALUES (v_player, v_clan, '2025-06-01 00:00:00+00', '2025-06-01 00:00:00+00',
        'first-complete-observation', 'adequate', v_poll, v_poll);
    RESET ROLE;
    ASSERT (SELECT transfer_pending_max_age_seconds = 172800 AND transfer_approval_max_age_seconds = 86400
        FROM guild.guild_settings WHERE guild_key = v_guild),
        'The transfer limits must default to two days pending and one day approved';
    ASSERT NOT EXISTS (SELECT FROM guild.account_transfer_request
        WHERE status IN ('pending', 'approved', 'awaiting_points')),
        'The earlier fixture must leave no open transfer request';
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (v_owner, v_player, 'verified', '2025-06-01 00:50:00+00')
    RETURNING verification_key INTO v_verification;
    SET LOCAL ROLE guild_runtime;
    PERFORM guild.link_player_account(v_owner, v_player, v_verification, false, NULL, '2025-06-01 01:00:00+00');

    -- A request that staff do not decide within the pending limit lapses.
    RESET ROLE;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (v_recipient, v_player, 'verified', '2025-06-02 00:50:00+00')
    RETURNING verification_key INTO v_recipient_verification;
    SET LOCAL ROLE guild_runtime;
    v_first := guild.request_account_transfer(v_recipient, v_player, v_recipient_verification, '2025-06-02 01:00:00+00');
    RESET ROLE;
    ASSERT guild.account_transfer_expires_at(v_first) = '2025-06-04 01:00:00+00'::timestamptz,
        'A pending request must lapse two days after it was made';
    SET LOCAL ROLE guild_runtime;
    BEGIN
        PERFORM guild.decide_account_transfer(v_first, v_staff, true, '2025-06-04 01:00:00+00');
        RAISE EXCEPTION 'A lapsed pending request was approved';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    ASSERT guild.expire_account_transfers('2025-06-04 00:59:59+00') = 0,
        'A request inside its limit must stay open';
    ASSERT guild.expire_account_transfers('2025-06-04 01:00:00+00') = 1,
        'The scheduler must expire the lapsed pending request';
    ASSERT guild.expire_account_transfers('2025-06-04 01:00:00+00') = 0,
        'Expiring transfer requests must be idempotent';
    RESET ROLE;
    ASSERT (SELECT status = 'expired' AND expired_at = '2025-06-04 01:00:00+00'::timestamptz
        AND decided_at IS NULL FROM guild.account_transfer_request
        WHERE transfer_request_key = v_first),
        'An expired request must record the moment its limit passed';
    SET LOCAL ROLE guild_runtime;
    BEGIN
        PERFORM guild.decide_account_transfer(v_first, v_staff, false, '2025-06-04 02:00:00+00');
        RAISE EXCEPTION 'An expired request was decided';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    v_rejected := false;
    BEGIN
        PERFORM guild.expire_account_transfers(clock_timestamp() + interval '1 hour');
    EXCEPTION WHEN invalid_parameter_value THEN v_rejected := true;
    END;
    ASSERT v_rejected, 'A transfer request was declared expired in the future';

    -- A lapsed request that the scheduler has not reached must not block a new one.
    RESET ROLE;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (v_recipient, v_player, 'verified', '2025-06-05 00:50:00+00')
    RETURNING verification_key INTO v_recipient_verification;
    SET LOCAL ROLE guild_runtime;
    v_stale := guild.request_account_transfer(v_recipient, v_player, v_recipient_verification, '2025-06-05 01:00:00+00');
    RESET ROLE;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (v_recipient, v_player, 'verified', '2025-06-08 00:50:00+00')
    RETURNING verification_key INTO v_recipient_verification;
    SET LOCAL ROLE guild_runtime;
    v_approved := guild.request_account_transfer(v_recipient, v_player, v_recipient_verification, '2025-06-08 01:00:00+00');
    RESET ROLE;
    ASSERT (SELECT status = 'expired' AND expired_at = '2025-06-07 01:00:00+00'::timestamptz
        FROM guild.account_transfer_request WHERE transfer_request_key = v_stale),
        'Asking again must expire the recipient''s lapsed request for the same link';
    SET LOCAL ROLE guild_runtime;

    -- An approval that the recipient does not use within the approval limit lapses.
    PERFORM guild.decide_account_transfer(v_approved, v_staff, true, '2025-06-09 00:00:00+00');
    BEGIN
        PERFORM guild.link_player_account(v_recipient, v_player,
            v_recipient_verification, false, v_approved, '2025-06-10 00:00:00+00');
        RAISE EXCEPTION 'A lapsed approval completed a transfer';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    ASSERT (SELECT user_key = v_owner FROM guild.current_account_link WHERE player_key = v_player),
        'A lapsed approval must leave the account with its owner';
    -- The limit is a guild setting: a longer one accepts the same approval.
    RESET ROLE;
    UPDATE guild.guild_settings SET transfer_approval_max_age_seconds = 172800
    WHERE guild_key = v_guild;
    SET LOCAL ROLE guild_runtime;
    v_link := guild.link_player_account(v_recipient, v_player,
        v_recipient_verification, false, v_approved, '2025-06-10 00:00:00+00');
    ASSERT (SELECT user_key = v_recipient FROM guild.current_account_link WHERE player_key = v_player),
        'An approval inside the configured limit must complete the transfer';
    RESET ROLE;
    UPDATE guild.guild_settings SET transfer_approval_max_age_seconds = 86400
    WHERE guild_key = v_guild;

    -- The scheduler expires an unused approval and keeps the decision as history.
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (v_second, v_player, 'verified', '2025-06-11 00:50:00+00')
    RETURNING verification_key INTO v_verification;
    SET LOCAL ROLE guild_runtime;
    v_unused := guild.request_account_transfer(v_second, v_player, v_verification, '2025-06-11 01:00:00+00');
    PERFORM guild.decide_account_transfer(v_unused, v_staff, true, '2025-06-11 02:00:00+00');
    ASSERT guild.expire_account_transfers('2025-06-12 01:59:59+00') = 0,
        'An approval inside its limit must stay usable';
    ASSERT guild.expire_account_transfers('2025-06-12 02:00:00+00') = 1,
        'The scheduler must expire the unused approval';
    RESET ROLE;
    ASSERT (SELECT status = 'expired' AND expired_at = '2025-06-12 02:00:00+00'::timestamptz
        AND decided_by = v_staff AND decided_at = '2025-06-11 02:00:00+00'::timestamptz
        FROM guild.account_transfer_request WHERE transfer_request_key = v_unused),
        'Expiry must keep the earlier approval as history';
    ASSERT guild.account_transfer_expires_at(v_unused) IS NULL,
        'A request that is no longer open has no expiry';
    SET LOCAL ROLE guild_runtime;
    BEGIN
        PERFORM guild.link_player_account(v_second, v_player,
            v_verification, false, v_unused, '2025-06-12 03:00:00+00');
        RAISE EXCEPTION 'An expired approval completed a transfer';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    v_rejected := false;
    BEGIN
        RESET ROLE;
        UPDATE guild.guild_settings SET transfer_pending_max_age_seconds = 0 WHERE guild_key = v_guild;
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN check_violation THEN v_rejected := true;
    END;
    ASSERT v_rejected, 'A transfer limit of zero seconds was accepted';
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'Transfer request and approval expiry assertions passed';
END;
$$;
RESET ROLE;

ROLLBACK;
