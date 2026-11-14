BEGIN;

-- V3, second part: Clan Games events, read requests, counter reads, evidence
-- and assessments. The service computes targets, inference and results; these
-- checks cover the keys and checks that bind the evidence together.
DO $$
DECLARE
    guild bigint; owner_id bigint; other_id bigint; player_id bigint; other_player bigint;
    achievement bigint; event_id bigint; baseline_request bigint; final_request bigint;
    regular_request bigint; baseline_fetch bigint; final_fetch bigint; baseline_read bigint;
    final_read bigint; participation bigint; progress bigint; episode bigint; other_episode bigint;
    proof bigint; assessment bigint; member_assessment bigint; other_member_assessment bigint;
    earlier_member_assessment bigint; moved_event bigint; rescheduled_event bigint;
    starts timestamptz := date_trunc('hour', clock_timestamp()) - interval '20 days';
    ends timestamptz := date_trunc('hour', clock_timestamp()) - interval '14 days';
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (940000000000000001) RETURNING guild_key INTO guild;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
    IF (SELECT refresh_seconds FROM guild.clan_games_collection_policy) <> 900 THEN
        RAISE EXCEPTION 'Active-event cadence must default to fifteen minutes';
    END IF;
    IF (SELECT checkpoint_tolerance_seconds FROM guild.clan_games_collection_policy) <> 1800 THEN
        RAISE EXCEPTION 'The T-24h read window must default to thirty minutes (DEC-03)';
    END IF;
    BEGIN
        UPDATE guild.guild_settings SET clan_games_start_day = 29;
        RAISE EXCEPTION 'a start day missing from February was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.guild_settings SET clan_games_event_seconds = 86400;
        RAISE EXCEPTION 'A Clan Games event of one day was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.guild_settings SET clan_games_account_points_cap = 0;
        RAISE EXCEPTION 'A points cap of zero was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.guild_settings SET clan_games_refresh_seconds = 0;
        RAISE EXCEPTION 'A refresh interval of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.guild_settings SET clan_games_checkpoint_tolerance_seconds = 0;
        RAISE EXCEPTION 'A T-24h read window of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.guild_settings SET clan_games_checkpoint_tolerance_seconds = 432000;
        RAISE EXCEPTION 'A T-24h read window that opens before the event start was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (940000000000000011) RETURNING user_key INTO owner_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (940000000000000012) RETURNING user_key INTO other_id;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#9PY') RETURNING player_key INTO player_id;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#9QY') RETURNING player_key INTO other_player;
    INSERT INTO guild.dim_achievement (source_name, village) VALUES ('Games Champion', 'home')
    RETURNING achievement_key INTO achievement;

    -- Events.
    INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
        source_correlation_id)
    VALUES (starts, ends, 4000, 'configured_schedule', 'schedule:test') RETURNING event_key INTO event_id;
    BEGIN
        INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
            source_correlation_id)
        VALUES (starts, ends + interval '1 day', 4000, 'manual', 'manual:test');
        RAISE EXCEPTION 'Manual retry duplicated a scheduled event';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
            source_correlation_id)
        VALUES (ends + interval '20 days', ends + interval '26 days', 4000, 'configured_schedule', 'schedule:test');
        RAISE EXCEPTION 'One schedule correlation created two events';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
            source_correlation_id)
        VALUES (starts + interval '1 day', ends + interval '1 day', 4000, 'manual', 'manual:overlap');
        RAISE EXCEPTION 'Overlapping Clan Games events were accepted';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
            source_correlation_id)
        VALUES (ends + interval '10 days', ends + interval '11 days', 4000, 'manual', 'manual:short');
        RAISE EXCEPTION 'A Clan Games event of one day was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
            source_correlation_id)
        VALUES (ends + interval '10 days', ends + interval '16 days', 4000, 'imported', 'import:test');
        RAISE EXCEPTION 'An unknown event source was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.dim_clan_games_event SET account_points_cap = 5000 WHERE event_key = event_id;
        RAISE EXCEPTION 'Retry silently changed frozen event evidence';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        UPDATE guild.dim_clan_games_event SET starts_at = starts + interval '1 day' WHERE event_key = event_id;
        RAISE EXCEPTION 'An event with wrong dates was edited instead of voided';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- CG-001: when the game moves Clan Games, the stored event is voided and
    -- kept, and a manual event that names it takes the new dates. The window
    -- of a voided event is free, and the schedule cannot create its month again.
    INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
        source_correlation_id)
    VALUES (starts + interval '60 days', ends + interval '60 days', 4000, 'configured_schedule', 'schedule:moved')
    RETURNING event_key INTO moved_event;
    UPDATE guild.dim_clan_games_event SET voided_at = clock_timestamp() WHERE event_key = moved_event;
    INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
        source_correlation_id, replaces_event_key)
    VALUES (starts + interval '61 days', ends + interval '61 days', 4000, 'manual', 'manual:rescheduled', moved_event)
    RETURNING event_key INTO rescheduled_event;
    BEGIN
        INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
            source_correlation_id, replaces_event_key)
        VALUES (starts + interval '120 days', ends + interval '120 days', 4000, 'manual', 'manual:second', moved_event);
        RAISE EXCEPTION 'One voided event was replaced twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
            source_correlation_id, replaces_event_key)
        VALUES (starts + interval '120 days', ends + interval '120 days', 4000, 'manual', 'manual:unknown', -1);
        RAISE EXCEPTION 'An event replaced an event that does not exist';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
            source_correlation_id)
        VALUES (starts + interval '90 days', ends + interval '90 days', 4000, 'configured_schedule', 'schedule:moved');
        RAISE EXCEPTION 'The schedule created the month of a voided event again';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
            source_correlation_id)
        VALUES (starts + interval '62 days', ends + interval '62 days', 4000, 'manual', 'manual:overlapping');
        RAISE EXCEPTION 'Two events that are not voided overlapped';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.dim_clan_games_event SET replaces_event_key = moved_event WHERE event_key = event_id;
        RAISE EXCEPTION 'An existing event was turned into a replacement';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    IF NOT EXISTS (SELECT FROM guild.dim_clan_games_event WHERE event_key = moved_event AND voided_at IS NOT NULL)
        OR (SELECT replaces_event_key FROM guild.dim_clan_games_event WHERE event_key = rescheduled_event)
            <> moved_event THEN
        RAISE EXCEPTION 'A rescheduled event lost the record it replaced';
    END IF;

    -- Read requests. due_at is the checkpoint; collect_from opens the window in
    -- which the collector may take the read, so a boundary read can finish
    -- before its checkpoint.
    INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
    VALUES (event_id, player_id, 'baseline', starts, starts - interval '20 days')
    RETURNING request_key INTO baseline_request;
    INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
    VALUES (event_id, player_id, 'final', ends, ends) RETURNING request_key INTO final_request;
    INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
    VALUES (event_id, player_id, 't_minus_24h', ends - interval '1 day',
        ends - interval '1 day' - interval '15 minutes');
    BEGIN
        INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
        VALUES (event_id, player_id, 'baseline', starts, starts - interval '1 hour');
        RAISE EXCEPTION 'Checkpoint queue must be idempotent';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
        VALUES (event_id, other_player, 't_minus_24h', ends - interval '1 day',
            ends - interval '1 day' + interval '1 minute');
        RAISE EXCEPTION 'A read window opened after its checkpoint';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
        VALUES (event_id, other_player, 'final', ends, ends - interval '1 hour');
        RAISE EXCEPTION 'A final read was given a window before the event end';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
    VALUES (event_id, player_id, 'regular', starts + interval '15 minutes', starts + interval '15 minutes')
    RETURNING request_key INTO regular_request;
    BEGIN
        INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
        VALUES (event_id, player_id, 'regular', starts + interval '30 minutes', starts + interval '30 minutes');
        RAISE EXCEPTION 'A second pending regular read was accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
        VALUES (event_id, player_id, 'transfer', starts + interval '1 day', starts + interval '1 day');
        RAISE EXCEPTION 'A transfer read was accepted without its transfer';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.clan_games_read_request SET status = 'missed' WHERE request_key = regular_request;
        RAISE EXCEPTION 'A read was closed as missed without its time';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.clan_games_read_request SET due_at = starts + interval '30 minutes'
        WHERE request_key = regular_request;
        RAISE EXCEPTION 'A regular read moved its checkpoint without its window';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.clan_games_read_request
    SET due_at = starts + interval '30 minutes', collect_from = starts + interval '30 minutes'
    WHERE request_key = regular_request;
    UPDATE guild.clan_games_read_request SET status = 'missed', missed_at = ends WHERE request_key = regular_request;
    -- A closed regular read no longer blocks the next one.
    INSERT INTO guild.clan_games_read_request (event_key, player_key, purpose, due_at, collect_from)
    VALUES (event_id, player_id, 'regular', starts + interval '45 minutes', starts + interval '45 minutes');
    BEGIN
        UPDATE guild.clan_games_read_request SET purpose = 'final' WHERE request_key = regular_request;
        RAISE EXCEPTION 'The runtime role changed the purpose of a read request';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.clan_games_read_request WHERE request_key = regular_request;
        RAISE EXCEPTION 'The runtime role deleted a read request';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Counter reads.
    INSERT INTO guild.fact_api_fetch_attempt (player_key, source_correlation_id, endpoint_kind,
        started_at, completed_at, http_status, outcome)
    VALUES (player_id, 'test:baseline', 'player_profile', starts - interval '1 minute', starts, 200, 'succeeded')
    RETURNING fetch_key INTO baseline_fetch;
    INSERT INTO guild.fact_api_fetch_attempt (player_key, source_correlation_id, endpoint_kind,
        started_at, completed_at, http_status, outcome)
    VALUES (player_id, 'test:final', 'player_profile', ends, ends + interval '1 minute', 200, 'succeeded')
    RETURNING fetch_key INTO final_fetch;
    INSERT INTO guild.fact_player_achievement_observation
        (player_key, achievement_key, observed_at, source_correlation_id, value)
    VALUES (player_id, achievement, starts, 'test:baseline', 50000),
        (player_id, achievement, ends + interval '1 minute', 'test:final', 50300);
    BEGIN
        INSERT INTO guild.clan_games_counter_read (request_key, event_key, player_key, source_fetch_key,
            achievement_key, observed_at, boundary_at, freshness_policy)
        VALUES (baseline_request, event_id, other_player, baseline_fetch, achievement, starts, starts, 'test');
        RAISE EXCEPTION 'A counter read answered the request of another account';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.clan_games_counter_read (request_key, event_key, player_key, source_fetch_key,
            achievement_key, observed_at, boundary_at, freshness_policy)
        VALUES (baseline_request, event_id, player_id, baseline_fetch, achievement,
            starts - interval '1 second', starts, 'test');
        RAISE EXCEPTION 'A counter read had no achievement observation behind it';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.clan_games_counter_read (request_key, event_key, player_key, source_fetch_key,
            achievement_key, observed_at, boundary_at, freshness_policy, clan_observation_status)
        VALUES (baseline_request, event_id, player_id, baseline_fetch, achievement, starts, starts, 'test', 'known');
        RAISE EXCEPTION 'A known observed clan was accepted without the clan';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.clan_games_counter_read (request_key, event_key, player_key, source_fetch_key,
            achievement_key, observed_at, boundary_at, source_as_of, freshness_policy)
        VALUES (baseline_request, event_id, player_id, baseline_fetch, achievement, starts, starts,
            starts + interval '1 second', 'test');
        RAISE EXCEPTION 'A source time after the observation was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.clan_games_counter_read (request_key, event_key, player_key, source_fetch_key,
        achievement_key, observed_at, boundary_at, freshness_status, freshness_policy)
    VALUES (baseline_request, event_id, player_id, baseline_fetch, achievement, starts, starts, 'adequate', 'test')
    RETURNING read_key INTO baseline_read;
    BEGIN
        INSERT INTO guild.clan_games_counter_read (request_key, event_key, player_key, source_fetch_key,
            achievement_key, observed_at, boundary_at, freshness_policy)
        VALUES (final_request, event_id, player_id, baseline_fetch, achievement, starts, ends, 'test');
        RAISE EXCEPTION 'One fetch answered two counter reads';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.clan_games_counter_read (request_key, event_key, player_key, source_fetch_key,
        achievement_key, observed_at, boundary_at, freshness_status, freshness_policy)
    VALUES (final_request, event_id, player_id, final_fetch, achievement, ends + interval '1 minute', ends,
        'adequate', 'test')
    RETURNING read_key INTO final_read;

    -- Participation and progress.
    INSERT INTO guild.clan_games_participation_evidence (event_key, player_key, baseline_read_key,
        evidence_note)
    VALUES (event_id, player_id, baseline_read, 'test') RETURNING participation_key INTO participation;
    BEGIN
        INSERT INTO guild.clan_games_participation_evidence (event_key, player_key, baseline_read_key,
            evidence_note)
        VALUES (event_id, other_player, baseline_read, 'test');
        RAISE EXCEPTION 'Participation evidence used the read of another account';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_games_progress (event_key, player_key, observed_at, source_correlation_id,
            measurement_method, evidence_status, points, evidence_note)
        VALUES (event_id, player_id, ends, 'test:manual', 'manual_entry', 'adequate', 300, 'test');
        RAISE EXCEPTION 'Manual points were accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_games_progress (event_key, player_key, observed_at, source_correlation_id,
            evidence_status, points, evidence_note)
        VALUES (event_id, player_id, ends, 'test:insufficient', 'insufficient_data', 0, 'test');
        RAISE EXCEPTION 'Missing historical evidence must not become zero-point success or failure';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_games_progress (event_key, player_key, observed_at, source_correlation_id,
        evidence_status, points, baseline_read_key, ending_read_key, participation_key, evidence_note)
    VALUES (event_id, player_id, ends + interval '1 minute', 'test:progress', 'adequate', 300, baseline_read,
        final_read, participation, 'test')
    RETURNING progress_key INTO progress;
    BEGIN
        INSERT INTO guild.fact_clan_games_progress (event_key, player_key, observed_at, source_correlation_id,
            evidence_status, points, evidence_note)
        VALUES (event_id, player_id, ends + interval '1 minute', 'test:progress:again', 'adequate', 300, 'test');
        RAISE EXCEPTION 'One account had two progress rows at one time';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_clan_games_progress SET points = 4000 WHERE progress_key = progress;
        RAISE EXCEPTION 'The runtime role rewrote recorded points';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Assessments, and the boundary read of a transfer.
    INSERT INTO guild.player_verification (user_key, player_key, status) VALUES (owner_id, player_id, 'verified')
    RETURNING verification_key INTO proof;
    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at, include_prelink_history)
    VALUES (owner_id, player_id, starts - interval '30 days', true) RETURNING attribution_key INTO episode;
    BEGIN
        INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, linked_at,
            transfer_boundary_read_key)
        VALUES (owner_id, player_id, proof, episode, starts, baseline_read);
        RAISE EXCEPTION 'A link named a boundary read without its transfer';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at, include_prelink_history)
    VALUES (other_id, other_player, starts - interval '30 days', true) RETURNING attribution_key INTO other_episode;
    BEGIN
        INSERT INTO guild.fact_clan_games_account_assessment (event_key, player_key, attribution_key, user_key,
            checkpoint_kind, checkpoint_at, calculation_version, rule_version, attribution_policy,
            membership_status, points_status, attribution_status, scope_starts_at, scope_ends_at,
            observed_seconds, required_points, evidence_note)
        VALUES (event_id, player_id, episode, other_id, 'final', ends, 1, 'v1', 'test',
            'adequate', 'adequate', 'adequate', starts, ends, 518400, 400, 'test');
        RAISE EXCEPTION 'An assessment named another owner for the episode';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_games_account_assessment (event_key, player_key, attribution_key, user_key,
            checkpoint_kind, checkpoint_at, calculation_version, rule_version, attribution_policy,
            membership_status, points_status, attribution_status, scope_starts_at, scope_ends_at,
            observed_seconds, required_points, evidence_note, result)
        VALUES (event_id, player_id, episode, owner_id, 'final', ends, 1, 'v1', 'test',
            'adequate', 'adequate', 'adequate', starts, ends, 518400, 400, 'test', 'pass');
        RAISE EXCEPTION 'An assessment result was written instead of computed';
    EXCEPTION WHEN generated_always THEN NULL;
    END;
    INSERT INTO guild.fact_clan_games_account_assessment (event_key, player_key, attribution_key, user_key,
        checkpoint_kind, checkpoint_at, calculation_version, rule_version, attribution_policy,
        membership_status, points_status, attribution_status, progress_key, participation_key,
        start_read_key, end_read_key, scope_starts_at, scope_ends_at, observed_seconds,
        eligible_points, required_points, evidence_note)
    VALUES (event_id, player_id, episode, owner_id, 'final', ends, 1, 'v1', 'test',
        'adequate', 'adequate', 'adequate', progress, participation, baseline_read, final_read,
        starts, ends, 518400, 300, 400, 'test')
    RETURNING account_assessment_key INTO assessment;
    IF (SELECT result FROM guild.fact_clan_games_account_assessment
        WHERE account_assessment_key = assessment) <> 'fail' THEN
        RAISE EXCEPTION 'Fewer eligible than required points did not fail';
    END IF;
    INSERT INTO guild.fact_clan_games_account_assessment (event_key, player_key, attribution_key, user_key,
        checkpoint_kind, checkpoint_at, calculation_version, rule_version, attribution_policy,
        membership_status, points_status, attribution_status, scope_starts_at, scope_ends_at,
        observed_seconds, eligible_points, required_points, evidence_note)
    VALUES (event_id, player_id, episode, owner_id, 'final', ends, 2, 'v1', 'test',
        'adequate', 'adequate', 'adequate', starts, ends, 518400, 400, 400, 'test'),
        (event_id, player_id, episode, owner_id, 'final', ends, 3, 'v1', 'test',
        'insufficient_data', 'adequate', 'adequate', starts, ends, 518400, 4000, 400, 'test'),
        (event_id, player_id, episode, owner_id, 'final', ends, 4, 'v1', 'test',
        'adequate', 'adequate', 'adequate', starts, ends, 518400, NULL, 400, 'test');
    IF ARRAY(SELECT result FROM guild.fact_clan_games_account_assessment
            WHERE event_key = event_id ORDER BY calculation_version)
        <> ARRAY['fail', 'pass', 'insufficient_data', 'insufficient_data'] THEN
        RAISE EXCEPTION 'Missing evidence must not produce a pass or a fail';
    END IF;
    BEGIN
        INSERT INTO guild.fact_clan_games_account_assessment (event_key, player_key, attribution_key, user_key,
            checkpoint_kind, checkpoint_at, calculation_version, rule_version, attribution_policy,
            membership_status, points_status, attribution_status, scope_starts_at, scope_ends_at,
            observed_seconds, required_points, evidence_note)
        VALUES (event_id, player_id, episode, owner_id, 'final', ends, 1, 'v1', 'test',
            'adequate', 'adequate', 'adequate', starts, ends, 518400, 400, 'test');
        RAISE EXCEPTION 'A calculation version was recorded twice for one slice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_games_account_assessment (event_key, player_key, attribution_key, user_key,
            checkpoint_kind, checkpoint_at, calculation_version, rule_version, attribution_policy,
            membership_status, points_status, attribution_status, scope_starts_at, scope_ends_at,
            observed_seconds, required_points, evidence_note)
        VALUES (event_id, player_id, episode, owner_id, 'final', ends, 5, 'v1', 'test',
            'adequate', 'adequate', 'adequate', ends, starts, 0, 0, 'test');
        RAISE EXCEPTION 'An assessment scope ended before it started';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO guild.fact_clan_games_member_assessment (event_key, user_key, checkpoint_kind,
        calculation_version, attribution_policy, attribution_status, evidence_note)
    VALUES (event_id, owner_id, 'final', 1, 'test', 'adequate', 'test')
    RETURNING member_assessment_key INTO member_assessment;
    INSERT INTO guild.fact_clan_games_member_assessment (event_key, user_key, checkpoint_kind,
        calculation_version, attribution_policy, attribution_status, evidence_note)
    VALUES (event_id, other_id, 'final', 1, 'test', 'adequate', 'test')
    RETURNING member_assessment_key INTO other_member_assessment;
    BEGIN
        INSERT INTO guild.fact_clan_games_member_assessment (event_key, user_key, checkpoint_kind,
            calculation_version, attribution_policy, attribution_status, evidence_note)
        VALUES (event_id, owner_id, 'final', 1, 'test', 'adequate', 'test');
        RAISE EXCEPTION 'A member calculation version was recorded twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.clan_games_member_account_input (member_assessment_key, event_key, checkpoint_kind,
        player_key, attribution_key, user_key)
    VALUES (member_assessment, event_id, 'final', player_id, episode, owner_id);
    BEGIN
        INSERT INTO guild.clan_games_member_account_input (member_assessment_key, event_key, checkpoint_kind,
            player_key, attribution_key, user_key)
        VALUES (other_member_assessment, event_id, 'final', player_id, episode, owner_id);
        RAISE EXCEPTION 'Another owner filled a frozen member scope';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.clan_games_member_account_input (member_assessment_key, event_key, checkpoint_kind,
            player_key, attribution_key, user_key)
        VALUES (other_member_assessment, event_id, 'final', player_id, other_episode, other_id);
        RAISE EXCEPTION 'A member input named the episode of another account';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_games_member_assessment (event_key, user_key, checkpoint_kind,
        calculation_version, attribution_policy, attribution_status, evidence_note)
    VALUES (event_id, owner_id, 't_minus_24h', 1, 'test', 'adequate', 'test')
    RETURNING member_assessment_key INTO earlier_member_assessment;
    BEGIN
        INSERT INTO guild.clan_games_member_account_input (member_assessment_key, account_assessment_key,
            event_key, checkpoint_kind, player_key, attribution_key, user_key)
        VALUES (earlier_member_assessment, assessment, event_id, 't_minus_24h', player_id, episode, owner_id);
        RAISE EXCEPTION 'A member input attached a slice of another checkpoint';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    UPDATE guild.clan_games_member_account_input SET account_assessment_key = assessment
    WHERE member_assessment_key = member_assessment;
    IF (SELECT result FROM guild.clan_games_member_result WHERE member_assessment_key = member_assessment)
        <> 'fail' THEN
        RAISE EXCEPTION 'The runtime role could not read the member result';
    END IF;
    BEGIN
        UPDATE guild.clan_games_member_account_input SET player_key = other_player
        WHERE member_assessment_key = member_assessment;
        RAISE EXCEPTION 'The runtime role changed the identity of a frozen input';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.clan_games_member_account_input WHERE member_assessment_key = member_assessment;
        RAISE EXCEPTION 'Frozen attribution scope was deleted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'Clan Games constraints passed';
END;
$$;

ROLLBACK;
