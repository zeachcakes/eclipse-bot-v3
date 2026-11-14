BEGIN;

-- V3, first part: tracked clans, member list polls, membership periods, the
-- season calendar, wars, profile observations and raids.
DO $$
DECLARE
    clan_a bigint; clan_b bigint; untracked bigint; player_a bigint; player_b bigint;
    poll_a bigint; poll_b bigint; failed_poll bigint; period bigint; war bigint; attack bigint;
    war_poll bigint; later_poll bigint;
    achievement bigint; raid bigint; raid_b bigint; raid_poll_one bigint; raid_poll_two bigint;
    seen timestamptz := clock_timestamp() - interval '10 days';
BEGIN
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#2PP') RETURNING clan_key INTO clan_a;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#2QQ') RETURNING clan_key INTO clan_b;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#2RR') RETURNING clan_key INTO untracked;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#2YY') RETURNING player_key INTO player_a;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#2LL') RETURNING player_key INTO player_b;

    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (clan_a), (clan_b);
    BEGIN
        UPDATE guild.clan_collection_settings SET membership_poll_seconds = 0 WHERE clan_key = clan_a;
        RAISE EXCEPTION 'A member list interval of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    -- Agreed default cadences (DEC-04); each is a positive per-clan setting.
    IF (SELECT (membership_poll_seconds, war_poll_seconds, player_profile_seconds,
            cwl_group_poll_seconds, cwl_war_poll_seconds, raid_poll_seconds, raid_report_seconds)
            <> (120, 120, 3600, 900, 120, 900, 28800)
        FROM guild.clan_collection_settings WHERE clan_key = clan_a) THEN
        RAISE EXCEPTION 'Collection cadences do not have their agreed defaults';
    END IF;
    UPDATE guild.clan_collection_settings SET war_poll_seconds = 300, player_profile_seconds = 7200,
        cwl_group_poll_seconds = 1800, cwl_war_poll_seconds = 300, raid_poll_seconds = 1800
    WHERE clan_key = clan_b;
    BEGIN
        UPDATE guild.clan_collection_settings SET war_poll_seconds = 0 WHERE clan_key = clan_a;
        RAISE EXCEPTION 'A war poll interval of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.clan_collection_settings SET player_profile_seconds = 0 WHERE clan_key = clan_a;
        RAISE EXCEPTION 'A profile interval of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.clan_collection_settings SET cwl_group_poll_seconds = 0 WHERE clan_key = clan_a;
        RAISE EXCEPTION 'A CWL group interval of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.clan_collection_settings SET cwl_war_poll_seconds = 0 WHERE clan_key = clan_a;
        RAISE EXCEPTION 'A CWL war interval of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.clan_collection_settings SET raid_poll_seconds = 0 WHERE clan_key = clan_a;
        RAISE EXCEPTION 'A raid interval of zero seconds was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.clan_collection_settings SET automatic_freeze_minutes = -1 WHERE clan_key = clan_a;
        RAISE EXCEPTION 'A negative CWL freeze cutoff was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.clan_collection_settings WHERE clan_key = clan_b;
        RAISE EXCEPTION 'The runtime role deleted a tracked clan';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    INSERT INTO guild.war_reminder_setting (clan_key, seconds_before_end) VALUES (clan_a, 28800), (clan_a, 14400);
    BEGIN
        INSERT INTO guild.war_reminder_setting (clan_key, seconds_before_end) VALUES (clan_a, 28800);
        RAISE EXCEPTION 'A repeated reminder must not duplicate';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.war_reminder_setting (clan_key, seconds_before_end) VALUES (untracked, 28800);
        RAISE EXCEPTION 'A reminder was configured for an untracked clan';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    DELETE FROM guild.war_reminder_setting WHERE clan_key = clan_a AND seconds_before_end = 14400;

    -- Member list polls and stored member state.
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_a, 'test:poll:a', seen, 'complete') RETURNING poll_key INTO poll_a;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_b, 'test:poll:b', seen, 'complete') RETURNING poll_key INTO poll_b;
    BEGIN
        INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (clan_a, 'test:poll:failed', seen, 'failed');
        RAISE EXCEPTION 'A failed poll was accepted without its failure code';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome, failure_code)
    VALUES (clan_a, 'test:poll:failed', seen + interval '2 minutes', 'failed', 'http_503')
    RETURNING poll_key INTO failed_poll;
    BEGIN
        INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (clan_a, 'test:poll:a', seen, 'complete');
        RAISE EXCEPTION 'A poll correlation ID was reused';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (untracked, 'test:poll:untracked', seen, 'complete');
        RAISE EXCEPTION 'An untracked clan was polled';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_member_observation (poll_key, player_key, in_game_role, donations, donations_received)
    VALUES (poll_a, player_a, 'member', 25, 10);
    BEGIN
        INSERT INTO guild.fact_clan_member_observation
            (poll_key, player_key, in_game_role, donations, donations_received)
        VALUES (poll_a, player_a, 'elder', 30, 10);
        RAISE EXCEPTION 'One poll stored two states for a member';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_member_observation (poll_key, player_key, donations)
        VALUES (poll_a, player_b, -1);
        RAISE EXCEPTION 'A negative donation counter was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_clan_member_observation SET donations = 0 WHERE poll_key = poll_a;
        RAISE EXCEPTION 'The runtime role rewrote stored member state';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
    VALUES (poll_a, clan_a, player_a, 'observed_join', seen);
    BEGIN
        INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
        VALUES (poll_a, clan_a, player_a, 'observed_join', seen);
        RAISE EXCEPTION 'One poll recorded the same join twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
        VALUES (poll_a, clan_b, player_b, 'observed_join', seen);
        RAISE EXCEPTION 'A membership change named a poll of another clan';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_clan_membership_change
            (poll_key, clan_key, player_key, change_kind, previous_success_at, observed_at)
        VALUES (poll_a, clan_a, player_b, 'observed_departure', seen + interval '1 minute', seen);
        RAISE EXCEPTION 'A departure followed a successful poll that came after it';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    -- Observed membership periods.
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
        confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (player_a, clan_a, seen, seen, 'test', 'adequate', poll_a, poll_a)
    RETURNING membership_period_key INTO period;
    BEGIN
        INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
            confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
        VALUES (player_a, clan_a, seen, seen, 'test', 'adequate', poll_a, poll_a);
        RAISE EXCEPTION 'Overlapping membership in one clan was accepted';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
            confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
        VALUES (player_b, clan_b, seen, seen, 'test', 'adequate', poll_a, poll_b);
        RAISE EXCEPTION 'A period started from a poll of another clan';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET observed_until = observed_since
        WHERE membership_period_key = period;
        RAISE EXCEPTION 'A period closed when it started';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET confirmed_through = observed_since - interval '1 second'
        WHERE membership_period_key = period;
        RAISE EXCEPTION 'A period was confirmed before it started';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period
        SET observed_until = seen + interval '1 minute', confirmed_through = seen + interval '2 minutes'
        WHERE membership_period_key = period;
        RAISE EXCEPTION 'A closed period was confirmed after it closed';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET observed_since = seen - interval '1 day'
        WHERE membership_period_key = period;
        RAISE EXCEPTION 'The runtime role moved the start of a period';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        UPDATE guild.observed_clan_membership_period SET clan_key = clan_b
        WHERE membership_period_key = period;
        RAISE EXCEPTION 'Reassigning the row incorrectly hid current membership without closure evidence';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    UPDATE guild.observed_clan_membership_period
    SET confirmed_through = seen + interval '2 minutes', last_poll_key = failed_poll
    WHERE membership_period_key = period;
    IF NOT EXISTS (SELECT FROM guild.current_observed_clan_member WHERE player_key = player_a) THEN
        RAISE EXCEPTION 'The runtime role could not read the membership it recorded';
    END IF;

    -- Season calendar.
    INSERT INTO guild.dim_coc_season (season_month, starts_at, ends_at)
    VALUES ('2026-10-01', '2026-09-28 05:00+00', '2026-10-26 05:00+00');
    BEGIN
        INSERT INTO guild.dim_coc_season (season_month, starts_at, ends_at)
        VALUES ('2026-11-02', '2026-10-26 05:00+00', '2026-11-30 05:00+00');
        RAISE EXCEPTION 'A season month that is not the first of a month was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_coc_season (season_month, starts_at, ends_at)
        VALUES ('2026-11-01', '2026-10-20 05:00+00', '2026-11-30 05:00+00');
        RAISE EXCEPTION 'Overlapping seasons were accepted';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_coc_season (season_month, starts_at, ends_at)
        VALUES ('2026-10-01', '2026-11-30 05:00+00', '2026-12-28 05:00+00');
        RAISE EXCEPTION 'Two rows were accepted for one season';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.dim_coc_season (season_month, starts_at, ends_at)
    VALUES ('2026-11-01', '2026-10-26 05:00+00', '2026-11-30 05:00+00');

    -- Wars.
    BEGIN
        INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
            team_size, attacks_per_member, identity_source)
        VALUES (greatest(clan_a, clan_b), least(clan_a, clan_b), seen, seen + interval '1 day',
            seen + interval '2 days', 15, 2, 'clan_pair_preparation');
        RAISE EXCEPTION 'A war accepted its clan pair out of order';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
            team_size, attacks_per_member, identity_source)
        VALUES (least(clan_a, clan_b), greatest(clan_a, clan_b), seen, seen + interval '1 day',
            seen + interval '1 day', 15, 2, 'clan_pair_preparation');
        RAISE EXCEPTION 'A war ended when its battle day started';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
            team_size, attacks_per_member, identity_source)
        VALUES (least(clan_a, clan_b), greatest(clan_a, clan_b), seen, seen + interval '1 day',
            seen + interval '2 days', 15, 2, 'cwl_war_tag');
        RAISE EXCEPTION 'A regular war claimed a CWL war tag identity';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
            team_size, attacks_per_member, war_kind, source_war_tag, identity_source, attack_allowance_source)
        VALUES (least(clan_a, clan_b), greatest(clan_a, clan_b), seen, seen + interval '1 day',
            seen + interval '2 days', 15, 2, 'cwl', '#2CWL', 'cwl_war_tag', 'game_format');
        RAISE EXCEPTION 'A game-format CWL allowance accepted two attacks per member';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
            team_size, attacks_per_member, source_war_tag, identity_source)
        VALUES (least(clan_a, clan_b), greatest(clan_a, clan_b), seen, seen + interval '1 day',
            seen + interval '2 days', 15, 2, ' ', 'clan_pair_preparation');
        RAISE EXCEPTION 'A blank source war tag was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
        team_size, attacks_per_member, identity_source)
    VALUES (least(clan_a, clan_b), greatest(clan_a, clan_b), seen, seen + interval '1 day',
        seen + interval '2 days', 15, 2, 'clan_pair_preparation') RETURNING war_key INTO war;
    BEGIN
        INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
            team_size, attacks_per_member, identity_source)
        VALUES (least(clan_a, clan_b), greatest(clan_a, clan_b), seen, seen + interval '1 day',
            seen + interval '2 days', 15, 2, 'clan_pair_preparation');
        RAISE EXCEPTION 'One clan pair and preparation start identified two wars';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    UPDATE guild.dim_war SET war_kind = 'custom' WHERE war_key = war;
    BEGIN
        UPDATE guild.dim_war SET ends_at = ends_at + interval '1 hour' WHERE war_key = war;
        RAISE EXCEPTION 'The runtime role moved the end of a recorded war';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- War polls prove coverage; observations name the poll that stored them.
    BEGIN
        INSERT INTO guild.war_poll (clan_key, endpoint_kind, source_correlation_id, observed_at, outcome)
        VALUES (clan_a, 'current_war', 'test:war-poll:none', seen, 'war');
        RAISE EXCEPTION 'A war poll found a war without naming it';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.war_poll (clan_key, endpoint_kind, source_correlation_id, observed_at, outcome, war_key)
        VALUES (clan_a, 'current_war', 'test:war-poll:not-in-war', seen, 'not_in_war', war);
        RAISE EXCEPTION 'A poll without a war named a war';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.war_poll (clan_key, endpoint_kind, source_correlation_id, observed_at, outcome)
        VALUES (clan_a, 'current_war', 'test:war-poll:failed', seen, 'failed');
        RAISE EXCEPTION 'A failed war poll was accepted without its failure code';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.war_poll (clan_key, endpoint_kind, source_correlation_id, observed_at, outcome)
        VALUES (untracked, 'current_war', 'test:war-poll:untracked', seen, 'not_in_war');
        RAISE EXCEPTION 'An untracked clan was polled for its war';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.war_poll (clan_key, endpoint_kind, source_correlation_id, observed_at, outcome, war_key)
    VALUES (clan_a, 'current_war', 'test:war-poll:1', seen, 'war', war) RETURNING war_poll_key INTO war_poll;
    INSERT INTO guild.war_poll (clan_key, endpoint_kind, source_correlation_id, observed_at, outcome, war_key)
    VALUES (clan_a, 'current_war', 'test:war-poll:2', seen + interval '5 minutes', 'war', war)
    RETURNING war_poll_key INTO later_poll;
    INSERT INTO guild.war_poll (clan_key, endpoint_kind, source_correlation_id, observed_at, outcome,
        failure_code)
    VALUES (clan_a, 'current_war', 'test:war-poll:3', seen + interval '10 minutes', 'failed', 'http_503');
    BEGIN
        INSERT INTO guild.war_poll (clan_key, endpoint_kind, source_correlation_id, observed_at, outcome)
        VALUES (clan_a, 'current_war', 'test:war-poll:1', seen, 'not_in_war');
        RAISE EXCEPTION 'A war poll correlation ID was reused';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    INSERT INTO guild.fact_war_observation (war_key, observed_at, war_poll_key, source_correlation_id,
        source_payload)
    VALUES (war, seen, war_poll, 'test:war', '{"state": "inWar", "clan": {"tag": "#2PP"}}');
    BEGIN
        INSERT INTO guild.fact_war_observation (war_key, observed_at, war_poll_key, source_correlation_id,
            source_payload)
        VALUES (war, seen + interval '1 minute', war_poll, 'test:war:time', '{"state": "inWar"}');
        RAISE EXCEPTION 'A war observation was stored at another time than its poll';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_war_observation (war_key, observed_at, war_poll_key, source_correlation_id,
            source_payload)
        VALUES (war, seen + interval '5 minutes', later_poll, 'test:war:token',
            '{"clan": {"members": [{"token": "x"}]}}');
        RAISE EXCEPTION 'A war response with a token was stored';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_war_observation (war_key, observed_at, war_poll_key, source_correlation_id,
            source_payload)
        VALUES (war, seen + interval '5 minutes', later_poll, 'test:war:array', '[]');
        RAISE EXCEPTION 'A war response that is not an object was stored';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    INSERT INTO guild.war_participant (war_key, clan_key, player_key)
    VALUES (war, clan_a, player_a), (war, clan_b, player_b);
    BEGIN
        INSERT INTO guild.war_participant (war_key, clan_key, player_key) VALUES (war, clan_b, player_a);
        RAISE EXCEPTION 'An account took part on both sides of one war';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.fact_war_roster_observation (war_key, clan_key, player_key, observed_at, war_poll_key,
        source_correlation_id, player_name, town_hall_level, map_position)
    VALUES (war, clan_a, player_a, seen, war_poll, 'test:roster', 'Attacker', 16, 1);
    BEGIN
        INSERT INTO guild.fact_war_roster_observation (war_key, clan_key, player_key, observed_at, war_poll_key,
            source_correlation_id, player_name, town_hall_level, map_position)
        VALUES (war, clan_b, player_a, seen + interval '5 minutes', later_poll, 'test:roster', 'Attacker', 16, 1);
        RAISE EXCEPTION 'A roster row named the other side of its participant';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_war_roster_observation (war_key, clan_key, player_key, observed_at, war_poll_key,
            source_correlation_id, player_name, town_hall_level, map_position)
        VALUES (war, clan_b, player_b, seen + interval '1 minute', war_poll, 'test:roster', 'Defender', 16, 1);
        RAISE EXCEPTION 'A roster row was stored without a poll at its time';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_war_clan_observation (war_key, clan_key, observed_at, war_poll_key,
            source_correlation_id, state, stars, attacks, destruction_percentage)
        VALUES (war, clan_a, seen, war_poll, 'test:clan', 'inWar', 3, 1, 100.5);
        RAISE EXCEPTION 'A destruction above 100 percent was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_war_clan_observation (war_key, clan_key, observed_at, war_poll_key,
        source_correlation_id, state, stars, attacks, destruction_percentage)
    VALUES (war, clan_a, seen, war_poll, 'test:clan', 'inWar', 3, 1, 100);

    INSERT INTO guild.fact_war_attack (war_key, attacker_key, defender_key, attack_order, stars,
        destruction_percentage, first_observed_at, last_observed_at, source_correlation_id)
    VALUES (war, player_a, player_b, 1, 3, 100, seen, seen, 'test:attack') RETURNING attack_key INTO attack;
    IF (SELECT occurred_at FROM guild.fact_war_attack WHERE attack_key = attack) IS NOT NULL THEN
        RAISE EXCEPTION 'Observation time must not silently become attack occurrence time';
    END IF;
    BEGIN
        INSERT INTO guild.fact_war_attack (war_key, attacker_key, defender_key, attack_order, stars,
            destruction_percentage, first_observed_at, last_observed_at, source_correlation_id)
        VALUES (war, player_a, player_b, 1, 3, 100, seen, seen, 'test:attack:again');
        RAISE EXCEPTION 'Repeated attack fetch was incorrectly accepted as a second attack';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_war_attack (war_key, attacker_key, defender_key, attack_order, stars,
            destruction_percentage, first_observed_at, last_observed_at, source_correlation_id)
        VALUES (war, player_a, player_a, 2, 1, 50, seen, seen, 'test:attack:self');
        RAISE EXCEPTION 'An account attacked itself';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_war_attack (war_key, attacker_key, defender_key, attack_order, stars,
            destruction_percentage, first_observed_at, last_observed_at, source_correlation_id)
        VALUES (war, player_a, player_b, 3, 4, 100, seen, seen, 'test:attack:stars');
        RAISE EXCEPTION 'An attack with four stars was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_war_attack (war_key, attacker_key, defender_key, attack_order, stars,
            destruction_percentage, first_observed_at, last_observed_at, source_correlation_id)
        VALUES (war, player_a, player_b, 4, 1, 50, seen, seen - interval '1 second', 'test:attack:time');
        RAISE EXCEPTION 'An attack was last observed before it was first observed';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.fact_war_attack SET last_observed_at = seen + interval '5 minutes' WHERE attack_key = attack;
    BEGIN
        UPDATE guild.fact_war_attack SET stars = 1 WHERE attack_key = attack;
        RAISE EXCEPTION 'The runtime role rewrote the stars of a recorded attack';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.fact_war_attack WHERE attack_key = attack;
        RAISE EXCEPTION 'The runtime role deleted a recorded attack';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Profile and achievement observations, and raids.
    INSERT INTO guild.fact_player_counter_observation
        (player_key, observed_at, source_correlation_id, town_hall_level, war_stars)
    VALUES (player_a, seen, 'test:profile', 16, 1200);
    BEGIN
        INSERT INTO guild.fact_player_counter_observation
            (player_key, observed_at, source_correlation_id, town_hall_level, war_stars)
        VALUES (player_a, seen, 'test:profile:again', 16, 1201);
        RAISE EXCEPTION 'One account had two profile observations at one time';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.dim_achievement (source_name, village) VALUES ('Games Champion', 'home')
    RETURNING achievement_key INTO achievement;
    BEGIN
        INSERT INTO guild.dim_achievement (source_name, village) VALUES ('Games Champion', 'home');
        RAISE EXCEPTION 'An achievement was identified twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_player_achievement_observation
            (player_key, achievement_key, observed_at, source_correlation_id, value)
        VALUES (player_a, achievement, seen, 'test:achievement', -1);
        RAISE EXCEPTION 'A negative achievement counter was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.dim_raid_weekend (clan_key, starts_at, ends_at)
    VALUES (clan_a, seen - interval '3 days', seen) RETURNING raid_weekend_key INTO raid;
    BEGIN
        INSERT INTO guild.dim_raid_weekend (clan_key, starts_at, ends_at)
        VALUES (clan_a, seen - interval '3 days', seen + interval '1 day');
        RAISE EXCEPTION 'One clan had two raid weekends with the same start';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- GAP-11: every raid poll is kept; state and totals are stored on change.
    INSERT INTO guild.dim_raid_weekend (clan_key, starts_at, ends_at)
    VALUES (clan_b, seen - interval '3 days', seen) RETURNING raid_weekend_key INTO raid_b;
    INSERT INTO guild.raid_poll (clan_key, source_correlation_id, observed_at, outcome, raid_weekend_key)
    VALUES (clan_a, 'test:raid-poll:1', seen - interval '1 hour', 'weekend', raid)
    RETURNING raid_poll_key INTO raid_poll_one;
    INSERT INTO guild.raid_poll (clan_key, source_correlation_id, observed_at, outcome, raid_weekend_key)
    VALUES (clan_a, 'test:raid-poll:2', seen, 'weekend', raid) RETURNING raid_poll_key INTO raid_poll_two;
    INSERT INTO guild.raid_poll (clan_key, source_correlation_id, observed_at, outcome, failure_code)
    VALUES (clan_a, 'test:raid-poll:3', seen + interval '1 hour', 'failed', 'http_503');
    INSERT INTO guild.raid_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_b, 'test:raid-poll:4', seen, 'no_weekend');
    BEGIN
        INSERT INTO guild.raid_poll (clan_key, source_correlation_id, observed_at, outcome, raid_weekend_key)
        VALUES (clan_a, 'test:raid-poll:5', seen, 'weekend', raid_b);
        RAISE EXCEPTION 'A raid poll named another clan''s weekend';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.raid_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (clan_a, 'test:raid-poll:6', seen, 'failed');
        RAISE EXCEPTION 'A failed raid poll had no failure code';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.raid_poll (clan_key, source_correlation_id, observed_at, outcome)
        VALUES (clan_a, 'test:raid-poll:7', seen, 'weekend');
        RAISE EXCEPTION 'A successful raid poll named no weekend';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_raid_weekend_observation
        (raid_weekend_key, observed_at, raid_poll_key, source_state, reported_members, capital_total_loot)
    VALUES (raid, seen - interval '1 hour', raid_poll_one, 'ongoing', 1, 12000);
    BEGIN
        INSERT INTO guild.fact_raid_weekend_observation
            (raid_weekend_key, observed_at, raid_poll_key, source_state, reported_members, capital_total_loot)
        VALUES (raid, seen, raid_poll_one, 'ended', 1, 12000);
        RAISE EXCEPTION 'A weekend state named another poll time';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.fact_raid_member_observation
        (raid_weekend_key, player_key, observed_at, raid_poll_key, source_correlation_id, capital_resources_looted)
    VALUES (raid, player_a, seen - interval '1 hour', raid_poll_one, 'test:raid', 12000);
    BEGIN
        INSERT INTO guild.fact_raid_member_observation
            (raid_weekend_key, player_key, observed_at, raid_poll_key, source_correlation_id,
                capital_resources_looted)
        VALUES (raid, player_a, seen, raid_poll_two, 'test:raid:negative', -1);
        RAISE EXCEPTION 'Negative raid loot was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_raid_member_observation
            (raid_weekend_key, player_key, observed_at, raid_poll_key, source_correlation_id,
                capital_resources_looted)
        VALUES (raid_b, player_a, seen, raid_poll_two, 'test:raid:wrong-weekend', 100);
        RAISE EXCEPTION 'A raid total named a poll of another weekend';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    -- The unchanged total is not stored again, but coverage reaches the second
    -- poll and the failed poll extends nothing.
    IF (SELECT (observed_through, successful_polls) FROM guild.raid_weekend_coverage
        WHERE raid_weekend_key = raid) <> (seen, 2::bigint) THEN
        RAISE EXCEPTION 'Raid coverage did not reach the latest successful poll';
    END IF;
    RAISE NOTICE 'Membership, war, profile and raid constraints passed';
