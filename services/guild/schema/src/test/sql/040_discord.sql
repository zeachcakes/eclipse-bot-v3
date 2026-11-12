BEGIN;
SET LOCAL TIME ZONE 'Asia/Kolkata';

-- The fixtures below run as guild_runtime, the role of the backend. Between
-- RESET ROLE and the next SET LOCAL ROLE the database administrator runs what
-- that role may not: configuration, private-ledger fixtures, and checks that
-- read a private ledger.
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    guild bigint;
    member_id bigint;
    moderator bigint;
    ordinary_user bigint;
    leader_role bigint;
    temporary_role bigint;
    eligibility_role bigint;
    channel_a bigint;
    channel_b bigint;
    first_join bigint;
    award bigint;
    first_award bigint;
    issued bigint;
    october_warning bigint;
    fifth_warning bigint;
    action_id bigint;
    claim record;
    n integer;
    total bigint;
    total_before_departure bigint;
    october_total bigint;
    november_total bigint;
    rejected boolean;
BEGIN
    RESET ROLE;
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (9400000000000000001)
    RETURNING guild_key INTO guild;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9400000000000000011)
    RETURNING user_key INTO member_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9400000000000000012)
    RETURNING user_key INTO moderator;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9400000000000000013)
    RETURNING user_key INTO ordinary_user;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9400000000000000021, 'Leadership') RETURNING role_key INTO leader_role;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9400000000000000022, 'New Joinee') RETURNING role_key INTO temporary_role;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9400000000000000023, 'Chat eligible') RETURNING role_key INTO eligibility_role;
    RESET ROLE;
    INSERT INTO guild.chat_xp_eligibility_role (role_key) VALUES (eligibility_role);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (9400000000000000031, 'chat-a') RETURNING channel_key INTO channel_a;
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (9400000000000000032, 'chat-b') RETURNING channel_key INTO channel_b;
    RESET ROLE;
    INSERT INTO guild.server_role_binding (purpose, role_key)
    VALUES ('leadership', leader_role);
    INSERT INTO guild.developer_allowlist (user_key)
    VALUES (ordinary_user);
    INSERT INTO guild.guild_settings (guild_key, new_joinee_days) VALUES (guild, 7);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (moderator, leader_role, 'add', '2026-10-01 00:00:00+00', 'manual');

    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (member_id, 'join', '2026-10-31 00:00:00+00')
    RETURNING membership_event_key INTO first_join;
    -- A later configuration change must not rewrite the first join's policy.
    RESET ROLE;
    UPDATE guild.guild_settings SET new_joinee_days = 3 WHERE guild_key = guild;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind,
            origin_join_event_key, expires_at)
    VALUES (member_id, temporary_role, 'add', '2026-10-31 01:00:00+00',
        'onboarding', first_join, '2026-11-07 00:00:00+00');
    IF NOT EXISTS (SELECT 1 FROM guild.discord_member_role
        WHERE user_key = member_id AND role_key = temporary_role
            AND expires_at = '2026-11-07 00:00:00+00'::timestamptz) THEN
        RAISE EXCEPTION 'selected join provenance and New Joinee expiry were not retained';
    END IF;
    rejected := false;
    BEGIN
        INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind,
                origin_join_event_key, expires_at)
        VALUES (member_id, temporary_role, 'add', '2026-10-31 01:00:00+00',
            'onboarding', first_join, '2026-11-08 00:00:00+00');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'incorrect New Joinee expiry accepted'; END IF;

    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (member_id, eligibility_role, 'add', '2026-10-31 01:00:00+00', 'manual');

    FOR n IN 1..5 LOOP
        award := guild.credit_chat_xp(member_id,
            CASE WHEN n % 2 = 0 THEN channel_a ELSE channel_b END,
            9400000000000000100::numeric + n,
            CASE WHEN n = 5 THEN '2026-11-01 00:00:00+00'::timestamptz
                ELSE '2026-10-31 23:59:01+00'::timestamptz END);
        IF award IS NULL THEN RAISE EXCEPTION 'one of first five XP awards was denied'; END IF;
        IF n = 1 THEN first_award := award; END IF;
    END LOOP;
    IF guild.credit_chat_xp(member_id, channel_a,
        9400000000000000106, '2026-10-31 23:59:59+00') IS NOT NULL THEN
        RAISE EXCEPTION 'sixth cross-channel message was credited';
    END IF;
    IF guild.credit_chat_xp(member_id, channel_b,
        9400000000000000101, '2026-10-31 23:59:01+00') <> first_award THEN
        RAISE EXCEPTION 'message retry was not idempotent';
    END IF;
    rejected := false;
    BEGIN
        PERFORM guild.credit_chat_xp(ordinary_user, channel_b,
            9400000000000000101, '2026-10-31 23:59:01+00');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'duplicate message changed XP recipient'; END IF;
    RESET ROLE;
    SELECT count(*) INTO total FROM guild.fact_chat_xp_award
    WHERE user_key = member_id;
    SET LOCAL ROLE guild_runtime;
    IF total <> 5 THEN RAISE EXCEPTION 'rejected/retried messages changed earning allowance'; END IF;
    award := guild.credit_chat_xp(member_id, channel_a,
        9400000000000000107, '2026-11-01 00:01:00+00');
    IF award IS NOT NULL THEN RAISE EXCEPTION 'source minute/month boundary bypassed rolling limit'; END IF;
    SELECT xp_total INTO october_total FROM guild.chat_xp_monthly_totals_utc
    WHERE user_key = member_id AND month_utc = '2026-10-01';
    IF october_total NOT BETWEEN 60 AND 100 THEN
        RAISE EXCEPTION 'October aggregation did not contain four 15..25 XP awards';
    END IF;
    SELECT xp_total INTO november_total FROM guild.chat_xp_monthly_totals_utc
    WHERE user_key = member_id AND month_utc = '2026-11-01';
    IF november_total NOT BETWEEN 15 AND 25 THEN
        RAISE EXCEPTION 'source XP month was affected by session timezone';
    END IF;
    total_before_departure := october_total + november_total;
    RESET ROLE;
    IF (SELECT count(*) FROM guild.fact_chat_xp_decision
        WHERE user_key = member_id) <> 7 THEN
        RAISE EXCEPTION 'credited/rejected message decisions were not both persisted';
    END IF;
    SET LOCAL ROLE guild_runtime;

    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (member_id, 'departure', '2026-11-02 00:00:00+00'),
        (member_id, 'join', '2026-10-30 00:00:00+00');
    IF (SELECT is_present FROM guild.discord_member_state
        WHERE user_key = member_id) THEN
        RAISE EXCEPTION 'out-of-order join replaced a newer departure';
    END IF;
    SELECT xp_total INTO total FROM guild.chat_xp_all_time_totals
    WHERE user_key = member_id;
    IF total <> total_before_departure THEN RAISE EXCEPTION 'departure erased XP'; END IF;
    IF (SELECT cumulative_xp FROM guild.chat_member_rank_state
        WHERE user_key = member_id) <> total_before_departure THEN
        RAISE EXCEPTION 'departure erased the cumulative rank projection';
    END IF;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (member_id, 'join', '2026-11-03 00:00:00+00');
    IF NOT (SELECT is_present FROM guild.discord_member_state
        WHERE user_key = member_id) THEN
        RAISE EXCEPTION 'rejoin did not restore member projection';
    END IF;
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (member_id, temporary_role, 'remove', '2026-11-07 00:00:00+00', 'new_joinee_expiry'),
        (member_id, temporary_role, 'add', '2026-11-01 00:00:00+00', 'reconciliation');
    IF EXISTS (SELECT 1 FROM guild.discord_member_role
        WHERE user_key = member_id AND role_key = temporary_role) THEN
        RAISE EXCEPTION 'out-of-order role add restored a removed role';
    END IF;

    rejected := false;
    BEGIN
        PERFORM guild.issue_warning(member_id, ordinary_user, 'unauthorized', now());
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'developer without moderation role issued warning'; END IF;
    rejected := false;
    BEGIN
        PERFORM guild.issue_warning(member_id, moderator, '  ', now());
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'blank warning reason accepted'; END IF;

    october_warning := guild.issue_warning(member_id, moderator,
        'October issue near GMT boundary', '2026-11-01 00:30:00+01');
    FOR n IN 1..5 LOOP
        issued := guild.issue_warning(member_id, moderator,
            'November reason ' || n::text, '2026-11-01 01:00:00+00');
        RESET ROLE;
        IF n = 4 AND EXISTS (SELECT 1 FROM guild.moderation_action) THEN
            RAISE EXCEPTION 'kick was requested before fifth valid monthly warning';
        END IF;
        SET LOCAL ROLE guild_runtime;
    END LOOP;
    fifth_warning := issued;
    RESET ROLE;
    SELECT moderation_action_key INTO STRICT action_id FROM guild.moderation_action
    WHERE subject_user_key = member_id AND warning_month_gmt = '2026-11-01';
    IF (SELECT status FROM guild.moderation_action WHERE moderation_action_key = action_id)
        <> 'pending' THEN RAISE EXCEPTION 'kick request was incorrectly marked executed'; END IF;
    SET LOCAL ROLE guild_runtime;
    -- The kick worker discovers work through the pending view only.
    IF NOT EXISTS (SELECT FROM guild.pending_moderation_action
        WHERE moderation_action_key = action_id AND subject_user_key = member_id) THEN
        RAISE EXCEPTION 'pending kick decision was not visible to the worker view';
    END IF;
    IF NOT has_table_privilege('guild_runtime', 'guild.pending_moderation_action', 'SELECT')
        OR has_table_privilege('guild_runtime', 'guild.moderation_action', 'SELECT')
        OR has_table_privilege('guild_runtime', 'guild.warning', 'SELECT') THEN
        RAISE EXCEPTION 'runtime must read pending kicks through the view, not the private ledgers';
    END IF;
    PERFORM guild.revoke_warning(fifth_warning, moderator, 'staff correction', '2026-11-02 00:00:00+00');
    PERFORM guild.revoke_warning(fifth_warning, moderator, 'staff correction', '2026-11-02 00:00:00+00');
    RESET ROLE;
    SELECT active_warnings INTO total FROM guild.active_warning_counts
    WHERE subject_user_key = member_id AND issue_month_gmt = '2026-11-01';
    SET LOCAL ROLE guild_runtime;
    IF total <> 4 THEN RAISE EXCEPTION 'revocation did not remove exactly one warning'; END IF;
    -- Four active warnings no longer support the kick that is still waiting.
    RESET ROLE;
    IF (SELECT status <> 'cancelled' OR cancelled_at <> '2026-11-02 00:00:00+00'::timestamptz
        FROM guild.moderation_action WHERE moderation_action_key = action_id) THEN
        RAISE EXCEPTION 'a revoked warning did not cancel the waiting kick';
    END IF;
    SET LOCAL ROLE guild_runtime;
    IF EXISTS (SELECT FROM guild.pending_moderation_action WHERE moderation_action_key = action_id)
        OR (guild.claim_moderation_action(action_id, 'kick-worker')).action IS NOT NULL THEN
        RAISE EXCEPTION 'a cancelled kick was offered to the worker';
    END IF;
    PERFORM guild.revoke_warning(october_warning, moderator, 'late correction', '2026-11-02 00:00:00+00');
    RESET ROLE;
    SELECT active_warnings INTO total FROM guild.active_warning_counts
    WHERE subject_user_key = member_id AND issue_month_gmt = '2026-11-01';
    SET LOCAL ROLE guild_runtime;
    IF total <> 4 THEN RAISE EXCEPTION 'cross-month revocation reduced the wrong month'; END IF;
    rejected := false;
    BEGIN
        PERFORM guild.revoke_warning(fifth_warning, moderator, 'duplicate correction', now());
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'conflicting revocation retry was accepted'; END IF;
    PERFORM guild.issue_warning(member_id, moderator, 'sixth issued warning', '2026-11-03 00:00:00+00');
    RESET ROLE;
    SELECT count(*) INTO total FROM guild.moderation_action;
    SET LOCAL ROLE guild_runtime;
    IF total <> 1 THEN RAISE EXCEPTION 'duplicate kick decision created for same month'; END IF;
    -- The fifth active warning of the same month arms the cancelled kick again.
    IF NOT EXISTS (SELECT FROM guild.pending_moderation_action
        WHERE moderation_action_key = action_id AND status = 'pending' AND attempts_remaining = 3) THEN
        RAISE EXCEPTION 'a new fifth active warning did not arm the cancelled kick again';
    END IF;
    PERFORM guild.issue_warning(member_id, moderator, 'new calendar month', '2026-12-01 00:00:00+00');
    RESET ROLE;
    SELECT active_warnings INTO total FROM guild.active_warning_counts
    WHERE subject_user_key = member_id AND issue_month_gmt = '2026-12-01';
    SET LOCAL ROLE guild_runtime;
    IF total <> 1 THEN RAISE EXCEPTION 'new GMT month retained earlier active count'; END IF;

    -- A retry that omits the revocation time must match its own first attempt.
    PERFORM guild.revoke_warning(october_warning, moderator, 'late correction');
    -- The UUID-bearing revocation command is replay-safe and identity-checked.
    issued := guild.issue_warning(member_id, moderator, 'January issue', '2027-01-05 00:00:00+00');
    PERFORM guild.revoke_warning_command('00000000-0000-4000-8000-000000000401',
        issued, moderator, 'command correction', '2027-01-06 00:00:00+00');
    PERFORM guild.revoke_warning_command('00000000-0000-4000-8000-000000000401',
        issued, moderator, 'command correction');
    RESET ROLE;
    SELECT count(*) INTO total FROM guild.warning_revocation WHERE warning_key = issued;
    SET LOCAL ROLE guild_runtime;
    IF total <> 1 THEN RAISE EXCEPTION 'revocation command replay created % decisions', total; END IF;
    RESET ROLE;
    IF EXISTS (SELECT FROM guild.active_warning_counts
        WHERE subject_user_key = member_id AND issue_month_gmt = '2027-01-01') THEN
        RAISE EXCEPTION 'revocation command left its warning active';
    END IF;
    SET LOCAL ROLE guild_runtime;
    rejected := false;
    BEGIN
        PERFORM guild.revoke_warning_command('00000000-0000-4000-8000-000000000401',
            issued, moderator, 'different reason');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'revocation operation UUID was reused with other arguments'; END IF;
    rejected := false;
    BEGIN
        PERFORM guild.revoke_warning_command('00000000-0000-4000-8000-000000000402',
            issued, moderator, 'second operation');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'a second operation revoked an already revoked warning'; END IF;
    rejected := false;
    BEGIN
        PERFORM guild.revoke_warning_command('00000000-0000-4000-8000-000000000403',
            october_warning, ordinary_user, 'unauthorized');
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'non-moderator used the revocation command'; END IF;
    RESET ROLE;
    SELECT count(*) INTO total FROM guild.fact_warning_event
    WHERE warning_key = fifth_warning;
    SET LOCAL ROLE guild_runtime;
    IF total <> 2 THEN RAISE EXCEPTION 'issuance and revocation facts not both retained'; END IF;
    IF NOT (SELECT relkind = 'v' FROM pg_class
        WHERE oid = 'guild.fact_warning_event'::regclass) THEN
        RAISE EXCEPTION 'warning history must derive from its immutable source records';
    END IF;
    RESET ROLE;
    IF (SELECT count(DISTINCT warning_event_key) FROM guild.fact_warning_event
        WHERE warning_key = fifth_warning) <> 2 THEN
        RAISE EXCEPTION 'derived warning events lost stable distinct identities';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.fact_warning_event e
        JOIN guild.warning_revocation r USING (warning_key)
        WHERE e.warning_key = fifth_warning AND e.event_kind = 'revoked'
            AND e.actor_user_key = r.revoked_by_user_key AND e.reason = r.reason
            AND e.occurred_at = r.revoked_at AND e.recorded_at = r.recorded_at) THEN
        RAISE EXCEPTION 'derived revocation history lost actor/reason/time evidence';
    END IF;
    SET LOCAL ROLE guild_runtime;
    SELECT count(*) INTO total FROM guild.warning_history(member_id, member_id);
    IF total < 2 THEN RAISE EXCEPTION 'member could not read own warning history'; END IF;
    rejected := false;
    BEGIN
        PERFORM 1 FROM guild.warning_history(ordinary_user, member_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'developer privilege exposed another member warning history'; END IF;

    -- A result is reported with the token of the claim that produced it.
    rejected := false;
    BEGIN
        PERFORM guild.record_moderation_attempt(action_id, gen_random_uuid(), 'succeeded', 204);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'a kick result was accepted without its claim'; END IF;
    SELECT * INTO claim FROM guild.claim_moderation_action(action_id, 'kick-worker');
    IF claim.action IS DISTINCT FROM 'kick' OR claim.claim_token IS NULL THEN
        RAISE EXCEPTION 'an armed kick was not offered with a claim token';
    END IF;
    PERFORM guild.record_moderation_attempt(action_id, claim.claim_token, 'uncertain', NULL,
        'connection_lost');
    RESET ROLE;
    IF (SELECT status FROM guild.moderation_action WHERE moderation_action_key = action_id)
        <> 'uncertain' THEN RAISE EXCEPTION 'uncertain Discord outcome became success'; END IF;
    SET LOCAL ROLE guild_runtime;
    -- An uncertain kick is tried again after the retry delay, not before.
    IF NOT EXISTS (SELECT FROM guild.pending_moderation_action
        WHERE moderation_action_key = action_id AND status = 'uncertain' AND attempts_remaining = 2
            AND next_attempt_at > clock_timestamp() + interval '4 minutes') THEN
        RAISE EXCEPTION 'an uncertain kick was not scheduled for another attempt';
    END IF;
    IF (guild.claim_moderation_action(action_id, 'kick-worker')).action IS NOT NULL THEN
        RAISE EXCEPTION 'an uncertain kick was offered before its retry delay';
    END IF;
    RESET ROLE;
    UPDATE guild.moderation_action SET next_attempt_at = clock_timestamp() - interval '1 second'
    WHERE moderation_action_key = action_id;
    SET LOCAL ROLE guild_runtime;
    SELECT * INTO claim FROM guild.claim_moderation_action(action_id, 'kick-worker');
    IF claim.action IS DISTINCT FROM 'check_member' THEN
        RAISE EXCEPTION 'an uncertain kick was not offered with a member check';
    END IF;
    PERFORM guild.record_moderation_attempt(action_id, claim.claim_token, 'succeeded', 204);
    RESET ROLE;
    SELECT count(*) INTO total FROM guild.fact_moderation_action_attempt
    WHERE moderation_action_key = action_id;
    SET LOCAL ROLE guild_runtime;
    IF total <> 2 THEN RAISE EXCEPTION 'moderation attempt retry history was not retained'; END IF;
    RESET ROLE;
    IF (SELECT status FROM guild.moderation_action WHERE moderation_action_key = action_id)
        <> 'succeeded' THEN RAISE EXCEPTION 'confirmed successful attempt not projected'; END IF;
    SET LOCAL ROLE guild_runtime;

    rejected := false;
    BEGIN
        RESET ROLE;
        UPDATE guild.fact_warning_event SET reason = 'rewritten' WHERE warning_key = fifth_warning;
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'historical warning evidence was editable'; END IF;
END;
$$;
RESET ROLE;

ROLLBACK;
