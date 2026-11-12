-- A failed or incomplete request must never turn current membership into history.
BEGIN;
DO $$
DECLARE
    g bigint; ca bigint; cb bigint; p1 bigint; p2 bigint; p3 bigint;
    first_poll bigint; positive_poll bigint; failed_poll bigint; incomplete_poll bigint;
    closing_poll bigint; recent_poll bigint; stale_poll bigint; wrong_clan_poll bigint;
    period1 bigint; period2 bigint;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (900000000000000070) RETURNING guild_key INTO g;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#P0Y20') RETURNING clan_key INTO ca;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#Q0L20') RETURNING clan_key INTO cb;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y202') RETURNING player_key INTO p1;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#Q0L202') RETURNING player_key INTO p2;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y209') RETURNING player_key INTO p3;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (ca), (cb);
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-membership-close:first', '2026-11-01 10:00Z', 'complete') RETURNING poll_key INTO first_poll;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-membership-close:positive', '2026-11-01 10:02Z', 'complete') RETURNING poll_key INTO positive_poll;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome, failure_code)
        VALUES (ca, 'test-membership-close:failed', '2026-11-01 10:04Z', 'failed', 'timeout') RETURNING poll_key INTO failed_poll;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-membership-close:incomplete', '2026-11-01 10:06Z', 'incomplete') RETURNING poll_key INTO incomplete_poll;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-membership-close:closing', '2026-11-01 10:08Z', 'complete') RETURNING poll_key INTO closing_poll;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-membership-close:stale', '2026-11-01 10:10Z', 'complete') RETURNING poll_key INTO stale_poll;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-membership-close:recent', '2026-11-01 10:12Z', 'complete') RETURNING poll_key INTO recent_poll;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (cb, 'test-membership-close:wrong-clan', '2026-11-01 10:14Z', 'complete') RETURNING poll_key INTO wrong_clan_poll;
    -- A member's state is stored once and not repeated for later polls.
    INSERT INTO guild.fact_clan_member_observation (poll_key, player_key) VALUES
        (first_poll, p1), (first_poll, p2);
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since, confirmed_through,
            boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (p1, ca, '2026-11-01 10:00Z', '2026-11-01 10:02Z',
            'observed-boundary-v1', 'adequate', first_poll, positive_poll)
    RETURNING membership_period_key INTO period1;
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since, confirmed_through,
            boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (p2, ca, '2026-11-01 10:00Z', '2026-11-01 10:12Z',
            'observed-boundary-v1', 'adequate', first_poll, recent_poll)
    RETURNING membership_period_key INTO period2;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET observed_until = '2026-11-01 10:04Z'
        WHERE membership_period_key = period1;
        RAISE EXCEPTION 'Failed-poll time incorrectly closed current membership';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET observed_until = '2026-11-01 10:06Z'
        WHERE membership_period_key = period1;
        RAISE EXCEPTION 'Incomplete-poll time incorrectly closed current membership';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
        VALUES (failed_poll, ca, p1, 'observed_departure', '2026-11-01 10:04Z');
        RAISE EXCEPTION 'Failed poll incorrectly supplied explicit departure evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
        VALUES (incomplete_poll, ca, p1, 'observed_departure', '2026-11-01 10:06Z');
        RAISE EXCEPTION 'Incomplete poll incorrectly supplied explicit departure evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET observed_until = '2026-11-01 10:08Z'
        WHERE membership_period_key = period1;
        RAISE EXCEPTION 'An unprocessed member-observation table was incorrectly treated as departure proof';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    IF NOT guild.is_currently_tracked_player(p1) THEN
        RAISE EXCEPTION 'Rejected closure changed current membership';
    END IF;
    INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, previous_success_at, observed_at)
    VALUES (closing_poll, ca, p1, 'observed_departure', '2026-11-01 10:02Z', '2026-11-01 10:08Z'),
            (stale_poll, ca, p2, 'observed_departure', '2026-11-01 10:02Z', '2026-11-01 10:10Z'),
            (wrong_clan_poll, cb, p2, 'observed_departure', NULL, '2026-11-01 10:14Z');
    UPDATE guild.observed_clan_membership_period SET observed_until = '2026-11-01 10:08Z'
    WHERE membership_period_key = period1;
    IF guild.is_currently_tracked_player(p1) THEN
        RAISE EXCEPTION 'Supported closure left an account in current membership';
    END IF;
    IF (SELECT confirmed_through FROM guild.observed_clan_membership_period
        WHERE membership_period_key = period1) IS DISTINCT FROM '2026-11-01 10:02Z'::timestamptz THEN
        RAISE EXCEPTION 'Closing evidence must not overwrite the last positive confirmation';
    END IF;
    BEGIN
        UPDATE guild.observed_clan_membership_period
        SET observed_until = '2026-11-01 10:10Z', confirmed_through = '2026-11-01 10:02Z', last_poll_key = positive_poll
        WHERE membership_period_key = period2;
        RAISE EXCEPTION 'Out-of-order departure incorrectly rewound newer positive evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET observed_until = '2026-11-01 10:14Z'
        WHERE membership_period_key = period2;
        RAISE EXCEPTION 'Another clan departure incorrectly closed this clan membership';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET player_key = p3 WHERE membership_period_key = period2;
        RAISE EXCEPTION 'Reassigning the row incorrectly hid current membership without closure evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET observed_until = NULL WHERE membership_period_key = period1;
        RAISE EXCEPTION 'A closed historical interval was incorrectly reopened in place';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    IF NOT guild.is_currently_tracked_player(p2) THEN
        RAISE EXCEPTION 'Stale or unrelated evidence changed current membership';
    END IF;
    IF has_function_privilege('guild_runtime',
        'guild.membership_has_closing_evidence(bigint,bigint,timestamp with time zone)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Internal evidence helper must not expose additional runtime authority';
    END IF;
    RAISE NOTICE 'Membership closure assertions passed: failure/incomplete/unsupported/stale closures rejected, exact departure accepted, confirmation gap preserved';
END;
$$;
SET LOCAL ROLE guild_runtime;
DO $$
BEGIN
    BEGIN
        UPDATE guild.observed_clan_membership_period SET observed_until = '2026-11-01 10:14Z'
        WHERE player_key = (SELECT player_key FROM guild.dim_player_account WHERE player_tag = '#Q0L202');
        RAISE EXCEPTION 'Runtime collector incorrectly closed membership without matching evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$$;
RESET ROLE;
ROLLBACK;
