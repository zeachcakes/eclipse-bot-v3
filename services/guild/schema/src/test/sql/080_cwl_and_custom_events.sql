BEGIN;

-- V6: CWL cycles, signups, plans, pins, benches and exports, custom events and
-- activity command operations. The service checks permissions, deadlines,
-- availability, freezes and benches; these checks cover the keys and row checks.
DO $$
DECLARE
    staff_id bigint; member_id bigint; clan_a bigint; clan_b bigint; untracked bigint;
    player_a bigint; player_b bigint; war bigint; regular_war bigint; attack bigint;
    cycle bigint; earlier_cycle bigint; second_cycle bigint; schedule_rev bigint;
    participation bigint; other_participation bigint;
    earlier_participation bigint; group_poll bigint; later_poll bigint; failed_poll bigint;
    group_observation bigint;
    signup bigint; signup_rev bigint; move_rev bigint; plan bigint; other_plan bigint; incident bigint; export_revision bigint;
    signup_export bigint; sheet_attempt bigint; signups_channel bigint; signups_report uuid;
    signups_revision uuid;
    carry_plan bigint; manual_plan bigint;
    event_id bigint; custom_signup bigint; roster bigint;
    op_signup uuid := gen_random_uuid(); op_retry uuid := gen_random_uuid(); op_pin uuid := gen_random_uuid();
    op_event uuid := gen_random_uuid(); op_roster uuid := gen_random_uuid(); op_result uuid := gen_random_uuid();
    op_withdraw uuid := gen_random_uuid(); op_select uuid := gen_random_uuid();
    op_select_other uuid := gen_random_uuid(); op_resize uuid := gen_random_uuid();
    op_withdraw_clan uuid := gen_random_uuid(); op_reselect uuid := gen_random_uuid();
    op_move uuid := gen_random_uuid(); op_reschedule uuid := gen_random_uuid();
    op_second_cycle uuid := gen_random_uuid();
    seen timestamptz := '2026-11-03 08:00+00';