END;
$$;

-- GAP-12: a move is observed on two independent poll cycles. Clan B sees the
-- account at 12:01; clan A first sees its departure at 12:02. Both real
-- boundaries are stored, in either ingestion order.
DO $$
DECLARE
    clan_a bigint; clan_b bigint; mover bigint; mover_later bigint; member_id bigint;
    proof bigint; episode bigint; join_event bigint; role_a bigint; role_b bigint;
    a_1158 bigint; a_1200 bigint; a_1201h bigint; a_1202 bigint; a_1204 bigint; b_1201 bigint;
    b_1203 bigint;
    period_a bigint; period_b bigint; presence interval;
    noon timestamptz := date_trunc('hour', clock_timestamp() - interval '5 days');
BEGIN
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#9PP') RETURNING clan_key INTO clan_a;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#9QQ') RETURNING clan_key INTO clan_b;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (clan_a), (clan_b);
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#9YY') RETURNING player_key INTO mover;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#9LL') RETURNING player_key INTO mover_later;

    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_a, 'test:move:a:1158', noon - interval '2 minutes', 'complete') RETURNING poll_key INTO a_1158;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_a, 'test:move:a:1200', noon, 'complete') RETURNING poll_key INTO a_1200;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_b, 'test:move:b:1201', noon + interval '1 minute', 'complete') RETURNING poll_key INTO b_1201;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_a, 'test:move:a:1202', noon + interval '2 minutes', 'complete') RETURNING poll_key INTO a_1202;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_a, 'test:move:a:1201h', noon + interval '90 seconds', 'complete') RETURNING poll_key INTO a_1201h;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_b, 'test:move:b:1203', noon + interval '3 minutes', 'complete') RETURNING poll_key INTO b_1203;
    INSERT INTO guild.clan_membership_poll (clan_key, source_correlation_id, observed_at, outcome)
    VALUES (clan_a, 'test:move:a:1204', noon + interval '4 minutes', 'complete') RETURNING poll_key INTO a_1204;
    INSERT INTO guild.fact_player_counter_observation (player_key, observed_at, source_correlation_id, war_stars)
    VALUES (mover, noon, 'test:move:profile', 900);

    -- Order 1: B's join is ingested while A's period is still open.
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
        confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (mover, clan_a, noon - interval '2 minutes', noon, 'test', 'adequate', a_1158, a_1200)
    RETURNING membership_period_key INTO period_a;
    INSERT INTO guild.fact_clan_membership_change (poll_key, clan_key, player_key, change_kind, observed_at)
    VALUES (b_1201, clan_b, mover, 'observed_join', noon + interval '1 minute');
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
        confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (mover, clan_b, noon + interval '1 minute', noon + interval '1 minute', 'test', 'adequate',
        b_1201, b_1201)
    RETURNING membership_period_key INTO period_b;
    IF (SELECT count(*) FROM guild.observed_clan_membership_period
        WHERE player_key = mover AND observed_until IS NULL) <> 2 THEN
        RAISE EXCEPTION 'Both open periods of an asynchronous move were not retained';
    END IF;
    IF (SELECT array_agg(clan_key) FROM guild.current_observed_clan_member WHERE player_key = mover)
        IS DISTINCT FROM ARRAY[clan_b] THEN
        RAISE EXCEPTION 'The newer observation did not resolve the current clan of a moving account';
    END IF;
    IF EXISTS (SELECT FROM guild.current_clan_member_state WHERE clan_key = clan_a AND player_key = mover) THEN
        RAISE EXCEPTION 'The member list of the old clan still showed a moved account';
    END IF;
    IF (SELECT array_agg(clan_key) FROM guild.current_clan_lifetime_war_stars WHERE player_key = mover)
        IS DISTINCT FROM ARRAY[clan_b] THEN
        RAISE EXCEPTION 'A moving account was ranked in a clan other than its resolved current clan';
    END IF;
    -- Only a later departure from A closes its period; the boundary stays 12:02.
    INSERT INTO guild.fact_clan_membership_change
        (poll_key, clan_key, player_key, change_kind, previous_success_at, observed_at)
    VALUES (a_1202, clan_a, mover, 'observed_departure', noon, noon + interval '2 minutes');
    UPDATE guild.observed_clan_membership_period SET observed_until = noon + interval '2 minutes'
    WHERE membership_period_key = period_a;

    -- A second B period that overlaps the first is still rejected.
    BEGIN
        INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
            confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
        VALUES (mover, clan_b, noon + interval '1 minute', noon + interval '1 minute', 'test', 'adequate',
            b_1201, b_1201);
        RAISE EXCEPTION 'Overlapping periods of one account in one clan were accepted';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
            confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
        VALUES (mover, clan_a, noon, noon, 'test', 'adequate', a_1158, a_1200);
        RAISE EXCEPTION 'A period overlapping a closed period of the same clan was accepted';
    EXCEPTION WHEN exclusion_violation THEN NULL;
    END;

    -- Order 2: A's departure is ingested before B's earlier join.
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
        confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (mover_later, clan_a, noon - interval '2 minutes', noon, 'test', 'adequate', a_1158, a_1200);
    INSERT INTO guild.fact_clan_membership_change
        (poll_key, clan_key, player_key, change_kind, previous_success_at, observed_at)
    VALUES (a_1202, clan_a, mover_later, 'observed_departure', noon, noon + interval '2 minutes');
    UPDATE guild.observed_clan_membership_period SET observed_until = noon + interval '2 minutes'
    WHERE player_key = mover_later AND clan_key = clan_a;
    IF EXISTS (SELECT FROM guild.current_observed_clan_member WHERE player_key = mover_later) THEN
        RAISE EXCEPTION 'A closed period remained current';
    END IF;
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
        confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (mover_later, clan_b, noon + interval '1 minute', noon + interval '1 minute', 'test', 'adequate',
        b_1201, b_1201);
    IF (SELECT clan_key FROM guild.current_observed_clan_member WHERE player_key = mover_later)
        IS DISTINCT FROM clan_b THEN
        RAISE EXCEPTION 'A join ingested after the departure did not become current';
    END IF;

    -- Both orders store the same boundaries.
    IF ARRAY(SELECT (clan_key, observed_since, observed_until)::text FROM guild.observed_clan_membership_period
            WHERE player_key = mover ORDER BY clan_key)
        IS DISTINCT FROM ARRAY(SELECT (clan_key, observed_since, observed_until)::text
            FROM guild.observed_clan_membership_period WHERE player_key = mover_later ORDER BY clan_key) THEN
        RAISE EXCEPTION 'The ingestion order changed the stored membership boundaries';
    END IF;

    -- Clan Games presence (SR-CG-03): the union of the periods clipped to
    -- confirmed_through counts the overlapping supported time once. A was
    -- last seen at 12:01:30 and B is confirmed through 12:03: 11:58-12:03.
    UPDATE guild.observed_clan_membership_period
    SET confirmed_through = noon + interval '90 seconds', last_poll_key = a_1201h
    WHERE membership_period_key = period_a;
    UPDATE guild.observed_clan_membership_period
    SET confirmed_through = noon + interval '3 minutes', last_poll_key = b_1203
    WHERE membership_period_key = period_b;
    SELECT sum(upper(r) - lower(r)) INTO presence
    FROM unnest((
        SELECT range_agg(tstzrange(observed_since, confirmed_through, '[)'))
        FROM guild.observed_clan_membership_period WHERE player_key = mover
    )) r;
    IF presence <> interval '300 seconds' THEN
        RAISE EXCEPTION 'Supported presence across two clans was not counted once: %', presence;
    END IF;

    -- Current role: a linked, present member holds only the resolved clan's role.
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (930000000000000041) RETURNING user_key INTO member_id;
    INSERT INTO guild.player_verification (user_key, player_key, status)
    VALUES (member_id, mover, 'verified') RETURNING verification_key INTO proof;
    INSERT INTO guild.metric_attribution_episode (user_key, player_key, first_link_at)
    VALUES (member_id, mover, noon) RETURNING attribution_key INTO episode;
    INSERT INTO guild.account_link (user_key, player_key, verification_key, attribution_key, is_primary)
    VALUES (member_id, mover, proof, episode, true);
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at, new_joinee_policy_days)
    VALUES (member_id, 'join', noon, 7) RETURNING membership_event_key INTO join_event;
    INSERT INTO guild.discord_member_state (user_key, is_present, last_membership_event_key, last_event_at)
    VALUES (member_id, true, join_event, noon);
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (930000000000000051, 'Clan A') RETURNING role_key INTO role_a;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (930000000000000052, 'Clan B') RETURNING role_key INTO role_b;
    INSERT INTO guild.role_binding (clan_key, purpose, role_key) VALUES (clan_a, 'member', role_a), (clan_b, 'member', role_b);
    IF (SELECT array_agg(role_key) FROM guild.desired_clan_member_role WHERE user_key = member_id)
        IS DISTINCT FROM ARRAY[role_b] THEN
        RAISE EXCEPTION 'The desired clan role did not follow the resolved current clan';
    END IF;
    -- The account moves back: A sees it at 12:04 before B observes the
    -- departure. The newer observation wins again, for the role and the board.
    INSERT INTO guild.observed_clan_membership_period (player_key, clan_key, observed_since,
        confirmed_through, boundary_policy, coverage_status, first_poll_key, last_poll_key)
    VALUES (mover, clan_a, noon + interval '4 minutes', noon + interval '4 minutes', 'test', 'adequate',
        a_1204, a_1204);
    IF (SELECT array_agg(role_key) FROM guild.desired_clan_member_role WHERE user_key = member_id)
        IS DISTINCT FROM ARRAY[role_a] THEN
        RAISE EXCEPTION 'The desired clan role did not follow the latest positive observation';
    END IF;
    IF (SELECT array_agg(clan_key) FROM guild.current_clan_lifetime_war_stars WHERE player_key = mover)
        IS DISTINCT FROM ARRAY[clan_a] THEN
        RAISE EXCEPTION 'The board did not follow the latest positive observation';
    END IF;
    RAISE NOTICE 'Asynchronous cross-clan move passed';
END;
$$;

ROLLBACK;
