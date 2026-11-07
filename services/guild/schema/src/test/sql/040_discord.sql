BEGIN;
SET LOCAL TIME ZONE 'Asia/Kolkata';

DO $$
DECLARE
    guild bigint;
    member_id bigint;
    moderator bigint;
    ordinary_user bigint;
    leader_role bigint;
    temporary_role bigint;
    channel_a bigint;
    channel_b bigint;
    first_join bigint;
    award bigint;
    first_award bigint;
    issued bigint;
    october_warning bigint;
    fifth_warning bigint;
    action_id bigint;
    n integer;
    total bigint;
    rejected boolean;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (9400000000000000001)
    RETURNING guild_key INTO guild;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9400000000000000011)
    RETURNING user_key INTO member_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9400000000000000012)
    RETURNING user_key INTO moderator;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9400000000000000013)
    RETURNING user_key INTO ordinary_user;
    INSERT INTO guild.dim_discord_role (guild_key, discord_role_id, role_name)
    VALUES (guild, 9400000000000000021, 'Leadership') RETURNING role_key INTO leader_role;
    INSERT INTO guild.dim_discord_role (guild_key, discord_role_id, role_name)
    VALUES (guild, 9400000000000000022, 'New Joinee') RETURNING role_key INTO temporary_role;
    INSERT INTO guild.dim_discord_channel (guild_key, discord_channel_id, channel_name)
    VALUES (guild, 9400000000000000031, 'chat-a') RETURNING channel_key INTO channel_a;
    INSERT INTO guild.dim_discord_channel (guild_key, discord_channel_id, channel_name)
    VALUES (guild, 9400000000000000032, 'chat-b') RETURNING channel_key INTO channel_b;
    INSERT INTO guild.server_role_binding (guild_key, purpose, role_key)
    VALUES (guild, 'leadership', leader_role);
    INSERT INTO guild.developer_allowlist (guild_key, user_key)
    VALUES (guild, ordinary_user);
    INSERT INTO guild.guild_settings (guild_key, new_joinee_days) VALUES (guild, 7);
    INSERT INTO guild.fact_role_change
        (guild_key, user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (guild, moderator, leader_role, 'add', '2026-10-01 00:00:00+00', 'manual');

    INSERT INTO guild.fact_discord_membership_event
        (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, member_id, 'join', '2026-10-31 00:00:00+00')
    RETURNING membership_event_key INTO first_join;
    -- A later configuration change must not rewrite the first join's policy.
    UPDATE guild.guild_settings SET new_joinee_days = 3 WHERE guild_key = guild;
    INSERT INTO guild.fact_role_change
        (guild_key, user_key, role_key, change_kind, changed_at, provenance_kind,
            origin_join_event_key, expires_at)
    VALUES (guild, member_id, temporary_role, 'add', '2026-10-31 01:00:00+00',
        'onboarding', first_join, '2026-11-07 00:00:00+00');
    IF NOT EXISTS (SELECT 1 FROM guild.discord_member_role
        WHERE user_key = member_id AND role_key = temporary_role
            AND expires_at = '2026-11-07 00:00:00+00'::timestamptz) THEN
        RAISE EXCEPTION 'selected join provenance and New Joinee expiry were not retained';
    END IF;
    rejected := false;
    BEGIN
        INSERT INTO guild.fact_role_change
            (guild_key, user_key, role_key, change_kind, changed_at, provenance_kind,
                origin_join_event_key, expires_at)
        VALUES (guild, member_id, temporary_role, 'add', '2026-10-31 01:00:00+00',
            'onboarding', first_join, '2026-11-08 00:00:00+00');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'incorrect New Joinee expiry accepted'; END IF;
    rejected := false;
    BEGIN
        INSERT INTO guild.fact_role_change
            (guild_key, user_key, role_key, change_kind, changed_at, provenance_kind)
        VALUES (guild + 1000000, member_id, leader_role, 'add', now(), 'manual');
    EXCEPTION WHEN foreign_key_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'cross-guild role assignment accepted'; END IF;

    FOR n IN 1..5 LOOP
        award := guild.credit_chat_xp(guild, member_id,
            CASE WHEN n % 2 = 0 THEN channel_a ELSE channel_b END,
            9400000000000000100::numeric + n, '2026-10-31 23:59:01+00');
        IF award IS NULL THEN RAISE EXCEPTION 'one of first five XP awards was denied'; END IF;
        IF n = 1 THEN first_award := award; END IF;
    END LOOP;
    IF guild.credit_chat_xp(guild, member_id, channel_a,
        9400000000000000106, '2026-10-31 23:59:59+00') IS NOT NULL THEN
        RAISE EXCEPTION 'sixth cross-channel message was credited';
    END IF;
    IF guild.credit_chat_xp(guild, member_id, channel_b,
        9400000000000000101, '2026-10-31 23:59:01+00') <> first_award THEN
        RAISE EXCEPTION 'message retry was not idempotent';
    END IF;
    rejected := false;
    BEGIN
        PERFORM guild.credit_chat_xp(guild, ordinary_user, channel_b,
            9400000000000000101, '2026-10-31 23:59:01+00');
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'duplicate message changed XP recipient'; END IF;
    SELECT credited_messages INTO total FROM guild.chat_xp_minute_usage
    WHERE guild_key = guild AND user_key = member_id AND minute_utc = '2026-10-31 23:59:00';
    IF total <> 5 THEN RAISE EXCEPTION 'rejected/retried awards consumed XP allowance'; END IF;
    award := guild.credit_chat_xp(guild, member_id, channel_a,
        9400000000000000107, '2026-11-01 00:00:00+00');
    IF award IS NULL THEN RAISE EXCEPTION 'new UTC minute did not reset XP allowance'; END IF;
    SELECT xp_total INTO total FROM guild.chat_xp_monthly_totals_utc
    WHERE guild_key = guild AND user_key = member_id AND month_utc = '2026-10-01';
    IF total <> 100 THEN RAISE EXCEPTION 'UTC monthly XP aggregation was incorrect'; END IF;
    SELECT xp_total INTO total FROM guild.chat_xp_monthly_totals_utc
    WHERE guild_key = guild AND user_key = member_id AND month_utc = '2026-11-01';
    IF total <> 20 THEN RAISE EXCEPTION 'XP month boundary was affected by session timezone'; END IF;

    INSERT INTO guild.fact_discord_membership_event
        (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, member_id, 'departure', '2026-11-02 00:00:00+00'),
        (guild, member_id, 'join', '2026-10-30 00:00:00+00');
    IF (SELECT is_present FROM guild.discord_member_state
        WHERE guild_key = guild AND user_key = member_id) THEN
        RAISE EXCEPTION 'out-of-order join replaced a newer departure';
    END IF;
    SELECT xp_total INTO total FROM guild.chat_xp_all_time_totals
    WHERE guild_key = guild AND user_key = member_id;
    IF total <> 120 THEN RAISE EXCEPTION 'departure erased XP'; END IF;
    INSERT INTO guild.fact_discord_membership_event
        (guild_key, user_key, event_kind, occurred_at)
    VALUES (guild, member_id, 'join', '2026-11-03 00:00:00+00');
    IF NOT (SELECT is_present FROM guild.discord_member_state
        WHERE guild_key = guild AND user_key = member_id) THEN
        RAISE EXCEPTION 'rejoin did not restore member projection';
    END IF;
    INSERT INTO guild.fact_role_change
        (guild_key, user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (guild, member_id, temporary_role, 'remove', '2026-11-07 00:00:00+00', 'new_joinee_expiry'),
        (guild, member_id, temporary_role, 'add', '2026-11-01 00:00:00+00', 'reconciliation');
    IF EXISTS (SELECT 1 FROM guild.discord_member_role
        WHERE guild_key = guild AND user_key = member_id AND role_key = temporary_role) THEN
        RAISE EXCEPTION 'out-of-order role add restored a removed role';
    END IF;

    rejected := false;
    BEGIN
        PERFORM guild.issue_warning(guild, member_id, ordinary_user, 'unauthorized', now());
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'developer without moderation role issued warning'; END IF;
    rejected := false;
    BEGIN
        PERFORM guild.issue_warning(guild, member_id, moderator, '  ', now());
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'blank warning reason accepted'; END IF;

    october_warning := guild.issue_warning(guild, member_id, moderator,
        'October issue near GMT boundary', '2026-11-01 00:30:00+01');
    FOR n IN 1..5 LOOP
        issued := guild.issue_warning(guild, member_id, moderator,
            'November reason ' || n::text, '2026-11-01 01:00:00+00');
        IF n = 4 AND EXISTS (SELECT 1 FROM guild.moderation_action WHERE guild_key = guild) THEN
            RAISE EXCEPTION 'kick was requested before fifth valid monthly warning';
        END IF;
    END LOOP;
    fifth_warning := issued;
    SELECT moderation_action_key INTO STRICT action_id FROM guild.moderation_action
    WHERE guild_key = guild AND subject_user_key = member_id AND warning_month_gmt = '2026-11-01';
    IF (SELECT status FROM guild.moderation_action WHERE moderation_action_key = action_id)
        <> 'pending' THEN RAISE EXCEPTION 'kick request was incorrectly marked executed'; END IF;
    PERFORM guild.revoke_warning(fifth_warning, moderator, 'staff correction', '2026-11-02 00:00:00+00');
    SELECT active_warnings INTO total FROM guild.active_warning_counts
    WHERE guild_key = guild AND subject_user_key = member_id AND issue_month_gmt = '2026-11-01';
    IF total <> 4 THEN RAISE EXCEPTION 'revocation did not remove exactly one warning'; END IF;
    PERFORM guild.revoke_warning(october_warning, moderator, 'late correction', '2026-11-02 00:00:00+00');
    SELECT active_warnings INTO total FROM guild.active_warning_counts
    WHERE guild_key = guild AND subject_user_key = member_id AND issue_month_gmt = '2026-11-01';
    IF total <> 4 THEN RAISE EXCEPTION 'cross-month revocation reduced the wrong month'; END IF;
    rejected := false;
    BEGIN
        PERFORM guild.revoke_warning(fifth_warning, moderator, 'duplicate correction', now());
    EXCEPTION WHEN unique_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'warning was revoked twice'; END IF;
    PERFORM guild.issue_warning(guild, member_id, moderator, 'sixth issued warning', '2026-11-03 00:00:00+00');
    SELECT count(*) INTO total FROM guild.moderation_action WHERE guild_key = guild;
    IF total <> 1 THEN RAISE EXCEPTION 'duplicate kick decision created for same month'; END IF;
    PERFORM guild.issue_warning(guild, member_id, moderator, 'new calendar month', '2026-12-01 00:00:00+00');
    SELECT active_warnings INTO total FROM guild.active_warning_counts
    WHERE guild_key = guild AND subject_user_key = member_id AND issue_month_gmt = '2026-12-01';
    IF total <> 1 THEN RAISE EXCEPTION 'new GMT month retained earlier active count'; END IF;
    SELECT count(*) INTO total FROM guild.fact_warning_event
    WHERE warning_key = fifth_warning;
    IF total <> 2 THEN RAISE EXCEPTION 'issuance and revocation facts not both retained'; END IF;
    SELECT count(*) INTO total FROM guild.warning_history(guild, member_id, member_id);
    IF total < 2 THEN RAISE EXCEPTION 'member could not read own warning history'; END IF;
    rejected := false;
    BEGIN
        PERFORM 1 FROM guild.warning_history(guild, ordinary_user, member_id);
    EXCEPTION WHEN insufficient_privilege THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'developer privilege exposed another member warning history'; END IF;

    PERFORM guild.record_moderation_attempt(action_id, 'uncertain', NULL, 'connection_lost');
    IF (SELECT status FROM guild.moderation_action WHERE moderation_action_key = action_id)
        <> 'uncertain' THEN RAISE EXCEPTION 'uncertain Discord outcome became success'; END IF;
    PERFORM guild.record_moderation_attempt(action_id, 'succeeded', 204);
    SELECT count(*) INTO total FROM guild.fact_moderation_action_attempt
    WHERE moderation_action_key = action_id;
    IF total <> 2 THEN RAISE EXCEPTION 'moderation attempt retry history was not retained'; END IF;
    IF (SELECT status FROM guild.moderation_action WHERE moderation_action_key = action_id)
        <> 'succeeded' THEN RAISE EXCEPTION 'confirmed successful attempt not projected'; END IF;

    rejected := false;
    BEGIN
        UPDATE guild.fact_warning_event SET reason = 'rewritten' WHERE warning_key = fifth_warning;
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'historical warning evidence was editable'; END IF;
END;
$$;

ROLLBACK;
