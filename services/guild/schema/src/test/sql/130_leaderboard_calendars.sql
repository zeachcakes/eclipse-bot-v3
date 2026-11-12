BEGIN;

-- The fixtures below run as guild_runtime, the role of the backend. Between
-- RESET ROLE and the next SET LOCAL ROLE the database administrator runs what
-- that role may not: configuration, private-ledger fixtures, and checks that
-- read a private ledger.
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    v_guild bigint;
    v_staff bigint;
    v_member bigint;
    v_ordinary bigint;
    v_role bigint;
    v_channel bigint;
    v_default_period bigint;
    v_january bigint;
    v_march bigint;
    v_april bigint;
    v_may bigint;
    v_current bigint;
    v_policy bigint;
    v_first_request bigint;
    v_second_request bigint;
    v_award bigint;
    v_xp bigint;
    v_count bigint;
    v_rejected boolean;
    v_period guild.dim_leaderboard_monthly_period%ROWTYPE;
    v_original_end timestamptz;
    v_first_operation uuid := '12121212-1212-4212-8212-121212121212';
    v_second_operation uuid := '13131313-1313-4313-8313-131313131313';
BEGIN
    RESET ROLE;
    INSERT INTO guild.dim_guild (discord_guild_id)
    VALUES (9812000000000000001) RETURNING guild_key INTO v_guild;
    INSERT INTO guild.guild_settings (guild_key) VALUES (v_guild);
    IF (SELECT relkind FROM pg_class WHERE oid = 'guild.leaderboard_calendar_state'::regclass)
        <> 'v' OR EXISTS (SELECT FROM guild.leaderboard_calendar_state WHERE guild_key = v_guild) THEN
        RAISE EXCEPTION 'Calendar selection must be an uninitialized guild-settings projection';
    END IF;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (9812000000000000011) RETURNING user_key INTO v_staff;
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (9812000000000000012) RETURNING user_key INTO v_member;
    INSERT INTO guild.dim_discord_user (discord_user_id)
    VALUES (9812000000000000013) RETURNING user_key INTO v_ordinary;
    RESET ROLE;
    INSERT INTO guild.developer_allowlist (user_key) VALUES (v_staff);
    SET LOCAL ROLE guild_runtime;

    v_default_period := guild.ensure_leaderboard_monthly_period('2024-12-15 12:00:00+00');
    SELECT * INTO STRICT v_period FROM guild.dim_leaderboard_monthly_period
    WHERE period_key = v_default_period;
    IF v_period.timezone_name <> 'Etc/UTC'
        OR v_period.starts_at <> '2024-12-01 00:00:00+00'::timestamptz
        OR v_period.ends_at <> '2025-01-01 00:00:00+00'::timestamptz
        OR v_period.is_transition THEN
        RAISE EXCEPTION 'Initial reporting period did not use the GMT default';
    END IF;
    v_original_end := v_period.ends_at;
    IF NOT EXISTS (SELECT FROM guild.guild_settings
        WHERE guild_key = v_guild
            AND leaderboard_next_policy_key = v_period.calendar_policy_key
            AND leaderboard_next_timezone_name = 'Etc/UTC'
            AND leaderboard_policy_selected_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Initial calendar policy was not selected in guild settings';
    END IF;
    v_rejected := false;
    BEGIN
        RESET ROLE;
        UPDATE guild.guild_settings SET leaderboard_next_timezone_name = NULL
        WHERE guild_key = v_guild;
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN check_violation THEN v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'Partial calendar selection was accepted'; END IF;
    v_rejected := false;
    BEGIN
        RESET ROLE;
        UPDATE guild.leaderboard_calendar_state SET next_timezone_name = 'Asia/Kolkata'
        WHERE guild_key = v_guild;
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'Calendar selection disagreed with its policy'; END IF;
    IF guild.ensure_leaderboard_monthly_period('2024-12-31 23:59:59+00')
        <> v_default_period THEN
        RAISE EXCEPTION 'Repeated period materialization was not idempotent';
    END IF;

    -- Trusted operator fixtures represent historical policy requests. Runtime
    -- configuration uses set_leaderboard_timezone, which fixes the current
    -- period before selecting a next-period policy.
    RESET ROLE;
    INSERT INTO guild.leaderboard_calendar_policy (timezone_name, requested_at, requested_by_user_key, reason)
    VALUES ('America/New_York', '2024-12-20 12:00:00+00', v_staff,
        'Historical transition fixture') RETURNING calendar_policy_key INTO v_policy;
    UPDATE guild.leaderboard_calendar_state
    SET next_policy_key = v_policy, next_timezone_name = 'America/New_York'
    WHERE guild_key = v_guild;
    SET LOCAL ROLE guild_runtime;
    v_january := guild.ensure_leaderboard_monthly_period('2025-01-15 12:00:00+00');
    SELECT * INTO STRICT v_period FROM guild.dim_leaderboard_monthly_period
    WHERE period_key = v_january;
    IF v_period.calendar_month <> '2025-01-01'::date
        OR v_period.starts_at <> v_original_end
        OR v_period.ends_at <> '2025-02-01 05:00:00+00'::timestamptz
        OR NOT v_period.is_transition THEN
        RAISE EXCEPTION 'Timezone transition introduced a gap or changed the old boundary';
    END IF;
    IF (SELECT ends_at FROM guild.dim_leaderboard_monthly_period
        WHERE period_key = v_default_period) <> v_original_end THEN
        RAISE EXCEPTION 'Historical reporting period changed during timezone transition';
    END IF;

    v_march := guild.ensure_leaderboard_monthly_period('2025-03-20 12:00:00+00');
    SELECT * INTO STRICT v_period FROM guild.dim_leaderboard_monthly_period
    WHERE period_key = v_march;
    IF v_period.starts_at <> '2025-03-01 05:00:00+00'::timestamptz
        OR v_period.ends_at <> '2025-04-01 04:00:00+00'::timestamptz
        OR extract(epoch FROM v_period.ends_at - v_period.starts_at) <> 31 * 86400 - 3600
        OR v_period.is_transition THEN
        RAISE EXCEPTION 'Named timezone did not retain the daylight-saving boundary';
    END IF;

    RESET ROLE;
    INSERT INTO guild.leaderboard_calendar_policy (timezone_name, requested_at, requested_by_user_key, reason)
    VALUES ('Asia/Kolkata', '2025-03-20 12:00:00+00', v_staff,
        'Historical eastward transition fixture') RETURNING calendar_policy_key INTO v_policy;
    UPDATE guild.leaderboard_calendar_state
    SET next_policy_key = v_policy, next_timezone_name = 'Asia/Kolkata'
    WHERE guild_key = v_guild;
    SET LOCAL ROLE guild_runtime;
    v_april := guild.ensure_leaderboard_monthly_period('2025-04-15 12:00:00+00');
    SELECT * INTO STRICT v_period FROM guild.dim_leaderboard_monthly_period
    WHERE period_key = v_april;
    IF v_period.starts_at <> '2025-04-01 04:00:00+00'::timestamptz
        OR v_period.ends_at <> '2025-04-30 18:30:00+00'::timestamptz
        OR NOT v_period.is_transition THEN
        RAISE EXCEPTION 'Eastward timezone transition was not explicit and contiguous';
    END IF;
    v_may := guild.ensure_leaderboard_monthly_period('2025-05-15 12:00:00+00');
    SELECT * INTO STRICT v_period FROM guild.dim_leaderboard_monthly_period
    WHERE period_key = v_may;
    IF v_period.starts_at <> '2025-04-30 18:30:00+00'::timestamptz
        OR v_period.ends_at <> '2025-05-31 18:30:00+00'::timestamptz
        OR v_period.is_transition THEN
        RAISE EXCEPTION 'Period after a timezone transition did not return to local boundaries';
    END IF;

    v_rejected := false;
    BEGIN
        RESET ROLE;
        UPDATE guild.dim_leaderboard_monthly_period SET ends_at = ends_at + interval '1 hour'
        WHERE period_key = v_default_period;
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN check_violation THEN v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'Historical period boundary was mutable'; END IF;

    v_rejected := false;
    BEGIN
        RESET ROLE;
        INSERT INTO guild.dim_leaderboard_monthly_period (calendar_policy_key, timezone_name, sequence_number, calendar_month,
                starts_at, ends_at, previous_period_key, is_transition)
        VALUES (v_period.calendar_policy_key, v_period.timezone_name,
            v_period.sequence_number + 1, '2025-06-01', v_period.ends_at + interval '1 second',
            '2025-06-30 18:30:00+00', v_period.period_key, true);
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN check_violation THEN v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'A reporting-period gap was accepted'; END IF;

    v_rejected := false;
    BEGIN
        PERFORM guild.ensure_leaderboard_monthly_period(statement_timestamp() + interval '2 months');
    EXCEPTION WHEN invalid_parameter_value THEN v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'A future period could be frozen prematurely'; END IF;

    v_rejected := false;
    BEGIN
        PERFORM guild.set_leaderboard_timezone(v_ordinary,
            'America/Los_Angeles', 'Unauthorized configuration');
    EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'An ordinary member configured the calendar'; END IF;
    v_rejected := false;
    BEGIN
        PERFORM guild.set_leaderboard_timezone(v_staff,
            'Not/A_Real_Zone', 'Invalid timezone');
    EXCEPTION WHEN invalid_parameter_value THEN v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'An invalid timezone was accepted'; END IF;

    v_current := guild.ensure_leaderboard_monthly_period(statement_timestamp());
    SELECT ends_at INTO v_original_end FROM guild.dim_leaderboard_monthly_period
    WHERE period_key = v_current;
    v_first_request := guild.set_leaderboard_timezone(v_staff,
        'America/Los_Angeles', 'Next period request one', v_first_operation);
    v_second_request := guild.set_leaderboard_timezone(v_staff,
        'Pacific/Auckland', 'Next period request two', v_second_operation);
    IF guild.set_leaderboard_timezone(v_staff,
        'America/Los_Angeles', 'Next period request one', v_first_operation) <> v_first_request THEN
        RAISE EXCEPTION 'Timezone request retry was not idempotent';
    END IF;
    RESET ROLE;
    IF (SELECT next_policy_key FROM guild.leaderboard_calendar_state WHERE guild_key = v_guild)
        <> v_second_request THEN
        RAISE EXCEPTION 'A stale request retry replaced the newer next-period policy';
    END IF;
    SET LOCAL ROLE guild_runtime;
    SELECT * INTO STRICT v_period FROM guild.dim_leaderboard_monthly_period
    WHERE period_key = v_current;
    IF v_period.timezone_name <> 'Asia/Kolkata' OR v_period.ends_at <> v_original_end THEN
        RAISE EXCEPTION 'Timezone configuration changed an active reporting period';
    END IF;
    IF nullif(current_setting('guild.actor_user_key', true), '') IS NOT NULL
        OR nullif(current_setting('guild.change_source', true), '') IS NOT NULL THEN
        RAISE EXCEPTION 'Timezone command leaked its scoped audit context';
    END IF;

    v_rejected := false;
    BEGIN
        PERFORM guild.set_leaderboard_timezone(v_staff,
            'Etc/UTC', 'Next period request one', v_first_operation);
    EXCEPTION WHEN check_violation THEN v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'Conflicting timezone operation identity accepted'; END IF;
    v_rejected := false;
    BEGIN
        RESET ROLE;
        UPDATE guild.leaderboard_calendar_policy SET timezone_name = 'Etc/UTC'
        WHERE calendar_policy_key = v_first_request;
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN check_violation THEN v_rejected := true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'An existing calendar policy was mutable'; END IF;

    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9812000000000000021, 'XP eligibility') RETURNING role_key INTO v_role;
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (9812000000000000031, 'chat') RETURNING channel_key INTO v_channel;
    RESET ROLE;
    INSERT INTO guild.chat_xp_eligibility_role (role_key) VALUES (v_role);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (v_member, 'join', statement_timestamp() - interval '2 hours');
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (v_member, v_role, 'add', statement_timestamp() - interval '1 hour', 'manual');
    v_award := guild.credit_chat_xp(v_member, v_channel,
        9812000000000000101, statement_timestamp());
    IF v_award IS NULL THEN RAISE EXCEPTION 'Eligible member did not earn the leaderboard fixture'; END IF;
    RESET ROLE;
    SELECT xp INTO STRICT v_xp FROM guild.fact_chat_xp_award WHERE xp_award_key = v_award;
    SET LOCAL ROLE guild_runtime;
    IF NOT EXISTS (SELECT FROM guild.chat_xp_current_member_all_time
        WHERE user_key = v_member AND xp_total = v_xp)
        OR NOT EXISTS (SELECT FROM guild.current_chat_xp_monthly_leaderboard
            WHERE period_key = v_current AND user_key = v_member AND xp_total = v_xp) THEN
        RAISE EXCEPTION 'Current member score did not use retained period boundaries';
    END IF;

    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (v_member, 'departure', statement_timestamp() - interval '10 minutes');
    IF EXISTS (SELECT FROM guild.chat_xp_current_member_all_time
        WHERE user_key = v_member)
        OR EXISTS (SELECT FROM guild.chat_xp_monthly_leaderboard
            WHERE user_key = v_member) THEN
        RAISE EXCEPTION 'Departed member remained on current-member leaderboards';
    END IF;
    RESET ROLE;
    IF NOT EXISTS (SELECT FROM guild.fact_chat_xp_award WHERE xp_award_key = v_award AND xp = v_xp) THEN
        RAISE EXCEPTION 'Departure erased retained XP evidence';
    END IF;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (v_member, 'join', statement_timestamp() - interval '5 minutes');
    IF NOT EXISTS (SELECT FROM guild.chat_xp_current_member_all_time
        WHERE user_key = v_member AND xp_total = v_xp) THEN
        RAISE EXCEPTION 'Rejoin did not restore current-member leaderboard eligibility';
    END IF;

    SELECT count(*) INTO v_count FROM guild.leaderboard_metric_definition
    WHERE metric_key = 'war_stars' AND period_kind = 'monthly'
        AND definition_status = 'needs_definition';
    IF v_count <> 1 THEN RAISE EXCEPTION 'Unsupported monthly counter formula was silently invented'; END IF;
    IF has_table_privilege('guild_runtime', 'guild.leaderboard_calendar_state', 'UPDATE') THEN
        RAISE EXCEPTION 'Runtime can bypass the authorized timezone setter';
    END IF;
END;
$$;
RESET ROLE;

ROLLBACK;
