BEGIN;
SET LOCAL TIME ZONE 'Asia/Kolkata';

-- Trusted test fixtures place prior decisions on the processing timeline without
-- sleeping or altering the production clock. Ordinary runtime cannot write them.
CREATE FUNCTION pg_temp.seed_chat_award(p_user bigint, p_channel bigint,
    p_role bigint, p_message numeric, p_at timestamptz, p_xp integer DEFAULT 15)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE award_id bigint;
BEGIN
    INSERT INTO guild.fact_chat_xp_decision (user_key, channel_key, discord_message_id, message_sent_at,
            decided_at, policy_key, outcome, eligibility_role_key, xp)
    VALUES (p_user, p_channel, p_message, p_at, p_at,
        'rolling_60s_v1', 'credited', p_role, p_xp)
    RETURNING xp_award_key INTO award_id;
    RETURN award_id;
END;
$$;

-- The fixtures below run as guild_runtime, the role of the backend. Between
-- RESET ROLE and the next SET LOCAL ROLE the database administrator runs what
-- that role may not: configuration, private-ledger fixtures, and checks that
-- read a private ledger.
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    server_id bigint;
    alice bigint;
    bob bigint;
    absent_member bigint;
    rolling_member bigint;
    invalid_role_member bigint;
    moderator bigint;
    kicked_member bigint;
    failed_member bigint;
    role_a bigint;
    role_b bigint;
    expired_role bigint;
    deleted_role bigint;
    leadership_role bigint;
    channel_a bigint;
    channel_b bigint;
    rank_role bigint;
    award_id bigint;
    initial_xp integer;
    decision_id bigint;
    rank_member bigint;
    tier record;
    sample_count integer;
    action_id bigint;
    failed_action bigint;
    lease_member bigint; lease_action bigint;
    config_member bigint; config_action bigint;
    flight_member bigint; flight_action bigint; flight_warning bigint;
    claim record; stale_claim record; late_outcome text;
    manual_member bigint; late_member bigint; manual_kick bigint;
    join_id bigint;
    stale_join bigint;
    warning_id bigint;
    command_warning bigint;
    command_id uuid := '00000000-0000-4000-8000-000000000105';
    boundary_time timestamptz := clock_timestamp();
    message_id numeric := 9105000000000001000;
    rejected boolean;
