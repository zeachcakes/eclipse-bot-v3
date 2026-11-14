BEGIN;

-- V8: leaderboard calendar policies, reporting periods and the metric catalog.
-- The service computes period boundaries in the policy's zone; these checks
-- cover the keys, the selection and the non-overlapping periods.
DO $$
DECLARE
    guild bigint; actor_id bigint; utc_policy bigint; tokyo_policy bigint; first_period bigint;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (995000000000000001) RETURNING guild_key INTO guild;
    BEGIN
        INSERT INTO guild.leaderboard_metric_definition VALUES
            ('donations', 'monthly', 'player_account', 'latest_lifetime_counter', 'needs_definition', 'Undefined');
        RAISE EXCEPTION 'Unsupported monthly counter formula was silently invented';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    -- GAP-09: donations are a supported per-season board, nothing more.
    IF NOT EXISTS (SELECT FROM guild.leaderboard_metric_definition
        WHERE metric_key = 'donations' AND period_kind = 'season'
            AND calculation_method = 'latest_season_counter' AND definition_status = 'supported') THEN
        RAISE EXCEPTION 'The season donations board is not in the metric catalog';
    END IF;
    IF EXISTS (SELECT FROM guild.leaderboard_metric_definition
        WHERE metric_key = 'donations' AND period_kind <> 'season') THEN
        RAISE EXCEPTION 'A donations board other than the season board was added';
    END IF;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (995000000000000011) RETURNING user_key INTO actor_id;
    IF EXISTS (SELECT FROM guild.leaderboard_calendar_state) THEN
        RAISE EXCEPTION 'Calendar selection must be an uninitialized guild-settings projection';
    END IF;
    BEGIN
        UPDATE guild.leaderboard_metric_definition SET definition_status = 'supported';
        RAISE EXCEPTION 'The runtime role changed the metric catalog';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    BEGIN
        INSERT INTO guild.leaderboard_calendar_policy (reason) VALUES (' ');
        RAISE EXCEPTION 'A calendar policy without a reason was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.leaderboard_calendar_policy (reason) VALUES ('Initial GMT leaderboard calendar')
    RETURNING calendar_policy_key INTO utc_policy;
    INSERT INTO guild.leaderboard_calendar_policy (timezone_name, requested_by_user_key, reason)
    VALUES ('Asia/Tokyo', actor_id, 'Members are in Japan') RETURNING calendar_policy_key INTO tokyo_policy;
    BEGIN
        INSERT INTO guild.leaderboard_calendar_policy (operation_id, timezone_name, reason)
        SELECT operation_id, 'Europe/Paris', 'Retry' FROM guild.leaderboard_calendar_policy
        WHERE calendar_policy_key = tokyo_policy;
        RAISE EXCEPTION 'Conflicting timezone operation identity accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.leaderboard_calendar_policy SET timezone_name = 'Europe/Paris'
        WHERE calendar_policy_key = tokyo_policy;
        RAISE EXCEPTION 'An existing calendar policy was mutable';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    BEGIN
        UPDATE guild.guild_settings SET leaderboard_next_policy_key = utc_policy;
        RAISE EXCEPTION 'Partial calendar selection was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.guild_settings SET leaderboard_next_policy_key = utc_policy,
            leaderboard_next_timezone_name = 'Asia/Tokyo', leaderboard_policy_selected_at = clock_timestamp();
        RAISE EXCEPTION 'Calendar selection disagreed with its policy';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    UPDATE guild.guild_settings SET leaderboard_next_policy_key = utc_policy,
        leaderboard_next_timezone_name = 'Etc/UTC', leaderboard_policy_selected_at = clock_timestamp();
    IF (SELECT next_timezone_name FROM guild.leaderboard_calendar_state) <> 'Etc/UTC' THEN
        RAISE EXCEPTION 'Initial calendar policy was not selected in guild settings';
    END IF;

    BEGIN
        INSERT INTO guild.dim_leaderboard_monthly_period (calendar_policy_key, timezone_name, sequence_number,
            calendar_month, starts_at, ends_at, is_transition)
        VALUES (utc_policy, 'Etc/UTC', 1, '2026-10-15', '2026-10-01 00:00+00', '2026-11-01 00:00+00', false);
        RAISE EXCEPTION 'A reporting month that is not the first of a month was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_leaderboard_monthly_period (calendar_policy_key, timezone_name, sequence_number,
            calendar_month, starts_at, ends_at, is_transition)
        VALUES (utc_policy, 'Asia/Tokyo', 1, '2026-10-01', '2026-10-01 00:00+00', '2026-11-01 00:00+00', false);
        RAISE EXCEPTION 'A period named another zone than its policy';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_leaderboard_monthly_period (calendar_policy_key, timezone_name, sequence_number,
            calendar_month, starts_at, ends_at, is_transition)
        VALUES (utc_policy, 'Etc/UTC', 2, '2026-10-01', '2026-10-01 00:00+00', '2026-11-01 00:00+00', false);
        RAISE EXCEPTION 'A later period was accepted without its predecessor';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.dim_leaderboard_monthly_period (calendar_policy_key, timezone_name, sequence_number,
        calendar_month, starts_at, ends_at, is_transition)
    VALUES (utc_policy, 'Etc/UTC', 1, '2026-10-01', '2026-10-01 00:00+00', '2026-11-01 00:00+00', false)
    RETURNING period_key INTO first_period;
    BEGIN
        INSERT INTO guild.dim_leaderboard_monthly_period (calendar_policy_key, timezone_name, sequence_number,
            calendar_month, starts_at, ends_at, previous_period_key, is_transition)
        VALUES (tokyo_policy, 'Asia/Tokyo', 2, '2026-11-01', '2026-10-31 15:00+00', '2026-11-30 15:00+00',
            first_period, true);
        RAISE EXCEPTION 'Overlapping reporting periods were accepted';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;
    INSERT INTO guild.dim_leaderboard_monthly_period (calendar_policy_key, timezone_name, sequence_number,
        calendar_month, starts_at, ends_at, previous_period_key, is_transition)
    VALUES (tokyo_policy, 'Asia/Tokyo', 2, '2026-11-01', '2026-11-01 00:00+00', '2026-11-30 15:00+00',
        first_period, true);
    BEGIN
        INSERT INTO guild.dim_leaderboard_monthly_period (calendar_policy_key, timezone_name, sequence_number,
            calendar_month, starts_at, ends_at, previous_period_key, is_transition)
        VALUES (tokyo_policy, 'Asia/Tokyo', 3, '2026-12-01', '2026-11-30 15:00+00', '2026-12-31 15:00+00',
            first_period, false);
        RAISE EXCEPTION 'Two periods followed one predecessor';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.dim_leaderboard_monthly_period SET ends_at = '2026-11-02 00:00+00'
        WHERE period_key = first_period;
        RAISE EXCEPTION 'Historical period boundary was mutable';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.dim_leaderboard_monthly_period WHERE period_key = first_period;
        RAISE EXCEPTION 'A reporting period was deleted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'Leaderboard calendar constraints passed';
END;
$$;

ROLLBACK;