BEGIN
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (980000000000000011) RETURNING user_key INTO staff_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (980000000000000012) RETURNING user_key INTO member_id;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#8PP') RETURNING clan_key INTO clan_a;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#8QQ') RETURNING clan_key INTO clan_b;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#8RR') RETURNING clan_key INTO untracked;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (clan_a), (clan_b);
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#8YY') RETURNING player_key INTO player_a;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#8LL') RETURNING player_key INTO player_b;
    INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at, team_size,
        attacks_per_member, war_kind, source_war_tag, identity_source, attack_allowance_source)
    VALUES (least(clan_a, untracked), greatest(clan_a, untracked), seen, seen + interval '1 day',
        seen + interval '2 days', 15, 1, 'cwl', '#8CWL1', 'cwl_war_tag', 'game_format') RETURNING war_key INTO war;
    INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at, team_size,
        attacks_per_member, identity_source)
    VALUES (least(clan_b, untracked), greatest(clan_b, untracked), seen, seen + interval '1 day',
        seen + interval '2 days', 15, 2, 'clan_pair_preparation') RETURNING war_key INTO regular_war;
    INSERT INTO guild.war_participant (war_key, clan_key, player_key)
    VALUES (war, clan_a, player_a), (war, untracked, player_b);
    INSERT INTO guild.fact_war_attack (war_key, attacker_key, defender_key, attack_order, stars,
        destruction_percentage, first_observed_at, last_observed_at, source_correlation_id)
    VALUES (war, player_a, player_b, 1, 1, 40, seen + interval '1 day', seen + interval '1 day', 'test:cwl-attack')
    RETURNING attack_key INTO attack;

    -- Activity command operations.
    BEGIN
        INSERT INTO guild.activity_command_operation (operation_id, actor_user_key, action, arguments)
        VALUES (op_signup, member_id, 'cwl_signup', '["not", "an", "object"]');
        RAISE EXCEPTION 'Untyped command arguments were stored';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.activity_command_operation (operation_id, actor_user_key, action, arguments)
    VALUES (op_signup, member_id, 'cwl_signup', '{"days": [1, 2, 3]}'),
        (op_retry, member_id, 'cwl_signup', '{"days": [4]}'),
        (op_pin, staff_id, 'cwl_pin', '{}'), (op_event, staff_id, 'custom_event_signup', '{}'),
        (op_roster, staff_id, 'custom_event_roster', '{}'), (op_result, staff_id, 'custom_event_result', '{}'),
        (op_withdraw, staff_id, 'custom_event_signup', '{}'),
        (op_select, staff_id, 'cwl_select_clan', '{}'), (op_select_other, staff_id, 'cwl_select_clan', '{}'),
        (op_resize, staff_id, 'cwl_change_clan', '{}'), (op_withdraw_clan, staff_id, 'cwl_change_clan', '{}'),
        (op_reselect, staff_id, 'cwl_change_clan', '{}'), (op_move, staff_id, 'cwl_move_signup', '{}'),
        (op_reschedule, staff_id, 'cwl_reschedule', '{}'), (op_second_cycle, staff_id, 'cwl_create_cycle', '{}');
    BEGIN
        INSERT INTO guild.activity_command_operation (operation_id, actor_user_key, action, arguments)
        VALUES (op_signup, staff_id, 'cwl_signup', '{"days": [5]}');
        RAISE EXCEPTION 'Operation identity accepted changed arguments';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.activity_command_operation SET arguments = '{}' WHERE operation_id = op_signup;
        RAISE EXCEPTION 'A command changed its stored arguments';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Cycles, participating clans and War Days.
    BEGIN
        INSERT INTO guild.cwl_cycle (calendar_month) VALUES ('2026-12-15');
        RAISE EXCEPTION 'A CWL cycle that is not a calendar month was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    -- Only one cycle is open at a time (CWL-018): the earlier cycle ends
    -- before the next one is created.
    INSERT INTO guild.cwl_cycle (calendar_month) VALUES ('2026-11-01') RETURNING cycle_key INTO earlier_cycle;
    INSERT INTO guild.cwl_participating_clan (cycle_key, clan_key)
    VALUES (earlier_cycle, clan_a) RETURNING participation_key INTO earlier_participation;
    BEGIN
        INSERT INTO guild.cwl_cycle (calendar_month) VALUES ('2026-12-01');
        RAISE EXCEPTION 'A cycle was created while another cycle was open';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.cwl_cycle SET state = 'ended' WHERE cycle_key = earlier_cycle;
        RAISE EXCEPTION 'A cycle ended without its end time';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.cwl_cycle SET state = 'ended', ended_at = '2026-11-12 00:00+00' WHERE cycle_key = earlier_cycle;
    INSERT INTO guild.cwl_cycle (calendar_month) VALUES ('2026-12-01') RETURNING cycle_key INTO cycle;
    BEGIN
        INSERT INTO guild.cwl_cycle (calendar_month) VALUES ('2026-11-01');
        RAISE EXCEPTION 'The scheduled CWL cycle of one month was created twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_cycle (calendar_month, month_sequence) VALUES ('2026-12-01', 0);
        RAISE EXCEPTION 'A cycle before the first of its month was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    IF EXISTS (SELECT FROM guild.current_cwl_cycle WHERE cycle_key = cycle) THEN
        RAISE EXCEPTION 'A cycle without a schedule revision had a signup close';
    END IF;

    -- Signup schedule (CWL-003, CWL-018): the scheduler writes the first
    -- revision without an actor; staff reschedule with a further revision.
    BEGIN
        INSERT INTO guild.fact_cwl_cycle_schedule_revision (cycle_key, revision, signup_closes_at, actor_user_key)
        VALUES (cycle, 1, '2026-12-01 00:00+00', staff_id);
        RAISE EXCEPTION 'A staff schedule revision omitted its reason and operation';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_cycle_schedule_revision (cycle_key, revision, signup_closes_at)
        VALUES (cycle, 2, '2026-12-03 00:00+00');
        RAISE EXCEPTION 'A reschedule was recorded without its actor';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_cycle_schedule_revision (cycle_key, revision, signup_closes_at)
    VALUES (cycle, 1, '2026-12-01 00:00+00');
    IF (SELECT signup_closes_at FROM guild.current_cwl_cycle WHERE cycle_key = cycle) <> '2026-12-01 00:00+00' THEN
        RAISE EXCEPTION 'The scheduled close was not 00:00 UTC on the first day of the month';
    END IF;
    BEGIN
        INSERT INTO guild.fact_cwl_cycle_schedule_revision (cycle_key, revision, signup_closes_at,
            actor_user_key, reason, operation_id)
        VALUES (cycle, 1, '2026-12-03 00:00+00', staff_id, 'The game moved CWL', op_reschedule);
        RAISE EXCEPTION 'One schedule revision number was used twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_cycle_schedule_revision (cycle_key, revision, signup_closes_at,
        actor_user_key, reason, operation_id)
    VALUES (cycle, 2, '2026-12-03 00:00+00', staff_id, 'The game moved CWL', op_reschedule)
    RETURNING schedule_revision_key INTO schedule_rev;
    BEGIN
        INSERT INTO guild.fact_cwl_cycle_schedule_revision (cycle_key, revision, signup_closes_at,
            actor_user_key, reason, operation_id)
        VALUES (cycle, 3, '2026-12-04 00:00+00', staff_id, 'Retry', op_reschedule);
        RAISE EXCEPTION 'One operation rescheduled a cycle twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    IF (SELECT (signup_closes_at, schedule_revision) FROM guild.current_cwl_cycle WHERE cycle_key = cycle)
        IS DISTINCT FROM ('2026-12-03 00:00+00'::timestamptz, 2)
        OR (SELECT count(*) FROM guild.fact_cwl_cycle_schedule_revision WHERE cycle_key = cycle) <> 2 THEN
        RAISE EXCEPTION 'A rescheduled cycle did not follow its latest revision or lost the earlier one';
    END IF;
    BEGIN
        UPDATE guild.fact_cwl_cycle_schedule_revision SET signup_closes_at = '2026-12-05 00:00+00'
        WHERE schedule_revision_key = schedule_rev;
        RAISE EXCEPTION 'A signup close was moved in place';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- The second CWL of a month cannot start while the first cycle is open.
    BEGIN
        INSERT INTO guild.cwl_cycle (calendar_month, month_sequence) VALUES ('2026-12-01', 2);
        RAISE EXCEPTION 'A further cycle of a month was created while the first was open';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.cwl_cycle SET calendar_month = '2027-01-01' WHERE cycle_key = cycle;
        RAISE EXCEPTION 'The runtime role moved a cycle to another month';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_participating_clan (cycle_key, clan_key) VALUES (cycle, untracked);
        RAISE EXCEPTION 'An untracked clan was selected for CWL';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.cwl_participating_clan (cycle_key, clan_key)
    VALUES (cycle, clan_a) RETURNING participation_key INTO participation;
    INSERT INTO guild.cwl_participating_clan (cycle_key, clan_key)
    VALUES (cycle, clan_b) RETURNING participation_key INTO other_participation;
    BEGIN
        INSERT INTO guild.cwl_participating_clan (cycle_key, clan_key) VALUES (cycle, clan_a);
        RAISE EXCEPTION 'One clan was selected twice in a cycle';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    -- Participation revisions: selection, lineup size, withdrawal and a new
    -- selection keep their actor and operation.
    BEGIN
        INSERT INTO guild.fact_cwl_participation_revision (participation_key, revision, lineup_size,
            actor_user_key, operation_id)
        VALUES (participation, 1, 20, staff_id, op_select);
        RAISE EXCEPTION 'A lineup of 20 accounts was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_participation_revision (participation_key, revision, lineup_size, withdrawn,
            actor_user_key, operation_id)
        VALUES (participation, 1, 15, true, staff_id, op_select);
        RAISE EXCEPTION 'A clan was withdrawn by its first revision';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_participation_revision (participation_key, revision, lineup_size,
        actor_user_key, operation_id)
    VALUES (participation, 1, 15, staff_id, op_select), (other_participation, 1, 30, staff_id, op_select_other);
    BEGIN
        INSERT INTO guild.fact_cwl_participation_revision (participation_key, revision, lineup_size,
            actor_user_key, operation_id)
        VALUES (participation, 2, 30, staff_id, op_select);
        RAISE EXCEPTION 'One operation produced two participation revisions';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_participation_revision (participation_key, revision, lineup_size,
            actor_user_key, operation_id)
        VALUES (participation, 1, 30, staff_id, op_resize);
        RAISE EXCEPTION 'One participation revision number was used twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_participation_revision (participation_key, revision, lineup_size, withdrawn,
        actor_user_key, operation_id)
    VALUES (participation, 2, 30, false, staff_id, op_resize), (participation, 3, 30, true, staff_id, op_withdraw_clan);
    IF (SELECT (lineup_size, withdrawn) FROM guild.current_cwl_participation
        WHERE participation_key = participation) IS DISTINCT FROM (30::smallint, true) THEN
        RAISE EXCEPTION 'The current participation did not follow its latest revision';
    END IF;
    INSERT INTO guild.fact_cwl_participation_revision (participation_key, revision, lineup_size,
        actor_user_key, operation_id)
    VALUES (participation, 4, 15, staff_id, op_reselect);
    IF EXISTS (SELECT FROM guild.current_cwl_participation WHERE participation_key = earlier_participation) THEN
        RAISE EXCEPTION 'A clan without a revision appeared as selected';
    END IF;
    BEGIN
        UPDATE guild.fact_cwl_participation_revision SET withdrawn = true WHERE participation_key = participation;
        RAISE EXCEPTION 'A participation revision was edited in place';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    INSERT INTO guild.cwl_clan_day (participation_key, war_day)
    SELECT p, d FROM unnest(ARRAY[participation, other_participation]) AS p, generate_series(1, 7) AS d;
    BEGIN
        INSERT INTO guild.cwl_clan_day (participation_key, war_day) VALUES (participation, 8);
        RAISE EXCEPTION 'Derived plan days allowed an eighth day';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.cwl_clan_day SET war_key = war WHERE participation_key = participation AND war_day = 1;
    BEGIN
        UPDATE guild.cwl_clan_day SET war_key = war WHERE participation_key = participation AND war_day = 2;
        RAISE EXCEPTION 'One war was placed on two War Days of a clan';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    -- Freeze records.
    BEGIN
        INSERT INTO guild.fact_cwl_day_freeze (participation_key, war_day, war_key, automatic_freeze_minutes,
            frozen_at)
        VALUES (participation, 2, war, 60, seen + interval '23 hours');
        RAISE EXCEPTION 'A freeze named a war that is not the war of its day';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_day_freeze (participation_key, war_day, war_key, automatic_freeze_minutes,
            frozen_at)
        VALUES (participation, 1, war, -1, seen + interval '1 day');
        RAISE EXCEPTION 'A negative freeze cutoff was recorded';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_day_freeze (participation_key, war_day, war_key, automatic_freeze_minutes, frozen_at)
    VALUES (participation, 1, war, 60, seen + interval '23 hours');
    BEGIN
        INSERT INTO guild.fact_cwl_day_freeze (participation_key, war_day, war_key, automatic_freeze_minutes,
            frozen_at)
        VALUES (participation, 1, war, 30, seen + interval '23 hours 30 minutes');
        RAISE EXCEPTION 'A later cutoff recorded a second freeze of one War Day';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.cwl_clan_day SET war_key = NULL WHERE participation_key = participation AND war_day = 1;
        RAISE EXCEPTION 'A frozen War Day changed its war';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;

    -- League group polls. Every poll has a row; the group is stored on change.
    BEGIN
        INSERT INTO guild.cwl_group_poll (cycle_key, clan_key, source_correlation_id, observed_at, outcome)
        VALUES (cycle, untracked, 'test:group-poll:untracked', seen, 'no_group');
        RAISE EXCEPTION 'A league group was polled for an untracked clan';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_group_poll (cycle_key, clan_key, source_correlation_id, observed_at, outcome)
        VALUES (cycle, clan_a, 'test:group-poll:failed', seen, 'failed');
        RAISE EXCEPTION 'A failed group poll was recorded without its failure code';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_group_poll (cycle_key, clan_key, source_correlation_id, observed_at, outcome,
            failure_code)
        VALUES (cycle, clan_a, 'test:group-poll:code', seen, 'group', 'http_503');
        RAISE EXCEPTION 'A successful group poll carried a failure code';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.cwl_group_poll (cycle_key, clan_key, source_correlation_id, observed_at, outcome)
    VALUES (cycle, clan_a, 'test:group-poll:1', seen, 'group') RETURNING cwl_group_poll_key INTO group_poll;
    BEGIN
        INSERT INTO guild.cwl_group_poll (cycle_key, clan_key, source_correlation_id, observed_at, outcome)
        VALUES (cycle, clan_a, 'test:group-poll:1', seen + interval '15 minutes', 'group');
        RAISE EXCEPTION 'One fetch was recorded as two group polls';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- An unchanged group stores no second observation; its poll proves coverage.
    INSERT INTO guild.cwl_group_poll (cycle_key, clan_key, source_correlation_id, observed_at, outcome)
    VALUES (cycle, clan_a, 'test:group-poll:2', seen + interval '15 minutes', 'group')
    RETURNING cwl_group_poll_key INTO later_poll;
    INSERT INTO guild.cwl_group_poll (cycle_key, clan_key, source_correlation_id, observed_at, outcome,
        failure_code)
    VALUES (cycle, clan_a, 'test:group-poll:3', seen + interval '30 minutes', 'failed', 'http_503')
    RETURNING cwl_group_poll_key INTO failed_poll;
    BEGIN
        UPDATE guild.cwl_group_poll SET outcome = 'group', failure_code = NULL WHERE cwl_group_poll_key = failed_poll;
        RAISE EXCEPTION 'A failed group poll was rewritten as a success';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- League group observations and round references.
    BEGIN
        INSERT INTO guild.fact_cwl_group_observation (cwl_group_poll_key, cycle_key, clan_key, observed_at,
            source_season, source_state, is_complete)
        VALUES (failed_poll, cycle, clan_a, seen + interval '30 minutes', '2026-12', 'inWar', true);
        RAISE EXCEPTION 'A failed poll produced a group observation';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_group_observation (cwl_group_poll_key, cycle_key, clan_key, observed_at,
            source_season, source_state, is_complete)
        VALUES (group_poll, cycle, clan_b, seen, '2026-12', 'inWar', true);
        RAISE EXCEPTION 'A group observation named another clan than its poll';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_group_observation (cwl_group_poll_key, cycle_key, clan_key, observed_at,
            source_season, source_state, is_complete)
        VALUES (group_poll, cycle, clan_a, seen + interval '1 minute', '2026-12', 'inWar', true);
        RAISE EXCEPTION 'A group observation named another time than its poll';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_group_observation (cwl_group_poll_key, cycle_key, clan_key, observed_at,
            source_season, source_state, is_complete)
        VALUES (group_poll, cycle, clan_a, seen, ' ', 'inWar', true);
        RAISE EXCEPTION 'A blank source season was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_group_observation (cwl_group_poll_key, cycle_key, clan_key, observed_at,
        source_season, source_state, is_complete)
    VALUES (group_poll, cycle, clan_a, seen, '2026-12', 'inWar', true)
    RETURNING group_observation_key INTO group_observation;
    BEGIN
        INSERT INTO guild.fact_cwl_group_observation (cwl_group_poll_key, cycle_key, clan_key, observed_at,
            source_season, source_state, is_complete)
        VALUES (group_poll, cycle, clan_a, seen, '2026-12', 'ended', true);
        RAISE EXCEPTION 'One poll stored two group observations';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    IF (SELECT count(*) FROM guild.cwl_group_poll WHERE cycle_key = cycle AND clan_key = clan_a) <> 3
        OR (SELECT count(*) FROM guild.fact_cwl_group_observation WHERE cycle_key = cycle AND clan_key = clan_a) <> 1 THEN
        RAISE EXCEPTION 'Group polls and stored observations were not kept apart';
    END IF;
    INSERT INTO guild.fact_cwl_registered_clan (group_observation_key, clan_key) VALUES (group_observation, clan_a);
    BEGIN
        INSERT INTO guild.fact_cwl_registered_player (group_observation_key, clan_key, player_key,
            town_hall_level, source_name)
        VALUES (group_observation, clan_b, player_a, 16, 'Player');
        RAISE EXCEPTION 'A registered player named a clan the group did not register';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_registered_player (group_observation_key, clan_key, player_key,
        town_hall_level, source_name)
    VALUES (group_observation, clan_a, player_a, 16, 'Player');
    -- A round that is not scheduled yet repeats the placeholder #0 in every
    -- position; a real war tag appears once in a group observation.
    INSERT INTO guild.cwl_round_war_reference (group_observation_key, round_ordinal, tag_position, source_war_tag)
    VALUES (group_observation, 1, 1, '#8CWL1'), (group_observation, 1, 2, '#8CWL2'),
        (group_observation, 2, 1, '#0'), (group_observation, 2, 2, '#0'),
        (group_observation, 2, 3, '#0'), (group_observation, 2, 4, '#0');
    BEGIN
        INSERT INTO guild.cwl_round_war_reference (group_observation_key, round_ordinal, tag_position,
            source_war_tag)
        VALUES (group_observation, 2, 4, '#8CWL3');
        RAISE EXCEPTION 'Two tags took one position of a round';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_round_war_reference (group_observation_key, round_ordinal, tag_position,
            source_war_tag)
        VALUES (group_observation, 3, 1, '#8CWL1');
        RAISE EXCEPTION 'One war tag was referenced twice in a group observation';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_round_war_reference (group_observation_key, round_ordinal, tag_position,
            source_war_tag)
        VALUES (group_observation, 3, 0, '#8CWL4');
        RAISE EXCEPTION 'A tag position before the first was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.cwl_round_war_reference SET war_key = war
        WHERE group_observation_key = group_observation AND source_war_tag = '#0';
        RAISE EXCEPTION 'A placeholder #0 round reference was given a war';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.cwl_round_war_reference SET war_key = regular_war
        WHERE group_observation_key = group_observation AND round_ordinal = 1 AND tag_position = 1;
        RAISE EXCEPTION 'A round reference named a war with another tag';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    UPDATE guild.cwl_round_war_reference SET war_key = war
    WHERE group_observation_key = group_observation AND round_ordinal = 1 AND tag_position = 1;
    BEGIN
        DELETE FROM guild.cwl_round_war_reference WHERE group_observation_key = group_observation;
        RAISE EXCEPTION 'A round war reference was deleted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Signups and their revisions. The target clan belongs to each revision.
    INSERT INTO guild.cwl_signup (cycle_key, player_key) VALUES (cycle, player_a) RETURNING signup_key INTO signup;
    BEGIN
        INSERT INTO guild.cwl_signup (cycle_key, player_key) VALUES (cycle, player_a);
        RAISE EXCEPTION 'An account had two signups in one cycle';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
            town_hall_level, actor_user_key, operation_id)
        VALUES (signup, cycle, earlier_participation, 1, ARRAY[1]::smallint[], 16, member_id, op_signup);
        RAISE EXCEPTION 'A signup targeted a clan of another cycle';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
            town_hall_level, actor_user_key, operation_id)
        VALUES (signup, earlier_cycle, earlier_participation, 1, ARRAY[1]::smallint[], 16, member_id, op_signup);
        RAISE EXCEPTION 'A signup revision named another cycle than its signup';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
            town_hall_level, actor_user_key, operation_id)
        VALUES (signup, cycle, participation, 1, ARRAY[]::smallint[], 16, member_id, op_signup);
        RAISE EXCEPTION 'Invalid War Days were accepted: none';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
            town_hall_level, actor_user_key, operation_id)
        VALUES (signup, cycle, participation, 1, ARRAY[1, 8]::smallint[], 16, member_id, op_signup);
        RAISE EXCEPTION 'Invalid War Days were accepted: day 8';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
            town_hall_level, actor_user_key, operation_id)
        VALUES (signup, cycle, participation, 1, ARRAY[1, NULL]::smallint[], 16, member_id, op_signup);
        RAISE EXCEPTION 'Invalid War Days were accepted: a null day';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
            town_hall_level, actor_user_key, operation_id)
        VALUES (signup, cycle, participation, 1, ARRAY[[1, 2], [3, 4]]::smallint[], 16, member_id, op_signup);
        RAISE EXCEPTION 'Invalid War Days were accepted: two dimensions';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
            town_hall_level, actor_user_key, operation_id)
        VALUES (signup, cycle, participation, 1, ARRAY[1, 2, 3, 4, 5, 6, 7, 7]::smallint[], 16, member_id, op_signup);
        RAISE EXCEPTION 'Invalid War Days were accepted: eight days';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
        town_hall_level, actor_user_key, operation_id)
    VALUES (signup, cycle, participation, 1, ARRAY[1, 2, 3]::smallint[], 16, member_id, op_signup)
    RETURNING signup_revision_key INTO signup_rev;
    BEGIN
        INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
            town_hall_level, actor_user_key, operation_id)
        VALUES (signup, cycle, participation, 2, ARRAY[4]::smallint[], 16, member_id, op_signup);
        RAISE EXCEPTION 'One stable operation produces one signup revision';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
            town_hall_level, actor_user_key, operation_id)
        VALUES (signup, cycle, participation, 1, ARRAY[4]::smallint[], 16, member_id, op_retry);
        RAISE EXCEPTION 'One signup revision number was used twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_cwl_signup_revision SET withdrawn = true WHERE signup_revision_key = signup_rev;
        RAISE EXCEPTION 'A signup revision was edited in place';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- Staff move the signup to the other participating clan with a revision.
    INSERT INTO guild.fact_cwl_signup_revision (signup_key, cycle_key, participation_key, revision, war_days,
        town_hall_level, actor_user_key, operation_id)
    VALUES (signup, cycle, other_participation, 2, ARRAY[1, 2, 3]::smallint[], 16, staff_id, op_move)
    RETURNING signup_revision_key INTO move_rev;
    IF (SELECT participation_key FROM guild.current_cwl_signup WHERE signup_key = signup)
        IS DISTINCT FROM other_participation THEN
        RAISE EXCEPTION 'A moved signup did not follow its latest revision';
    END IF;

    -- Plans, inputs and assignments.
    BEGIN
        INSERT INTO guild.cwl_plan_revision (participation_key, revision, source_kind, algorithm_version, phase)
        VALUES (participation, 1, 'manual', 'manual', 'current_season_performance');
        RAISE EXCEPTION 'A manual plan was recorded without its staff actor';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_plan_revision (participation_key, revision, source_kind, algorithm_version, phase,
            objective)
        VALUES (participation, 1, 'automatic', 'v1', 'initial_th_availability', 'maximize_stars');
        RAISE EXCEPTION 'An unagreed planning objective was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.cwl_plan_revision (participation_key, revision, source_kind, algorithm_version, phase)
    VALUES (participation, 1, 'automatic', 'initial-input-snapshot-v1', 'initial_th_availability')
    RETURNING plan_key INTO plan;
    INSERT INTO guild.cwl_plan_revision (participation_key, revision, source_kind, algorithm_version, phase)
    VALUES (other_participation, 1, 'automatic', 'initial-input-snapshot-v1', 'initial_th_availability')
    RETURNING plan_key INTO other_plan;
    BEGIN
        INSERT INTO guild.cwl_plan_revision (participation_key, revision, source_kind, algorithm_version, phase)
        VALUES (participation, 1, 'automatic', 'v2', 'initial_th_availability');
        RAISE EXCEPTION 'One plan revision number was used twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_plan_input (plan_key, participation_key, player_key, signup_revision_key,
            current_season_stars, current_season_attacks, source_war_keys, rating)
        VALUES (plan, participation, player_a, signup_rev, 0, 0, '{}', 1.5);
        RAISE EXCEPTION 'A rating was stored without its method';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_plan_input (plan_key, participation_key, player_key, signup_revision_key,
            current_season_stars, current_season_attacks, source_war_keys)
        VALUES (plan, participation, player_a, move_rev, 0, 0, '{}');
        RAISE EXCEPTION 'A plan input used a signup revision that targets another clan';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_plan_input (plan_key, participation_key, player_key, signup_revision_key,
            current_season_stars, current_season_attacks, source_war_keys)
        VALUES (plan, other_participation, player_a, move_rev, 0, 0, '{}');
        RAISE EXCEPTION 'A plan input named another clan than its plan';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    -- Day 1 froze before the signup moved to the other clan: this clan's plan
    -- keeps the account with the earlier revision that targeted it (GAP-15).
    INSERT INTO guild.fact_cwl_plan_input (plan_key, participation_key, player_key, signup_revision_key,
        current_season_stars, current_season_attacks, source_war_keys)
    VALUES (plan, participation, player_a, signup_rev, 0, 0, '{}');
    BEGIN
        INSERT INTO guild.cwl_plan_assignment (plan_key, war_day, slot_number, player_key)
        VALUES (plan, 1, 1, player_b);
        RAISE EXCEPTION 'An account without plan input was assigned';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_plan_assignment (plan_key, war_day, slot_number, player_key)
        VALUES (plan, 1, 31, player_a);
        RAISE EXCEPTION 'A slot beyond 30 was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.cwl_plan_assignment (plan_key, war_day, slot_number, player_key) VALUES (plan, 1, 1, player_a);
    BEGIN
        INSERT INTO guild.cwl_plan_assignment (plan_key, war_day, slot_number, player_key)
        VALUES (plan, 1, 2, player_a);
        RAISE EXCEPTION 'One account took two slots on one War Day';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.cwl_plan_assignment SET slot_number = 2 WHERE plan_key = plan;
        RAISE EXCEPTION 'A plan assignment was edited in place';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_replan_request (participation_key, reason, completed_plan_key)
        VALUES (participation, 'test', other_plan);
        RAISE EXCEPTION 'A replan request completed with the plan of another clan';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.cwl_replan_request (participation_key, reason) VALUES (participation, 'signup_close');
    UPDATE guild.cwl_replan_request SET completed_plan_key = plan WHERE participation_key = participation;
    UPDATE guild.cwl_plan_revision SET published_at = clock_timestamp(), quality = 'incomplete' WHERE plan_key = plan;
    -- The next automatic plan carries the frozen Day 1 assignment forward with
    -- that historical input, and a staff replacement after the cutoff is its
    -- own manual revision with an actor (GAP-16). The published plan is kept.
    INSERT INTO guild.cwl_plan_revision (participation_key, revision, source_kind, algorithm_version, phase)
    VALUES (participation, 2, 'automatic', 'initial-input-snapshot-v1', 'current_season_performance')
    RETURNING plan_key INTO carry_plan;
    INSERT INTO guild.fact_cwl_plan_input (plan_key, participation_key, player_key, signup_revision_key,
        current_season_stars, current_season_attacks, source_war_keys)
    VALUES (carry_plan, participation, player_a, signup_rev, 0, 0, '{}');
    INSERT INTO guild.cwl_plan_assignment (plan_key, war_day, slot_number, player_key)
    VALUES (carry_plan, 1, 1, player_a);
    INSERT INTO guild.cwl_plan_revision (participation_key, revision, source_kind, actor_user_key,
        algorithm_version, phase)
    VALUES (participation, 3, 'manual', staff_id, 'manual', 'current_season_performance')
    RETURNING plan_key INTO manual_plan;
    IF (SELECT signup_revision_key FROM guild.current_cwl_signup WHERE signup_key = signup) = signup_rev
        OR NOT EXISTS (SELECT FROM guild.cwl_plan_assignment WHERE plan_key = plan AND war_day = 1)
        OR (SELECT count(*) FROM guild.cwl_plan_revision WHERE participation_key = participation) <> 3 THEN
        RAISE EXCEPTION 'A frozen assignment or its history was not retained after a signup move';
    END IF;

    -- Pin revisions: a pin and an unpin keep their actor, reason and operation.
    BEGIN
        INSERT INTO guild.fact_cwl_manual_pin_revision (participation_key, war_day, slot_number, revision,
            player_key, actor_user_key, reason, operation_id)
        VALUES (participation, 1, 1, 1, player_a, staff_id, ' ', op_pin);
        RAISE EXCEPTION 'A pin without a reason was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_manual_pin_revision (participation_key, war_day, slot_number, revision,
            player_key, actor_user_key, reason, operation_id)
        VALUES (participation, 8, 1, 1, player_a, staff_id, 'Captain', op_pin);
        RAISE EXCEPTION 'A pin was placed on a War Day the clan does not have';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_manual_pin_revision (participation_key, war_day, slot_number, revision,
        player_key, actor_user_key, reason, operation_id)
    VALUES (participation, 1, 1, 1, player_a, staff_id, 'Captain', op_pin),
        (participation, 1, 2, 1, player_b, staff_id, 'Backup', op_pin);
    BEGIN
        INSERT INTO guild.fact_cwl_manual_pin_revision (participation_key, war_day, slot_number, revision,
            player_key, actor_user_key, reason, operation_id)
        VALUES (participation, 1, 1, 1, player_b, staff_id, 'Captain', op_pin);
        RAISE EXCEPTION 'One pin revision number was used twice for a slot';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- Unpinning slot 2 is a revision without an account.
    INSERT INTO guild.fact_cwl_manual_pin_revision (participation_key, war_day, slot_number, revision,
        actor_user_key, reason, operation_id)
    VALUES (participation, 1, 2, 2, staff_id, 'Not needed', op_pin);
    IF ARRAY(SELECT player_key FROM guild.current_cwl_manual_pin WHERE participation_key = participation)
        <> ARRAY[player_a] THEN
        RAISE EXCEPTION 'The current pins did not follow the latest revision of each slot';
    END IF;

    -- Bench incidents, assignments and resolutions.
    BEGIN
        INSERT INTO guild.fact_cwl_bench_incident (participation_key, player_key, war_key, incident_kind,
            source_observed_at)
        VALUES (participation, player_a, war, 'poor_attack', seen + interval '2 days');
        RAISE EXCEPTION 'A poor-attack incident was recorded without its attack';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_bench_incident (participation_key, player_key, war_key, attack_key, incident_kind,
        source_observed_at)
    VALUES (participation, player_a, war, attack, 'poor_attack', seen + interval '2 days')
    RETURNING incident_key INTO incident;
    BEGIN
        INSERT INTO guild.fact_cwl_bench_incident (participation_key, player_key, war_key, incident_kind,
            source_observed_at)
        VALUES (participation, player_a, war, 'missed_attack', seen + interval '2 days');
        RAISE EXCEPTION 'Repeated source attack duplicated penalty';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- The reserved bench day changes only by revision (CWL-013, CWL-017).
    BEGIN
        INSERT INTO guild.fact_cwl_bench_assignment_revision (incident_key, participation_key, revision, war_day)
        VALUES (incident, other_participation, 1, 2);
        RAISE EXCEPTION 'A bench was assigned in another clan';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_bench_assignment_revision (incident_key, participation_key, revision, war_day)
        VALUES (incident, participation, 1, 8);
        RAISE EXCEPTION 'A bench was assigned to a War Day the clan does not have';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_bench_assignment_revision (incident_key, participation_key, revision)
        VALUES (incident, participation, 1);
        RAISE EXCEPTION 'The first bench revision reserved no War Day';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_bench_assignment_revision (incident_key, participation_key, revision, war_day)
    VALUES (incident, participation, 1, 2);
    BEGIN
        INSERT INTO guild.fact_cwl_bench_assignment_revision (incident_key, participation_key, revision, war_day)
        VALUES (incident, participation, 1, 3);
        RAISE EXCEPTION 'One bench revision number was used twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_cwl_bench_assignment_revision SET war_day = 3 WHERE incident_key = incident;
        RAISE EXCEPTION 'A reserved bench day was moved in place';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- Day 2 did not serve the bench, so the reservation moves to Day 3.
    INSERT INTO guild.fact_cwl_bench_assignment_revision (incident_key, participation_key, revision, war_day)
    VALUES (incident, participation, 2, 3);
    IF (SELECT (war_day, revision) FROM guild.current_cwl_bench_assignment WHERE incident_key = incident)
        IS DISTINCT FROM (3::smallint, 2)
        OR (SELECT war_day FROM guild.fact_cwl_bench_assignment_revision
            WHERE incident_key = incident AND revision = 1) <> 2 THEN
        RAISE EXCEPTION 'A moved bench day lost its earlier reservation';
    END IF;
    -- A revision without a day releases the reservation.
    INSERT INTO guild.fact_cwl_bench_assignment_revision (incident_key, participation_key, revision)
    VALUES (incident, participation, 3);
    IF EXISTS (SELECT FROM guild.current_cwl_bench_assignment WHERE incident_key = incident) THEN
        RAISE EXCEPTION 'A released bench day stayed reserved';
    END IF;
    BEGIN
        INSERT INTO guild.fact_cwl_bench_resolution (incident_key, resolution, reason)
        VALUES (incident, 'served', 'Sat out');
        RAISE EXCEPTION 'A served bench was recorded without its War Day';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_bench_resolution (incident_key, resolution, reason)
        VALUES (incident, 'staff_override', 'Excused');
        RAISE EXCEPTION 'A staff override was recorded without its actor';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_bench_resolution (incident_key, resolution, actor_user_key, reason)
    VALUES (incident, 'staff_override', staff_id, 'Excused');
    BEGIN
        INSERT INTO guild.fact_cwl_bench_resolution (incident_key, resolution, reason)
        VALUES (incident, 'season_expiry', 'Season ended');
        RAISE EXCEPTION 'An incident was resolved twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    -- Exports.
    BEGIN
        INSERT INTO guild.cwl_export_revision (participation_key, resource_kind, plan_key, export_sequence)
        VALUES (participation, 'signups', plan, 1);
        RAISE EXCEPTION 'A signup export named a plan';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.cwl_export_revision (participation_key, resource_kind, plan_key, export_sequence,
        sheet_document_id, sheet_tab)
    VALUES (participation, 'lineups', plan, 1, 'sheet-doc-1', 'Lineups')
    RETURNING export_revision_key INTO export_revision;
    BEGIN
        INSERT INTO guild.cwl_export_revision (participation_key, resource_kind, plan_key, export_sequence,
            sheet_document_id)
        VALUES (participation, 'lineups', other_plan, 2, 'sheet-doc-1');
        RAISE EXCEPTION 'A Sheets destination was recorded without its tab';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    -- A move is exported for the clan the signup leaves and the clan it joins.
    INSERT INTO guild.cwl_export_revision (participation_key, resource_kind, signup_revision_key, export_sequence)
    VALUES (participation, 'signups', move_rev, 1) RETURNING export_revision_key INTO signup_export;
    INSERT INTO guild.cwl_export_revision (participation_key, resource_kind, signup_revision_key, export_sequence)
    VALUES (other_participation, 'signups', move_rev, 1);
    BEGIN
        INSERT INTO guild.cwl_export_revision (participation_key, resource_kind, signup_revision_key,
            export_sequence)
        VALUES (other_participation, 'signups', move_rev, 2);
        RAISE EXCEPTION 'One signup revision was exported twice for one clan';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_export_revision (participation_key, resource_kind, plan_key, export_sequence)
        VALUES (participation, 'lineups', plan, 2);
        RAISE EXCEPTION 'One plan was exported as two revisions';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_export_revision (participation_key, resource_kind, plan_key, export_sequence)
        VALUES (participation, 'lineups', other_plan, 1);
        RAISE EXCEPTION 'Two exports of one clan and kind shared a sequence';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- GAP-19: a signup-list export freezes the revision of each signup it lists.
    INSERT INTO guild.cwl_export_signup_input (export_revision_key, signup_key, signup_revision_key)
    VALUES (signup_export, signup, move_rev);
    BEGIN
        INSERT INTO guild.cwl_export_signup_input (export_revision_key, signup_key, signup_revision_key)
        VALUES (signup_export, signup, signup_rev);
        RAISE EXCEPTION 'One export listed a signup twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.cwl_export_signup_input (export_revision_key, signup_key, signup_revision_key)
        VALUES (export_revision, signup, move_rev);
        RAISE EXCEPTION 'A lineup export listed signup inputs';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    -- GAP-08: the cwl_signups channel shows the signups frozen by an export.
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (980000000000000099, 'cwl-signups') RETURNING channel_key INTO signups_channel;
    INSERT INTO guild.channel_binding (purpose, clan_key, channel_key) VALUES ('cwl_signups', clan_a, signups_channel);
    INSERT INTO guild.notification_report (logical_report_key, report_kind, channel_key, audience)
    VALUES ('cwl:signups:1', 'cwl_signups', signups_channel, 'members') RETURNING report_key INTO signups_report;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at, report_key, report_revision)
    VALUES ('cwl:signups:1:export:1', 'report_create', 'cwl_signups', signups_channel, 'members',
        clock_timestamp(), signups_report, 1)
    RETURNING operation_key INTO signups_revision;
    BEGIN
        INSERT INTO guild.notification_cwl_signups_context (operation_key, export_revision_key)
        VALUES (signups_revision, export_revision);
        RAISE EXCEPTION 'A signup list named a lineup export';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.notification_cwl_signups_context (operation_key, export_revision_key)
    VALUES (signups_revision, signup_export);
    BEGIN
        UPDATE guild.notification_cwl_signups_context SET export_revision_key = signup_export
        WHERE operation_key = signups_revision;
        RAISE EXCEPTION 'A signup list context was rewritten';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- A Sheets writer holds the destination lease and authorizes before writing.
    INSERT INTO guild.cwl_sheet_destination (participation_key, resource_kind) VALUES (participation, 'lineups');
    BEGIN
        UPDATE guild.cwl_sheet_destination SET lease_owner = 'worker-1'
        WHERE participation_key = participation AND resource_kind = 'lineups';
        RAISE EXCEPTION 'A lease was taken without expiry or fence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.cwl_sheet_destination SET lease_owner = 'worker-1',
        lease_expires_at = clock_timestamp() + interval '5 minutes', fence = gen_random_uuid()
    WHERE participation_key = participation AND resource_kind = 'lineups';
    INSERT INTO guild.fact_cwl_export_attempt (export_revision_key, export_format, attempt_number, fence,
        lease_expires_at)
    VALUES (export_revision, 'google_sheets', 1, gen_random_uuid(), clock_timestamp() + interval '5 minutes')
    RETURNING export_attempt_key INTO sheet_attempt;
    UPDATE guild.fact_cwl_export_attempt SET outcome = 'failed', error_code = 'quota', completed_at = clock_timestamp()
    WHERE export_attempt_key = sheet_attempt;
    BEGIN
        INSERT INTO guild.fact_cwl_export_attempt (export_revision_key, export_format, attempt_number, outcome)
        VALUES (export_revision, 'google_sheets', 2, 'succeeded');
        RAISE EXCEPTION 'A Sheets attempt was recorded without an authorization fence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_cwl_export_attempt (export_revision_key, export_format, attempt_number)
        VALUES (export_revision, 'csv', 1);
        RAISE EXCEPTION 'A CSV attempt was recorded without its outcome';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_cwl_export_attempt (export_revision_key, export_format, attempt_number, outcome,
        artifact_reference, completed_at)
    VALUES (export_revision, 'csv', 1, 'succeeded', 'lineups-1.csv', clock_timestamp());
    BEGIN
        INSERT INTO guild.fact_cwl_export_attempt (export_revision_key, export_format, attempt_number, outcome,
            completed_at)
        VALUES (export_revision, 'csv', 1, 'succeeded', clock_timestamp());
        RAISE EXCEPTION 'One export attempt number was used twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_cwl_export_attempt SET export_revision_key = export_revision
        WHERE export_attempt_key = sheet_attempt;
        RAISE EXCEPTION 'An export attempt changed its identity';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    UPDATE guild.cwl_export_revision SET sheets_state = 'failed' WHERE export_revision_key = export_revision;

    -- CWL-018: after the first cycle ended, staff create the further cycle of a
    -- month in which the game runs a second CWL.
    UPDATE guild.cwl_cycle SET state = 'ended', ended_at = '2026-12-12 00:00+00' WHERE cycle_key = cycle;
    INSERT INTO guild.cwl_cycle (calendar_month, month_sequence) VALUES ('2026-12-01', 2)
    RETURNING cycle_key INTO second_cycle;
    INSERT INTO guild.fact_cwl_cycle_schedule_revision (cycle_key, revision, signup_closes_at,
        actor_user_key, reason, operation_id)
    VALUES (second_cycle, 1, '2026-12-16 00:00+00', staff_id, 'Second CWL of the month', op_second_cycle);
    IF (SELECT count(*) FROM guild.current_cwl_cycle WHERE calendar_month = '2026-12-01') <> 2
        OR (SELECT count(*) FROM guild.cwl_cycle WHERE state <> 'ended') <> 1 THEN
        RAISE EXCEPTION 'A month did not keep its two CWL cycles, or more than one cycle was open';
    END IF;

    -- Custom events.
    BEGIN
        INSERT INTO guild.custom_event (event_name, created_by) VALUES (' ', staff_id);
        RAISE EXCEPTION 'A custom event without a name was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.custom_event (event_name, created_by) VALUES ('Friendly war', staff_id)
    RETURNING event_key INTO event_id;
    INSERT INTO guild.custom_event_signup (event_key, player_key) VALUES (event_id, player_a)
    RETURNING signup_key INTO custom_signup;
    BEGIN
        INSERT INTO guild.custom_event_signup (event_key, player_key) VALUES (event_id, player_a);
        RAISE EXCEPTION 'An account signed up twice for one custom event';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.fact_custom_event_signup_revision (signup_key, revision, actor_user_key, operation_id)
    VALUES (custom_signup, 1, member_id, op_event);
    BEGIN
        INSERT INTO guild.fact_custom_event_signup_revision (signup_key, revision, withdrawn, actor_user_key,
            operation_id)
        VALUES (custom_signup, 2, true, member_id, op_event);
        RAISE EXCEPTION 'One operation wrote two custom signup revisions';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_custom_event_signup_revision (signup_key, revision, withdrawn, actor_user_key,
            operation_id)
        VALUES (custom_signup, 1, true, staff_id, op_withdraw);
        RAISE EXCEPTION 'One custom signup revision number was used twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.fact_custom_event_signup_revision (signup_key, revision, withdrawn, actor_user_key,
        operation_id)
    VALUES (custom_signup, 2, true, staff_id, op_withdraw);
    IF NOT (SELECT withdrawn FROM guild.current_custom_event_signup WHERE signup_key = custom_signup) THEN
        RAISE EXCEPTION 'The current custom signup did not follow its latest revision';
    END IF;
    INSERT INTO guild.custom_roster_revision (event_key, revision, actor_user_key, reason, operation_id)
    VALUES (event_id, 1, staff_id, 'Selected', op_roster) RETURNING roster_key INTO roster;
    BEGIN
        INSERT INTO guild.custom_roster_account (roster_key, event_key, player_key, signup_key)
        VALUES (roster, event_id, player_b, custom_signup);
        RAISE EXCEPTION 'A roster account named the signup of another account';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.custom_roster_account (roster_key, event_key, player_key, signup_key)
    VALUES (roster, event_id, player_a, custom_signup);
    BEGIN
        UPDATE guild.custom_event SET war_key = regular_war WHERE event_key = event_id;
        RAISE EXCEPTION 'A game-war association omitted its actor, operation and reason';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.custom_event SET war_key = regular_war, associated_by = staff_id,
        association_operation_id = op_result, association_reason = 'Friendly war result'
    WHERE event_key = event_id;
    BEGIN
        INSERT INTO guild.custom_event (event_name, created_by, war_key, associated_by, association_operation_id,
            association_reason)
        VALUES ('Second event', staff_id, regular_war, staff_id, op_roster, 'Same war');
        RAISE EXCEPTION 'One war was associated with two custom events';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.custom_event WHERE event_key = event_id;
        RAISE EXCEPTION 'Deleting its event erased a retained association';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'CWL and custom event constraints passed';
END;
$$;

ROLLBACK;
