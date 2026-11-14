BEGIN;

-- V4, second part: warnings, revocations, kick decisions and attempts, manual
-- moderation from the audit log, accepted joins and leadership notices. The
-- service decides when to kick, claim, cancel and notify; these checks cover
-- the keys and the row checks behind those decisions.
DO $$
DECLARE
    guild bigint; subject_id bigint; moderator_id bigint; other_id bigint;
    warning_id bigint; other_warning bigint; kick bigint; attempt bigint; manual bigint; join_event bigint;
    revoked_warning bigint; rearm_warning bigint; stay bigint; other_stay bigint;
    lost bigint; unsent bigint; late bigint; takeover bigint;
    token uuid := gen_random_uuid(); issued timestamptz := '2026-11-30 23:30-05';
BEGIN
    INSERT INTO guild.dim_guild (discord_guild_id) VALUES (960000000000000001) RETURNING guild_key INTO guild;
    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.guild_settings (guild_key) VALUES (guild);
    IF (SELECT (kick_max_attempts, kick_retry_seconds) FROM guild.guild_settings) IS DISTINCT FROM (3, 300) THEN
        RAISE EXCEPTION 'The kick retry policy must default to three attempts five minutes apart';
    END IF;
    BEGIN
        UPDATE guild.guild_settings SET kick_max_attempts = 0;
        RAISE EXCEPTION 'An attempt limit of zero was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (960000000000000011)
    RETURNING user_key INTO subject_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (960000000000000012)
    RETURNING user_key INTO moderator_id;
    INSERT INTO guild.dim_discord_user (discord_user_id) VALUES (960000000000000013)
    RETURNING user_key INTO other_id;

    -- Warnings count in the GMT month of their issue time, whatever the session time zone.
    SET LOCAL TIME ZONE 'America/New_York';
    BEGIN
        INSERT INTO guild.warning (subject_user_key, issued_by_user_key, issued_at, reason)
        VALUES (subject_id, moderator_id, issued, '  ');
        RAISE EXCEPTION 'blank warning reason accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.warning (subject_user_key, issued_by_user_key, issued_at, reason)
    VALUES (subject_id, moderator_id, issued, 'Missed attacks') RETURNING warning_key INTO warning_id;
    IF (SELECT issue_month_gmt FROM guild.warning WHERE warning_key = warning_id) <> '2026-12-01' THEN
        RAISE EXCEPTION 'A warning month followed the session time zone instead of GMT';
    END IF;
    SET LOCAL TIME ZONE 'UTC';
    BEGIN
        INSERT INTO guild.warning (operation_id, subject_user_key, issued_by_user_key, reason)
        SELECT operation_id, subject_id, moderator_id, 'Missed attacks' FROM guild.warning
        WHERE warning_key = warning_id;
        RAISE EXCEPTION 'Stable warning command UUID was not unique';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO guild.warning (subject_user_key, issued_by_user_key, issued_at, reason)
    VALUES (other_id, moderator_id, issued, 'Spam') RETURNING warning_key INTO other_warning;
    BEGIN
        UPDATE guild.warning SET reason = 'Changed' WHERE warning_key = warning_id;
        RAISE EXCEPTION 'historical warning evidence was editable';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.warning WHERE warning_key = warning_id;
        RAISE EXCEPTION 'A warning was deleted instead of revoked';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    INSERT INTO guild.warning_revocation (warning_key, revoked_by_user_key, reason)
    VALUES (other_warning, moderator_id, 'Issued in error');
    BEGIN
        INSERT INTO guild.warning_revocation (warning_key, revoked_by_user_key, reason)
        VALUES (other_warning, moderator_id, 'Issued in error again');
        RAISE EXCEPTION 'a second operation revoked an already revoked warning';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.warning_revocation (warning_key, revoked_by_user_key, reason)
        VALUES (warning_id, moderator_id, '');
        RAISE EXCEPTION 'A revocation without a reason was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.warning_revocation WHERE warning_key = other_warning;
        RAISE EXCEPTION 'A revocation was withdrawn by deleting it';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Kick decisions.
    BEGIN
        INSERT INTO guild.moderation_action (subject_user_key, warning_month_gmt, trigger_warning_key)
        VALUES (subject_id, '2026-12-01', other_warning);
        RAISE EXCEPTION 'A kick decision named the warning of another member';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.moderation_action (subject_user_key, warning_month_gmt, trigger_warning_key, action_kind)
        VALUES (subject_id, '2026-12-01', warning_id, 'ban');
        RAISE EXCEPTION 'An automatic ban was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.moderation_action (subject_user_key, warning_month_gmt, trigger_warning_key, next_attempt_at)
        VALUES (subject_id, '2026-12-01', warning_id, NULL);
        RAISE EXCEPTION 'A pending kick was not due for an attempt';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.moderation_action (subject_user_key, warning_month_gmt, trigger_warning_key)
    VALUES (subject_id, '2026-12-01', warning_id) RETURNING moderation_action_key INTO kick;
    BEGIN
        INSERT INTO guild.moderation_action (subject_user_key, warning_month_gmt, trigger_warning_key)
        VALUES (subject_id, '2026-12-01', warning_id);
        RAISE EXCEPTION 'duplicate kick decision created for same month';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.moderation_action SET status = 'cancelled' WHERE moderation_action_key = kick;
        RAISE EXCEPTION 'A kick was cancelled without its cancellation time';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.moderation_action SET status = 'succeeded' WHERE moderation_action_key = kick;
        RAISE EXCEPTION 'A succeeded kick still owed an attempt';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.moderation_action SET attempts_remaining = 0 WHERE moderation_action_key = kick;
        RAISE EXCEPTION 'A kick owed an attempt with none remaining';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.moderation_action SET lease_owner = 'worker-1' WHERE moderation_action_key = kick;
        RAISE EXCEPTION 'A claim was recorded without its lease expiry';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.moderation_action SET subject_user_key = other_id WHERE moderation_action_key = kick;
        RAISE EXCEPTION 'The runtime role moved a kick to another member';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    UPDATE guild.moderation_action
    SET lease_owner = 'worker-1', lease_expires_at = clock_timestamp() + interval '5 minutes', claim_token = token
    WHERE moderation_action_key = kick;
    IF NOT EXISTS (SELECT FROM guild.pending_moderation_action WHERE moderation_action_key = kick) THEN
        RAISE EXCEPTION 'pending kick decision was not visible to the worker view';
    END IF;

    -- Decision history (GAP-06, MOD-009): the decision, a cancellation after a
    -- revocation and rearming after another fifth warning are all kept.
    INSERT INTO guild.warning (subject_user_key, issued_by_user_key, issued_at, reason)
    VALUES (subject_id, moderator_id, issued + interval '1 minute', 'Missed attacks again')
    RETURNING warning_key INTO revoked_warning;
    INSERT INTO guild.warning (subject_user_key, issued_by_user_key, issued_at, reason)
    VALUES (subject_id, moderator_id, issued + interval '3 minutes', 'Missed attacks a third time')
    RETURNING warning_key INTO rearm_warning;
    INSERT INTO guild.fact_moderation_action_transition (moderation_action_key, subject_user_key,
        transition_kind, trigger_warning_key, origin, attempts_granted, occurred_at)
    VALUES (kick, subject_id, 'decided', warning_id, 'system', 3, issued);
    BEGIN
        INSERT INTO guild.fact_moderation_action_transition (moderation_action_key, subject_user_key,
            transition_kind, trigger_warning_key, origin, attempts_granted, occurred_at)
        VALUES (kick, subject_id, 'decided', rearm_warning, 'system', 3, issued);
        RAISE EXCEPTION 'A kick decision was decided twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_action_transition (moderation_action_key, subject_user_key,
            transition_kind, revoked_warning_key, origin, actor_user_key, occurred_at)
        VALUES (kick, subject_id, 'cancelled', revoked_warning, 'staff', moderator_id, issued);
        RAISE EXCEPTION 'A cancellation named a warning that was not revoked';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_action_transition (moderation_action_key, subject_user_key,
            transition_kind, revoked_warning_key, origin, actor_user_key, occurred_at)
        VALUES (kick, subject_id, 'cancelled', other_warning, 'staff', moderator_id, issued);
        RAISE EXCEPTION 'A cancellation named the revoked warning of another member';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.warning_revocation (warning_key, revoked_by_user_key, reason)
    VALUES (revoked_warning, moderator_id, 'Excused');
    BEGIN
        INSERT INTO guild.fact_moderation_action_transition (moderation_action_key, subject_user_key,
            transition_kind, revoked_warning_key, origin, occurred_at)
        VALUES (kick, subject_id, 'cancelled', revoked_warning, 'staff', issued);
        RAISE EXCEPTION 'A staff transition was recorded without its actor';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_action_transition (moderation_action_key, subject_user_key,
            transition_kind, trigger_warning_key, revoked_warning_key, origin, actor_user_key, occurred_at)
        VALUES (kick, subject_id, 'cancelled', warning_id, revoked_warning, 'staff', moderator_id, issued);
        RAISE EXCEPTION 'A cancellation named a trigger warning';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_action_transition (moderation_action_key, subject_user_key,
            transition_kind, trigger_warning_key, origin, occurred_at)
        VALUES (kick, subject_id, 'rearmed', rearm_warning, 'system', issued);
        RAISE EXCEPTION 'Rearming did not record the attempts it granted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_moderation_action_transition (moderation_action_key, subject_user_key,
        transition_kind, revoked_warning_key, origin, actor_user_key, occurred_at)
    VALUES (kick, subject_id, 'cancelled', revoked_warning, 'staff', moderator_id, issued + interval '2 minutes');
    INSERT INTO guild.fact_moderation_action_transition (moderation_action_key, subject_user_key,
        transition_kind, trigger_warning_key, origin, attempts_granted, occurred_at)
    VALUES (kick, subject_id, 'rearmed', rearm_warning, 'system', 3, issued + interval '3 minutes');
    IF ARRAY(SELECT transition_kind FROM guild.fact_moderation_action_transition
            WHERE moderation_action_key = kick ORDER BY occurred_at, transition_key)
        IS DISTINCT FROM ARRAY['decided', 'cancelled', 'rearmed']
        OR (SELECT count(*) FROM guild.moderation_action WHERE subject_user_key = subject_id) <> 1 THEN
        RAISE EXCEPTION 'The decision history was not kept beside one current decision';
    END IF;
    BEGIN
        UPDATE guild.fact_moderation_action_transition SET occurred_at = issued WHERE moderation_action_key = kick;
        RAISE EXCEPTION 'The runtime role rewrote decision history';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Kick authorizations (GAP-13): each attempt is authorized before any call
    -- to Discord and targets one accepted join of the member.
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at, new_joinee_policy_days)
    VALUES (subject_id, 'join', issued - interval '30 days', 7) RETURNING membership_event_key INTO stay;
    INSERT INTO guild.fact_discord_accepted_join (membership_event_key, user_key) VALUES (stay, subject_id);
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at, new_joinee_policy_days)
    VALUES (other_id, 'join', issued - interval '30 days', 7) RETURNING membership_event_key INTO other_stay;
    INSERT INTO guild.fact_discord_accepted_join (membership_event_key, user_key) VALUES (other_stay, other_id);
    BEGIN
        INSERT INTO guild.fact_moderation_action_attempt (moderation_action_key, subject_user_key, attempt_number,
            claim_token, worker_key, target_membership_event_key, lease_expires_at)
        VALUES (kick, subject_id, 1, gen_random_uuid(), 'worker-1', other_stay, clock_timestamp() + interval '5 minutes');
        RAISE EXCEPTION 'A kick attempt targeted the stay of another member';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_action_attempt (moderation_action_key, subject_user_key, attempt_number,
            claim_token, worker_key, target_membership_event_key, lease_expires_at)
        VALUES (kick, subject_id, 1, gen_random_uuid(), '{"worker": 1}', stay, clock_timestamp() + interval '5 minutes');
        RAISE EXCEPTION 'A free-form worker identifier was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_action_attempt (moderation_action_key, subject_user_key, attempt_number,
            claim_token, worker_key, target_membership_event_key, lease_expires_at, started_at, attempted_at,
            recorded_at, outcome, http_status)
        VALUES (kick, subject_id, 1, gen_random_uuid(), 'worker-1', stay, clock_timestamp() + interval '5 minutes',
            clock_timestamp(), clock_timestamp(), clock_timestamp(), 'succeeded', 403);
        RAISE EXCEPTION 'A kick succeeded with a failing HTTP status';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    -- A lost response: the call started and its result is unknown.
    INSERT INTO guild.fact_moderation_action_attempt (moderation_action_key, subject_user_key, attempt_number,
        claim_token, worker_key, target_membership_event_key, lease_expires_at)
    VALUES (kick, subject_id, 1, token, 'worker-1', stay, clock_timestamp() + interval '5 minutes')
    RETURNING moderation_attempt_key INTO lost;
    BEGIN
        UPDATE guild.fact_moderation_action_attempt
        SET outcome = 'failed', attempted_at = clock_timestamp(), recorded_at = clock_timestamp()
        WHERE moderation_attempt_key = lost;
        RAISE EXCEPTION 'A result was recorded for an attempt that never consumed its send permission';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.fact_moderation_action_attempt SET started_at = clock_timestamp()
    WHERE moderation_attempt_key = lost;
    BEGIN
        UPDATE guild.fact_moderation_action_attempt
        SET outcome = 'succeeded', attempted_at = clock_timestamp(), recorded_at = clock_timestamp()
        WHERE moderation_attempt_key = lost;
        RAISE EXCEPTION 'A kick succeeded without a Discord response';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_moderation_action_attempt
        SET outcome = 'failed', attempted_at = clock_timestamp(), recorded_at = clock_timestamp(),
            diagnostic_code = '{"message": "Missing Permissions"}'
        WHERE moderation_attempt_key = lost;
        RAISE EXCEPTION 'A response body was stored as a diagnostic code';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    UPDATE guild.fact_moderation_action_attempt
    SET outcome = 'uncertain', attempted_at = clock_timestamp(), recorded_at = clock_timestamp(),
        diagnostic_code = 'timeout'
    WHERE moderation_attempt_key = lost;
    BEGIN
        INSERT INTO guild.fact_moderation_action_attempt (moderation_action_key, subject_user_key, attempt_number,
            claim_token, worker_key, target_membership_event_key, lease_expires_at)
        VALUES (kick, subject_id, 2, token, 'worker-2', stay, clock_timestamp() + interval '5 minutes');
        RAISE EXCEPTION 'A claim token authorized a second attempt';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_action_attempt (moderation_action_key, subject_user_key, attempt_number,
            claim_token, worker_key, target_membership_event_key, lease_expires_at)
        VALUES (kick, subject_id, 1, gen_random_uuid(), 'worker-2', stay, clock_timestamp() + interval '5 minutes');
        RAISE EXCEPTION 'Two attempts shared one attempt number';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    -- Absence of the member resolves nothing; only kick-specific evidence does.
    BEGIN
        INSERT INTO guild.fact_moderation_attempt_resolution (moderation_attempt_key, resolved_outcome,
            evidence_kind, observed_at)
        VALUES (lost, 'succeeded', 'member_present_same_join', clock_timestamp());
        RAISE EXCEPTION 'A kick was confirmed without the bot''s audit log entry';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_moderation_attempt_resolution (moderation_attempt_key, resolved_outcome,
        evidence_kind, discord_audit_log_entry_id, observed_at)
    VALUES (lost, 'succeeded', 'audit_log', 960000000000000201, issued + interval '4 minutes');
    BEGIN
        UPDATE guild.fact_moderation_action_attempt SET outcome = 'failed' WHERE moderation_attempt_key = lost;
        RAISE EXCEPTION 'A resolved uncertain attempt changed its reported outcome';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;

    -- A crash before the call: the authorization never started, so it proves
    -- that Discord was not called. A takeover authorizes a new attempt.
    INSERT INTO guild.fact_moderation_action_attempt (moderation_action_key, subject_user_key, attempt_number,
        claim_token, worker_key, target_membership_event_key, lease_expires_at)
    VALUES (kick, subject_id, 2, gen_random_uuid(), 'worker-2', stay, clock_timestamp() + interval '5 minutes')
    RETURNING moderation_attempt_key INTO unsent;
    -- A late real success after a takeover is retained for its own authorization.
    INSERT INTO guild.fact_moderation_action_attempt (moderation_action_key, subject_user_key, attempt_number,
        claim_token, worker_key, target_membership_event_key, lease_expires_at, started_at)
    VALUES (kick, subject_id, 3, gen_random_uuid(), 'worker-3', stay, clock_timestamp() + interval '5 minutes',
        clock_timestamp())
    RETURNING moderation_attempt_key INTO late;
    INSERT INTO guild.fact_moderation_action_attempt (moderation_action_key, subject_user_key, attempt_number,
        claim_token, worker_key, target_membership_event_key, lease_expires_at)
    VALUES (kick, subject_id, 4, gen_random_uuid(), 'worker-4', stay, clock_timestamp() + interval '10 minutes')
    RETURNING moderation_attempt_key INTO takeover;
    UPDATE guild.fact_moderation_action_attempt
    SET outcome = 'succeeded', http_status = 204, attempted_at = issued + interval '5 minutes',
        recorded_at = clock_timestamp()
    WHERE moderation_attempt_key = late;
    BEGIN
        INSERT INTO guild.fact_moderation_attempt_resolution (moderation_attempt_key, resolved_outcome,
            evidence_kind, observed_at)
        VALUES (late, 'failed', 'member_present_same_join', clock_timestamp());
        RAISE EXCEPTION 'An attempt with a reported result was resolved again';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    IF ARRAY(SELECT moderation_attempt_key FROM guild.confirmed_moderation_kick
            WHERE moderation_action_key = kick ORDER BY moderation_attempt_key)
        IS DISTINCT FROM ARRAY[lost, late]
        OR (SELECT count(*) FROM guild.fact_moderation_event
            WHERE subject_user_key = subject_id AND origin = 'bot') <> 2 THEN
        RAISE EXCEPTION 'Confirmed kicks did not come only from kick-specific evidence';
    END IF;
    IF (SELECT started_at FROM guild.fact_moderation_action_attempt WHERE moderation_attempt_key = unsent)
        IS NOT NULL THEN
        RAISE EXCEPTION 'An unsent authorization consumed its send permission';
    END IF;
    BEGIN
        UPDATE guild.fact_moderation_action_attempt SET target_membership_event_key = stay
        WHERE moderation_attempt_key = takeover;
        RAISE EXCEPTION 'The runtime role moved the target of an authorization';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    attempt := takeover;
    UPDATE guild.moderation_action
    SET status = 'uncertain', attempts_remaining = 2, next_attempt_at = clock_timestamp() + interval '5 minutes',
        lease_owner = NULL, lease_expires_at = NULL, claim_token = NULL
    WHERE moderation_action_key = kick;

    -- Manual moderation from the audit log.
    BEGIN
        INSERT INTO guild.fact_manual_moderation_action (discord_audit_log_entry_id, action_kind,
            subject_user_key, actor_user_key, occurred_at)
        VALUES (960000000000000101, 'timeout', subject_id, moderator_id, issued);
        RAISE EXCEPTION 'A timeout without its end was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_manual_moderation_action (discord_audit_log_entry_id, action_kind,
            subject_user_key, actor_user_key, occurred_at, timeout_until)
        VALUES (960000000000000101, 'kick', subject_id, moderator_id, issued, issued + interval '1 hour');
        RAISE EXCEPTION 'A kick carried a timeout end';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_manual_moderation_action (discord_audit_log_entry_id, action_kind,
            subject_user_key, actor_user_key, occurred_at, timeout_until)
        VALUES (960000000000000101, 'timeout', subject_id, moderator_id, issued, issued);
        RAISE EXCEPTION 'A timeout ended when it started';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_manual_moderation_action (discord_audit_log_entry_id, action_kind,
            subject_user_key, actor_user_key, occurred_at, reason)
        VALUES (960000000000000101, 'kick', subject_id, moderator_id, issued, repeat('x', 513));
        RAISE EXCEPTION 'An audit log reason longer than 512 characters was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    INSERT INTO guild.fact_manual_moderation_action (discord_audit_log_entry_id, action_kind,
        subject_user_key, actor_user_key, occurred_at, reason)
    VALUES (960000000000000101, 'kick', subject_id, moderator_id, issued, 'Inactive')
    RETURNING manual_action_key INTO manual;
    BEGIN
        INSERT INTO guild.fact_manual_moderation_action (discord_audit_log_entry_id, action_kind,
            subject_user_key, actor_user_key, occurred_at)
        VALUES (960000000000000101, 'ban', subject_id, moderator_id, issued);
        RAISE EXCEPTION 'One audit log entry was accepted as two different actions';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        UPDATE guild.fact_manual_moderation_action SET reason = 'Changed' WHERE manual_action_key = manual;
        RAISE EXCEPTION 'Manual moderation history was mutable';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- Accepted joins and leadership notices.
    INSERT INTO guild.fact_discord_membership_event (user_key, event_kind, occurred_at, new_joinee_policy_days)
    VALUES (subject_id, 'join', issued + interval '1 hour', 7) RETURNING membership_event_key INTO join_event;
    BEGIN
        INSERT INTO guild.fact_discord_accepted_join (membership_event_key, user_key) VALUES (join_event, other_id);
        RAISE EXCEPTION 'An accepted join named another member';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.fact_discord_accepted_join (membership_event_key, user_key) VALUES (join_event, subject_id);
    BEGIN
        INSERT INTO guild.fact_discord_accepted_join (membership_event_key, user_key) VALUES (join_event, subject_id);
        RAISE EXCEPTION 'A join was accepted twice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_notice (subject_user_key, notice_kind, moderation_action_key,
            membership_event_key, kick_month_gmt, occurred_at)
        VALUES (subject_id, 'kick_rejoin', kick, join_event, '2026-12-01', issued + interval '1 hour');
        RAISE EXCEPTION 'A bot kick notice was recorded without its confirmed attempt';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_notice (subject_user_key, notice_kind, manual_action_key,
            membership_event_key, kick_month_gmt, occurred_at)
        VALUES (subject_id, 'unban_rejoin', manual, join_event, '2026-12-02', issued + interval '1 hour');
        RAISE EXCEPTION 'A notice month that is not the first of a month was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_notice (subject_user_key, notice_kind, manual_action_key,
            membership_event_key, kick_month_gmt, occurred_at, warning_key)
        VALUES (subject_id, 'manual_kick_rejoin', manual, join_event, '2026-12-01', issued + interval '1 hour',
            warning_id);
        RAISE EXCEPTION 'A rejoin notice named a warning';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO guild.fact_moderation_notice (subject_user_key, notice_kind, manual_action_key,
            membership_event_key, kick_month_gmt, occurred_at)
        VALUES (other_id, 'manual_kick_rejoin', manual, join_event, '2026-12-01', issued + interval '1 hour');
        RAISE EXCEPTION 'A notice named the manual action of another member';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    INSERT INTO guild.fact_moderation_notice (subject_user_key, notice_kind, manual_action_key,
        membership_event_key, kick_month_gmt, occurred_at)
    VALUES (subject_id, 'manual_kick_rejoin', manual, join_event, '2026-12-01', issued + interval '1 hour');
    BEGIN
        INSERT INTO guild.fact_moderation_notice (subject_user_key, notice_kind, manual_action_key,
            membership_event_key, kick_month_gmt, occurred_at)
        VALUES (subject_id, 'manual_kick_rejoin', manual, join_event, '2026-12-01', issued + interval '1 hour');
        RAISE EXCEPTION 'A rejoin created a second identical notice';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        DELETE FROM guild.fact_moderation_notice WHERE subject_user_key = subject_id;
        RAISE EXCEPTION 'A leadership notice was deleted';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE NOTICE 'Warning, kick and moderation notice constraints passed';
END;
$$;

ROLLBACK;
