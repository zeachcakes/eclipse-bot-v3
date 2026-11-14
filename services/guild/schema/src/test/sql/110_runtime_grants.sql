BEGIN;

-- V9: what guild_runtime, the role of the guild service, may do. The schema
-- holds no routines or triggers (ADR 0012). The runtime role reads every table
-- and view, inserts facts without updating or deleting them, and changes only
-- the tables and columns listed below. The UPDATE and DELETE lists repeat V9 on
-- purpose: a change to those grants must change this check as well.
DO $$
DECLARE
    runtime oid := 'guild_runtime'::regrole;
    guild_ns oid := 'guild'::regnamespace;
    difference text;
    item record;
BEGIN
    IF EXISTS (SELECT FROM pg_catalog.pg_proc WHERE pronamespace = guild_ns) THEN
        RAISE EXCEPTION 'The guild schema holds a function or procedure: %',
            (SELECT string_agg(proname, ', ') FROM pg_catalog.pg_proc WHERE pronamespace = guild_ns);
    END IF;
    IF EXISTS (SELECT FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
        WHERE c.relnamespace = guild_ns AND NOT t.tgisinternal) THEN
        RAISE EXCEPTION 'The guild schema holds a trigger';
    END IF;
    IF EXISTS (SELECT FROM pg_catalog.pg_rewrite r JOIN pg_catalog.pg_class c ON c.oid = r.ev_class
        WHERE c.relnamespace = guild_ns AND r.rulename <> '_RETURN') THEN
        RAISE EXCEPTION 'The guild schema holds a rewrite rule';
    END IF;

    -- PUBLIC gets nothing, and the runtime role owns nothing and creates nothing.
    IF EXISTS (SELECT FROM pg_catalog.pg_class c, aclexplode(c.relacl) x
        WHERE c.relnamespace = guild_ns AND x.grantee = 0) THEN
        RAISE EXCEPTION 'PUBLIC holds a privilege on a guild relation';
    END IF;
    IF has_schema_privilege('public', 'guild', 'USAGE') OR has_schema_privilege('public', 'guild', 'CREATE') THEN
        RAISE EXCEPTION 'PUBLIC can use the guild schema';
    END IF;
    IF has_schema_privilege(runtime, guild_ns, 'CREATE') OR NOT has_schema_privilege(runtime, guild_ns, 'USAGE')
        OR EXISTS (SELECT FROM pg_catalog.pg_class WHERE relnamespace = guild_ns AND relowner = runtime) THEN
        RAISE EXCEPTION 'The runtime role can create objects in or owns part of the guild schema';
    END IF;

    -- SELECT on every table and view except the Flyway history, which stays
    -- private; no other privilege beyond the lists below.
    IF EXISTS (SELECT FROM pg_catalog.pg_class c, aclexplode(c.relacl) x
        WHERE c.relnamespace = guild_ns AND c.relname = 'flyway_schema_history' AND x.grantee = runtime) THEN
        RAISE EXCEPTION 'The runtime role holds a privilege on the Flyway history';
    END IF;
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO difference
    FROM pg_catalog.pg_class c
    WHERE c.relnamespace = guild_ns AND c.relkind IN ('r', 'v') AND c.relname <> 'flyway_schema_history'
        AND NOT has_table_privilege(runtime, c.oid, 'SELECT');
    IF difference IS NOT NULL THEN
        RAISE EXCEPTION 'The runtime role cannot read: %', difference;
    END IF;
    SELECT string_agg(DISTINCT c.relname || ' ' || x.privilege_type, ', ') INTO difference
    FROM pg_catalog.pg_class c, aclexplode(c.relacl) x
    WHERE c.relnamespace = guild_ns AND x.grantee = runtime
        AND x.privilege_type NOT IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'USAGE');
    IF difference IS NOT NULL THEN
        RAISE EXCEPTION 'The runtime role holds an unexpected privilege: %', difference;
    END IF;
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO difference
    FROM pg_catalog.pg_class c
    WHERE c.relnamespace = guild_ns AND c.relkind = 'v'
        AND (has_table_privilege(runtime, c.oid, 'INSERT') OR has_table_privilege(runtime, c.oid, 'UPDATE')
            OR has_table_privilege(runtime, c.oid, 'DELETE') OR has_any_column_privilege(runtime, c.oid, 'UPDATE'));
    IF difference IS NOT NULL THEN
        RAISE EXCEPTION 'The runtime role can write through a view: %', difference;
    END IF;

    -- INSERT on every table except the operator-seeded guild row and reference data.
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO difference
    FROM pg_catalog.pg_class c
    WHERE c.relnamespace = guild_ns AND c.relkind = 'r' AND c.relname <> 'flyway_schema_history'
        AND has_table_privilege(runtime, c.oid, 'INSERT')
            = (c.relname IN ('dim_guild', 'chat_xp_policy', 'chat_rank_tier', 'leaderboard_metric_definition'));
    IF difference IS NOT NULL THEN
        RAISE EXCEPTION 'INSERT does not match the grant policy on: %', difference;
    END IF;

    -- UPDATE: '*' is a table-level grant, otherwise one row per column.
    WITH expected (table_name, column_name) AS (VALUES
        ('dim_discord_user', 'display_name'), ('dim_player_account', 'player_name'), ('dim_clan', 'clan_name'),
        ('dim_discord_role', 'role_name'), ('dim_discord_role', 'last_synced_at'),
        ('dim_discord_role', 'deleted_at'), ('dim_discord_channel', 'channel_name'),
        ('dim_discord_channel', 'last_synced_at'), ('dim_discord_channel', 'deleted_at'),
        ('dim_war', 'war_kind'),
        ('fact_api_fetch_attempt', 'completed_at'), ('fact_api_fetch_attempt', 'http_status'),
        ('fact_api_fetch_attempt', 'outcome'), ('fact_api_fetch_attempt', 'error_code'),
        ('fact_war_attack', 'last_observed_at'),
        ('fact_moderation_action_attempt', 'started_at'), ('fact_moderation_action_attempt', 'attempted_at'),
        ('fact_moderation_action_attempt', 'recorded_at'), ('fact_moderation_action_attempt', 'outcome'),
        ('fact_moderation_action_attempt', 'http_status'), ('fact_moderation_action_attempt', 'diagnostic_code'),
        ('fact_notification_dispatch_attempt', 'started_at'), ('fact_notification_dispatch_attempt', 'finished_at'),
        ('fact_notification_dispatch_attempt', 'outcome'), ('fact_notification_dispatch_attempt', 'recorded_at'),
        ('fact_notification_dispatch_attempt', 'discord_message_id'),
        ('fact_notification_dispatch_attempt', 'http_status'), ('fact_notification_dispatch_attempt', 'error_code'),
        ('clan_games_member_account_input', 'account_assessment_key'),
        ('account_link', 'unlinked_at'), ('account_link', 'is_primary'),
        ('metric_attribution_episode', 'closed_at'),
        ('observed_clan_membership_period', 'observed_until'),
        ('observed_clan_membership_period', 'confirmed_through'),
        ('observed_clan_membership_period', 'last_poll_key'),
        ('observed_clan_membership_period', 'coverage_status'),
        ('chat_member_rank_state', '*'), ('discord_member_role', '*'), ('discord_member_state', '*'),
        ('account_transfer_request', 'status'), ('account_transfer_request', 'decided_by'),
        ('account_transfer_request', 'decided_at'), ('account_transfer_request', 'consumed_at'),
        ('account_transfer_request', 'cancelled_at'), ('account_transfer_request', 'expired_at'),
        ('activity_command_operation', 'result_key'),
        ('clan_games_read_request', 'due_at'), ('clan_games_read_request', 'collect_from'),
        ('clan_games_read_request', 'status'), ('clan_games_read_request', 'missed_at'),
        ('custom_event', 'state'), ('custom_event', 'war_key'), ('custom_event', 'associated_by'),
        ('custom_event', 'association_operation_id'), ('custom_event', 'association_reason'),
        ('cwl_bench_assignment', 'war_day'), ('cwl_bench_assignment', 'assigned_at'),
        ('cwl_clan_day', 'war_key'), ('cwl_cycle', 'state'), ('cwl_cycle', 'ended_at'),
        ('cwl_export_revision', 'sheets_state'),
        ('cwl_sheet_destination', 'lease_owner'), ('cwl_sheet_destination', 'lease_expires_at'),
        ('cwl_sheet_destination', 'fence'), ('cwl_sheet_destination', 'confirmed_sequence'),
        ('fact_cwl_export_attempt', 'outcome'), ('fact_cwl_export_attempt', 'artifact_reference'),
        ('fact_cwl_export_attempt', 'error_code'), ('fact_cwl_export_attempt', 'completed_at'),
        ('cwl_plan_revision', 'published_at'), ('cwl_plan_revision', 'quality'),
        ('cwl_plan_revision', 'source_kind'), ('cwl_plan_revision', 'actor_user_key'),
        ('cwl_replan_request', 'completed_plan_key'), ('cwl_round_war_reference', 'war_key'),
        ('moderation_action', 'status'), ('moderation_action', 'attempts_remaining'),
        ('moderation_action', 'next_attempt_at'), ('moderation_action', 'lease_owner'),
        ('moderation_action', 'lease_expires_at'), ('moderation_action', 'claim_token'),
        ('moderation_action', 'cancelled_at'), ('moderation_action', 'trigger_warning_key'),
        ('moderation_action', 'decided_at'),
        ('notification_operation', 'status'), ('notification_operation', 'current_fence'),
        ('notification_operation', 'operation_kind'), ('notification_operation', 'remaining_seconds'),
        ('notification_operation', 'publication_state'), ('notification_operation', 'publication_fence'),
        ('notification_operation', 'publication_lease_expires_at'),
        ('notification_operation', 'publication_worker_key'),
        ('notification_report', 'discord_message_id'), ('notification_report', 'message_confirmed_at'),
        ('notification_report', 'latest_revision'), ('notification_role_target', 'generation'),
        ('guild_settings', 'new_joinee_days'), ('guild_settings', 'updated_at'),
        ('guild_settings', 'verification_max_age_seconds'), ('guild_settings', 'transfer_pending_max_age_seconds'),
        ('guild_settings', 'transfer_approval_max_age_seconds'), ('guild_settings', 'clan_games_enabled'),
        ('guild_settings', 'clan_games_start_day'), ('guild_settings', 'clan_games_start_time_utc'),
        ('guild_settings', 'clan_games_event_seconds'), ('guild_settings', 'clan_games_account_points_cap'),
        ('guild_settings', 'clan_games_refresh_seconds'),
        ('guild_settings', 'clan_games_checkpoint_tolerance_seconds'), ('guild_settings', 'kick_max_attempts'),
        ('guild_settings', 'kick_retry_seconds'), ('guild_settings', 'leaderboard_next_policy_key'),
        ('guild_settings', 'leaderboard_next_timezone_name'), ('guild_settings', 'leaderboard_policy_selected_at'),
        ('clan_collection_settings', 'enabled'), ('clan_collection_settings', 'membership_poll_seconds'),
        ('clan_collection_settings', 'war_poll_seconds'), ('clan_collection_settings', 'player_profile_seconds'),
        ('clan_collection_settings', 'cwl_group_poll_seconds'), ('clan_collection_settings', 'cwl_war_poll_seconds'),
        ('clan_collection_settings', 'raid_poll_seconds'),
        ('clan_collection_settings', 'raid_report_seconds'), ('clan_collection_settings', 'automatic_freeze_minutes'),
        ('clan_collection_settings', 'sheet_document_id'),
        ('role_binding', 'role_key'), ('chat_rank_role_binding', 'role_key'), ('channel_binding', 'channel_key')
    ), actual (table_name, column_name) AS (
        SELECT c.relname, '*' FROM pg_catalog.pg_class c, aclexplode(c.relacl) x
        WHERE c.relnamespace = guild_ns AND x.grantee = runtime AND x.privilege_type = 'UPDATE'
        UNION
        SELECT c.relname, a.attname FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped,
            aclexplode(a.attacl) x
        WHERE c.relnamespace = guild_ns AND x.grantee = runtime AND x.privilege_type = 'UPDATE'
    )
    SELECT string_agg(side || ' ' || table_name || '.' || column_name, ', ' ORDER BY table_name, column_name)
    INTO difference
    FROM (
        (SELECT 'missing', * FROM expected EXCEPT SELECT 'missing', * FROM actual)
        UNION ALL
        (SELECT 'extra', * FROM actual EXCEPT SELECT 'extra', * FROM expected)
    ) d (side, table_name, column_name);
    IF difference IS NOT NULL THEN
        RAISE EXCEPTION 'UPDATE grants differ from the grant policy: %', difference;
    END IF;

    WITH expected (table_name) AS (VALUES
        ('chat_member_rank_state'), ('discord_member_role'), ('discord_member_state'),
        ('notification_role_source_requirement'), ('role_binding'), ('channel_binding'),
        ('chat_rank_role_binding'), ('war_reminder_setting'), ('chat_xp_eligibility_role'),
        ('developer_allowlist')
    ), actual (table_name) AS (
        SELECT c.relname FROM pg_catalog.pg_class c
        WHERE c.relnamespace = guild_ns AND c.relkind = 'r' AND has_table_privilege(runtime, c.oid, 'DELETE')
    )
    SELECT string_agg(side || ' ' || table_name, ', ' ORDER BY table_name) INTO difference
    FROM (
        (SELECT 'missing', * FROM expected EXCEPT SELECT 'missing', * FROM actual)
        UNION ALL
        (SELECT 'extra', * FROM actual EXCEPT SELECT 'extra', * FROM expected)
    ) d (side, table_name);
    IF difference IS NOT NULL THEN
        RAISE EXCEPTION 'DELETE grants differ from the grant policy: %', difference;
    END IF;

    -- No UPDATE reaches a key, an identity or a generated column, outside the
    -- projections that the service rebuilds.
    SELECT string_agg(c.relname || '.' || a.attname, ', ' ORDER BY c.relname, a.attname) INTO difference
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE c.relnamespace = guild_ns AND c.relkind = 'r'
        AND c.relname NOT IN ('chat_member_rank_state', 'discord_member_role', 'discord_member_state')
        AND has_column_privilege(runtime, c.oid, a.attnum, 'UPDATE')
        AND (a.attidentity <> '' OR a.attgenerated <> ''
            OR EXISTS (SELECT FROM pg_catalog.pg_constraint k
                WHERE k.conrelid = c.oid AND k.contype = 'p' AND a.attnum = ANY (k.conkey))
            OR (c.relname LIKE 'dim\_%' AND EXISTS (SELECT FROM pg_catalog.pg_constraint k
                WHERE k.conrelid = c.oid AND k.contype = 'u' AND k.conkey = ARRAY[a.attnum])));
    IF difference IS NOT NULL THEN
        RAISE EXCEPTION 'An UPDATE grant reaches a key or an identity: %', difference;
    END IF;

    -- No sequence privilege: PostgreSQL does not check one for an identity
    -- column's default, so INSERT alone fills it (proved below).
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO difference
    FROM pg_catalog.pg_class c
    WHERE c.relnamespace = guild_ns AND c.relkind = 'S'
        AND (has_sequence_privilege(runtime, c.oid, 'USAGE') OR has_sequence_privilege(runtime, c.oid, 'SELECT')
            OR has_sequence_privilege(runtime, c.oid, 'UPDATE'));
    IF difference IS NOT NULL THEN
        RAISE EXCEPTION 'The runtime role holds a privilege on a sequence: %', difference;
    END IF;

    SET LOCAL ROLE guild_runtime;
    INSERT INTO guild.dim_achievement (source_name, village) VALUES ('Grant check', 'home');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'The runtime role could not fill an identity column without a sequence grant';
    END IF;

    -- The runtime role cannot update or delete a fact.
    FOR item IN
        SELECT c.relname, (SELECT a.attname FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                    AND a.attidentity = '' AND a.attgenerated = ''
                ORDER BY a.attnum LIMIT 1) AS probe_column
        FROM pg_catalog.pg_class c
        WHERE c.relnamespace = guild_ns AND c.relkind = 'r'
            AND (c.relname LIKE 'fact\_%' OR c.relname IN ('player_verification', 'war_participant', 'warning',
                'warning_revocation', 'clan_membership_poll', 'clan_games_counter_read',
                'clan_games_participation_evidence', 'clan_games_member_account_input', 'custom_roster_revision',
                'custom_roster_account', 'cwl_plan_assignment', 'notification_kafka_receipt', 'war_poll'))
        ORDER BY c.relname
    LOOP
        BEGIN
            EXECUTE format('UPDATE guild.%I SET %I = %I', item.relname, item.probe_column, item.probe_column);
            RAISE EXCEPTION 'The runtime role can update the fact %', item.relname;
        EXCEPTION WHEN insufficient_privilege THEN NULL;
        END;
        BEGIN
            EXECUTE format('DELETE FROM guild.%I', item.relname);
            RAISE EXCEPTION 'The runtime role can delete from the fact %', item.relname;
        EXCEPTION WHEN insufficient_privilege THEN NULL;
        END;
    END LOOP;
    RAISE NOTICE 'Runtime grant checks passed';
END;
$$;

ROLLBACK;
