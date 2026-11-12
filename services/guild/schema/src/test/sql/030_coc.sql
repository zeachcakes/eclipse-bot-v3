-- Run against the fully migrated guild database with ON_ERROR_STOP enabled.
BEGIN;
-- The fixtures below run as guild_runtime, the role of the backend. Between
-- RESET ROLE and the next SET LOCAL ROLE the database administrator runs what
-- that role may not: configuration, private-ledger fixtures, and checks that
-- read a private ledger.
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    g bigint; ca bigint; cb bigint; p1 bigint; p2 bigint; p3 bigint; u bigint;
    pa0 bigint; pa3 bigint; pa6 bigint; pb3 bigint; pb6 bigint; pf bigint;
    e bigint; e_again bigint; achievement bigint; progress1 bigint; progress2 bigint;
    assessment1 bigint; assessment2 bigint; member_result bigint; episode1 bigint; episode2 bigint;
    incomplete_member bigint; w bigint; raid bigint;
    donor bigint; idle_member bigint; member_poll bigint; season bigint; next_season bigint;
    n numeric; target numeric; text_result text;
BEGIN
    RESET ROLE;
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (900000000000000030) RETURNING guild_key INTO g;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#P0Y') RETURNING clan_key INTO ca;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#Q0L') RETURNING clan_key INTO cb;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y2') RETURNING player_key INTO p1;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#Q0L2') RETURNING player_key INTO p2;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y9') RETURNING player_key INTO p3;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (900000000000000031) RETURNING user_key INTO u;
    RESET ROLE;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (ca), (cb);
    INSERT INTO guild.war_reminder_setting VALUES (ca, 28800), (ca, 14400);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:a0', '2026-11-22 08:00Z', 'complete') RETURNING poll_key INTO pa0;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:a3', '2026-11-25 08:00Z', 'complete') RETURNING poll_key INTO pa3;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:a6', '2026-11-28 08:00Z', 'complete') RETURNING poll_key INTO pa6;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (cb, 'test-coc:b3', '2026-11-25 08:00Z', 'complete') RETURNING poll_key INTO pb3;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (cb, 'test-coc:b6', '2026-11-28 08:00Z', 'complete') RETURNING poll_key INTO pb6;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome, failure_code)
        VALUES (ca, 'test-coc:failed', '2026-11-29 08:00Z', 'failed', 'timeout') RETURNING poll_key INTO pf;
    BEGIN
        INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
            VALUES (pf, ca, p2, 'observed_departure', '2026-11-29 08:00Z');
        RAISE EXCEPTION 'Failed polling was incorrectly accepted as departure evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, previous_success_at, observed_at)
    VALUES (pa3, ca, p1, 'observed_departure', '2026-11-22 08:00Z', '2026-11-25 08:00Z');
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since, observed_until, confirmed_through,
            boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES
        (p1, ca, '2026-11-22 08:00Z', '2026-11-25 08:00Z', '2026-11-25 08:00Z', 'test-observed-boundary-v1', 'adequate', pa0, pa3),
        (p1, cb, '2026-11-25 08:00Z', NULL, '2026-11-28 08:00Z', 'test-observed-boundary-v1', 'adequate', pb3, pb6),
        (p2, ca, '2026-11-25 08:00Z', NULL, '2026-11-28 08:00Z', 'test-observed-boundary-v1', 'adequate', pa3, pa6);
    RESET ROLE;
    IF NOT guild.is_currently_tracked_player(p1) OR guild.is_currently_tracked_player(p3) THEN
        RAISE EXCEPTION 'Current tracked membership eligibility is incorrect';
    END IF;
    SET LOCAL ROLE guild_runtime;
    BEGIN
        INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since, observed_until, confirmed_through,
                boundary_policy, coverage_status, first_poll_key, last_poll_key)
        VALUES (p1, ca, '2026-11-25 08:00Z', NULL, '2026-11-28 08:00Z', 'test', 'adequate', pa3, pa6);
        RAISE EXCEPTION 'Overlapping membership in two clans was incorrectly accepted';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;

    INSERT INTO guild.fact_player_counter_observation (player_key, observed_at, source_correlation_id, war_stars)
    VALUES (p1, '2026-11-01 00:00Z', 'test-coc:profile1', 100),
            (p1, '2026-11-02 00:00Z', 'test-coc:profile2', 110),
            (p2, '2026-11-02 00:00Z', 'test-coc:profile3', 300),
            (p3, '2026-11-02 00:00Z', 'test-coc:profile4', 900);
    SELECT war_stars INTO n FROM guild.current_clan_lifetime_war_stars WHERE player_key = p1;
    IF n IS DISTINCT FROM 110 THEN RAISE EXCEPTION 'Lifetime stars must take latest snapshot, not sum'; END IF;
    IF EXISTS (SELECT FROM guild.current_clan_lifetime_war_stars WHERE player_key = p3) THEN
        RAISE EXCEPTION 'Non-current account incorrectly appeared on clan leaderboard';
    END IF;
    IF (SELECT count(*) FROM guild.current_clan_lifetime_war_stars) <> 2 THEN
        RAISE EXCEPTION 'Current clan leaderboard must include exactly the two eligible accounts';
    END IF;

    RESET ROLE;
    INSERT INTO guild.guild_settings (guild_key) VALUES (g);
    SET LOCAL ROLE guild_runtime;
    e := guild.create_scheduled_clan_games(2026, 11);
    e_again := guild.create_scheduled_clan_games(2026, 11);
    IF e IS DISTINCT FROM e_again THEN RAISE EXCEPTION 'Scheduled event creation must be idempotent'; END IF;
    SELECT observed_seconds, required_points INTO n, target
        FROM guild.clan_games_observed_target(e, p1, '2026-11-28 08:00Z');
    IF n IS DISTINCT FROM 518400::numeric OR target IS DISTINCT FROM 400::numeric THEN
        RAISE EXCEPTION 'Moving tracked clans must produce six days and one full-account target: %, %', n, target;
    END IF;
    SELECT observed_seconds, required_points INTO n, target
        FROM guild.clan_games_observed_target(e, p1, '2026-11-27 08:00Z');
    IF n IS DISTINCT FROM 432000::numeric OR abs(target - 400::numeric * 432000 / 518400) > 0.00000001 THEN
        RAISE EXCEPTION 'T-24 must use only elapsed membership, divided by full event duration';
    END IF;
    SELECT required_points INTO target FROM guild.clan_games_observed_target(e, p2, '2026-11-28 08:00Z');
    IF target IS DISTINCT FROM 200::numeric THEN RAISE EXCEPTION 'Half-event account must owe 200 points'; END IF;
    SELECT observed_seconds INTO n FROM guild.clan_games_observed_target(e, p1, '2026-12-01 08:00Z');
    IF n IS DISTINCT FROM 518400::numeric THEN RAISE EXCEPTION 'Open membership must stop at event/confirmed boundary'; END IF;

    -- Detailed source-evidence, transfer slicing and rounded member assessments
    -- are exercised independently in 100_clan_games.sql.

    INSERT INTO guild.dim_war
        (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at, team_size, attacks_per_member, identity_source)
    VALUES (ca, cb, '2026-11-01 00:00Z', '2026-11-02 00:00Z', '2026-11-03 00:00Z', 5, 2, 'clan_pair_preparation')
    RETURNING war_key INTO w;
    INSERT INTO guild.war_participant VALUES (w, ca, p1), (w, ca, p2), (w, cb, p3);
    INSERT INTO guild.fact_war_roster_observation
        (war_key, clan_key, player_key, observed_at, source_correlation_id, player_name, town_hall_level, map_position)
    VALUES (w, ca, p1, '2026-11-02 00:00Z', 'test-coc:roster', 'Earlier name', 15, 1);
    INSERT INTO guild.fact_war_attack
        (war_key, attacker_key, defender_key, attack_order, stars, destruction_percentage,
            first_observed_at, last_observed_at, source_correlation_id)
    VALUES (w, p1, p3, 1, 3, 100, '2026-11-02 01:00Z', '2026-11-02 02:00Z', 'test-coc:attack1');
    BEGIN
        INSERT INTO guild.fact_war_attack
            (war_key, attacker_key, defender_key, attack_order, stars, destruction_percentage,
                first_observed_at, last_observed_at, source_correlation_id)
        VALUES (w, p1, p3, 1, 3, 100, '2026-11-02 01:00Z', '2026-11-02 02:00Z', 'test-coc:duplicate');
        RAISE EXCEPTION 'Repeated attack fetch was incorrectly accepted as a second attack';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_war_attack
            (war_key, attacker_key, defender_key, attack_order, stars, destruction_percentage,
                first_observed_at, last_observed_at, source_correlation_id)
        VALUES (w, p1, p2, 2, 3, 100, '2026-11-02 01:00Z', '2026-11-02 02:00Z', 'test-coc:wrong-side');
        RAISE EXCEPTION 'Same-clan attack was incorrectly accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    IF (SELECT occurred_at FROM guild.fact_war_attack WHERE war_key = w) IS NOT NULL THEN
        RAISE EXCEPTION 'Observation time must not silently become attack occurrence time';
    END IF;

    INSERT INTO guild.dim_raid_weekend (clan_key, starts_at, ends_at)
        VALUES (ca, '2026-11-06 07:00Z', '2026-11-09 07:00Z') RETURNING raid_weekend_key INTO raid;
    INSERT INTO guild.fact_raid_member_observation
        (raid_weekend_key, player_key, observed_at, source_correlation_id, capital_resources_looted)
    VALUES (raid, p1, '2026-11-06 08:00Z', 'test-coc:raid1', 1000),
            (raid, p1, '2026-11-06 16:00Z', 'test-coc:raid2', 2000);
    SELECT capital_resources_looted INTO n FROM guild.latest_raid_member_total
        WHERE raid_weekend_key = raid AND player_key = p1;
    IF n IS DISTINCT FROM 2000::numeric THEN RAISE EXCEPTION 'Raid total must select latest rather than sum snapshots'; END IF;

    -- The season calendar: a season ends on the last Monday of the month at 05:00 UTC.
    season := guild.ensure_coc_season('2026-11-30 04:59Z');
    next_season := guild.ensure_coc_season('2026-11-30 05:00Z');
    IF season = next_season OR guild.ensure_coc_season('2026-11-01 00:00Z') <> season
        OR NOT EXISTS (SELECT FROM guild.dim_coc_season WHERE season_key = season
            AND season_month = '2026-11-01' AND starts_at = '2026-10-26 05:00Z'
            AND ends_at = '2026-11-30 05:00Z')
        OR NOT EXISTS (SELECT FROM guild.dim_coc_season WHERE season_key = next_season
            AND season_month = '2026-12-01' AND starts_at = '2026-11-30 05:00Z'
            AND ends_at = '2026-12-28 05:00Z') THEN
        RAISE EXCEPTION 'Season calendar does not end on the last Monday at 05:00 UTC';
    END IF;

    -- A member's state is stored only when it changed.
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0YG') RETURNING player_key INTO donor;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0YL') RETURNING player_key INTO idle_member;
    IF has_table_privilege(current_user, 'guild.fact_clan_member_observation', 'INSERT') THEN
        RAISE EXCEPTION 'Runtime can store member state without the change check';
    END IF;
    BEGIN
        PERFORM guild.record_clan_member_observation(pf, donor, 'member', 1, 1);
        RAISE EXCEPTION 'A failed poll was accepted as member state';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:d1', '2026-11-26 08:00Z', 'complete') RETURNING poll_key INTO member_poll;
    IF NOT guild.record_clan_member_observation(member_poll, donor, 'member', 100, 40)
        OR NOT guild.record_clan_member_observation(member_poll, p2, 'coLeader', 10, 5)
        OR guild.record_clan_member_observation(member_poll, donor, 'member', 100, 40) THEN
        RAISE EXCEPTION 'The first state of a member was not stored exactly once';
    END IF;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:d2', '2026-11-26 08:02Z', 'complete') RETURNING poll_key INTO member_poll;
    IF guild.record_clan_member_observation(member_poll, donor, 'member', 100, 40) THEN
        RAISE EXCEPTION 'An unchanged member state was stored again';
    END IF;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:d3', '2026-11-26 08:04Z', 'complete') RETURNING poll_key INTO member_poll;
    IF NOT guild.record_clan_member_observation(member_poll, donor, 'member', 120, 40) THEN
        RAISE EXCEPTION 'A changed donation counter was not stored';
    END IF;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:d4', '2026-11-26 08:06Z', 'complete') RETURNING poll_key INTO member_poll;
    IF NOT guild.record_clan_member_observation(member_poll, donor, 'elder', 120, 40) THEN
        RAISE EXCEPTION 'A changed role was not stored';
    END IF;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:d5', '2026-11-30 04:58Z', 'complete') RETURNING poll_key INTO member_poll;
    IF NOT guild.record_clan_member_observation(member_poll, donor, 'elder', 150, 40)
        OR NOT guild.record_clan_member_observation(member_poll, idle_member, 'member', 0, 0) THEN
        RAISE EXCEPTION 'The last state before the season end was not stored';
    END IF;
    -- The season ends. The game resets the counters; a member who donated
    -- nothing has the same state as before and still gets a row for the new season.
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:d6', '2026-11-30 05:02Z', 'complete') RETURNING poll_key INTO member_poll;
    IF NOT guild.record_clan_member_observation(member_poll, donor, 'elder', 0, 0)
        OR NOT guild.record_clan_member_observation(member_poll, idle_member, 'member', 0, 0) THEN
        RAISE EXCEPTION 'The first poll of a season did not store a baseline for every member';
    END IF;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:d7', '2026-11-30 05:04Z', 'complete') RETURNING poll_key INTO member_poll;
    IF guild.record_clan_member_observation(member_poll, idle_member, 'member', 0, 0) THEN
        RAISE EXCEPTION 'The season baseline was stored a second time';
    END IF;
    -- The donor leaves at this poll and is back at the next one with the same state.
    INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
    VALUES (member_poll, ca, donor, 'observed_departure', '2026-11-30 05:04Z');
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (ca, 'test-coc:d8', '2026-11-30 05:06Z', 'complete') RETURNING poll_key INTO member_poll;
    IF NOT guild.record_clan_member_observation(member_poll, donor, 'elder', 0, 0) THEN
        RAISE EXCEPTION 'A member who left and returned did not get a new state row';
    END IF;
    IF (SELECT count(*) FROM guild.fact_clan_member_observation WHERE player_key = donor) <> 6
        OR (SELECT count(*) FROM guild.fact_clan_member_observation WHERE player_key = idle_member) <> 2 THEN
        RAISE EXCEPTION 'Member state rows do not match the changes that the polls saw';
    END IF;
    -- A season total is the last counter that a poll saw before the season ended.
    IF NOT EXISTS (SELECT FROM guild.clan_member_season_donation
            WHERE clan_key = ca AND player_key = donor AND season_key = season
                AND donations = 150 AND donations_received = 40
                AND counter_observed_at = '2026-11-30 04:58Z')
        OR NOT EXISTS (SELECT FROM guild.clan_member_season_donation
            WHERE clan_key = ca AND player_key = donor AND season_key = next_season AND donations = 0)
        OR (SELECT count(*) FROM guild.clan_member_season_donation
            WHERE clan_key = ca AND player_key = idle_member AND donations = 0) <> 2 THEN
        RAISE EXCEPTION 'Season donation totals are not the last counters of each season';
    END IF;
    -- The current member list is rebuilt from each member's latest state.
    IF NOT EXISTS (SELECT FROM guild.current_clan_member_state
            WHERE clan_key = ca AND player_key = p2 AND in_game_role = 'coLeader'
                AND donations = 10 AND state_observed_at = '2026-11-26 08:00Z')
        OR EXISTS (SELECT FROM guild.current_clan_member_state WHERE player_key = donor) THEN
        RAISE EXCEPTION 'Current member state does not follow current membership';
    END IF;
    RAISE NOTICE 'CoC assertions passed: membership evidence/overlap, latest counters, event idempotency, proration, war integrity, raid totals, member state on change and season donations';
END;
$$;
RESET ROLE;
ROLLBACK;
