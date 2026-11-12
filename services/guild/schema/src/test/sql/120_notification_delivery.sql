BEGIN;
-- The fixtures below run as guild_runtime, the role of the backend. Between
-- RESET ROLE and the next SET LOCAL ROLE the database administrator runs what
-- that role may not: configuration, private-ledger fixtures, and checks that
-- read a private ledger.
SET LOCAL ROLE guild_runtime;
DO $$
DECLARE
    g bigint; u bigint; returning_user bigint; clan bigint; opponent bigint; channel_id bigint;
    role_a bigint; role_b bigint; unrelated_role bigint;
    war_id bigint; ended_war bigint;
    op uuid; replay uuid; token uuid; old_token uuid; pub_token uuid;
    catchup uuid; checkpoint uuid; attempted_checkpoint uuid;
    report_id uuid; report_op uuid; older_report_op uuid;
    first_role_op uuid; current_role_op uuid;
    role_version bigint; next_generation bigint;
    base_time timestamptz := clock_timestamp();
    rejected boolean; total bigint;
BEGIN
    RESET ROLE;
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (811200) RETURNING guild_key INTO g;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (811201) RETURNING user_key INTO u;
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (811202, 'war') RETURNING channel_key INTO channel_id;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (811203, 'Clan') RETURNING role_key INTO role_a;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (811204, 'Town hall') RETURNING role_key INTO role_b;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (811205, 'Unrelated manual role') RETURNING role_key INTO unrelated_role;

    -- A business transaction rollback must also roll back its outbox entry.
    BEGIN
        PERFORM guild.queue_notification_ping('rollback', 'welcome', channel_id,
            base_time, base_time + interval '1 hour');
        RAISE EXCEPTION 'simulate business rollback';
    EXCEPTION WHEN raise_exception THEN NULL;
    END;
    IF EXISTS (SELECT FROM guild.notification_operation WHERE logical_key = 'rollback') THEN
        RAISE EXCEPTION 'rolled-back domain decision left delivery work';
    END IF;
    op := guild.queue_notification_ping('welcome:one', 'welcome', channel_id,
        base_time - interval '1 second', base_time + interval '1 hour');
    replay := guild.queue_notification_ping('welcome:one', 'welcome', channel_id,
        base_time - interval '1 second', base_time + interval '1 hour');
    IF op <> replay OR (SELECT count(*) FROM guild.notification_outbox WHERE operation_key = op) <> 1 THEN
        RAISE EXCEPTION 'logical notification retry duplicated its intent/outbox';
    END IF;
    IF guild.claim_notification_dispatch(op, 'worker') IS NOT NULL THEN
        RAISE EXCEPTION 'dispatch bypassed the Kafka consumption stage';
    END IF;
    pub_token := guild.claim_notification_publication(op, 'publisher');
    IF pub_token IS NULL OR guild.claim_notification_publication(op, 'other') IS NOT NULL THEN
        RAISE EXCEPTION 'publication lease did not serialize workers';
    END IF;
    PERFORM guild.finish_notification_publication(op, pub_token, 'uncertain');
    pub_token := guild.claim_notification_publication(op, 'publisher');
    PERFORM guild.finish_notification_publication(op, pub_token, 'published', 'notifications', 0, 10);
    IF (SELECT status FROM guild.notification_operation WHERE operation_key = op) <> 'pending' THEN
        RAISE EXCEPTION 'Kafka broker acknowledgment was treated as Discord delivery';
    END IF;
    IF NOT guild.record_notification_consumption(op, 'delivery', 'notifications', 0, 10)
        OR guild.record_notification_consumption(op, 'delivery', 'notifications', 0, 10)
        OR guild.record_notification_consumption(op, 'delivery', 'notifications', 0, 11) THEN
        RAISE EXCEPTION 'Kafka replay did not deduplicate its logical operation';
    END IF;
    IF (SELECT count(*) FROM guild.notification_kafka_receipt
        WHERE operation_key = op AND consumer_group = 'delivery') <> 2
        OR (SELECT count(*) FROM guild.notification_consumer_seen
            WHERE operation_key = op AND consumer_group = 'delivery') <> 1
        OR NOT guild.record_notification_consumption(op, 'audit-reader', 'notifications', 0, 10) THEN
        RAISE EXCEPTION 'logical deduplication discarded replay evidence or another consumer group';
    END IF;
    replay := guild.queue_notification_ping('welcome:coordinate-conflict', 'welcome', channel_id,
        base_time, base_time + interval '1 hour');
    rejected := false;
    BEGIN PERFORM guild.record_notification_consumption(replay, 'delivery', 'notifications', 0, 10);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'Kafka coordinate was reassigned to another logical operation'; END IF;
    token := guild.claim_notification_dispatch(op, 'worker');
    IF token IS NULL OR guild.claim_notification_dispatch(op, 'other') IS NOT NULL THEN
        RAISE EXCEPTION 'multiple ping dispatch attempts were authorized';
    END IF;
    rejected := false;
    BEGIN PERFORM guild.record_notification_result(op, token, 'succeeded', 811210, 200);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'RPC acceptance became delivery before send authorization'; END IF;
    IF NOT guild.begin_notification_send(op, token) OR guild.begin_notification_send(op, token) THEN
        RAISE EXCEPTION 'send permit was not one-use';
    END IF;
    PERFORM guild.record_notification_result(op, token, 'uncertain', NULL, NULL, 'ack_lost');
    IF guild.claim_notification_dispatch(op, 'replay') IS NOT NULL THEN
        RAISE EXCEPTION 'uncertain ping was automatically retried';
    END IF;
    IF (SELECT count(*) FROM guild.fact_notification_dispatch_authorization WHERE operation_key = op) <> 1
        OR (SELECT count(*) FROM guild.fact_notification_delivery_attempt WHERE operation_key = op AND outcome = 'uncertain') <> 1 THEN
        RAISE EXCEPTION 'uncertainty/authorization facts were not retained separately';
    END IF;
    rejected := false;
    BEGIN
        RESET ROLE;
        UPDATE guild.fact_notification_dispatch_attempt SET outcome = 'failed' WHERE operation_key = op;
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'terminal uncertainty was rewritten after dispatch'; END IF;
    rejected := false;
    BEGIN
        RESET ROLE;
        UPDATE guild.fact_notification_dispatch_attempt SET started_at = NULL WHERE operation_key = op;
        SET LOCAL ROLE guild_runtime;
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'consumed one-use permit could be reopened'; END IF;

    op := guild.queue_notification_ping('welcome:confirmed', 'welcome', channel_id,
        base_time, base_time + interval '1 hour');
    PERFORM guild.record_notification_consumption(op, 'delivery', 'notifications', 0, 12);
    token := guild.claim_notification_dispatch(op, 'worker');
    PERFORM guild.begin_notification_send(op, token);
    rejected := false;
    BEGIN PERFORM guild.record_notification_result(op, token, 'succeeded', NULL, 200);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'message delivery success had no Discord message ID'; END IF;
    PERFORM guild.record_notification_result(op, token, 'succeeded', 811211, 200);
    IF (SELECT status FROM guild.notification_operation WHERE operation_key = op) <> 'delivered'
        OR guild.claim_notification_dispatch(op, 'replay') IS NOT NULL THEN
        RAISE EXCEPTION 'confirmed delivery was not terminal';
    END IF;

    op := guild.queue_notification_ping('welcome:expired', 'welcome', channel_id,
        base_time - interval '2 hours', base_time - interval '1 hour');
    PERFORM guild.record_notification_consumption(op, 'delivery', 'notifications', 0, 13);
    token := guild.claim_notification_dispatch(op, 'worker');
    IF token IS NOT NULL
        OR (SELECT status FROM guild.notification_operation WHERE operation_key = op) <> 'expired' THEN
        RAISE EXCEPTION 'expired unattempted ping was dispatched';
    END IF;

    -- Crash after reservation, before Node begins: lease expiry cannot recover
    -- the ping by sending it again. Publication leases, independently, can retry.
    op := guild.queue_notification_ping('welcome:crash', 'welcome', channel_id,
        base_time, base_time + interval '1 hour');
    PERFORM guild.record_notification_consumption(op, 'delivery', 'notifications', 0, 14);
    old_token := guild.claim_notification_dispatch(op, 'crashed-worker', 1);
    pub_token := guild.claim_notification_publication(op, 'crashed-publisher', 1);
    PERFORM pg_sleep(1.1);
    token := guild.claim_notification_dispatch(op, 'replacement');
    IF token IS NOT NULL OR guild.begin_notification_send(op, old_token)
        OR (SELECT status FROM guild.notification_operation WHERE operation_key = op) <> 'uncertain' THEN
        RAISE EXCEPTION 'expired ping authorization was reused';
    END IF;
    token := guild.claim_notification_publication(op, 'replacement-publisher');
    IF token IS NULL OR token = pub_token THEN RAISE EXCEPTION 'publication fence did not advance'; END IF;
    rejected := false;
    BEGIN PERFORM guild.finish_notification_publication(op, pub_token, 'published', 'notifications', 0, 15);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'stale publisher could confirm another worker lease'; END IF;

    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#C0P') RETURNING clan_key INTO clan;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#Q0L') RETURNING clan_key INTO opponent;
    RESET ROLE;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (clan);
    INSERT INTO guild.war_reminder_setting VALUES (clan, 28800), (clan, 14400);
    INSERT INTO guild.channel_binding (purpose, clan_key, channel_key) VALUES ('war', clan, channel_id);
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
        team_size, attacks_per_member, identity_source)
    VALUES (least(clan, opponent), greatest(clan, opponent), base_time - interval '23 hours',
        base_time - interval '21 hours', base_time + interval '3 hours', 15, 2, 'manual_validated')
    RETURNING war_key INTO war_id;
    PERFORM guild.schedule_war_reminders(war_id, clan);
    catchup := guild.coalesce_missed_war_reminders(war_id, clan);
    IF catchup IS NULL OR guild.coalesce_missed_war_reminders(war_id, clan) <> catchup
        OR (SELECT count(*) FROM guild.notification_catchup_input WHERE catchup_operation_key = catchup) <> 2 THEN
        RAISE EXCEPTION 'missed eight/four hour checkpoints were not coalesced exactly once';
    END IF;
    SELECT operation_key INTO checkpoint FROM guild.notification_operation
    WHERE war_key = war_id AND checkpoint_offset_seconds = 28800;
    IF guild.claim_notification_dispatch(checkpoint, 'old-event') IS NOT NULL THEN
        RAISE EXCEPTION 'superseded checkpoint remained dispatchable';
    END IF;
    PERFORM guild.record_notification_consumption(catchup, 'delivery', 'notifications', 0, 16);
    token := guild.claim_notification_dispatch(catchup, 'worker');
    IF NOT guild.begin_notification_send(catchup, token) THEN RAISE EXCEPTION 'active-war catch-up was not dispatchable'; END IF;
    SELECT remaining_seconds INTO total FROM guild.notification_operation WHERE operation_key = catchup;
    IF total NOT BETWEEN 10790 AND 10800 THEN RAISE EXCEPTION 'catch-up used an old checkpoint label instead of current remaining time'; END IF;

    -- An already attempted checkpoint cannot be renamed into catch-up work.
    INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
        team_size, attacks_per_member, identity_source)
    VALUES (least(clan, opponent), greatest(clan, opponent), base_time - interval '24 hours',
        base_time - interval '22 hours', base_time + interval '2 hours', 15, 2, 'manual_validated')
    RETURNING war_key INTO war_id;
    PERFORM guild.schedule_war_reminders(war_id, clan);
    SELECT operation_key INTO attempted_checkpoint FROM guild.notification_operation
    WHERE war_key = war_id AND checkpoint_offset_seconds = 28800;
    PERFORM guild.record_notification_consumption(attempted_checkpoint, 'delivery', 'notifications', 0, 17);
    token := guild.claim_notification_dispatch(attempted_checkpoint, 'worker');
    PERFORM guild.begin_notification_send(attempted_checkpoint, token);
    PERFORM guild.record_notification_result(attempted_checkpoint, token, 'uncertain');
    catchup := guild.coalesce_missed_war_reminders(war_id, clan);
    IF EXISTS (SELECT FROM guild.notification_catchup_input WHERE source_operation_key = attempted_checkpoint)
        OR (SELECT count(*) FROM guild.notification_catchup_input WHERE catchup_operation_key = catchup) <> 1 THEN
        RAISE EXCEPTION 'attempted checkpoint was relabeled as never-attempted catch-up';
    END IF;
    INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at,
        team_size, attacks_per_member, identity_source)
    VALUES (least(clan, opponent), greatest(clan, opponent), base_time - interval '28 hours',
        base_time - interval '25 hours', base_time - interval '1 hour', 15, 2, 'manual_validated')
    RETURNING war_key INTO ended_war;
    PERFORM guild.schedule_war_reminders(ended_war, clan);
    IF guild.coalesce_missed_war_reminders(ended_war, clan) IS NOT NULL THEN
        RAISE EXCEPTION 'ended war produced catch-up ping';
    END IF;

    role_version := guild.set_notification_desired_roles(u, ARRAY[role_a], 'clan');
    SELECT operation_key INTO first_role_op FROM guild.notification_operation
    WHERE target_user_key = u AND role_generation = role_version;
    PERFORM guild.record_notification_consumption(first_role_op, 'delivery', 'notifications', 0, 18);
    old_token := guild.claim_notification_dispatch(first_role_op, 'role-worker');
    next_generation := guild.set_notification_desired_roles(u, ARRAY[role_b], 'town-hall');
    IF next_generation <= role_version OR guild.begin_notification_send(first_role_op, old_token) THEN
        RAISE EXCEPTION 'superseded desired-role generation remained applicable';
    END IF;
    PERFORM guild.set_notification_desired_roles(u, ARRAY[role_a], 'rank');
    PERFORM guild.set_notification_desired_roles(u, ARRAY[]::bigint[], 'clan');
    SELECT t.generation INTO role_version FROM guild.notification_role_target t WHERE user_key = u;
    IF (SELECT count(*) FROM guild.notification_role_generation_requirement
        WHERE user_key = u AND generation = role_version AND is_desired) <> 2 THEN
        RAISE EXCEPTION 'withdrawing one source erased another source role requirement';
    END IF;
    IF EXISTS (SELECT FROM guild.notification_role_generation_requirement
        WHERE user_key = u AND role_key = unrelated_role) THEN
        RAISE EXCEPTION 'reconciliation claimed an unrelated manually held role';
    END IF;
    PERFORM guild.set_notification_desired_roles(u, ARRAY[]::bigint[], 'rank');
    IF EXISTS (SELECT FROM guild.notification_role_generation_requirement r JOIN guild.notification_role_target t
        USING (user_key, generation) WHERE r.user_key = u AND role_key = role_a AND is_desired) THEN
        RAISE EXCEPTION 'last source withdrawal retained desired role';
    END IF;
    SELECT n.operation_key INTO current_role_op FROM guild.notification_operation n
    JOIN guild.notification_role_target t
        ON t.user_key = n.target_user_key AND t.generation = n.role_generation
    WHERE n.target_user_key = u;
    PERFORM guild.record_notification_consumption(current_role_op, 'delivery', 'notifications', 0, 20);
    token := guild.claim_notification_dispatch(current_role_op, 'role-worker');
    IF NOT guild.begin_notification_send(current_role_op, token) THEN RAISE EXCEPTION 'latest desired roles were not reconcilable'; END IF;
    PERFORM guild.record_notification_result(current_role_op, token, 'succeeded', NULL, 204);
    old_token := guild.claim_notification_dispatch(current_role_op, 'role-recheck', 1);
    IF old_token IS NULL THEN RAISE EXCEPTION 'ping one-attempt policy was wrongly applied to role reconciliation'; END IF;
    PERFORM pg_sleep(1.1);
    token := guild.claim_notification_dispatch(current_role_op, 'role-replacement');
    IF token IS NULL OR token = old_token OR guild.begin_notification_send(current_role_op, old_token) THEN
        RAISE EXCEPTION 'role retry did not fence out its stale worker';
    END IF;
    rejected := false;
    BEGIN PERFORM guild.record_notification_result(current_role_op, old_token, 'succeeded', NULL, 204);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'stale role worker recorded current success'; END IF;

    -- Role work that is claimed while its member is absent is superseded. The
    -- same role set, submitted again after the member returns, is queued again.
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (811206)
    RETURNING user_key INTO returning_user;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (returning_user, 'join', base_time - interval '3 hours');
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (returning_user, 'departure', base_time - interval '2 hours');
    role_version := guild.set_notification_desired_roles(returning_user, ARRAY[role_a], 'clan');
    SELECT operation_key INTO first_role_op FROM guild.notification_operation
    WHERE target_user_key = returning_user AND role_generation = role_version;
    PERFORM guild.record_notification_consumption(first_role_op, 'delivery', 'notifications', 0, 31);
    token := guild.claim_notification_dispatch(first_role_op, 'role-worker');
    IF token IS NOT NULL OR (SELECT status FROM guild.notification_operation
        WHERE operation_key = first_role_op) <> 'superseded' THEN
        RAISE EXCEPTION 'role work for an absent member was not superseded';
    END IF;
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (returning_user, 'join', base_time - interval '1 hour');
    next_generation := guild.set_notification_desired_roles(returning_user, ARRAY[role_a], 'clan');
    SELECT operation_key INTO current_role_op FROM guild.notification_operation
    WHERE target_user_key = returning_user AND role_generation = next_generation AND status = 'pending';
    IF next_generation <= role_version OR current_role_op IS NULL THEN
        RAISE EXCEPTION 'unchanged desired roles were not queued again after the member returned';
    END IF;
    -- Work that can still apply the roles is reused, not queued a second time.
    IF guild.set_notification_desired_roles(returning_user, ARRAY[role_a], 'clan') <> next_generation THEN
        RAISE EXCEPTION 'an unchanged role set with deliverable work got another generation';
    END IF;
    PERFORM guild.record_notification_consumption(current_role_op, 'delivery', 'notifications', 0, 32);
    token := guild.claim_notification_dispatch(current_role_op, 'role-worker');
    IF token IS NULL OR NOT guild.begin_notification_send(current_role_op, token) THEN
        RAISE EXCEPTION 'requeued desired roles were not reconcilable';
    END IF;
    PERFORM guild.record_notification_result(current_role_op, token, 'succeeded', NULL, 204);
    IF guild.set_notification_desired_roles(returning_user, ARRAY[role_a], 'clan') <> next_generation THEN
        RAISE EXCEPTION 'delivered roles of a present member got another generation';
    END IF;
    -- Roles that were delivered before the member left are lost in Discord,
    -- so the same role set is queued again after the next join.
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (returning_user, 'departure', clock_timestamp());
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at)
    VALUES (returning_user, 'join', clock_timestamp());
    IF guild.set_notification_desired_roles(returning_user, ARRAY[role_a], 'clan') <= next_generation THEN
        RAISE EXCEPTION 'delivered roles were not queued again after the member left and returned';
    END IF;

    -- A report is one Discord message, edited in place. The first revision
    -- creates the message and its delivery records the message identity.
    report_id := guild.register_notification_report('raid:report', 'raid_report', channel_id, 'members');
    report_op := guild.queue_notification_report(report_id, 'raid:revision:1', base_time);
    IF guild.queue_notification_report(report_id, 'raid:revision:1', base_time) <> report_op
        OR (SELECT latest_revision FROM guild.notification_report WHERE report_key = report_id) <> 1 THEN
        RAISE EXCEPTION 'replayed report revision was queued twice';
    END IF;
    IF NOT EXISTS (SELECT FROM guild.notification_operation WHERE operation_key = report_op
        AND status = 'pending' AND operation_kind = 'report_create' AND report_revision = 1) THEN
        RAISE EXCEPTION 'first report revision was not queued as a pending create';
    END IF;
    PERFORM guild.record_notification_consumption(report_op, 'delivery', 'notifications', 0, 19);
    token := guild.claim_notification_dispatch(report_op, 'report-worker');
    IF token IS NULL OR NOT guild.begin_notification_send(report_op, token) THEN
        RAISE EXCEPTION 'report create could not be dispatched';
    END IF;
    PERFORM guild.record_notification_result(report_op, token, 'succeeded', 811220, 200);
    IF (SELECT discord_message_id FROM guild.notification_report WHERE report_key = report_id) IS DISTINCT FROM 811220
        OR (SELECT status FROM guild.notification_operation WHERE operation_key = report_op) <> 'delivered'
        OR guild.claim_notification_dispatch(report_op, 'report-worker') IS NOT NULL THEN
        RAISE EXCEPTION 'delivered report create did not confirm its message once';
    END IF;

    -- Only the latest revision is sent. A waiting older revision is superseded
    -- when the next one is queued.
    older_report_op := guild.queue_notification_report(report_id, 'raid:revision:2', base_time);
    report_op := guild.queue_notification_report(report_id, 'raid:revision:3', base_time);
    PERFORM guild.record_notification_consumption(older_report_op, 'delivery', 'notifications', 0, 21);
    PERFORM guild.record_notification_consumption(report_op, 'delivery', 'notifications', 0, 22);
    IF (SELECT status FROM guild.notification_operation WHERE operation_key = older_report_op) <> 'superseded'
        OR guild.claim_notification_dispatch(older_report_op, 'report-worker') IS NOT NULL THEN
        RAISE EXCEPTION 'older waiting report revision remained sendable';
    END IF;

    -- A later revision edits the known message, waits for the revision in
    -- flight, and cannot move the report to another message.
    token := guild.claim_notification_dispatch(report_op, 'report-worker');
    IF token IS NULL OR (SELECT operation_kind FROM guild.notification_operation
        WHERE operation_key = report_op) <> 'report_edit' THEN
        RAISE EXCEPTION 'later report revision was not claimed as an edit';
    END IF;
    older_report_op := report_op;
    report_op := guild.queue_notification_report(report_id, 'raid:revision:4', base_time);
    PERFORM guild.record_notification_consumption(report_op, 'delivery', 'notifications', 0, 23);
    IF (SELECT status FROM guild.notification_operation WHERE operation_key = older_report_op) <> 'in_flight'
        OR guild.claim_notification_dispatch(report_op, 'second-worker') IS NOT NULL THEN
        RAISE EXCEPTION 'two revisions of one report were in flight together';
    END IF;
    IF NOT guild.begin_notification_send(older_report_op, token) THEN
        RAISE EXCEPTION 'report edit in flight lost its send permit';
    END IF;
    rejected := false;
    BEGIN PERFORM guild.record_notification_result(older_report_op, token, 'succeeded', 811221, 200);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'report edit replaced the report message'; END IF;
    PERFORM guild.record_notification_result(older_report_op, token, 'succeeded', 811220, 200);

    -- Discord no longer has the message: the report forgets it and the same
    -- revision is sent again as a create.
    token := guild.claim_notification_dispatch(report_op, 'report-worker');
    rejected := false;
    BEGIN PERFORM guild.record_notification_report_missing(report_op, token);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'report message was declared missing before any edit was sent'; END IF;
    IF NOT guild.begin_notification_send(report_op, token) THEN
        RAISE EXCEPTION 'report edit could not be dispatched';
    END IF;
    PERFORM guild.record_notification_report_missing(report_op, token);
    IF (SELECT discord_message_id FROM guild.notification_report WHERE report_key = report_id) IS NOT NULL
        OR (SELECT status FROM guild.notification_operation WHERE operation_key = report_op) <> 'failed' THEN
        RAISE EXCEPTION 'missing report message was kept';
    END IF;
    token := guild.claim_notification_dispatch(report_op, 'report-worker');
    IF token IS NULL OR (SELECT operation_kind FROM guild.notification_operation
        WHERE operation_key = report_op) <> 'report_create'
        OR NOT guild.begin_notification_send(report_op, token) THEN
        RAISE EXCEPTION 'report with a missing message was not recreated';
    END IF;
    PERFORM guild.record_notification_result(report_op, token, 'succeeded', 811222, 200);
    IF (SELECT discord_message_id FROM guild.notification_report WHERE report_key = report_id) IS DISTINCT FROM 811222 THEN
        RAISE EXCEPTION 'recreated report message was not recorded';
    END IF;

    -- A revision that was in flight when a newer one arrived is superseded at
    -- its next claim, and the newer one is then free to go.
    older_report_op := guild.queue_notification_report(report_id, 'raid:revision:5', base_time);
    PERFORM guild.record_notification_consumption(older_report_op, 'delivery', 'notifications', 0, 24);
    old_token := guild.claim_notification_dispatch(older_report_op, 'report-worker', 1);
    report_op := guild.queue_notification_report(report_id, 'raid:revision:6', base_time);
    PERFORM guild.record_notification_consumption(report_op, 'delivery', 'notifications', 0, 25);
    PERFORM pg_sleep(1.1);
    IF old_token IS NULL OR guild.claim_notification_dispatch(older_report_op, 'report-worker') IS NOT NULL THEN
        RAISE EXCEPTION 'expired older report revision was claimed after a newer one';
    END IF;
    IF (SELECT status FROM guild.notification_operation WHERE operation_key = older_report_op) <> 'superseded'
        OR guild.begin_notification_send(older_report_op, old_token) THEN
        RAISE EXCEPTION 'expired older report revision was sent after a newer one';
    END IF;
    token := guild.claim_notification_dispatch(report_op, 'report-worker');
    IF token IS NULL OR NOT guild.begin_notification_send(report_op, token) THEN
        RAISE EXCEPTION 'latest report revision was blocked by an expired older one';
    END IF;
    PERFORM guild.record_notification_result(report_op, token, 'failed', NULL, 500, 'discord_unavailable');
    token := guild.claim_notification_dispatch(report_op, 'report-worker');
    IF token IS NULL OR NOT guild.begin_notification_send(report_op, token) THEN
        RAISE EXCEPTION 'failed report edit could not be sent again';
    END IF;
    PERFORM guild.record_notification_result(report_op, token, 'succeeded', 811222, 200);

    -- A message found after an uncertain create is adopted once; later
    -- revisions edit it.
    report_id := guild.register_notification_report('games:report', 'clan_games_report', channel_id, 'members');
    PERFORM guild.record_notification_report_message(report_id, 811230);
    PERFORM guild.record_notification_report_message(report_id, 811230);
    rejected := false;
    BEGIN PERFORM guild.record_notification_report_message(report_id, 811231);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'adopted report message was replaced'; END IF;
    report_op := guild.queue_notification_report(report_id, 'games:revision:1', base_time);
    IF (SELECT operation_kind FROM guild.notification_operation WHERE operation_key = report_op) <> 'report_edit' THEN
        RAISE EXCEPTION 'revision of a report with a known message was not an edit';
    END IF;
    rejected := false;
    BEGIN PERFORM guild.queue_notification_report(report_id, 'raid:revision:6', base_time);
    EXCEPTION WHEN check_violation THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'one logical key was accepted for two reports'; END IF;
END;
$$;
RESET ROLE;
ROLLBACK;
