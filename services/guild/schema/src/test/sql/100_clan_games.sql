BEGIN;
SET LOCAL plpgsql.check_asserts = on;

CREATE FUNCTION pg_temp.cg_read(
    g bigint, e bigint, p bigint, achievement bigint, kind text,
    due timestamptz, observed timestamptz, counter bigint,
    transfer_id bigint DEFAULT NULL, freshness text DEFAULT 'adequate',
    clan_override bigint DEFAULT NULL
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE request_id bigint; fetch_id bigint; result_id bigint; profile_clan bigint;
    pending_due timestamptz;
BEGIN
    -- A player has one pending regular request, so a regular read answers it
    -- at the time that request is due.
    IF kind = 'regular' THEN
        SELECT request_key, due_at INTO request_id, pending_due FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = 'regular' AND status = 'pending';
        due := coalesce(pending_due, due);
    END IF;
    IF request_id IS NULL THEN
        INSERT INTO guild.clan_games_read_request
            (event_key, player_key, purpose, due_at, transfer_request_key)
        VALUES (e, p, kind, due, transfer_id)
        ON CONFLICT (event_key, player_key, purpose, due_at, transfer_request_key) DO NOTHING
        RETURNING request_key INTO request_id;
    END IF;
    IF request_id IS NULL THEN
        SELECT request_key INTO request_id FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = kind AND due_at = due
            AND transfer_request_key IS NOT DISTINCT FROM transfer_id;
    END IF;
    INSERT INTO guild.fact_api_fetch_attempt (
        player_key, source_correlation_id, endpoint_kind,
        started_at, completed_at, http_status, outcome
    ) VALUES (p, gen_random_uuid()::text, 'player_profile',
        observed - interval '1 second', observed, 200, 'succeeded')
    RETURNING fetch_key INTO fetch_id;
    INSERT INTO guild.fact_player_achievement_observation
        (player_key, achievement_key, observed_at, source_correlation_id, value, target, stars)
    VALUES (p, achievement, observed, gen_random_uuid()::text, counter, 100000, 3)
    ON CONFLICT (player_key, achievement_key, observed_at) DO NOTHING;
    SELECT clan_key INTO profile_clan FROM guild.observed_clan_membership_period
    WHERE player_key = p AND observed_since <= observed
        AND (observed_until IS NULL OR observed_until > observed);
    profile_clan := coalesce(clan_override, profile_clan);
    INSERT INTO guild.clan_games_counter_read (
        request_key, event_key, player_key, transfer_request_key, source_fetch_key,
        achievement_key, observed_at, boundary_at, source_as_of, freshness_status, freshness_policy,
        observed_clan_key, clan_observation_status
    ) VALUES (request_id, e, p, transfer_id, fetch_id, achievement, observed,
        CASE WHEN kind = 'transfer' THEN observed ELSE due END, observed, freshness, 'synthetic-exact-boundary',
        profile_clan, CASE WHEN profile_clan IS NULL THEN 'no_clan' ELSE 'known' END)
    RETURNING read_key INTO result_id;
    RETURN result_id;
END;
$$;

-- The fixtures below run as guild_runtime, the role of the backend. Between
-- RESET ROLE and the next SET LOCAL ROLE the database administrator runs what
-- that role may not: configuration, private-ledger fixtures, and checks that
-- read a private ledger.
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    g bigint; clan_id bigint; other_clan bigint; p bigint; p2 bigint; p3 bigint; missing_player bigint;
    alice bigint; bob bigint; other_member bigint; staff bigint; role_id bigint;
    e bigint; achievement bigint; wrong_achievement bigint; poll0 bigint; poll6 bigint; poll_short bigint;
    verification_id bigint; link_id bigint; transfer_id bigint; old_episode bigint; new_episode bigint;
    other_episode2 bigint; other_episode3 bigint;
    b bigint; b2 bigint; b3 bigint; first_read bigint; first2 bigint; first3 bigint;
    transfer_read bigint; final_read bigint; final2 bigint; final3 bigint; checkpoint_read bigint;
    unknown_freshness_read bigint;
    part bigint; part2 bigint; part3 bigint; ambiguous bigint; progress bigint;
    old_assessment bigint; new_assessment bigint; short2 bigint; short3 bigint;
    old_member bigint; new_member bigint; combined_member bigint; t24 bigint; unknown_assessment bigint;
    missing_baseline bigint; contradictory_read bigint; failed_fetch bigint; pending_read bigint;
    zero_player bigint; zero_user bigint; zero_episode bigint; zero_baseline bigint; zero_end bigint;
    zero_assessment bigint; zero_member bigint;
    n numeric; label text; r record;
    starts timestamptz := '2026-11-22 08:00:00+00';
    ends timestamptz := '2026-11-28 08:00:00+00';
    midpoint timestamptz := '2026-11-25 08:00:00+00';
    short_end timestamptz := '2026-11-22 12:45:07.200+00';
BEGIN
    RESET ROLE;
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (9100000000000000100) RETURNING guild_key INTO g;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#P0C') RETURNING clan_key INTO clan_id;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#Q0C') RETURNING clan_key INTO other_clan;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#P0Y') RETURNING player_key INTO p;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#Q0L') RETURNING player_key INTO p2;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#R0J') RETURNING player_key INTO p3;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#G0V') RETURNING player_key INTO missing_player;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000101) RETURNING user_key INTO alice;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000102) RETURNING user_key INTO bob;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000103) RETURNING user_key INTO other_member;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000104) RETURNING user_key INTO staff;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000106) RETURNING user_key INTO zero_user;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#C0V') RETURNING player_key INTO zero_player;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (9100000000000000105, 'Co-leader') RETURNING role_key INTO role_id;
    RESET ROLE;
    INSERT INTO guild.server_role_binding VALUES ('co_leader', role_id);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_role_change (user_key, role_key, change_kind, changed_at, provenance_kind)
    VALUES (staff, role_id, 'add', starts - interval '1 day', 'manual');
    RESET ROLE;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (clan_id);
    INSERT INTO guild.guild_settings (guild_key) VALUES (g);
    SET LOCAL ROLE guild_runtime;
    ASSERT (SELECT refresh_seconds = 900 FROM guild.clan_games_collection_policy WHERE guild_key = g),
        'Active-event cadence must default to fifteen minutes';
    e := guild.create_scheduled_clan_games(2026, 11);
    PERFORM guild.queue_clan_games_reads(e, p);
    ASSERT guild.queue_clan_games_reads(e, p) = 0, 'Checkpoint queue must be idempotent';
    ASSERT (SELECT count(*) = 3 FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose IN ('baseline', 't_minus_24h', 'final')),
        'Boundary reads must exist independently from regular refresh requests';
    ASSERT (SELECT count(*) = 1 AND min(due_at) = starts + interval '15 minutes'
        FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = 'regular'),
        'Only the next regular read may be queued, one interval after the event start';

    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_id, 'cg:start', starts, 'complete') RETURNING poll_key INTO poll0;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_id, 'cg:end', ends, 'complete') RETURNING poll_key INTO poll6;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_id, 'cg:short', short_end, 'complete') RETURNING poll_key INTO poll_short;
    INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
    VALUES (poll_short, clan_id, p2, 'observed_departure', short_end),
        (poll_short, clan_id, p3, 'observed_departure', short_end);
    INSERT INTO guild.observed_clan_membership_period (
        player_key, clan_key, observed_since, observed_until, confirmed_through,
        boundary_policy, coverage_status, first_poll_key, last_poll_key
    ) VALUES
        (p, clan_id, starts, NULL, ends, 'synthetic-v1', 'adequate', poll0, poll6),
        (missing_player, clan_id, starts, NULL, ends, 'synthetic-v1', 'adequate', poll0, poll6),
        (zero_player, clan_id, starts, NULL, ends, 'synthetic-v1', 'adequate', poll0, poll6),
        (p2, clan_id, starts, short_end, short_end, 'synthetic-v1', 'adequate', poll0, poll_short),
        (p3, clan_id, starts, short_end, short_end, 'synthetic-v1', 'adequate', poll0, poll_short);
    INSERT INTO guild.dim_achievement (source_name, village)
    VALUES ('Games Champion', 'home') RETURNING achievement_key INTO achievement;
    INSERT INTO guild.dim_achievement (source_name, village)
    VALUES ('Other Achievement', 'home') RETURNING achievement_key INTO wrong_achievement;
    b := pg_temp.cg_read(g, e, p, achievement, 'baseline', starts, starts, 10000);
    b2 := pg_temp.cg_read(g, e, p2, achievement, 'baseline', starts, starts, 20000);
    b3 := pg_temp.cg_read(g, e, p3, achievement, 'baseline', starts, starts, 30000);
    first_read := pg_temp.cg_read(g, e, p, achievement, 'regular',
        starts + interval '1 hour', starts + interval '1 hour', 10050);
    first2 := pg_temp.cg_read(g, e, p2, achievement, 'regular',
        starts + interval '1 hour', starts + interval '1 hour', 20010);
    first3 := pg_temp.cg_read(g, e, p3, achievement, 'regular',
        starts + interval '1 hour', starts + interval '1 hour', 30010);
    INSERT INTO guild.clan_games_participation_evidence
        (event_key, player_key, baseline_read_key, first_increase_read_key, evidence_note)
    VALUES (e, p, b, first_read, 'Consistent tracked-clan observations')
    RETURNING participation_key INTO part;
    INSERT INTO guild.clan_games_participation_evidence
        (event_key, player_key, baseline_read_key, first_increase_read_key, evidence_note)
    VALUES (e, p2, b2, first2, 'Consistent through first increase') RETURNING participation_key INTO part2;
    INSERT INTO guild.clan_games_participation_evidence
        (event_key, player_key, baseline_read_key, first_increase_read_key, evidence_note)
    VALUES (e, p3, b3, first3, 'Consistent through first increase') RETURNING participation_key INTO part3;
    ASSERT (SELECT status = 'inferred' AND inferred_clan_key = clan_id
        FROM guild.clan_games_participation_evidence WHERE participation_key = part),
        'Participation must be inferred from consistent event-start membership and first increase';
    INSERT INTO guild.clan_games_participation_evidence (event_key, player_key, evidence_note)
    VALUES (e, missing_player, 'No event-start evidence') RETURNING participation_key INTO ambiguous;
    ASSERT (SELECT status = 'insufficient_data' AND inferred_clan_key IS NULL
        FROM guild.clan_games_participation_evidence WHERE participation_key = ambiguous),
        'Missing affiliation must not be guessed';
    BEGIN
        PERFORM pg_temp.cg_read(g, e, missing_player, achievement, 'baseline',
            starts, starts + interval '1 day', 237655);
        RAISE EXCEPTION 'A late current read reconstructed a missed baseline';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        PERFORM pg_temp.cg_read(g, e, missing_player, wrong_achievement, 'regular',
            midpoint, midpoint, 400);
        RAISE EXCEPTION 'An unrelated achievement supplied Clan Games points';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    missing_baseline := pg_temp.cg_read(g, e, missing_player, achievement, 'baseline',
        starts, starts, 40000);
    contradictory_read := pg_temp.cg_read(g, e, missing_player, achievement, 'regular',
        starts + interval '1 hour', starts + interval '1 hour', 40050, NULL, 'adequate', other_clan);
    INSERT INTO guild.clan_games_participation_evidence
        (event_key, player_key, baseline_read_key, first_increase_read_key, evidence_note)
    VALUES (e, missing_player, missing_baseline, contradictory_read, 'Profile clan contradicts membership ledger')
    RETURNING participation_key INTO ambiguous;
    ASSERT (SELECT status = 'insufficient_data' FROM guild.clan_games_participation_evidence
        WHERE participation_key = ambiguous), 'A contradictory profile clan must prevent participation inference';
    BEGIN
        INSERT INTO guild.fact_clan_games_progress
            (event_key, player_key, observed_at, source_correlation_id, measurement_method,
                evidence_status, points, evidence_note)
        VALUES (e, p, midpoint, 'manual-score-attempt', 'manual_evidence', 'adequate', 400, 'Forbidden');
        RAISE EXCEPTION 'Manual points were accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    -- Operator fixture proof has an explicit synthetic API-verification time.
    RESET ROLE;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (alice, p, 'verified', starts + interval '110 minutes') RETURNING verification_key INTO verification_id;
    SET LOCAL ROLE guild_runtime;
    link_id := guild.link_player_account(alice, p, verification_id, false, NULL, starts + interval '2 hours');
    RESET ROLE;
    SELECT attribution_key INTO old_episode FROM guild.account_link WHERE link_key = link_id;
    SET LOCAL ROLE guild_runtime;
    PERFORM guild.unlink_player_account(alice, p, NULL, starts + interval '1 day');
    RESET ROLE;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (alice, p, 'verified', starts + interval '2 days') RETURNING verification_key INTO verification_id;
    SET LOCAL ROLE guild_runtime;
    link_id := guild.link_player_account(alice, p, verification_id, false, NULL, starts + interval '2 days');
    RESET ROLE;
    ASSERT (SELECT attribution_key = old_episode FROM guild.account_link WHERE link_key = link_id),
        'Same-user relink must retain the gap and first-link backfill episode';
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (bob, p, 'verified', midpoint - interval '70 minutes') RETURNING verification_key INTO verification_id;
    SET LOCAL ROLE guild_runtime;
    transfer_id := guild.request_account_transfer(bob, p, verification_id, midpoint - interval '1 hour');
    PERFORM guild.decide_account_transfer(transfer_id, staff, true, midpoint - interval '30 minutes');
    ASSERT guild.link_player_account(bob, p, verification_id, false, transfer_id,
        midpoint - interval '1 minute') IS NULL, 'Transfer activated before the points refresh';
    RESET ROLE;
    ASSERT (SELECT status = 'awaiting_points' FROM guild.account_transfer_request
        WHERE transfer_request_key = transfer_id), 'Waiting for points must be explicit';
    SET LOCAL ROLE guild_runtime;
    ASSERT (SELECT user_key = alice FROM guild.current_account_link WHERE player_key = p),
        'Waiting must preserve the old effective owner';
    INSERT INTO guild.fact_api_fetch_attempt (
        player_key, source_correlation_id, endpoint_kind,
        started_at, completed_at, http_status, outcome, error_code
    ) VALUES (p, 'cg:transfer-failed', 'player_profile', midpoint - interval '40 seconds',
        midpoint - interval '30 seconds', 503, 'failed', 'maintenance')
    RETURNING fetch_key INTO failed_fetch;
    SELECT request_key INTO pending_read FROM guild.clan_games_read_request
    WHERE transfer_request_key = transfer_id AND purpose = 'transfer';
    BEGIN
        INSERT INTO guild.fact_player_achievement_observation
            (player_key, achievement_key, observed_at, source_correlation_id, value)
        VALUES (p, achievement, midpoint - interval '30 seconds', 'cg:invalid-failed-counter', 10099);
        INSERT INTO guild.clan_games_counter_read (
            request_key, event_key, player_key, transfer_request_key, source_fetch_key,
            achievement_key, observed_at, boundary_at, freshness_status, freshness_policy
        ) VALUES (pending_read, e, p, transfer_id, failed_fetch, achievement,
            midpoint - interval '30 seconds', midpoint - interval '30 seconds', 'adequate', 'invalid-failed-source');
        RAISE EXCEPTION 'An API failure was accepted as transfer-boundary evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    ASSERT (SELECT status = 'pending' FROM guild.clan_games_read_request WHERE request_key = pending_read),
        'API failure must leave the checkpoint retryable';
    transfer_read := pg_temp.cg_read(g, e, p, achievement, 'transfer',
        midpoint - interval '1 minute', midpoint, 10100, transfer_id);
    link_id := guild.link_player_account(bob, p, verification_id, false, transfer_id, midpoint);
    RESET ROLE;
    SELECT attribution_key INTO new_episode FROM guild.account_link WHERE link_key = link_id;
    ASSERT new_episode <> old_episode AND (SELECT transfer_boundary_read_key = transfer_read
        FROM guild.account_link WHERE link_key = link_id), 'Effective transfer must retain its counter evidence';
    SET LOCAL ROLE guild_runtime;
    checkpoint_read := pg_temp.cg_read(g, e, p, achievement, 't_minus_24h',
        ends - interval '24 hours', ends - interval '24 hours', 10250);
    final_read := pg_temp.cg_read(g, e, p, achievement, 'final', ends, ends, 10300);
    final2 := pg_temp.cg_read(g, e, p2, achievement, 'final', ends, ends, 20015);
    final3 := pg_temp.cg_read(g, e, p3, achievement, 'final', ends, ends, 30015);
    INSERT INTO guild.fact_clan_games_progress (
        event_key, player_key, observed_at, source_correlation_id, evidence_status,
        baseline_read_key, ending_read_key, participation_key, evidence_note
    ) VALUES (e, p, ends, 'cg:progress', 'adequate', b, final_read, part, 'Supported source delta')
    RETURNING progress_key INTO progress;
    ASSERT (SELECT points = 300 FROM guild.fact_clan_games_progress WHERE progress_key = progress),
        'Event points must be the actual difference, not a lifetime total or milestone';
    unknown_freshness_read := pg_temp.cg_read(g, e, p, achievement, 'regular',
        ends - interval '2 hours', ends - interval '2 hours', 10275, NULL, 'unknown');
    BEGIN
        INSERT INTO guild.fact_clan_games_progress (
            event_key, player_key, observed_at, source_correlation_id, evidence_status,
            baseline_read_key, ending_read_key, participation_key, evidence_note
        ) VALUES (e, p, ends - interval '2 hours', 'cg:unknown-freshness', 'adequate',
            b, unknown_freshness_read, part, 'A current response does not prove freshness');
        RAISE EXCEPTION 'Unknown freshness was silently accepted as adequate';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_games_account_assessment (
        event_key, player_key, attribution_key, checkpoint_kind, checkpoint_at, calculation_version,
        rule_version, attribution_policy, membership_status, points_status, attribution_status,
        start_read_key, end_read_key, participation_key, evidence_note
    ) VALUES (e, p, old_episode, 'final', ends, 1, 'v1', 'episode-v1', 'adequate', 'adequate', 'adequate',
        b, transfer_read, part, 'Old owner exact counter slice') RETURNING account_assessment_key INTO old_assessment;
    INSERT INTO guild.fact_clan_games_account_assessment (
        event_key, player_key, attribution_key, checkpoint_kind, checkpoint_at, calculation_version,
        rule_version, attribution_policy, membership_status, points_status, attribution_status,
        start_read_key, end_read_key, participation_key, evidence_note
    ) VALUES (e, p, new_episode, 'final', ends, 1, 'v1', 'episode-v1', 'adequate', 'adequate', 'adequate',
        transfer_read, final_read, part, 'New owner exact counter slice') RETURNING account_assessment_key INTO new_assessment;
    RESET ROLE;
    ASSERT (SELECT eligible_points = 100 AND required_points = 200
        FROM guild.fact_clan_games_account_assessment WHERE account_assessment_key = old_assessment),
        'Old owner must keep actual 100 points and half-event target including gap/backfill';
    ASSERT (SELECT eligible_points = 200 AND required_points = 200
        FROM guild.fact_clan_games_account_assessment WHERE account_assessment_key = new_assessment),
        'New owner must receive actual 200 points, not an even guessed split';
    SET LOCAL ROLE guild_runtime;
    BEGIN
        INSERT INTO guild.fact_clan_games_account_assessment (
            event_key, player_key, attribution_key, checkpoint_kind, checkpoint_at, calculation_version,
            rule_version, attribution_policy, membership_status, points_status, attribution_status,
            start_read_key, end_read_key, participation_key, eligible_points, evidence_note
        ) VALUES (e, p, old_episode, 'final', ends, 2, 'v1', 'episode-v1', 'adequate', 'adequate', 'adequate',
            b, transfer_read, part, 150, 'A guessed time split must fail');
        RAISE EXCEPTION 'A time-prorated invented points split was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_games_account_assessment (
        event_key, player_key, attribution_key, checkpoint_kind, checkpoint_at, calculation_version,
        rule_version, attribution_policy, membership_status, points_status, attribution_status,
        start_read_key, end_read_key, participation_key, evidence_note
    ) VALUES (e, p, new_episode, 't_minus_24h', ends - interval '24 hours', 1,
        'v1', 'episode-v1', 'adequate', 'adequate', 'adequate',
        transfer_read, checkpoint_read, part, 'Elapsed new-owner time only')
    RETURNING account_assessment_key INTO t24;
    RESET ROLE;
    ASSERT (SELECT observed_seconds = 172800 AND eligible_points = 150
        AND abs(required_points - 400::numeric / 3) < 0.000001
        FROM guild.fact_clan_games_account_assessment WHERE account_assessment_key = t24),
        'T-24 must not project the final day or include the earlier owner time';
    SET LOCAL ROLE guild_runtime;

    INSERT INTO guild.fact_clan_games_member_assessment (
        event_key, user_key, checkpoint_kind, calculation_version, attribution_policy, attribution_status, evidence_note
    ) VALUES (e, alice, 'final', 1, 'episode-v1', 'adequate', 'Old owner')
    RETURNING member_assessment_key INTO old_member;
    INSERT INTO guild.fact_clan_games_member_assessment (
        event_key, user_key, checkpoint_kind, calculation_version, attribution_policy, attribution_status, evidence_note
    ) VALUES (e, bob, 'final', 1, 'episode-v1', 'adequate', 'New owner')
    RETURNING member_assessment_key INTO new_member;
    RESET ROLE;
    ASSERT (SELECT result = 'insufficient_data' FROM guild.clan_games_member_result
        WHERE member_assessment_key = old_member), 'Expected evidence starts missing';
    SET LOCAL ROLE guild_runtime;
    PERFORM guild.attach_clan_games_member_input(old_member, old_assessment);
    PERFORM guild.attach_clan_games_member_input(new_member, new_assessment);
    PERFORM guild.attach_clan_games_member_input(old_member, old_assessment);
    BEGIN
        PERFORM guild.attach_clan_games_member_input(old_member, new_assessment);
        RAISE EXCEPTION 'Another owner filled a frozen member scope';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        RESET ROLE;
        DELETE FROM guild.clan_games_member_account_input WHERE member_assessment_key = old_member;
        SET LOCAL ROLE guild_runtime;
        RAISE EXCEPTION 'Frozen attribution scope was deleted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RESET ROLE;
    ASSERT (SELECT result = 'fail' FROM guild.clan_games_member_result WHERE member_assessment_key = old_member),
        'Old owner result must not move to the new owner';
    ASSERT (SELECT result = 'pass' FROM guild.clan_games_member_result WHERE member_assessment_key = new_member),
        'New owner should pass using only their supported slice';

    INSERT INTO guild.metric_attribution_episode (
        user_key, player_key, first_link_at, include_prelink_history
    ) VALUES (other_member, p2, starts, true) RETURNING attribution_key INTO other_episode2;
    INSERT INTO guild.metric_attribution_episode (
        user_key, player_key, first_link_at, include_prelink_history
    ) VALUES (other_member, p3, starts, true) RETURNING attribution_key INTO other_episode3;
    SET LOCAL ROLE guild_runtime;
    FOR r IN SELECT * FROM (VALUES (p2, other_episode2, b2, final2, part2),
        (p3, other_episode3, b3, final3, part3)) AS x(player, episode, baseline, ending, participation)
    LOOP
        INSERT INTO guild.fact_clan_games_account_assessment (
            event_key, player_key, attribution_key, checkpoint_kind, checkpoint_at, calculation_version,
            rule_version, attribution_policy, membership_status, points_status, attribution_status,
            start_read_key, end_read_key, participation_key, evidence_note
        ) VALUES (e, r.player, r.episode, 'final', ends, 1, 'v1', 'episode-v1',
            'adequate', 'adequate', 'adequate', r.baseline, r.ending, r.participation, 'Small target')
        RETURNING account_assessment_key INTO short2;
        IF r.player = p2 THEN short3 := short2; END IF;
    END LOOP;
    INSERT INTO guild.fact_clan_games_member_assessment (
        event_key, user_key, checkpoint_kind, calculation_version, attribution_policy, attribution_status, evidence_note
    ) VALUES (e, other_member, 'final', 1, 'episode-v1', 'adequate', 'Round once after combining')
    RETURNING member_assessment_key INTO combined_member;
    PERFORM guild.attach_clan_games_member_input(combined_member, short3);
    PERFORM guild.attach_clan_games_member_input(combined_member, short2);
    RESET ROLE;
    ASSERT (SELECT abs(unrounded_required_points - 26.4) < 0.000001 AND required_points = 30
        AND eligible_points = 30 AND result = 'pass' FROM guild.clan_games_member_result
        WHERE member_assessment_key = combined_member), 'Targets must combine before rounding to ten';
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_clan_games_member_assessment (
        event_key, user_key, checkpoint_kind, calculation_version, attribution_policy, attribution_status, evidence_note
    ) VALUES (e, other_member, 'final', 2, 'episode-v1', 'adequate', 'A missing alt must not be waived')
    RETURNING member_assessment_key INTO combined_member;
    PERFORM guild.attach_clan_games_member_input(combined_member, short3);
    RESET ROLE;
    ASSERT (SELECT count(*) = 2 AND count(account_assessment_key) = 1
        FROM guild.clan_games_member_account_input WHERE member_assessment_key = combined_member),
        'Missing evidence must occupy a frozen expected row';
    ASSERT (SELECT result = 'insufficient_data' FROM guild.clan_games_member_result
        WHERE member_assessment_key = combined_member), 'Omitting a known eligible account must not produce a complete result';
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_clan_games_account_assessment (
        event_key, player_key, checkpoint_kind, checkpoint_at, calculation_version, rule_version,
        attribution_policy, membership_status, points_status, attribution_status, evidence_note
    ) VALUES (e, missing_player, 'final', ends, 1, 'v1', 'unknown',
        'insufficient_data', 'insufficient_data', 'insufficient_data', 'No supported final or affiliation evidence')
    RETURNING account_assessment_key INTO unknown_assessment;
    RESET ROLE;
    ASSERT (SELECT result = 'insufficient_data' AND eligible_points IS NULL
        FROM guild.fact_clan_games_account_assessment WHERE account_assessment_key = unknown_assessment),
        'Missing historical evidence must not become zero-point success or failure';
    SET LOCAL ROLE guild_runtime;
    zero_baseline := pg_temp.cg_read(g, e, zero_player, achievement, 'baseline', starts, starts, 50000);
    zero_end := pg_temp.cg_read(g, e, zero_player, achievement, 'final', ends, ends, 50000);
    RESET ROLE;
    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at, include_prelink_history)
    VALUES (zero_user, zero_player, starts, true) RETURNING attribution_key INTO zero_episode;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.fact_clan_games_account_assessment (
        event_key, player_key, attribution_key, checkpoint_kind, checkpoint_at, calculation_version,
        rule_version, attribution_policy, membership_status, points_status, attribution_status,
        start_read_key, end_read_key, evidence_note
    ) VALUES (e, zero_player, zero_episode, 'final', ends, 1, 'v1', 'episode-v1',
        'adequate', 'adequate', 'adequate', zero_baseline, zero_end, 'Measured zero, not a missing counter')
    RETURNING account_assessment_key INTO zero_assessment;
    INSERT INTO guild.fact_clan_games_member_assessment (
        event_key, user_key, checkpoint_kind, calculation_version, attribution_policy, attribution_status, evidence_note
    ) VALUES (e, zero_user, 'final', 1, 'episode-v1', 'adequate', 'Known-zero account')
    RETURNING member_assessment_key INTO zero_member;
    PERFORM guild.attach_clan_games_member_input(zero_member, zero_assessment);
    RESET ROLE;
    ASSERT (SELECT result = 'fail' AND eligible_points = 0 AND required_points = 400
        FROM guild.clan_games_member_result WHERE member_assessment_key = zero_member),
        'Real baseline/end zero must fail a supported positive target without inventing affiliation';
    SET LOCAL ROLE guild_runtime;
    BEGIN
        INSERT INTO guild.fact_clan_games_account_assessment (
            event_key, player_key, attribution_key, checkpoint_kind, checkpoint_at, calculation_version,
            rule_version, attribution_policy, membership_status, points_status, attribution_status,
            eligible_points, end_read_key, evidence_note
        ) VALUES (e, zero_player, zero_episode, 'final', ends, 2, 'v1', 'episode-v1',
            'adequate', 'adequate', 'adequate', 0, zero_end, 'Missing baseline is never measured zero');
        RAISE EXCEPTION 'Missing baseline was replaced by an asserted zero';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'Clan Games actual counters, inferred clan, checkpoints, waiting transfer, owner slices and combined rounding passed';
