-- Run against the fully migrated guild database with ON_ERROR_STOP enabled.
BEGIN;
DO $$
DECLARE
    g bigint; ca bigint; cb bigint; p1 bigint; p2 bigint; p3 bigint; u bigint;
    pa0 bigint; pa3 bigint; pa6 bigint; pb3 bigint; pb6 bigint; pf bigint;
    e bigint; e_again bigint; achievement bigint; progress1 bigint; progress2 bigint;
    assessment1 bigint; assessment2 bigint; member_result bigint; episode1 bigint; episode2 bigint;
    incomplete_member bigint; w bigint; raid bigint;
    n numeric; target numeric; text_result text;
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (900000000000000030) RETURNING guild_key INTO g;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#P0Y') RETURNING clan_key INTO ca;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#Q0L') RETURNING clan_key INTO cb;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y2') RETURNING player_key INTO p1;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#Q0L2') RETURNING player_key INTO p2;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y9') RETURNING player_key INTO p3;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (900000000000000031) RETURNING user_key INTO u;
    INSERT INTO guild.clan_collection_settings (guild_key, clan_key) VALUES (g, ca), (g, cb);
    INSERT INTO guild.war_reminder_setting VALUES (g, ca, 28800), (g, ca, 14400);
    INSERT INTO guild.clan_membership_poll (guild_key, clan_key, source_correlation_id, observed_at, outcome)
        VALUES (g, ca, 'test-coc:a0', '2026-11-22 08:00Z', 'complete') RETURNING poll_key INTO pa0;
    INSERT INTO guild.clan_membership_poll (guild_key, clan_key, source_correlation_id, observed_at, outcome)
        VALUES (g, ca, 'test-coc:a3', '2026-11-25 08:00Z', 'complete') RETURNING poll_key INTO pa3;
    INSERT INTO guild.clan_membership_poll (guild_key, clan_key, source_correlation_id, observed_at, outcome)
        VALUES (g, ca, 'test-coc:a6', '2026-11-28 08:00Z', 'complete') RETURNING poll_key INTO pa6;
    INSERT INTO guild.clan_membership_poll (guild_key, clan_key, source_correlation_id, observed_at, outcome)
        VALUES (g, cb, 'test-coc:b3', '2026-11-25 08:00Z', 'complete') RETURNING poll_key INTO pb3;
    INSERT INTO guild.clan_membership_poll (guild_key, clan_key, source_correlation_id, observed_at, outcome)
        VALUES (g, cb, 'test-coc:b6', '2026-11-28 08:00Z', 'complete') RETURNING poll_key INTO pb6;
    INSERT INTO guild.clan_membership_poll (guild_key, clan_key, source_correlation_id, observed_at, outcome, failure_code)
        VALUES (g, ca, 'test-coc:failed', '2026-11-29 08:00Z', 'failed', 'timeout') RETURNING poll_key INTO pf;
    BEGIN
        INSERT INTO guild.fact_clan_membership_change (poll_key, guild_key, clan_key, player_key, change_kind, observed_at)
            VALUES (pf, g, ca, p2, 'observed_departure', '2026-11-29 08:00Z');
        RAISE EXCEPTION 'Failed polling was incorrectly accepted as departure evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_membership_change
        (poll_key, guild_key, clan_key, player_key, change_kind, previous_success_at, observed_at)
    VALUES (pa3, g, ca, p1, 'observed_departure', '2026-11-22 08:00Z', '2026-11-25 08:00Z');
    INSERT INTO guild.observed_clan_membership_period
        (guild_key, player_key, clan_key, observed_since, observed_until, confirmed_through,
            boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES
        (g, p1, ca, '2026-11-22 08:00Z', '2026-11-25 08:00Z', '2026-11-25 08:00Z', 'test-observed-boundary-v1', 'adequate', pa0, pa3),
        (g, p1, cb, '2026-11-25 08:00Z', NULL, '2026-11-28 08:00Z', 'test-observed-boundary-v1', 'adequate', pb3, pb6),
        (g, p2, ca, '2026-11-25 08:00Z', NULL, '2026-11-28 08:00Z', 'test-observed-boundary-v1', 'adequate', pa3, pa6);
    IF NOT guild.is_currently_tracked_player(g, p1) OR guild.is_currently_tracked_player(g, p3) THEN
        RAISE EXCEPTION 'Current tracked membership eligibility is incorrect';
    END IF;
    BEGIN
        INSERT INTO guild.observed_clan_membership_period
            (guild_key, player_key, clan_key, observed_since, observed_until, confirmed_through,
                boundary_policy, coverage_status, first_poll_key, last_poll_key)
        VALUES (g, p1, ca, '2026-11-25 08:00Z', NULL, '2026-11-28 08:00Z', 'test', 'adequate', pa3, pa6);
        RAISE EXCEPTION 'Overlapping membership in two clans was incorrectly accepted';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;

    INSERT INTO guild.fact_player_counter_observation (player_key, observed_at, source_correlation_id, war_stars)
    VALUES (p1, '2026-11-01 00:00Z', 'test-coc:profile1', 100),
            (p1, '2026-11-02 00:00Z', 'test-coc:profile2', 110),
            (p2, '2026-11-02 00:00Z', 'test-coc:profile3', 300),
            (p3, '2026-11-02 00:00Z', 'test-coc:profile4', 900);
    SELECT war_stars INTO n FROM guild.current_clan_lifetime_war_stars WHERE guild_key = g AND player_key = p1;
    IF n IS DISTINCT FROM 110 THEN RAISE EXCEPTION 'Lifetime stars must take latest snapshot, not sum'; END IF;
    IF EXISTS (SELECT FROM guild.current_clan_lifetime_war_stars WHERE guild_key = g AND player_key = p3) THEN
        RAISE EXCEPTION 'Non-current account incorrectly appeared on clan leaderboard';
    END IF;
    IF (SELECT count(*) FROM guild.current_clan_lifetime_war_stars WHERE guild_key = g) <> 2 THEN
        RAISE EXCEPTION 'Current clan leaderboard must include exactly the two eligible accounts';
    END IF;

    INSERT INTO guild.clan_games_schedule (guild_key) VALUES (g);
    e := guild.create_scheduled_clan_games(g, 2026, 11);
    e_again := guild.create_scheduled_clan_games(g, 2026, 11);
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

    INSERT INTO guild.dim_achievement (source_name, village) VALUES ('Games Champion', 'home') RETURNING achievement_key INTO achievement;
    INSERT INTO guild.fact_player_achievement_observation
        (player_key, achievement_key, observed_at, source_correlation_id, value)
    VALUES (p1, achievement, '2026-11-22 08:00Z', 'test-coc:achievement0', 10000),
            (p1, achievement, '2026-11-28 08:00Z', 'test-coc:achievement6', 10400);
    INSERT INTO guild.fact_clan_games_progress
        (event_key, player_key, observed_at, source_correlation_id, measurement_method,
            evidence_status, points, baseline_achievement_key, baseline_observed_at,
            ending_achievement_key, ending_observed_at, evidence_note)
    VALUES (e, p1, '2026-11-28 08:00Z', 'test-coc:progress1', 'achievement_delta', 'adequate', 400,
            achievement, '2026-11-22 08:00Z', achievement, '2026-11-28 08:00Z', 'Synthetic boundary-complete evidence')
    RETURNING progress_key INTO progress1;
    BEGIN
        INSERT INTO guild.fact_clan_games_progress
            (event_key, player_key, observed_at, source_correlation_id, measurement_method,
                evidence_status, points, baseline_achievement_key, baseline_observed_at,
                ending_achievement_key, ending_observed_at, evidence_note)
        VALUES (e, p1, '2026-11-28 08:01Z', 'test-coc:bad-delta', 'achievement_delta', 'adequate', 399,
                achievement, '2026-11-22 08:00Z', achievement, '2026-11-28 08:00Z', 'Invalid difference');
        RAISE EXCEPTION 'Unsupported achievement difference was incorrectly accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_games_progress
        (event_key, player_key, observed_at, source_correlation_id, measurement_method, evidence_status, points, evidence_note)
    VALUES (e, p2, '2026-11-28 08:00Z', 'test-coc:progress2', 'manual_evidence', 'adequate', 100, 'Synthetic evidence')
    RETURNING progress_key INTO progress2;
    INSERT INTO guild.fact_clan_games_account_assessment
        (event_key, player_key, checkpoint_kind, checkpoint_at, calculation_version, rule_version,
            attribution_policy, membership_status, points_status, attribution_status, progress_key,
            observed_seconds, eligible_points, required_points, evidence_note)
    VALUES (e, p1, 'final', '2026-11-28 08:00Z', 1, 'unrounded-v1', 'test-explicit-input-v1',
            'adequate', 'adequate', 'adequate', progress1, 518400, 400, 400, 'Synthetic supported assessment')
    RETURNING account_assessment_key INTO assessment1;
    INSERT INTO guild.fact_clan_games_account_assessment
        (event_key, player_key, checkpoint_kind, checkpoint_at, calculation_version, rule_version,
            attribution_policy, membership_status, points_status, attribution_status, progress_key,
            observed_seconds, eligible_points, required_points, evidence_note)
    VALUES (e, p2, 'final', '2026-11-28 08:00Z', 1, 'unrounded-v1', 'test-explicit-input-v1',
            'adequate', 'adequate', 'adequate', progress2, 259200, 100, 200, 'Synthetic supported assessment')
    RETURNING account_assessment_key INTO assessment2;
    INSERT INTO guild.fact_clan_games_member_assessment
        (event_key, user_key, checkpoint_kind, calculation_version, attribution_policy, attribution_status, evidence_note)
    VALUES (e, u, 'final', 1, 'test-explicit-input-v1', 'adequate', 'Synthetic explicit ownership inputs')
    RETURNING member_assessment_key INTO member_result;
    INSERT INTO guild.metric_attribution_episode
        (guild_key, user_key, player_key, first_link_at, include_prelink_history)
    VALUES (g, u, p1, '2026-11-22 08:00Z', true) RETURNING attribution_key INTO episode1;
    INSERT INTO guild.metric_attribution_episode
        (guild_key, user_key, player_key, first_link_at, include_prelink_history)
    VALUES (g, u, p2, '2026-11-25 08:00Z', true) RETURNING attribution_key INTO episode2;
    INSERT INTO guild.clan_games_member_account_input
        (member_assessment_key, account_assessment_key, event_key, checkpoint_kind, player_key, attribution_key)
    VALUES (member_result, assessment1, e, 'final', p1, episode1),
            (member_result, assessment2, e, 'final', p2, episode2);
    SELECT result, required_points INTO text_result, target FROM guild.clan_games_member_result
        WHERE member_assessment_key = member_result;
    IF text_result IS DISTINCT FROM 'fail' OR target IS DISTINCT FROM 600::numeric THEN
        RAISE EXCEPTION 'Member result must sum account targets once across clans';
    END IF;
    BEGIN
        INSERT INTO guild.clan_games_member_account_input
            (member_assessment_key, account_assessment_key, event_key, checkpoint_kind, player_key, attribution_key)
        VALUES (member_result, assessment1, e, 'final', p1, episode1);
        RAISE EXCEPTION 'Duplicate account member input was incorrectly accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_games_member_assessment
        (event_key, user_key, checkpoint_kind, calculation_version, attribution_policy, attribution_status, evidence_note)
    VALUES (e, u, 'final', 2, 'test-explicit-input-v1', 'adequate', 'Unfinished evidence inputs')
    RETURNING member_assessment_key INTO incomplete_member;
    BEGIN
        INSERT INTO guild.clan_games_member_account_input
            (member_assessment_key, account_assessment_key, event_key, checkpoint_kind, player_key, attribution_key)
        VALUES (incomplete_member, assessment1, e, 'final', p1, episode2);
        RAISE EXCEPTION 'Attribution episode for a different account was incorrectly accepted';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    SELECT result INTO text_result FROM guild.clan_games_member_result
        WHERE member_assessment_key = incomplete_member;
    IF text_result IS DISTINCT FROM 'insufficient_data' THEN
        RAISE EXCEPTION 'A member assessment without account inputs must be insufficient';
    END IF;
    BEGIN
        INSERT INTO guild.fact_clan_games_account_assessment
            (event_key, player_key, checkpoint_kind, checkpoint_at, calculation_version, rule_version,
                attribution_policy, membership_status, points_status, attribution_status, progress_key,
                observed_seconds, eligible_points, required_points, evidence_note)
        VALUES (e, p2, 'final', '2026-11-28 08:00Z', 2, 'unrounded-v1', 'test-explicit-input-v1',
                'adequate', 'adequate', 'adequate', progress2, 518400, 100, 400, 'Unsupported full-event time');
        RAISE EXCEPTION 'Adequate membership time exceeding actual evidence was incorrectly accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_games_account_assessment
            (event_key, player_key, checkpoint_kind, checkpoint_at, calculation_version, rule_version,
                attribution_policy, membership_status, points_status, attribution_status, progress_key,
                observed_seconds, eligible_points, required_points, evidence_note)
        VALUES (e, p1, 't_minus_24h', '2026-11-27 08:00Z', 1, 'unrounded-v1', 'test-explicit-input-v1',
                'adequate', 'adequate', 'adequate', progress1, 432000, 400,
                400::numeric * 432000 / 518400, 'Future points must not reconstruct the checkpoint');
        RAISE EXCEPTION 'Post-checkpoint points were incorrectly accepted as T-24 evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_games_account_assessment
        (event_key, player_key, checkpoint_kind, checkpoint_at, calculation_version, rule_version,
            attribution_policy, membership_status, points_status, attribution_status,
            observed_seconds, eligible_points, required_points, evidence_note)
    VALUES (e, p3, 'final', '2026-11-28 08:00Z', 1, 'unrounded-v1', 'pending',
            'insufficient_data', 'insufficient_data', 'insufficient_data', 0, NULL, 0, 'Missing historical evidence');
    SELECT result INTO text_result FROM guild.fact_clan_games_account_assessment
        WHERE event_key = e AND player_key = p3;
    IF text_result IS DISTINCT FROM 'insufficient_data' THEN
        RAISE EXCEPTION 'Missing observations must not become a zero-point pass or failure';
    END IF;
    BEGIN
        INSERT INTO guild.fact_clan_games_account_assessment
            (event_key, player_key, checkpoint_kind, checkpoint_at, calculation_version, rule_version,
                attribution_policy, membership_status, points_status, attribution_status,
                observed_seconds, eligible_points, required_points, evidence_note)
        VALUES (e, p3, 'final', '2026-11-28 08:00Z', 2, 'unrounded-v1', 'pending',
                'insufficient_data', 'insufficient_data', 'insufficient_data', 259200, NULL, 0, 'Invalid exemption');
        RAISE EXCEPTION 'Zero-target staff exemption was incorrectly accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

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
    RAISE NOTICE 'CoC assertions passed: membership evidence/overlap, latest counters, event idempotency, proration, points provenance, unknowns, member sums, war integrity and raid totals';
END;
$$;
ROLLBACK;
