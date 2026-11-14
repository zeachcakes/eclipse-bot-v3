BEGIN;

-- V7: notification operations, the outbox, Kafka receipts, dispatch attempts,
-- catch-up, reports and desired-role generations. The service claims, fences
-- and supersedes work; these checks cover the keys and row checks behind it.
DO $$
DECLARE
    member_id bigint; role_id bigint; channel_id bigint; clan_a bigint; clan_b bigint; war bigint; cycle bigint;
    participation bigint; plan bigint; report uuid; ping uuid; reminder uuid; catchup uuid; role_work uuid;
    revision_one uuid; prompt uuid; dispatch uuid; fence uuid := gen_random_uuid();
    raid bigint; raid_report uuid; raid_revision uuid; event_a bigint; event_b bigint; raid_start uuid;
    assessment_a bigint; assessment_b bigint; first_catchup_b uuid; cg_player bigint; progress_a bigint;
    progress_b bigint; cg_other_player bigint;
    subject_id bigint; warning_id bigint; edit_m uuid; create_n uuid; raid_next bigint; raid_poll_id bigint;
    now_at timestamptz := clock_timestamp();
BEGIN
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (990000000000000011) RETURNING user_key INTO member_id;
    INSERT INTO guild.dim_discord_role (discord_role_id, role_name)
    VALUES (990000000000000021, 'War') RETURNING role_key INTO role_id;
    INSERT INTO guild.dim_discord_channel (discord_channel_id, channel_name)
    VALUES (990000000000000031, 'war') RETURNING channel_key INTO channel_id;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#9PP') RETURNING clan_key INTO clan_a;
    INSERT INTO guild.dim_clan (clan_tag) VALUES ('#9QQ') RETURNING clan_key INTO clan_b;
    INSERT INTO guild.clan_collection_settings (clan_key) VALUES (clan_a);
    INSERT INTO guild.dim_war (clan_a_key, clan_b_key, preparation_started_at, started_at, ends_at, team_size,
        attacks_per_member, identity_source)
    VALUES (least(clan_a, clan_b), greatest(clan_a, clan_b), now_at - interval '1 day', now_at,
        now_at + interval '1 day', 15, 2, 'clan_pair_preparation') RETURNING war_key INTO war;

    -- Pings and the logical key.
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at)
        VALUES ('welcome:member one', 'ping', 'welcome', channel_id, 'members', now_at);
        RAISE EXCEPTION 'A logical key with a space was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, expires_at)
        VALUES ('welcome:1', 'ping', 'welcome', channel_id, 'members', now_at, now_at);
        RAISE EXCEPTION 'A ping expired before it was due';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at, expires_at)
    VALUES ('welcome:1', 'ping', 'welcome', channel_id, 'members', now_at, now_at + interval '1 hour')
    RETURNING operation_key INTO ping;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at)
        VALUES ('welcome:1', 'ping', 'welcome', channel_id, 'members', now_at);
        RAISE EXCEPTION 'logical notification retry duplicated its intent/outbox';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, event_version)
        VALUES ('welcome:2', 'ping', 'welcome', channel_id, 'members', now_at, 2);
        RAISE EXCEPTION 'An unagreed event version was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.notification_operation SET channel_key = NULL WHERE operation_key = ping;
        RAISE EXCEPTION 'The runtime role moved queued work to another channel';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.notification_operation WHERE operation_key = ping;
        RAISE EXCEPTION 'The runtime role deleted queued delivery work';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Raid announcements name their clan, and mentions are explicit.
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at)
        VALUES ('raid:start:1', 'ping', 'raid_start', channel_id, 'members', now_at);
        RAISE EXCEPTION 'A raid announcement was queued without its clan';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at, clan_key)
    VALUES ('raid:start:1', 'ping', 'raid_start', channel_id, 'members', now_at, clan_a)
    RETURNING operation_key INTO raid_start;
    INSERT INTO guild.notification_mention_role (operation_key, role_key) VALUES (raid_start, role_id);
    INSERT INTO guild.notification_mention_user (operation_key, user_key) VALUES (raid_start, member_id);
    BEGIN
        INSERT INTO guild.notification_mention_role (operation_key, role_key) VALUES (raid_start, role_id);
        RAISE EXCEPTION 'One operation mentioned a role twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_mention_role (operation_key, role_key) VALUES (raid_start, -1);
        RAISE EXCEPTION 'An operation mentioned a role that does not exist';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.notification_mention_user WHERE operation_key = raid_start;
        RAISE EXCEPTION 'The mention targets of queued work were changed';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- War reminders and catch-up.
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, war_key, clan_key)
        VALUES ('war:reminder', 'ping', 'war_reminder', channel_id, 'members', now_at, war, clan_a);
        RAISE EXCEPTION 'A war reminder was queued without its offset';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, checkpoint_offset_seconds)
        VALUES ('war:reminder', 'ping', 'war_reminder', channel_id, 'members', now_at, 28800);
        RAISE EXCEPTION 'A war reminder was queued without its war';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at, expires_at, war_key, clan_key, checkpoint_offset_seconds)
    VALUES ('war:1:clan:1:offset:28800', 'ping', 'war_reminder', channel_id, 'members', now_at - interval '8 hours',
        now_at + interval '1 day', war, clan_a, 28800)
    RETURNING operation_key INTO reminder;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, war_key, clan_key, checkpoint_offset_seconds)
        VALUES ('war:1:clan:1:offset:28800:again', 'ping', 'war_reminder', channel_id, 'members', now_at,
            war, clan_a, 28800);
        RAISE EXCEPTION 'One reminder offset was queued twice for a war and clan';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at, expires_at, war_key, clan_key, remaining_seconds)
    VALUES ('war:1:clan:1:catchup', 'ping', 'war_catchup', channel_id, 'members', now_at, now_at + interval '1 day',
        war, clan_a, 86400)
    RETURNING operation_key INTO catchup;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, war_key, clan_key)
        VALUES ('war:1:clan:1:catchup:again', 'ping', 'war_catchup', channel_id, 'members', now_at, war, clan_a);
        RAISE EXCEPTION 'missed eight/four hour checkpoints were not coalesced exactly once';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- DEC-14: a later outage may queue another catch-up once the earlier one
    -- is finished, never two unfinished ones.
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at, war_key, clan_key)
    VALUES ('war:1:clan:2:catchup:1', 'ping', 'war_catchup', channel_id, 'members', now_at, war, clan_b)
    RETURNING operation_key INTO first_catchup_b;
    UPDATE guild.notification_operation SET status = 'in_flight' WHERE operation_key = first_catchup_b;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, war_key, clan_key)
        VALUES ('war:1:clan:2:catchup:2', 'ping', 'war_catchup', channel_id, 'members', now_at, war, clan_b);
        RAISE EXCEPTION 'A second catch-up was queued while the first was in flight';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    UPDATE guild.notification_operation SET status = 'delivered' WHERE operation_key = first_catchup_b;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at, war_key, clan_key)
    VALUES ('war:1:clan:2:catchup:2', 'ping', 'war_catchup', channel_id, 'members', now_at, war, clan_b);
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, war_key, clan_key)
        VALUES ('war:1:clan:2:catchup:3', 'ping', 'war_catchup', channel_id, 'members', now_at, war, clan_b);
        RAISE EXCEPTION 'Two pending catch-ups were queued for one war and clan';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- A reminder with no unused attack left is expired, never sent (WAR-005).
    BEGIN
        INSERT INTO guild.fact_notification_disposition (operation_key, disposition, cause, occurred_at)
        VALUES (first_catchup_b, 'superseded', 'no_unused_attacks', now_at);
        RAISE EXCEPTION 'A reminder without unused attacks was recorded as superseded';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_notification_disposition (operation_key, disposition, cause, occurred_at)
    SELECT operation_key, 'expired', 'no_unused_attacks', now_at
    FROM guild.notification_operation WHERE logical_key = 'war:1:clan:2:catchup:2';
    INSERT INTO guild.notification_catchup_input (catchup_operation_key, source_operation_key)
    VALUES (catchup, reminder);
    BEGIN
        INSERT INTO guild.notification_catchup_input (catchup_operation_key, source_operation_key)
        VALUES (ping, reminder);
        RAISE EXCEPTION 'One missed reminder was coalesced into two catch-ups';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- Suppression evidence (GAP-07): when and why, and what replaced it.
    BEGIN
        INSERT INTO guild.fact_notification_disposition (operation_key, disposition, cause, occurred_at)
        VALUES (reminder, 'superseded', 'coalesced_into_catchup', now_at);
        RAISE EXCEPTION 'A coalesced reminder did not name its catch-up';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_notification_disposition (operation_key, disposition, cause,
            superseded_by_operation_key, occurred_at)
        VALUES (reminder, 'expired', 'coalesced_into_catchup', catchup, now_at);
        RAISE EXCEPTION 'A supersession was recorded as an expiry';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_notification_disposition (operation_key, disposition, cause,
            superseded_by_operation_key, occurred_at)
        VALUES (reminder, 'superseded', 'coalesced_into_catchup', reminder, now_at);
        RAISE EXCEPTION 'An operation superseded itself';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_notification_disposition (operation_key, disposition, cause,
        superseded_by_operation_key, occurred_at)
    VALUES (reminder, 'superseded', 'coalesced_into_catchup', catchup, now_at);
    UPDATE guild.notification_operation SET status = 'superseded' WHERE operation_key = reminder;
    BEGIN
        INSERT INTO guild.fact_notification_disposition (operation_key, disposition, cause, occurred_at)
        VALUES (reminder, 'expired', 'war_inactive', now_at);
        RAISE EXCEPTION 'A suppressed operation was suppressed twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_notification_disposition SET occurred_at = now_at - interval '1 day'
        WHERE operation_key = reminder;
        RAISE EXCEPTION 'Suppression evidence was rewritten';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Desired-role generations.
    INSERT INTO guild.notification_role_target (user_key) VALUES (member_id);
    BEGIN
        INSERT INTO guild.notification_role_source_requirement (user_key, source_key, role_key)
        VALUES (member_id, 'clan member', role_id);
        RAISE EXCEPTION 'A source key with a space was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.notification_role_source_requirement (user_key, source_key, role_key)
    VALUES (member_id, 'war:1', role_id);
    INSERT INTO guild.notification_managed_role (user_key, role_key) VALUES (member_id, role_id);
    INSERT INTO guild.notification_role_generation (user_key, generation) VALUES (member_id, 1);
    BEGIN
        INSERT INTO guild.notification_role_generation (user_key, generation) VALUES (member_id, 0);
        RAISE EXCEPTION 'A role generation zero was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.notification_role_generation_requirement (user_key, generation, role_key, is_desired)
    VALUES (member_id, 1, role_id, true);
    UPDATE guild.notification_role_target SET generation = 1 WHERE user_key = member_id;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, target_user_key, role_generation)
        VALUES ('role:1:1', 'role_reconcile', 'role_reconcile', channel_id, 'members', now_at, member_id, 1);
        RAISE EXCEPTION 'Role work was given a channel';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, audience, due_at,
            target_user_key, role_generation)
        VALUES ('role:1:2', 'role_reconcile', 'role_reconcile', 'members', now_at, member_id, 2);
        RAISE EXCEPTION 'Role work named a generation that does not exist';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, audience, due_at,
        target_user_key, role_generation)
    VALUES ('role:1:1', 'role_reconcile', 'role_reconcile', 'members', now_at, member_id, 1)
    RETURNING operation_key INTO role_work;
    DELETE FROM guild.notification_role_source_requirement WHERE user_key = member_id;

    -- Reports.
    BEGIN
        INSERT INTO guild.notification_report (logical_report_key, report_kind, channel_key, audience,
            discord_message_id)
        VALUES ('clan-games:1', 'clan_games_report', channel_id, 'members', 990000000000000101);
        RAISE EXCEPTION 'A report message was recorded without its confirmation time';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.notification_report (logical_report_key, report_kind, channel_key, audience)
    VALUES ('clan-games:1', 'clan_games_report', channel_id, 'members') RETURNING report_key INTO report;
    BEGIN
        INSERT INTO guild.notification_report (logical_report_key, report_kind, channel_key, audience)
        VALUES ('clan-games:1', 'raid_report', channel_id, 'members');
        RAISE EXCEPTION 'one logical key was accepted for two reports';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, report_key)
        VALUES ('clan-games:1:revision:1', 'report_create', 'clan_games_report', channel_id, 'members', now_at,
            report);
        RAISE EXCEPTION 'A report operation was queued without its revision';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at, report_key, report_revision)
    VALUES ('clan-games:1:revision:1', 'report_create', 'clan_games_report', channel_id, 'members', now_at,
        report, 1)
    RETURNING operation_key INTO revision_one;
    BEGIN
        INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
            audience, due_at, report_key, report_revision)
        VALUES ('clan-games:1:revision:1:again', 'report_create', 'clan_games_report', channel_id, 'members',
            now_at, report, 1);
        RAISE EXCEPTION 'replayed report revision was queued twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    UPDATE guild.notification_report SET latest_revision = 1 WHERE report_key = report;
    UPDATE guild.notification_operation SET operation_kind = 'report_edit' WHERE operation_key = revision_one;
    UPDATE guild.notification_report SET discord_message_id = 990000000000000101, message_confirmed_at = now_at
    WHERE report_key = report;

    -- Outbox publication and Kafka receipts.
    BEGIN
        INSERT INTO guild.fact_notification_publication_attempt (outbox_key, publication_fence, outcome)
        SELECT outbox_key, gen_random_uuid(), 'published' FROM guild.notification_operation WHERE operation_key = ping;
        RAISE EXCEPTION 'A publication was confirmed without its Kafka coordinate';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_notification_publication_attempt (outbox_key, publication_fence, outcome, kafka_topic,
        kafka_partition, kafka_offset)
    SELECT outbox_key, fence, 'published', 'guild.notifications', 0, 1
    FROM guild.notification_operation WHERE operation_key = ping;
    BEGIN
        INSERT INTO guild.fact_notification_publication_attempt (outbox_key, publication_fence, outcome)
        SELECT outbox_key, fence, 'failed' FROM guild.notification_operation WHERE operation_key = ping;
        RAISE EXCEPTION 'stale publisher could confirm another worker lease';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    UPDATE guild.notification_operation SET publication_state = 'published', publication_fence = fence
    WHERE operation_key = ping;
    INSERT INTO guild.notification_kafka_receipt (operation_key, consumer_group, kafka_topic, kafka_partition,
        kafka_offset, is_first_for_operation)
    VALUES (ping, 'delivery', 'guild.notifications', 0, 1, true);
    BEGIN
        INSERT INTO guild.notification_kafka_receipt (operation_key, consumer_group, kafka_topic, kafka_partition,
            kafka_offset, is_first_for_operation)
        VALUES (catchup, 'delivery', 'guild.notifications', 0, 1, false);
        RAISE EXCEPTION 'Kafka coordinate was reassigned to another logical operation';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_kafka_receipt (operation_key, consumer_group, kafka_topic, kafka_partition,
            kafka_offset, is_first_for_operation)
        VALUES (ping, 'delivery', 'guild.notifications', 0, 2, true);
        RAISE EXCEPTION 'Kafka replay did not deduplicate its logical operation';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.notification_kafka_receipt (operation_key, consumer_group, kafka_topic, kafka_partition,
        kafka_offset, is_first_for_operation)
    VALUES (ping, 'delivery', 'guild.notifications', 0, 2, false),
        (ping, 'audit', 'guild.notifications', 0, 1, true);
    BEGIN
        UPDATE guild.notification_kafka_receipt SET is_first_for_operation = false WHERE operation_key = ping;
        RAISE EXCEPTION 'logical deduplication discarded replay evidence or another consumer group';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Dispatch authorizations, the send permit and the result.
    BEGIN
        INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action, worker_key,
            authorized_at, lease_expires_at)
        VALUES (ping, 1, true, 'ping', 'worker 1', now_at, now_at + interval '30 seconds');
        RAISE EXCEPTION 'An unbounded worker identity was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action, worker_key,
            authorized_at, lease_expires_at)
        VALUES (ping, 1, true, 'ping', 'worker-1', now_at, now_at);
        RAISE EXCEPTION 'A dispatch lease expired when it was granted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action, worker_key,
        authorized_at, lease_expires_at)
    VALUES (ping, 1, true, 'ping', 'worker-1', now_at, now_at + interval '30 seconds')
    RETURNING dispatch_key INTO dispatch;
    BEGIN
        INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action, worker_key,
            authorized_at, lease_expires_at)
        VALUES (ping, 2, true, 'ping', 'worker-2', now_at, now_at + interval '30 seconds');
        RAISE EXCEPTION 'multiple ping dispatch attempts were authorized';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- Role reconciliation may be attempted again.
    INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action, worker_key,
        authorized_at, lease_expires_at)
    VALUES (role_work, 1, false, 'role_reconcile', 'worker-1', now_at, now_at + interval '30 seconds'),
        (role_work, 2, false, 'role_reconcile', 'worker-2', now_at, now_at + interval '30 seconds');
    BEGIN
        UPDATE guild.fact_notification_dispatch_attempt SET outcome = 'succeeded' WHERE dispatch_key = dispatch;
        RAISE EXCEPTION 'An outcome was recorded without its finish and record times';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_notification_dispatch_attempt
        SET outcome = 'succeeded', finished_at = now_at, recorded_at = now_at, http_status = 200
        WHERE dispatch_key = dispatch;
        RAISE EXCEPTION 'RPC acceptance became delivery before send authorization';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_notification_dispatch_attempt SET http_status = 200 WHERE dispatch_key = dispatch;
        RAISE EXCEPTION 'A result was recorded without an outcome';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.fact_notification_dispatch_attempt SET started_at = now_at WHERE dispatch_key = dispatch;
    UPDATE guild.fact_notification_dispatch_attempt
    SET outcome = 'succeeded', finished_at = now_at, recorded_at = now_at, http_status = 200,
        discord_message_id = 990000000000000102
    WHERE dispatch_key = dispatch;
    BEGIN
        UPDATE guild.fact_notification_dispatch_attempt SET lease_expires_at = now_at + interval '1 hour'
        WHERE dispatch_key = dispatch;
        RAISE EXCEPTION 'consumed one-use permit could be reopened';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.fact_notification_dispatch_attempt WHERE dispatch_key = dispatch;
        RAISE EXCEPTION 'uncertainty/authorization facts were not retained separately';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    UPDATE guild.notification_operation SET status = 'delivered', current_fence = fence WHERE operation_key = ping;
    IF (SELECT count(*) FROM guild.fact_notification_delivery_attempt WHERE operation_key = ping) <> 1 THEN
        RAISE EXCEPTION 'The runtime role could not read the delivery it recorded';
    END IF;
    BEGIN
        INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action,
            worker_key, authorized_at, lease_expires_at)
        VALUES (role_work, 3, true, 'role_reconcile', 'worker-3', now_at, now_at + interval '30 seconds');
        RAISE EXCEPTION 'A ping flag disagreed with the authorized action';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    -- Report retries keep each attempt's action and target (GAP-17): edit M,
    -- find M missing, then create N for the same revision.
    BEGIN
        INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action,
            worker_key, authorized_at, lease_expires_at)
        VALUES (revision_one, 1, false, 'report_edit', 'worker-1', now_at, now_at + interval '30 seconds');
        RAISE EXCEPTION 'An edit was authorized without the message it targets';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action,
        requested_message_id, worker_key, authorized_at, lease_expires_at, started_at)
    VALUES (revision_one, 1, false, 'report_edit', 990000000000000101, 'worker-1', now_at,
        now_at + interval '30 seconds', now_at)
    RETURNING dispatch_key INTO edit_m;
    BEGIN
        UPDATE guild.fact_notification_dispatch_attempt
        SET outcome = 'succeeded', finished_at = now_at, recorded_at = now_at, http_status = 200,
            discord_message_id = 990000000000000109
        WHERE dispatch_key = edit_m;
        RAISE EXCEPTION 'An edit succeeded on a message other than the one it targeted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.fact_notification_dispatch_attempt
    SET outcome = 'failed', finished_at = now_at, recorded_at = now_at, http_status = 404,
        error_code = 'report_message_missing'
    WHERE dispatch_key = edit_m;
    UPDATE guild.notification_report SET discord_message_id = NULL, message_confirmed_at = NULL
    WHERE report_key = report;
    BEGIN
        INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action,
            requested_message_id, worker_key, authorized_at, lease_expires_at)
        VALUES (revision_one, 2, false, 'report_create', 990000000000000101, 'worker-2', now_at,
            now_at + interval '30 seconds');
        RAISE EXCEPTION 'A create named a message to edit';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action,
            replaced_dispatch_key, worker_key, authorized_at, lease_expires_at)
        VALUES (revision_one, 2, false, 'report_create', dispatch, 'worker-2', now_at,
            now_at + interval '30 seconds');
        RAISE EXCEPTION 'A replacement named an attempt of another operation';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.fact_notification_dispatch_attempt (operation_key, attempt_number, is_ping, dispatch_action,
        replaced_dispatch_key, worker_key, authorized_at, lease_expires_at, started_at)
    VALUES (revision_one, 2, false, 'report_create', edit_m, 'worker-2', now_at, now_at + interval '30 seconds',
        now_at)
    RETURNING dispatch_key INTO create_n;
    UPDATE guild.notification_operation SET operation_kind = 'report_create' WHERE operation_key = revision_one;
    UPDATE guild.fact_notification_dispatch_attempt
    SET outcome = 'succeeded', finished_at = now_at, recorded_at = now_at, http_status = 200,
        discord_message_id = 990000000000000110
    WHERE dispatch_key = create_n;
    UPDATE guild.notification_report SET discord_message_id = 990000000000000110, message_confirmed_at = now_at
    WHERE report_key = report;
    IF ARRAY(SELECT (dispatch_action, requested_message_id, outcome, discord_message_id)::text
            FROM guild.fact_notification_dispatch_attempt WHERE operation_key = revision_one ORDER BY attempt_number)
        IS DISTINCT FROM ARRAY['(report_edit,990000000000000101,failed,)',
            '(report_create,,succeeded,990000000000000110)'] THEN
        RAISE EXCEPTION 'A report retry lost the action or target of an earlier attempt';
    END IF;
    BEGIN
        UPDATE guild.fact_notification_dispatch_attempt SET dispatch_action = 'report_create'
        WHERE dispatch_key = edit_m;
        RAISE EXCEPTION 'The runtime role rewrote the action of an authorization';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Typed moderation and raid-start context (GAP-05).
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (990000000000000012) RETURNING user_key INTO subject_id;
    INSERT INTO guild.warning (subject_user_key, issued_by_user_key, reason)
    VALUES (subject_id, member_id, 'Missed attacks') RETURNING warning_key INTO warning_id;
    BEGIN
        INSERT INTO guild.notification_moderation_context (operation_key, context_kind, warning_key)
        VALUES (ping, 'warning_revoked', warning_id);
        RAISE EXCEPTION 'A moderation context named a source of another kind';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_moderation_context (operation_key, context_kind, revoked_warning_key)
        VALUES (ping, 'warning_revoked', warning_id);
        RAISE EXCEPTION 'A revocation context named a warning that was not revoked';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.warning_revocation (warning_key, revoked_by_user_key, reason)
    VALUES (warning_id, member_id, 'Issued in error');
    BEGIN
        INSERT INTO guild.notification_moderation_context (operation_key, context_kind, warning_key,
            revoked_warning_key)
        VALUES (ping, 'warning_revoked', warning_id, warning_id);
        RAISE EXCEPTION 'A moderation context named two sources';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.notification_moderation_context (operation_key, context_kind, revoked_warning_key)
    VALUES (ping, 'warning_revoked', warning_id);
    BEGIN
        UPDATE guild.notification_moderation_context SET context_kind = 'warning_issued' WHERE operation_key = ping;
        RAISE EXCEPTION 'A moderation context was rewritten';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- CWL notification context.
    INSERT INTO guild.cwl_cycle (calendar_month) VALUES ('2026-12-01') RETURNING cycle_key INTO cycle;
    INSERT INTO guild.cwl_participating_clan (cycle_key, clan_key)
    VALUES (cycle, clan_a) RETURNING participation_key INTO participation;
    INSERT INTO guild.cwl_plan_revision (participation_key, revision, source_kind, algorithm_version, phase)
    VALUES (participation, 1, 'automatic', 'v1', 'initial_th_availability') RETURNING plan_key INTO plan;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at)
    VALUES ('cwl:leadership:1', 'ping', 'cwl_leadership', channel_id, 'leadership', now_at)
    RETURNING operation_key INTO prompt;
    BEGIN
        INSERT INTO guild.notification_cwl_context (operation_key, cycle_key, participation_key)
        VALUES (prompt, cycle, participation);
        RAISE EXCEPTION 'A CWL context named a clan without its plan and War Day';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.notification_cwl_context (operation_key, cycle_key) VALUES (prompt, cycle);
    BEGIN
        INSERT INTO guild.notification_cwl_context (operation_key, cycle_key) VALUES (catchup, cycle);
        RAISE EXCEPTION 'A cycle got two leadership prompts';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.notification_cwl_context (operation_key, cycle_key, participation_key, plan_key, war_day)
    VALUES (revision_one, cycle, participation, plan, 1);
    BEGIN
        INSERT INTO guild.notification_cwl_context (operation_key, cycle_key, participation_key, plan_key, war_day)
        VALUES (role_work, cycle, participation, plan, 1);
        RAISE EXCEPTION 'A plan and War Day were queued as two roster operations';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.notification_cwl_context SET war_day = 2 WHERE operation_key = revision_one;
        RAISE EXCEPTION 'A CWL notification context was rewritten';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- Typed context of raid and Clan Games report revisions.
    INSERT INTO guild.dim_raid_weekend (clan_key, starts_at, ends_at)
    VALUES (clan_a, now_at - interval '3 days', now_at) RETURNING raid_weekend_key INTO raid;
    INSERT INTO guild.notification_report (logical_report_key, report_kind, channel_key, audience)
    VALUES ('raid:1', 'raid_report', channel_id, 'members') RETURNING report_key INTO raid_report;
    INSERT INTO guild.notification_operation (logical_key, operation_kind, notification_kind, channel_key,
        audience, due_at, report_key, report_revision)
    VALUES ('raid:1:revision:1', 'report_create', 'raid_report', channel_id, 'members', now_at, raid_report, 1)
    RETURNING operation_key INTO raid_revision;
    INSERT INTO guild.raid_poll (clan_key, source_correlation_id, observed_at, outcome, raid_weekend_key)
    VALUES (clan_a, 'test:raid-poll', now_at - interval '1 hour', 'weekend', raid)
    RETURNING raid_poll_key INTO raid_poll_id;
    BEGIN
        INSERT INTO guild.notification_raid_report_context (operation_key, raid_weekend_key, observed_through,
            raid_poll_key)
        VALUES (raid_revision, raid, now_at, raid_poll_id);
        RAISE EXCEPTION 'A raid report claimed coverage its poll did not observe';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.notification_raid_report_context (operation_key, raid_weekend_key, observed_through,
        raid_poll_key)
    VALUES (raid_revision, raid, now_at - interval '1 hour', raid_poll_id);
    BEGIN
        INSERT INTO guild.notification_raid_report_context (operation_key, raid_weekend_key, observed_through,
            raid_poll_key)
        VALUES (raid_revision, raid, now_at - interval '1 hour', raid_poll_id);
        RAISE EXCEPTION 'A raid report revision got two contexts';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.notification_raid_start_context (operation_key, raid_weekend_key) VALUES (raid_start, raid);
    BEGIN
        INSERT INTO guild.notification_raid_start_context (operation_key, raid_weekend_key) VALUES (ping, raid);
        RAISE EXCEPTION 'One raid weekend was announced twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_raid_start_context (operation_key, raid_weekend_key) VALUES (catchup, -1);
        RAISE EXCEPTION 'A raid start named an unknown weekend';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
        source_correlation_id)
    VALUES (now_at - interval '10 days', now_at - interval '4 days', 4000, 'configured_schedule', 'schedule:a')
    RETURNING event_key INTO event_a;
    INSERT INTO guild.dim_clan_games_event (starts_at, ends_at, account_points_cap, schedule_source,
        source_correlation_id)
    VALUES (now_at - interval '40 days', now_at - interval '34 days', 4000, 'configured_schedule', 'schedule:b')
    RETURNING event_key INTO event_b;
    INSERT INTO guild.fact_clan_games_member_assessment (event_key, user_key, checkpoint_kind,
        calculation_version, attribution_policy, attribution_status, evidence_note)
    VALUES (event_a, member_id, 'final', 1, 'test', 'adequate', 'test')
    RETURNING member_assessment_key INTO assessment_a;
    INSERT INTO guild.fact_clan_games_member_assessment (event_key, user_key, checkpoint_kind,
        calculation_version, attribution_policy, attribution_status, evidence_note)
    VALUES (event_b, member_id, 'final', 1, 'test', 'adequate', 'test')
    RETURNING member_assessment_key INTO assessment_b;
    INSERT INTO guild.notification_clan_games_report_context (operation_key, event_key)
    VALUES (revision_one, event_a);
    INSERT INTO guild.notification_clan_games_report_assessment (operation_key, event_key,
        member_assessment_key, checkpoint_kind)
    VALUES (revision_one, event_a, assessment_a, 'final');
    BEGIN
        INSERT INTO guild.notification_clan_games_report_assessment (operation_key, event_key,
            member_assessment_key, checkpoint_kind)
        VALUES (revision_one, event_a, assessment_b, 'final');
        RAISE EXCEPTION 'A Clan Games report published an assessment of another event';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_clan_games_report_assessment (operation_key, event_key,
            member_assessment_key, checkpoint_kind)
        VALUES (revision_one, event_b, assessment_b, 'final');
        RAISE EXCEPTION 'A published assessment named another event than its report';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.fact_clan_games_member_assessment (event_key, user_key, checkpoint_kind,
        calculation_version, attribution_policy, attribution_status, evidence_note)
    VALUES (event_a, member_id, 'final', 2, 'test', 'adequate', 'test')
    RETURNING member_assessment_key INTO assessment_b;
    BEGIN
        INSERT INTO guild.notification_clan_games_report_assessment (operation_key, event_key,
            member_assessment_key, checkpoint_kind)
        VALUES (revision_one, event_a, assessment_b, 't_minus_24h');
        RAISE EXCEPTION 'A published assessment named another checkpoint';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.notification_clan_games_report_assessment WHERE operation_key = revision_one;
        RAISE EXCEPTION 'A published assessment was removed from its report';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    -- DEC-16: a public points revision names the exact progress row per account.
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#9CGR') RETURNING player_key INTO cg_player;
    INSERT INTO guild.dim_player_account (player_tag) VALUES ('#9CGQ') RETURNING player_key INTO cg_other_player;
    INSERT INTO guild.fact_clan_games_progress (event_key, player_key, observed_at, source_correlation_id,
        evidence_status, evidence_note)
    VALUES (event_a, cg_player, now_at - interval '5 days', 'test:progress:a', 'insufficient_data', 'test')
    RETURNING progress_key INTO progress_a;
    INSERT INTO guild.fact_clan_games_progress (event_key, player_key, observed_at, source_correlation_id,
        evidence_status, evidence_note)
    VALUES (event_b, cg_other_player, now_at - interval '35 days', 'test:progress:b', 'insufficient_data', 'test')
    RETURNING progress_key INTO progress_b;
    INSERT INTO guild.notification_clan_games_report_progress (operation_key, event_key, player_key, progress_key)
    VALUES (revision_one, event_a, cg_player, progress_a);
    BEGIN
        INSERT INTO guild.notification_clan_games_report_progress (operation_key, event_key, player_key,
            progress_key)
        VALUES (revision_one, event_a, cg_player, progress_a);
        RAISE EXCEPTION 'A revision showed one account twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.notification_clan_games_report_progress (operation_key, event_key, player_key,
            progress_key)
        VALUES (revision_one, event_a, cg_other_player, progress_b);
        RAISE EXCEPTION 'A revision published progress of another event';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.notification_clan_games_report_progress SET progress_key = progress_b
        WHERE operation_key = revision_one;
        RAISE EXCEPTION 'A published progress row was changed';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'Notification delivery constraints passed';
END;
$$;

ROLLBACK;