END;
$$;
RESET ROLE;

-- Missed reads become terminal only when no current response could satisfy
-- them. These events are in the past, so the scheduler clock can pass them.
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    g bigint; e bigint; later_event bigint; p bigint; achievement bigint;
    owner_id bigint; recipient bigint; staff bigint;
    verification_id bigint; episode bigint; transfer_id bigint; transfer_request bigint;
    wait_clan bigint; wait_poll bigint; wait_player bigint; wait_owner bigint;
    wait_first bigint; wait_second bigint; wait_transfer bigint; unanswered_transfer bigint;
    starts timestamptz := '2025-10-22 08:00:00+00';
    ends timestamptz := '2025-10-28 08:00:00+00';
    rejected boolean := false;
BEGIN
    SELECT guild_key INTO STRICT g FROM guild.dim_guild;
    SELECT achievement_key INTO STRICT achievement FROM guild.dim_achievement
    WHERE source_name = 'Games Champion' AND village = 'home';
    SELECT user_key INTO STRICT staff FROM guild.dim_discord_user
    WHERE discord_user_id = 9100000000000000104;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#L0P') RETURNING player_key INTO p;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000111)
    RETURNING user_key INTO owner_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000112)
    RETURNING user_key INTO recipient;
    RESET ROLE;
    INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source, source_correlation_id)
    VALUES (starts, ends, 4000, 'configured_schedule', 'missed-read-test')
    RETURNING event_key INTO e;
    SET LOCAL ROLE guild_runtime;
    PERFORM guild.queue_clan_games_reads(e, p);

    -- Twenty minutes in: only the unread baseline is beyond recovery.
    PERFORM pg_temp.cg_read(g, e, p, achievement, 'regular',
        starts + interval '15 minutes', starts + interval '15 minutes 5 seconds', 100);
    ASSERT guild.close_missed_clan_games_reads(e, starts + interval '20 minutes') = 1,
        'Only the unread baseline may be closed shortly after the event starts';
    ASSERT (SELECT status = 'missed' AND missed_at = starts + interval '20 minutes'
        FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = 'baseline'),
        'A baseline with no read at the event start must become missed';
    ASSERT (SELECT count(*) = 2 FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose IN ('t_minus_24h', 'final')
            AND status = 'pending'), 'Future checkpoints must stay retryable';
    ASSERT guild.close_missed_clan_games_reads(e, starts + interval '20 minutes') = 0,
        'Closing missed reads must be idempotent';

    -- The next regular read follows the latest read, and no tick is materialised.
    ASSERT guild.queue_clan_games_reads(e, p) = 1, 'A completed regular read must queue the next one';
    ASSERT (SELECT count(*) = 1 AND min(due_at) = starts + interval '30 minutes 5 seconds'
        FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = 'regular' AND status = 'pending'),
        'The next regular read must be due one interval after the latest read';
    ASSERT guild.queue_clan_games_reads(e, p) = 0, 'Queueing the same regular read must be idempotent';

    -- An interval change moves the pending read instead of leaving old ticks.
    RESET ROLE;
    UPDATE guild.guild_settings SET clan_games_refresh_seconds = 1800 WHERE guild_key = g;
    SET LOCAL ROLE guild_runtime;
    ASSERT guild.queue_clan_games_reads(e, p) = 1, 'An interval change must move the pending read';
    ASSERT (SELECT count(*) = 1 AND min(due_at) = starts + interval '45 minutes 5 seconds'
        FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = 'regular' AND status = 'pending'),
        'The pending regular read must follow the new interval';
    RESET ROLE;
    UPDATE guild.guild_settings SET clan_games_refresh_seconds = 900 WHERE guild_key = g;
    SET LOCAL ROLE guild_runtime;
    ASSERT guild.queue_clan_games_reads(e, p) = 1, 'Restoring the interval must move the pending read back';
    BEGIN
        INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at)
        VALUES (e, p, 'regular', starts + interval '40 minutes');
        RAISE EXCEPTION 'A second pending regular read was accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    -- A late read answers the pending request. Nothing is missed during the event.
    PERFORM pg_temp.cg_read(g, e, p, achievement, 'regular',
        starts + interval '30 minutes 5 seconds', starts + interval '45 minutes 10 seconds', 180);
    ASSERT guild.queue_clan_games_reads(e, p) = 1, 'A late regular read must queue the next one';
    ASSERT (SELECT due_at = starts + interval '60 minutes 10 seconds'
        FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = 'regular' AND status = 'pending'),
        'The next regular read must follow the late read, not the old due time';
    ASSERT guild.close_missed_clan_games_reads(e, starts + interval '50 minutes') = 0,
        'A pending regular read must stay retryable while the event runs';
    ASSERT (SELECT count(*) = 3 FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = 'regular'),
        'Regular requests must grow with reads, not with the event length';

    -- Evidence observed in time but ingested late still completes its request.
    PERFORM pg_temp.cg_read(g, e, p, achievement, 'baseline', starts, starts, 40);
    ASSERT (SELECT status = 'succeeded' AND missed_at IS NULL FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = 'baseline'),
        'A valid late-ingested baseline must replace the missed state';

    -- A transfer read whose transfer was cancelled can never become effective.
    RESET ROLE;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (owner_id, p, 'verified', '2025-10-01 00:00:00+00')
    RETURNING verification_key INTO verification_id;
    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at, include_prelink_history)
    VALUES (owner_id, p, '2025-10-01 01:00:00+00', true) RETURNING attribution_key INTO episode;
    INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at, is_primary)
    VALUES (owner_id, p, verification_id, episode, '2025-10-01 01:00:00+00', true);
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (recipient, p, 'verified', '2025-10-23 00:50:00+00')
    RETURNING verification_key INTO verification_id;
    SET LOCAL ROLE guild_runtime;
    transfer_id := guild.request_account_transfer(recipient, p, verification_id, '2025-10-23 01:00:00+00');
    PERFORM guild.decide_account_transfer(transfer_id, staff, true, '2025-10-23 02:00:00+00');
    INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, transfer_request_key)
    VALUES (e, p, 'transfer', '2025-10-23 03:00:00+00', transfer_id)
    RETURNING request_key INTO transfer_request;
    ASSERT guild.close_missed_clan_games_reads(e, '2025-10-23 04:00:00+00') = 0,
        'A transfer read for an approved request must stay retryable';
    PERFORM guild.unlink_player_account(owner_id, p, NULL, '2025-10-24 00:00:00+00');
    ASSERT guild.close_missed_clan_games_reads(e, '2025-10-24 01:00:00+00') = 1,
        'Only the cancelled transfer read may be closed';
    ASSERT (SELECT status = 'missed' FROM guild.clan_games_read_request
        WHERE request_key = transfer_request), 'A cancelled transfer must close its boundary read';

    -- An approved transfer that waits for its boundary read does not lapse
    -- while that read is pending, and the limit restarts when the read arrives.
    SELECT clan_key INTO STRICT wait_clan FROM guild.dim_clan WHERE clan_tag = '#P0C';
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#U0V') RETURNING player_key INTO wait_player;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000113)
    RETURNING user_key INTO wait_owner;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000114)
    RETURNING user_key INTO wait_first;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (9100000000000000115)
    RETURNING user_key INTO wait_second;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (wait_clan, 'cg:transfer-wait', '2025-10-01 00:00:00+00', 'complete')
    RETURNING poll_key INTO wait_poll;
    INSERT INTO guild.observed_clan_membership_period (
        player_key, clan_key, observed_since, observed_until, confirmed_through,
        boundary_policy, coverage_status, first_poll_key, last_poll_key
    ) VALUES (wait_player, wait_clan, '2025-10-01 00:00:00+00', NULL, '2025-10-01 00:00:00+00',
        'synthetic-v1', 'adequate', wait_poll, wait_poll);
    RESET ROLE;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (wait_owner, wait_player, 'verified', '2025-10-01 00:50:00+00')
    RETURNING verification_key INTO verification_id;
    SET LOCAL ROLE guild_runtime;
    PERFORM guild.link_player_account(wait_owner, wait_player, verification_id, false, NULL,
        '2025-10-01 01:00:00+00');
    RESET ROLE;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (wait_first, wait_player, 'verified', '2025-10-23 00:50:00+00')
    RETURNING verification_key INTO verification_id;
    SET LOCAL ROLE guild_runtime;
    wait_transfer := guild.request_account_transfer(wait_first, wait_player, verification_id,
        '2025-10-23 01:00:00+00');
    PERFORM guild.decide_account_transfer(wait_transfer, staff, true, '2025-10-23 02:00:00+00');
    ASSERT guild.link_player_account(wait_first, wait_player, verification_id, false, wait_transfer,
        '2025-10-23 12:00:00+00') IS NULL, 'The transfer must wait for its boundary read';
    RESET ROLE;
    ASSERT (SELECT status = 'awaiting_points' FROM guild.account_transfer_request
        WHERE transfer_request_key = wait_transfer)
        AND guild.account_transfer_expires_at(wait_transfer) = 'infinity'::timestamptz,
        'A transfer with a pending boundary read must not have an expiry';
    SET LOCAL ROLE guild_runtime;
    ASSERT guild.expire_account_transfers('2025-10-26 00:00:00+00') = 0,
        'A slow read must not expire the waiting transfer';
    -- The read arrives two days after the approval, past the one-day limit.
    PERFORM pg_temp.cg_read(g, e, wait_player, achievement, 'transfer',
        '2025-10-23 12:00:00+00', '2025-10-25 12:00:00+00', 700, wait_transfer);
    RESET ROLE;
    ASSERT guild.account_transfer_expires_at(wait_transfer) = '2025-10-26 12:00:00+00'::timestamptz,
        'The approval limit must restart when the boundary read arrives';
    SET LOCAL ROLE guild_runtime;
    ASSERT guild.link_player_account(wait_first, wait_player, verification_id, false, wait_transfer,
        '2025-10-25 12:00:00+00') IS NOT NULL, 'A late boundary read must still complete the transfer';
    ASSERT (SELECT user_key = wait_first FROM guild.current_account_link WHERE player_key = wait_player),
        'The waiting transfer must take effect at its boundary read';

    -- A second transfer waits for a read that never arrives.
    RESET ROLE;
    INSERT INTO guild.player_verification (user_key, player_key, status, checked_at)
    VALUES (wait_second, wait_player, 'verified', '2025-10-26 00:50:00+00')
    RETURNING verification_key INTO verification_id;
    SET LOCAL ROLE guild_runtime;
    unanswered_transfer := guild.request_account_transfer(wait_second, wait_player, verification_id,
        '2025-10-26 01:00:00+00');
    PERFORM guild.decide_account_transfer(unanswered_transfer, staff, true, '2025-10-26 02:00:00+00');
    ASSERT guild.link_player_account(wait_second, wait_player, verification_id, false,
        unanswered_transfer, '2025-10-26 03:00:00+00') IS NULL,
        'The second transfer must wait for its boundary read';
    ASSERT guild.expire_account_transfers('2025-10-30 00:00:00+00') = 0,
        'The waiting transfer must stay open while its read is retryable';

    -- After the event: the regular read and T-24h are gone, the final read is not.
    ASSERT guild.close_missed_clan_games_reads(e, ends + interval '1 hour') = 2,
        'The event end must close the pending regular read and the T-24h checkpoint';
    ASSERT guild.queue_clan_games_reads(e, p) = 0, 'No regular read may be queued after its event';
    ASSERT NOT EXISTS (SELECT FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose IN ('regular', 't_minus_24h')
            AND status = 'pending'), 'No in-event checkpoint may stay pending after the event';
    ASSERT (SELECT status = 'pending' FROM guild.clan_games_read_request
        WHERE event_key = e AND player_key = p AND purpose = 'final'),
        'The final read must stay retryable until the next event starts';
    RESET ROLE;
    INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source, source_correlation_id)
    VALUES ('2025-11-22 08:00:00+00', '2025-11-28 08:00:00+00', 4000,
        'configured_schedule', 'missed-read-later-event')
    RETURNING event_key INTO later_event;
    SET LOCAL ROLE guild_runtime;
    ASSERT guild.close_missed_clan_games_reads(e, '2025-11-22 08:00:01+00') = 2,
        'The next event start must close the unread final checkpoint and the unanswered transfer read';
    ASSERT NOT EXISTS (SELECT FROM guild.clan_games_read_request
        WHERE event_key = e AND status = 'pending'),
        'No request of a superseded event may stay pending';
    -- With its read missed, the waiting transfer falls back to the approval limit.
    ASSERT guild.expire_account_transfers('2025-11-22 08:00:01+00') = 1,
        'A transfer whose boundary read was missed must expire';
    RESET ROLE;
    ASSERT (SELECT status = 'expired' AND expired_at = '2025-10-27 02:00:00+00'::timestamptz
        FROM guild.account_transfer_request WHERE transfer_request_key = unanswered_transfer),
        'The missed transfer must expire one day after its approval';
    SET LOCAL ROLE guild_runtime;
    ASSERT (SELECT user_key = wait_first FROM guild.current_account_link WHERE player_key = wait_player),
        'An expired transfer must leave the account with its owner';

    BEGIN
        PERFORM guild.close_missed_clan_games_reads(later_event, clock_timestamp() + interval '1 hour');
    EXCEPTION WHEN invalid_parameter_value THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'reads were declared missed in the future'; END IF;
    SET CONSTRAINTS ALL IMMEDIATE;
END;
$$;
RESET ROLE;
ROLLBACK;