BEGIN
    ASSERT (SELECT relkind = 'r' FROM pg_class
        WHERE oid = 'guild.fact_chat_xp_decision'::regclass),
        'XP decisions must remain the persisted source';
    ASSERT (SELECT relkind = 'v' FROM pg_class
        WHERE oid = 'guild.fact_chat_xp_award'::regclass),
        'Credited awards must be a projection, not a second persisted message';
    RESET ROLE;
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (9105000000000000001)
    RETURNING guild_key INTO server_id;
    INSERT INTO guild.guild_settings (guild_key) VALUES (server_id);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000011)
    RETURNING user_key INTO alice;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000012)
    RETURNING user_key INTO bob;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000013)
    RETURNING user_key INTO absent_member;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000014)
    RETURNING user_key INTO rolling_member;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000015)
    RETURNING user_key INTO invalid_role_member;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000016)
    RETURNING user_key INTO moderator;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000017)
    RETURNING user_key INTO kicked_member;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000018)
    RETURNING user_key INTO failed_member;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9105000000000000021, 'Eligible A') RETURNING role_key INTO role_a;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9105000000000000022, 'Eligible B') RETURNING role_key INTO role_b;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9105000000000000023, 'Expired') RETURNING role_key INTO expired_role;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name, deleted_at)
    VALUES (9105000000000000024, 'Deleted', clock_timestamp())
    RETURNING role_key INTO deleted_role;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9105000000000000025, 'Leadership') RETURNING role_key INTO leadership_role;
    RESET ROLE;
    INSERT INTO guild.server_role_binding (purpose, role_key)
    VALUES ('leadership', leadership_role);
    INSERT INTO guild.chat_xp_eligibility_role (role_key)
    VALUES (role_a), (role_b),
        (expired_role), (deleted_role);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (9105000000000000031, 'Chat A') RETURNING channel_key INTO channel_a;
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (9105000000000000032, 'Chat B') RETURNING channel_key INTO channel_b;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    SELECT member_id, 'join', '2026-01-01 00:00:00+00'::timestamptz
    FROM unnest(ARRAY[alice, bob, rolling_member, invalid_role_member,
        moderator, kicked_member, failed_member]) AS members(member_id);
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (alice, role_a, 'add', '2026-01-02 00:00:00+00', 'manual'),
        (bob, role_b, 'add', '2026-01-02 00:00:00+00', 'manual'),
        (rolling_member, role_a, 'add', '2026-01-02 00:00:00+00', 'manual'),
        (absent_member, role_a, 'add', '2026-01-02 00:00:00+00', 'manual'),
        (invalid_role_member, deleted_role, 'add', '2026-01-02 00:00:00+00', 'manual'),
        (moderator, leadership_role, 'add', '2026-01-02 00:00:00+00', 'manual');
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind,
            origin_join_event_key, expires_at)
    SELECT invalid_role_member, expired_role, 'add', '2026-01-02 00:00:00+00',
        'new_joinee_expiry', membership_event_key, new_joinee_expires_at
    FROM guild.fact_discord_membership_event
    WHERE user_key = invalid_role_member;

    award_id := guild.credit_chat_xp(alice, channel_a,
        9105000000000000101, '2026-10-31 23:59:59+00');
    RESET ROLE;
    SELECT xp INTO STRICT initial_xp FROM guild.fact_chat_xp_award WHERE xp_award_key = award_id;
    SET LOCAL ROLE guild_runtime;
    ASSERT initial_xp BETWEEN 15 AND 25, 'XP fell outside the approved range';
    ASSERT guild.credit_chat_xp(alice, channel_a,
        9105000000000000101, '2026-10-31 23:59:59+00') = award_id, 'Award replay changed identity';
    RESET ROLE;
    ASSERT (SELECT xp FROM guild.fact_chat_xp_award WHERE xp_award_key = award_id) = initial_xp,
        'Award replay rerolled XP';
    ASSERT (SELECT xp_award_key = xp_decision_key AND xp_award_key = award_id
        FROM guild.fact_chat_xp_decision WHERE discord_message_id = 9105000000000000101),
        'A credited message acquired a separate persisted award identity';
    SET LOCAL ROLE guild_runtime;
    rejected := false;
    BEGIN
        RESET ROLE;
        UPDATE guild.fact_chat_xp_award SET xp = 25 WHERE xp_award_key = award_id;
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'The award projection allowed XP history rewrites';
    ASSERT guild.credit_chat_xp(bob, channel_b,
        9105000000000000102, '2026-11-01 00:00:01+00') IS NOT NULL,
        'The second eligibility role did not qualify without a CoC account';
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (bob, role_a, 'add', clock_timestamp(), 'manual');
    ASSERT guild.credit_chat_xp(bob, channel_a,
        9105000000000000103, '2026-11-01 00:00:02+00') IS NOT NULL,
        'Holding both roles failed OR eligibility';

    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (alice, role_a, 'remove', clock_timestamp(), 'manual');
    ASSERT guild.credit_chat_xp(alice, channel_a,
        9105000000000000104, '2026-11-01 00:00:03+00') IS NULL, 'Role loss did not pause earning';
    ASSERT (SELECT is_present FROM guild.discord_member_state
        WHERE user_key = alice), 'Missing roles became a departure';
    ASSERT (SELECT cumulative_xp FROM guild.chat_member_rank_state
        WHERE user_key = alice) = initial_xp, 'Role loss erased rank/XP';
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (alice, role_b, 'add', clock_timestamp(), 'manual');
    ASSERT guild.credit_chat_xp(alice, channel_a,
        9105000000000000104, '2026-11-01 00:00:03+00') IS NULL,
        'Previously rejected message earned retroactively after roles changed';
    rejected := false;
    BEGIN
        PERFORM guild.credit_chat_xp(bob, channel_a,
            9105000000000000104, '2026-11-01 00:00:03+00');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'A rejected message identity was reused by another member';
    ASSERT guild.credit_chat_xp(absent_member, channel_a,
        9105000000000000105, '2026-11-01 00:00:04+00') IS NULL,
        'A role without current Discord presence qualified';
    RESET ROLE;
    ASSERT (SELECT xp_award_key IS NULL FROM guild.fact_chat_xp_decision
        WHERE discord_message_id = 9105000000000000105),
        'A rejected decision became addressable as a credited award';
    SET LOCAL ROLE guild_runtime;
    ASSERT guild.credit_chat_xp(invalid_role_member, channel_a,
        9105000000000000106, '2026-11-01 00:00:05+00') IS NULL,
        'Expired/deleted roles qualified';

    -- Four recent awards plus one expired award leave exactly one earning slot.
    FOR sample_count IN 1..5 LOOP
        RESET ROLE;
        PERFORM pg_temp.seed_chat_award(rolling_member, channel_a, role_a,
            9105000000000000200::numeric + sample_count,
            boundary_time - CASE WHEN sample_count = 1 THEN interval '61 seconds'
                ELSE interval '30 seconds' END);
        SET LOCAL ROLE guild_runtime;
    END LOOP;
    ASSERT guild.credit_chat_xp(rolling_member, channel_b,
        9105000000000000206, '2026-11-01 00:00:00+00') IS NOT NULL,
        'An expired processing-time award still consumed the rolling window';
    ASSERT guild.credit_chat_xp(rolling_member, channel_a,
        9105000000000000207, '2026-12-01 00:00:00+00') IS NULL,
        'A source-time calendar boundary bypassed the shared rolling limit';
    RESET ROLE;
    INSERT INTO guild.fact_chat_xp_decision (user_key, channel_key, discord_message_id, message_sent_at,
            decided_at, policy_key, outcome, eligibility_role_key)
    VALUES (alice, channel_a, 9105000000000000208, '2026-11-01 00:00:00+00',
        boundary_time - interval '61 seconds', 'rolling_60s_v1', 'rate_limited', role_b);
    SET LOCAL ROLE guild_runtime;
    ASSERT guild.credit_chat_xp(alice, channel_a,
        9105000000000000208, '2026-11-01 00:00:00+00') IS NULL,
        'An expired rejected decision was reconsidered';
    RESET ROLE;
    SELECT count(DISTINCT xp) INTO sample_count FROM (
        SELECT guild.sample_chat_xp() AS xp FROM generate_series(1, 128)
    ) samples WHERE xp BETWEEN 15 AND 25;
    SET LOCAL ROLE guild_runtime;
    ASSERT sample_count > 1, 'Random XP sampling behaved as a fixed award';

    ASSERT (SELECT array_agg(minimum_cumulative_xp ORDER BY rank_key) FROM guild.chat_rank_tier)
        = ARRAY[0, 4000, 12000, 28000, 60000, 120000, 240000, 400000, 650000, 1000000]::bigint[],
        'Seeded cumulative rank thresholds differ from the approved schedule';
    ASSERT (SELECT array_agg(rank_name ORDER BY rank_key) FROM guild.chat_rank_tier)
        = ARRAY['Stardust', 'Stargazer', 'Orbiter', 'Lunar Drift', 'Solar Wanderer',
            'Penumbra', 'Corona', 'Umbra', 'Totality', 'Eclipse Ascendant'],
        'Seeded rank names differ from the approved schedule';
    FOR tier IN SELECT * FROM guild.chat_rank_tier ORDER BY rank_key LOOP
        INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
        VALUES (9105000000000000300::numeric + tier.rank_key, tier.rank_name)
        RETURNING role_key INTO rank_role;
        RESET ROLE;
        INSERT INTO guild.chat_rank_role_binding (rank_key, role_key)
        VALUES (tier.rank_key, rank_role);
        SET LOCAL ROLE guild_runtime;
        IF tier.rank_key = 1 THEN CONTINUE; END IF;
        INSERT INTO guild.dim_discord_user (discord_user_id)
        VALUES (9105000000000000400::numeric + tier.rank_key) RETURNING user_key INTO rank_member;
        message_id := message_id + 1;
        RESET ROLE;
        PERFORM pg_temp.seed_chat_award(rank_member, channel_a, role_a,
            message_id, boundary_time - interval '2 hours');
        -- Seed the mutable cumulative projection immediately below a boundary;
        -- exercise real award/rank triggers without fabricating 40,000 messages.
        UPDATE guild.chat_member_rank_state
        SET cumulative_xp = tier.minimum_cumulative_xp - 16, rank_key = tier.rank_key - 1
        WHERE user_key = rank_member;
        SET LOCAL ROLE guild_runtime;
        message_id := message_id + 1;
        RESET ROLE;
        PERFORM pg_temp.seed_chat_award(rank_member, channel_a, role_a,
            message_id, boundary_time - interval '119 minutes');
        SET LOCAL ROLE guild_runtime;
        ASSERT (SELECT rank_key FROM guild.chat_member_rank_state
            WHERE user_key = rank_member) = tier.rank_key - 1,
            'Rank was granted below its cumulative threshold';
        RESET ROLE;
        UPDATE guild.chat_member_rank_state SET cumulative_xp = tier.minimum_cumulative_xp - 15
        WHERE user_key = rank_member;
        SET LOCAL ROLE guild_runtime;
        message_id := message_id + 1;
        RESET ROLE;
        PERFORM pg_temp.seed_chat_award(rank_member, channel_a, role_a,
            message_id, boundary_time - interval '118 minutes');
        SET LOCAL ROLE guild_runtime;
        ASSERT (SELECT rank_key FROM guild.chat_member_rank_state
            WHERE user_key = rank_member) = tier.rank_key,
            'Exact cumulative threshold did not grant the approved rank';
        ASSERT (SELECT count(*) FROM guild.desired_chat_rank_role
            WHERE user_key = rank_member) = 1,
            'Rank projection did not select exactly one highest bound role';
    END LOOP;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (rank_member, 'join', clock_timestamp() - interval '1 minute');
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    SELECT rank_member, role_key, 'add', clock_timestamp(), 'chat_rank'
    FROM guild.chat_rank_role_binding WHERE rank_key IN (1, 10);
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (rank_member, role_a, 'add', clock_timestamp(), 'manual');
    ASSERT (SELECT count(*) FROM guild.chat_rank_role_removal
        WHERE user_key = rank_member) = 1,
        'Rank reconciliation did not target exactly the stale rank role';
    ASSERT NOT EXISTS (SELECT FROM guild.chat_rank_role_removal
        WHERE user_key = rank_member AND role_key = role_a),
        'Rank reconciliation targeted an unrelated role';
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (alice, 'departure', clock_timestamp());
    ASSERT (SELECT cumulative_xp FROM guild.chat_member_rank_state
        WHERE user_key = alice) = initial_xp, 'Departure erased XP';
    ASSERT EXISTS (SELECT FROM guild.desired_chat_rank_role
        WHERE user_key = alice), 'Departure erased desired highest rank';

    command_warning := guild.issue_warning_command(command_id, bob,
        moderator, 'Stable command');
    ASSERT guild.issue_warning_command(command_id, bob,
        moderator, 'Stable command') = command_warning,
        'Command replay without an explicit issue time created another warning';
    RESET ROLE;
    ASSERT (SELECT count(*) FROM guild.warning WHERE operation_id = command_id) = 1,
        'Stable warning command UUID was not unique';
    ASSERT EXISTS (SELECT FROM guild.warning
        WHERE warning_key = command_warning AND issued_by_user_key = moderator
            AND subject_user_key = bob),
        'Canonical warning command lost its actor/source audit context';
    SET LOCAL ROLE guild_runtime;
    rejected := false;
    BEGIN
        PERFORM guild.issue_warning_command(command_id, bob,
            moderator, 'Changed reason');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'Warning operation UUID accepted a different reason';
    rejected := false;
    BEGIN
        PERFORM guild.issue_warning_command(command_id, alice,
            moderator, 'Stable command');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'Warning operation UUID accepted a different subject';

    FOR sample_count IN 1..5 LOOP
        PERFORM guild.issue_warning(kicked_member, moderator,
            'January threshold', '2026-01-31 23:59:00+00');
    END LOOP;
    RESET ROLE;
    SELECT moderation_action_key INTO STRICT action_id FROM guild.moderation_action
    WHERE subject_user_key = kicked_member;
    SET LOCAL ROLE guild_runtime;
    SELECT * INTO claim FROM guild.claim_moderation_action(action_id, 'worker-a');
    PERFORM guild.record_moderation_attempt(action_id, claim.claim_token, 'uncertain', NULL,
        'lost_receipt', '2026-02-01 00:01:00+00');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (kicked_member, 'departure', '2026-02-01 00:02:00+00'),
        (kicked_member, 'join', '2026-02-01 00:03:00+00');
    RESET ROLE;
    ASSERT NOT EXISTS (SELECT FROM guild.fact_moderation_notice
        WHERE subject_user_key = kicked_member), 'Uncertain kick became a confirmed rejoin notice';
    SET LOCAL ROLE guild_runtime;
    PERFORM guild.issue_warning(kicked_member, moderator,
        'Warning recorded before the success receipt', '2026-02-01 00:04:00+00');
    -- The next worker finds the member gone and confirms the earlier kick.
    SELECT * INTO claim FROM guild.claim_moderation_action(action_id, 'worker-a');
    ASSERT claim.action = 'check_member', 'An uncertain kick must be offered with a member check';
    PERFORM guild.record_moderation_attempt(action_id, claim.claim_token, 'succeeded', 204, NULL,
        '2026-02-01 00:01:00+00');
    RESET ROLE;
    ASSERT (SELECT count(*) FROM guild.fact_moderation_notice
        WHERE subject_user_key = kicked_member AND notice_kind = 'kick_rejoin'
            AND kick_month_gmt = '2026-02-01') = 1,
        'Late success receipt did not correlate the accepted execution-month rejoin';
    PERFORM guild.record_moderation_rejoin_notices(kicked_member);
    ASSERT (SELECT count(*) FROM guild.fact_moderation_notice
        WHERE subject_user_key = kicked_member) = 2,
        'Late evidence did not backfill exactly one warning notice, or replay duplicated notices';
    SET LOCAL ROLE guild_runtime;
    FOR sample_count IN 1..6 LOOP
        warning_id := guild.issue_warning(kicked_member, moderator,
            'Post-rejoin warning', '2026-02-01 00:04:00+00');
    END LOOP;
    RESET ROLE;
    ASSERT (SELECT count(*) FROM guild.fact_moderation_notice
        WHERE subject_user_key = kicked_member AND notice_kind = 'post_rejoin_warning') = 7,
        'Post-rejoin warnings did not each create a durable leadership notice';
    ASSERT (SELECT count(*) FROM guild.moderation_action
        WHERE subject_user_key = kicked_member) = 1,
        'Post-rejoin warnings created another automatic kick job';
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (kicked_member, 'departure', '2026-02-28 23:59:59+00'),
        (kicked_member, 'join', '2026-03-01 00:00:00+00');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (kicked_member, 'join', '2026-02-28 23:00:00+00')
    RETURNING membership_event_key INTO stale_join;
    RESET ROLE;
    ASSERT NOT EXISTS (SELECT FROM guild.fact_discord_accepted_join
        WHERE membership_event_key = stale_join), 'Stale join was treated as an accepted rejoin';
    ASSERT (SELECT count(*) FROM guild.fact_moderation_notice
        WHERE subject_user_key = kicked_member AND notice_kind = 'kick_rejoin') = 1,
        'Later-month or stale rejoin generated another same-month notice';
    SET LOCAL ROLE guild_runtime;
    FOR sample_count IN 1..5 LOOP
        PERFORM guild.issue_warning(kicked_member, moderator,
            'New GMT month', '2026-03-01 00:05:00+00');
    END LOOP;
    RESET ROLE;
    ASSERT (SELECT count(*) FROM guild.moderation_action
        WHERE subject_user_key = kicked_member) = 2, 'GMT monthly threshold did not reset';
    SET LOCAL ROLE guild_runtime;
    FOR sample_count IN 1..5 LOOP
        PERFORM guild.issue_warning(failed_member, moderator,
            'Failed action', '2026-02-01 00:00:00+00');
    END LOOP;
    RESET ROLE;
    SELECT moderation_action_key INTO STRICT failed_action FROM guild.moderation_action
    WHERE subject_user_key = failed_member;
    SET LOCAL ROLE guild_runtime;
    SELECT * INTO claim FROM guild.claim_moderation_action(failed_action, 'worker-a');
    PERFORM guild.record_moderation_attempt(failed_action, claim.claim_token, 'failed', 403,
        'missing_permission', '2026-02-01 00:01:00+00');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (failed_member, 'departure', '2026-02-01 00:02:00+00'),
        (failed_member, 'join', '2026-02-01 00:03:00+00');
    RESET ROLE;
    ASSERT NOT EXISTS (SELECT FROM guild.fact_moderation_notice
        WHERE subject_user_key = failed_member), 'Failed kick created a confirmed-kick notice';
    SET LOCAL ROLE guild_runtime;

    -- A failed kick is tried again after the retry delay, three attempts in all.
    ASSERT (SELECT status = 'failed' AND attempts_remaining = 2
        AND next_attempt_at = '2026-02-01 00:06:00+00'::timestamptz
        FROM guild.pending_moderation_action WHERE moderation_action_key = failed_action),
        'A failed kick must be scheduled five minutes after its attempt';
    rejected := false;
    BEGIN PERFORM guild.claim_moderation_action(failed_action, 'not a worker name');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'An unbounded worker identity claimed a kick';
    SELECT * INTO claim FROM guild.claim_moderation_action(failed_action, 'worker-a');
    ASSERT claim.action = 'kick' AND claim.claim_token IS NOT NULL,
        'A failed kick that is due must be offered as a plain kick with a claim token';
    ASSERT (guild.claim_moderation_action(failed_action, 'worker-b')).action IS NULL,
        'A second worker claimed a kick that is already held';
    -- No answer from Discord: the next worker must check the member first.
    PERFORM guild.record_moderation_attempt(failed_action, claim.claim_token, 'uncertain', NULL,
        'timeout', '2026-02-01 00:10:00+00');
    ASSERT (SELECT status = 'uncertain' AND attempts_remaining = 1 AND lease_expires_at IS NULL
        AND next_attempt_at = '2026-02-01 00:15:00+00'::timestamptz
        FROM guild.pending_moderation_action WHERE moderation_action_key = failed_action),
        'Recording an attempt must release the claim and schedule the last attempt';
    SELECT * INTO claim FROM guild.claim_moderation_action(failed_action, 'worker-b');
    ASSERT claim.action = 'check_member', 'An uncertain kick must be offered with a member check';
    PERFORM guild.record_moderation_attempt(failed_action, claim.claim_token, 'failed', 403,
        'missing_permission', '2026-02-01 00:20:00+00');
    ASSERT NOT EXISTS (SELECT FROM guild.pending_moderation_action
        WHERE moderation_action_key = failed_action)
        AND (guild.claim_moderation_action(failed_action, 'worker-a')).action IS NULL,
        'A kick that used all its attempts was offered again';
    RESET ROLE;
    ASSERT (SELECT status = 'failed' AND attempts_remaining = 0 AND next_attempt_at IS NULL
        FROM guild.moderation_action WHERE moderation_action_key = failed_action),
        'The last failed attempt must leave the kick failed for leadership';
    SET LOCAL ROLE guild_runtime;

    -- A claim that expires without a recorded attempt leaves the outcome
    -- unknown, so the next worker must check the member first.
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000091)
    RETURNING user_key INTO lease_member;
    FOR sample_count IN 1..5 LOOP
        PERFORM guild.issue_warning(lease_member, moderator,
            'Lease threshold', '2026-04-01 00:00:00+00');
    END LOOP;
    SELECT moderation_action_key INTO STRICT lease_action FROM guild.pending_moderation_action
    WHERE subject_user_key = lease_member;
    SELECT * INTO stale_claim FROM guild.claim_moderation_action(lease_action, 'worker-a', 60);
    ASSERT stale_claim.action = 'kick', 'A new kick must be offered as a plain kick';
    RESET ROLE;
    UPDATE guild.moderation_action SET lease_expires_at = clock_timestamp() - interval '1 second'
    WHERE moderation_action_key = lease_action;
    SET LOCAL ROLE guild_runtime;
    SELECT * INTO claim FROM guild.claim_moderation_action(lease_action, 'worker-b');
    ASSERT claim.action = 'check_member' AND claim.claim_token <> stale_claim.claim_token,
        'A kick whose claim expired unreported must be offered with a member check and a new token';
    -- The first worker reports late. Its claim was taken over, so the report
    -- is rejected: it spends no attempt and does not release the second claim.
    rejected := false;
    BEGIN
        PERFORM guild.record_moderation_attempt(lease_action, stale_claim.claim_token, 'failed',
            500, 'server_error', '2026-04-01 00:05:00+00');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'A report from a claim that was taken over was accepted';
    ASSERT (SELECT status = 'pending' AND attempts_remaining = 3
        AND lease_expires_at > clock_timestamp()
        FROM guild.pending_moderation_action WHERE moderation_action_key = lease_action)
        AND (guild.claim_moderation_action(lease_action, 'worker-c')).action IS NULL,
        'A rejected report must not spend an attempt or release the current claim';
    -- The member is gone: the worker records success instead of a second kick.
    PERFORM guild.record_moderation_attempt(lease_action, claim.claim_token, 'succeeded', NULL,
        'member_absent', '2026-04-01 00:10:00+00');
    ASSERT NOT EXISTS (SELECT FROM guild.pending_moderation_action
        WHERE moderation_action_key = lease_action)
        AND (guild.claim_moderation_action(lease_action, 'worker-a')).action IS NULL,
        'A succeeded kick was offered again';
    rejected := false;
    BEGIN
        PERFORM guild.record_moderation_attempt(lease_action, claim.claim_token, 'succeeded', NULL,
            'member_absent', '2026-04-01 00:10:00+00');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'A claim token was accepted for a second report';
    RESET ROLE;
    ASSERT (SELECT count(*) = 1 FROM guild.fact_moderation_action_attempt
        WHERE moderation_action_key = lease_action), 'A rejected report was stored as an attempt';
    SET LOCAL ROLE guild_runtime;

    -- Both limits are guild settings, fixed for a kick when it is decided.
    RESET ROLE;
    UPDATE guild.guild_settings SET kick_max_attempts = 2, kick_retry_seconds = 60
    WHERE guild_key = server_id;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000092)
    RETURNING user_key INTO config_member;
    FOR sample_count IN 1..5 LOOP
        PERFORM guild.issue_warning(config_member, moderator,
            'Configured threshold', '2026-04-02 00:00:00+00');
    END LOOP;
    SELECT moderation_action_key INTO STRICT config_action FROM guild.pending_moderation_action
    WHERE subject_user_key = config_member;
    RESET ROLE;
    UPDATE guild.guild_settings SET kick_max_attempts = 3 WHERE guild_key = server_id;
    SET LOCAL ROLE guild_runtime;
    SELECT * INTO claim FROM guild.claim_moderation_action(config_action, 'worker-a');
    PERFORM guild.record_moderation_attempt(config_action, claim.claim_token, 'failed', 500,
        'server_error', '2026-04-02 00:01:00+00');
    ASSERT (SELECT attempts_remaining = 1 AND next_attempt_at = '2026-04-02 00:02:00+00'::timestamptz
        FROM guild.pending_moderation_action WHERE moderation_action_key = config_action),
        'The configured attempt limit and retry delay were not applied';
    SELECT * INTO claim FROM guild.claim_moderation_action(config_action, 'worker-a');
    PERFORM guild.record_moderation_attempt(config_action, claim.claim_token, 'failed', 500,
        'server_error', '2026-04-02 00:03:00+00');
    ASSERT NOT EXISTS (SELECT FROM guild.pending_moderation_action
        WHERE moderation_action_key = config_action),
        'A later settings change altered the attempts of an open kick';
    RESET ROLE;
    UPDATE guild.guild_settings SET kick_retry_seconds = 300 WHERE guild_key = server_id;
    rejected := false;
    BEGIN UPDATE guild.guild_settings SET kick_max_attempts = 0 WHERE guild_key = server_id;
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'An attempt limit of zero was accepted';
    SET LOCAL ROLE guild_runtime;

    -- A revocation during a held claim does not interrupt that attempt. Its
    -- failure then cancels the kick instead of scheduling another attempt.
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000093)
    RETURNING user_key INTO flight_member;
    FOR sample_count IN 1..5 LOOP
        flight_warning := guild.issue_warning(flight_member, moderator,
            'In-flight threshold', '2026-04-03 00:00:00+00');
    END LOOP;
    SELECT moderation_action_key INTO STRICT flight_action FROM guild.pending_moderation_action
    WHERE subject_user_key = flight_member;
    SELECT * INTO claim FROM guild.claim_moderation_action(flight_action, 'worker-a');
    ASSERT claim.action = 'kick', 'The in-flight kick must be claimable';
    PERFORM guild.revoke_warning(flight_warning, moderator, 'Withdrawn', '2026-04-03 01:00:00+00');
    ASSERT (SELECT status = 'pending' FROM guild.pending_moderation_action
        WHERE moderation_action_key = flight_action),
        'A revocation cancelled a kick while a worker held it';
    PERFORM guild.record_moderation_attempt(flight_action, claim.claim_token, 'failed', 500,
        'server_error', '2026-04-03 01:01:00+00');
    RESET ROLE;
    ASSERT (SELECT status = 'cancelled' AND next_attempt_at IS NULL AND cancelled_at IS NOT NULL
        FROM guild.moderation_action WHERE moderation_action_key = flight_action),
        'A failed attempt on an unsupported kick must cancel it, not schedule a retry';
    SET LOCAL ROLE guild_runtime;
    -- A claim that expired unreported after a revocation is cancelled at the
    -- next claim. No worker took the kick over, so the first worker may still
    -- report. Only a confirmed kick changes the cancelled state.
    FOREACH late_outcome IN ARRAY ARRAY['uncertain', 'succeeded'] LOOP
        INSERT INTO guild.dim_discord_user (discord_user_id)
        VALUES (CASE late_outcome WHEN 'uncertain' THEN 9105000000000000094
            ELSE 9105000000000000095 END)
        RETURNING user_key INTO flight_member;
        FOR sample_count IN 1..5 LOOP
            flight_warning := guild.issue_warning(flight_member, moderator,
                'Expired claim threshold', '2026-04-04 00:00:00+00');
        END LOOP;
        SELECT moderation_action_key INTO STRICT flight_action FROM guild.pending_moderation_action
        WHERE subject_user_key = flight_member;
        SELECT * INTO stale_claim FROM guild.claim_moderation_action(flight_action, 'worker-a');
        ASSERT stale_claim.action = 'kick', 'The second in-flight kick must be claimable';
        PERFORM guild.revoke_warning(flight_warning, moderator, 'Withdrawn', '2026-04-04 01:00:00+00');
        RESET ROLE;
        UPDATE guild.moderation_action SET lease_expires_at = clock_timestamp() - interval '1 second'
        WHERE moderation_action_key = flight_action;
        SET LOCAL ROLE guild_runtime;
        ASSERT (guild.claim_moderation_action(flight_action, 'worker-b')).action IS NULL,
            'An unsupported kick was offered after its claim expired';
        RESET ROLE;
        ASSERT (SELECT status = 'cancelled' AND lease_owner IS NULL FROM guild.moderation_action
            WHERE moderation_action_key = flight_action),
            'The next claim must cancel a kick that lost its fifth active warning';
        SET LOCAL ROLE guild_runtime;
        PERFORM guild.record_moderation_attempt(flight_action, stale_claim.claim_token, late_outcome,
            CASE late_outcome WHEN 'succeeded' THEN 204 END,
            CASE late_outcome WHEN 'uncertain' THEN 'timeout' END, '2026-04-04 01:02:00+00');
        RESET ROLE;
        IF late_outcome = 'uncertain' THEN
            ASSERT (SELECT status = 'cancelled' FROM guild.moderation_action
                WHERE moderation_action_key = flight_action),
                'An uncertain report reopened a cancelled kick';
        ELSE
            ASSERT (SELECT status = 'succeeded' AND cancelled_at IS NULL FROM guild.moderation_action
                WHERE moderation_action_key = flight_action),
                'A confirmed kick must replace the cancelled state';
        END IF;
        ASSERT (SELECT count(*) = 1 FROM guild.fact_moderation_action_attempt
            WHERE moderation_action_key = flight_action), 'The late report must be retained';
        SET LOCAL ROLE guild_runtime;
    END LOOP;

    -- What a leader does by hand comes from the audit log of Discord.
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000096)
    RETURNING user_key INTO manual_member;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9105000000000000097)
    RETURNING user_key INTO late_member;
    ASSERT NOT has_table_privilege(current_user, 'guild.fact_manual_moderation_action', 'SELECT')
        AND NOT has_table_privilege(current_user, 'guild.fact_manual_moderation_action', 'INSERT'),
        'Runtime must use the entry point and the history reader for manual moderation';
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (manual_member, 'join', '2026-05-01 00:00:00+00');
    manual_kick := guild.record_manual_moderation_action(9105000000000000201, 'kick',
        manual_member, moderator, '2026-05-02 00:00:00+00', 'Spam in chat');
    ASSERT guild.record_manual_moderation_action(9105000000000000201, 'kick',
        manual_member, moderator, '2026-05-02 00:00:00+00', 'Spam in chat') = manual_kick,
        'A replayed audit log entry created a second action';
    rejected := false;
    BEGIN
        PERFORM guild.record_manual_moderation_action(9105000000000000201, 'ban',
            manual_member, moderator, '2026-05-02 00:00:00+00', 'Spam in chat');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'One audit log entry was accepted as two different actions';
    rejected := false;
    BEGIN
        PERFORM guild.record_manual_moderation_action(9105000000000000202, 'timeout',
            manual_member, moderator, '2026-05-02 00:00:00+00');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'A timeout without its end was accepted';
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (manual_member, 'departure', '2026-05-02 00:00:01+00');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (manual_member, 'join', '2026-05-03 00:00:00+00');
    RESET ROLE;
    ASSERT (SELECT count(*) = 1 AND bool_and(notice_kind = 'manual_kick_rejoin'
            AND manual_action_key = manual_kick AND kick_month_gmt = '2026-05-01')
        FROM guild.fact_moderation_notice WHERE subject_user_key = manual_member),
        'A rejoin after a manual kick in the same month must create one leadership notice';
    SET LOCAL ROLE guild_runtime;
    -- A manual kick does not replace the automatic kick of the fifth warning.
    FOR sample_count IN 1..5 LOOP
        PERFORM guild.issue_warning(manual_member, moderator,
            'After a manual kick', '2026-05-04 00:00:00+00');
    END LOOP;
    ASSERT EXISTS (SELECT FROM guild.pending_moderation_action
        WHERE subject_user_key = manual_member AND status = 'pending'),
        'A manual kick and rejoin suppressed the automatic kick of the fifth warning';
    -- A ban alone creates no notice. An unban followed by a rejoin does.
    PERFORM guild.record_manual_moderation_action(9105000000000000203, 'ban',
        manual_member, moderator, '2026-05-10 00:00:00+00');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (manual_member, 'departure', '2026-05-10 00:00:01+00');
    PERFORM guild.record_manual_moderation_action(9105000000000000204, 'unban',
        manual_member, moderator, '2026-05-12 00:00:00+00');
    PERFORM guild.record_manual_moderation_action(9105000000000000205, 'timeout',
        manual_member, moderator, '2026-05-12 01:00:00+00', NULL, '2026-05-12 02:00:00+00');
    RESET ROLE;
    ASSERT NOT EXISTS (SELECT FROM guild.fact_moderation_notice
        WHERE subject_user_key = manual_member AND notice_kind = 'unban_rejoin'),
        'An unban without a rejoin created a notice';
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (manual_member, 'join', '2026-05-13 00:00:00+00');
    RESET ROLE;
    ASSERT (SELECT count(*) FILTER (WHERE notice_kind = 'unban_rejoin') = 1
            AND count(*) FILTER (WHERE notice_kind = 'manual_kick_rejoin') = 2
            AND count(*) FILTER (WHERE notice_kind IN ('kick_rejoin', 'post_rejoin_warning')) = 0
        FROM guild.fact_moderation_notice WHERE subject_user_key = manual_member),
        'A rejoin after an unban must create its own notice and no bot-kick notice';
    SET LOCAL ROLE guild_runtime;
    -- The audit log entry can arrive after the rejoin is recorded.
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (late_member, 'join', '2026-06-01 00:00:00+00');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (late_member, 'departure', '2026-06-02 00:00:00+00');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (late_member, 'join', '2026-06-03 00:00:00+00');
    PERFORM guild.record_manual_moderation_action(9105000000000000206, 'kick',
        late_member, moderator, '2026-06-02 00:00:00+00');
    -- A rejoin in a later month is not a same-month rejoin.
    PERFORM guild.record_manual_moderation_action(9105000000000000207, 'kick',
        late_member, moderator, '2026-06-20 00:00:00+00');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (late_member, 'departure', '2026-06-20 00:00:01+00');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (late_member, 'join', '2026-07-01 00:00:00+00');
    RESET ROLE;
    ASSERT (SELECT count(*) = 1 AND bool_and(kick_month_gmt = '2026-06-01'
            AND occurred_at = '2026-06-03 00:00:00+00'::timestamptz)
        FROM guild.fact_moderation_notice WHERE subject_user_key = late_member),
        'A late audit log entry must create the notice of the earlier rejoin, and only that one';
    rejected := false;
    BEGIN UPDATE guild.fact_manual_moderation_action SET reason = 'Rewritten';
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    ASSERT rejected, 'Manual moderation history was mutable';
    SET LOCAL ROLE guild_runtime;
    -- Kick history holds the kicks of the bot and what a person did by hand.
    ASSERT (SELECT count(*) = 4 AND bool_and(origin = 'manual' AND actor_user_key = moderator)
            AND count(*) FILTER (WHERE action_kind = 'timeout'
                AND timeout_until = '2026-05-12 02:00:00+00'::timestamptz) = 1
        FROM guild.moderation_history(manual_member, manual_member)),
        'A member could not read their own manual moderation history';
    ASSERT (SELECT count(*) = 1 AND bool_and(origin = 'bot' AND action_kind = 'kick')
        FROM guild.moderation_history(moderator, kicked_member)),
        'A moderator could not read a confirmed kick of the bot';
    rejected := false;
    BEGIN PERFORM 1 FROM guild.moderation_history(late_member, manual_member);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    ASSERT rejected, 'A member read the moderation history of another member';
    RAISE NOTICE 'XP rolling windows/decisions/roles/ranks, confirmed-kick rejoin and manual moderation policies passed';
END;
$$;
RESET ROLE;

ROLLBACK;
