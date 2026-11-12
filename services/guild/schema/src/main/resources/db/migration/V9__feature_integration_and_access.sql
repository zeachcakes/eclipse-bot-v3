-- Cross-feature projections, provenance, configuration change history, and curated runtime
-- entry points. Services still implement CoC/Kafka/gRPC/Discord I/O themselves.

CREATE FUNCTION guild.clan_games_assessment_scope(p_event bigint, p_checkpoint text)
RETURNS TABLE (event_key bigint, user_key bigint, player_key bigint,
    attribution_key bigint, checkpoint_at timestamptz, scope_starts_at timestamptz,
    scope_ends_at timestamptz, observed_seconds numeric, required_points numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF p_checkpoint IS NULL OR p_checkpoint NOT IN ('final', 't_minus_24h') THEN
        RAISE EXCEPTION 'A supported Clan Games checkpoint is required' USING ERRCODE = '22023';
    END IF;
    RETURN QUERY
    SELECT e.event_key, a.user_key, a.player_key, a.attribution_key,
        t.at, scope.scope_starts_at, scope.scope_ends_at,
        scope.observed_seconds, scope.required_points
    FROM guild.dim_clan_games_event e
    CROSS JOIN guild.metric_attribution_episode a
    CROSS JOIN LATERAL (SELECT CASE p_checkpoint WHEN 'final' THEN e.ends_at
        ELSE e.ends_at - interval '24 hours' END AS at) t
    CROSS JOIN LATERAL guild.clan_games_attributed_target(
        e.event_key, a.player_key, a.attribution_key, t.at) scope
    WHERE e.event_key = p_event AND scope.observed_seconds > 0;
END;
$$;
COMMENT ON FUNCTION guild.clan_games_assessment_scope IS
    'Trusted backend assessment-worker input, not an end-user history command. '
    'Provides only event-scoped attribution needed to write assessments without '
    'giving the application migration credentials or raw link-ledger access.';

CREATE VIEW guild.latest_player_town_hall AS
SELECT DISTINCT ON (player_key) player_key, town_hall_level, observed_at
FROM guild.fact_player_counter_observation
WHERE town_hall_level IS NOT NULL
ORDER BY player_key, observed_at DESC;

CREATE VIEW guild.desired_clan_member_role AS
SELECT DISTINCT l.user_key, b.role_key
FROM guild.current_account_link l
JOIN guild.discord_member_state s USING (user_key)
JOIN guild.current_observed_clan_member m USING (player_key)
JOIN guild.clan_collection_settings c USING (clan_key)
JOIN guild.clan_role_binding b USING (clan_key)
JOIN guild.dim_discord_role r USING (role_key)
WHERE s.is_present AND c.enabled AND b.purpose = 'member' AND r.deleted_at IS NULL;
COMMENT ON VIEW guild.desired_clan_member_role IS
    'Union across all current links; last supported open membership is retained '
    'through failed polls. A primary change alone does not remove an alt-derived role.';

CREATE VIEW guild.desired_town_hall_role AS
SELECT DISTINCT l.user_key, b.role_key
FROM guild.current_account_link l
JOIN guild.discord_member_state s USING (user_key)
JOIN guild.latest_player_town_hall p USING (player_key)
JOIN guild.town_hall_role_binding b USING (town_hall_level)
JOIN guild.dim_discord_role r USING (role_key)
WHERE s.is_present AND r.deleted_at IS NULL;
COMMENT ON VIEW guild.desired_town_hall_role IS
    'Every distinct supported TH across primary and alts; missing profile fields '
    'do not erase a previously observed TH. Source freshness remains explicit.';

ALTER TABLE guild.fact_role_change
    ADD COLUMN notification_operation_key uuid REFERENCES guild.notification_operation;
CREATE FUNCTION guild.validate_role_operation_provenance() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, guild, pg_temp AS $$
BEGIN
    IF NEW.notification_operation_key IS NOT NULL AND NOT EXISTS (
        SELECT FROM guild.notification_operation n
        JOIN guild.notification_role_generation_requirement r
            ON r.user_key = n.target_user_key
                AND r.generation = n.role_generation
        WHERE n.operation_key = NEW.notification_operation_key
            AND n.operation_kind = 'role_reconcile'
            AND n.target_user_key = NEW.user_key
            AND r.role_key = NEW.role_key AND r.is_desired = (NEW.change_kind = 'add')
    ) THEN
        RAISE EXCEPTION 'Confirmed role evidence must match its managed operation scope'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER role_operation_provenance BEFORE INSERT ON guild.fact_role_change
FOR EACH ROW EXECUTE FUNCTION guild.validate_role_operation_provenance();
COMMENT ON COLUMN guild.fact_role_change.notification_operation_key IS
    'Optional causal reference for an actually observed role change. A pending '
    'operation alone is not confirmation; unrelated gateway/manual events remain valid.';


-- Configuration change history. One trigger per configuration table, attached
-- after the last table exists. A Clan Games event is included because staff
-- can create one by hand; the trigger function records only those. No other
-- table is recorded: game and Discord activity is kept by its own fact tables.
-- Each trigger receives the table's primary-key columns in key order, so the
-- function needs no catalog lookup per row.
DO $$
DECLARE
    item record;
    configuration_tables text[] := ARRAY[
        'guild_settings', 'role_binding', 'channel_binding', 'clan_collection_settings',
        'war_reminder_setting', 'chat_xp_policy', 'developer_allowlist',
        'chat_xp_eligibility_role', 'chat_rank_role_binding',
        'leaderboard_calendar_policy', 'leaderboard_metric_definition',
        'dim_clan_games_event'];
BEGIN
    FOR item IN SELECT c.relname, (
            SELECT string_agg(quote_literal(a.attname), ', '
                ORDER BY array_position(i.indkey::smallint[], a.attnum))
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
            WHERE i.indrelid = c.oid AND i.indisprimary
        ) AS key_columns
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'guild' AND c.relkind IN ('r', 'p')
            AND c.relname = ANY (configuration_tables)
    LOOP
        EXECUTE format('CREATE TRIGGER record_configuration_change '
            || 'AFTER INSERT OR UPDATE OR DELETE ON guild.%I FOR EACH ROW '
            || 'EXECUTE FUNCTION guild.record_configuration_change(%s)',
            item.relname, item.key_columns);
    END LOOP;
    IF (SELECT count(*) FROM pg_catalog.pg_trigger t
        JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'guild' AND t.tgname = 'record_configuration_change')
        <> cardinality(configuration_tables) THEN
        RAISE EXCEPTION 'A configuration table is missing, so its changes would not be recorded';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Runtime access. This is the only place that grants anything to guild_runtime.
-- The SQL caller is the trusted backend. Collector writes are trusted ingestion,
-- not Discord command authorization: no grant below permits a raw write to
-- account links, verification, configuration, warnings, current-role
-- projections, or the configuration change history. Private ledgers are read
-- through the actor-aware entry points only.
-- ---------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA guild FROM PUBLIC, guild_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA guild FROM PUBLIC, guild_runtime;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA guild FROM PUBLIC, guild_runtime;
REVOKE ALL ON SCHEMA guild FROM PUBLIC, guild_runtime;
GRANT USAGE ON SCHEMA guild TO guild_runtime;

GRANT INSERT ON
    guild.clan_games_counter_read, guild.clan_games_participation_evidence,
    guild.clan_games_read_request, guild.clan_membership_poll, guild.cwl_plan_assignment,
    guild.cwl_round_war_reference, guild.dim_achievement, guild.dim_clan,
    guild.dim_discord_channel, guild.dim_discord_role, guild.dim_discord_user,
    guild.dim_player_account, guild.dim_raid_weekend, guild.dim_war,
    guild.fact_api_fetch_attempt, guild.fact_clan_games_account_assessment,
    guild.fact_clan_games_member_assessment, guild.fact_clan_games_progress,
    guild.fact_clan_membership_change,
    guild.fact_cwl_bench_incident, guild.fact_cwl_export_attempt,
    guild.fact_cwl_group_observation, guild.fact_cwl_registered_clan,
    guild.fact_cwl_registered_player, guild.fact_discord_membership_event,
    guild.fact_player_achievement_observation, guild.fact_player_counter_observation,
    guild.fact_raid_member_observation, guild.fact_role_change, guild.fact_war_attack,
    guild.fact_war_clan_observation, guild.fact_war_observation,
    guild.fact_war_roster_observation, guild.observed_clan_membership_period,
    guild.war_participant
TO guild_runtime;
GRANT SELECT ON
    guild.channel_binding, guild.chat_member_rank_state, guild.chat_rank_role_binding,
    guild.chat_rank_role_removal, guild.chat_rank_tier, guild.chat_xp_all_time_totals,
    guild.chat_xp_current_member_all_time, guild.chat_xp_eligibility_role,
    guild.chat_xp_monthly_leaderboard, guild.chat_xp_monthly_totals_utc, guild.chat_xp_policy,
    guild.clan_collection_settings, guild.clan_games_collection_policy,
    guild.clan_games_counter_read, guild.clan_games_counter_value,
    guild.clan_games_member_expected_account, guild.clan_games_participation_evidence,
    guild.clan_games_read_request, guild.clan_games_schedule, guild.clan_member_season_donation,
    guild.clan_membership_poll, guild.clan_role_binding, guild.current_account_link,
    guild.current_chat_xp_monthly_leaderboard, guild.current_clan_lifetime_war_stars,
    guild.current_clan_member_state,
    guild.current_cwl_signup, guild.current_observed_clan_member, guild.custom_event,
    guild.custom_event_signup, guild.custom_event_war, guild.custom_roster_account,
    guild.custom_roster_revision, guild.cwl_bench_assignment, guild.cwl_clan_day,
    guild.cwl_clan_settings, guild.cwl_cycle, guild.cwl_export_revision, guild.cwl_manual_pin,
    guild.cwl_participating_clan, guild.cwl_plan_assignment, guild.cwl_plan_day,
    guild.cwl_plan_revision, guild.cwl_replan_request, guild.cwl_round_war_reference,
    guild.cwl_signup, guild.desired_chat_rank_role, guild.desired_clan_member_role,
    guild.desired_town_hall_role, guild.dim_achievement, guild.dim_clan,
    guild.dim_clan_games_event, guild.dim_coc_season, guild.dim_discord_channel, guild.dim_discord_role,
    guild.dim_discord_user, guild.dim_guild, guild.dim_leaderboard_monthly_period,
    guild.dim_player_account, guild.dim_raid_weekend, guild.dim_war, guild.discord_member_role,
    guild.discord_member_state, guild.fact_api_fetch_attempt, guild.fact_clan_games_progress,
    guild.fact_clan_member_observation, guild.fact_clan_membership_change,
    guild.fact_cwl_bench_incident, guild.fact_cwl_bench_resolution,
    guild.fact_cwl_export_attempt, guild.fact_cwl_group_observation, guild.fact_cwl_plan_input,
    guild.fact_cwl_registered_clan, guild.fact_cwl_registered_player,
    guild.fact_cwl_signup_revision, guild.fact_discord_membership_event,
    guild.fact_notification_delivery_attempt, guild.fact_notification_dispatch_attempt,
    guild.fact_notification_dispatch_authorization, guild.fact_notification_dispatch_outcome,
    guild.fact_notification_publication_attempt, guild.fact_player_achievement_observation,
    guild.fact_player_counter_observation, guild.fact_raid_member_observation,
    guild.fact_role_change, guild.fact_war_attack, guild.fact_war_clan_observation,
    guild.fact_war_observation, guild.fact_war_roster_observation, guild.guild_settings,
    guild.latest_player_counter, guild.latest_player_town_hall, guild.latest_raid_member_total,
    guild.leaderboard_metric_definition, guild.notification_catchup_input,
    guild.notification_consumer_seen, guild.notification_cwl_context,
    guild.notification_dispatch_state, guild.notification_kafka_receipt,
    guild.notification_managed_role, guild.notification_operation, guild.notification_outbox,
    guild.notification_report, guild.notification_role_generation,
    guild.notification_role_generation_requirement, guild.notification_role_source_requirement,
    guild.notification_role_target, guild.observed_clan_membership_period,
    guild.pending_moderation_action, guild.public_clan_games_progress,
    guild.server_role_binding, guild.town_hall_role_binding, guild.war_participant,
    guild.war_reminder_setting
TO guild_runtime;
GRANT UPDATE ON
    guild.dim_clan, guild.dim_discord_channel, guild.dim_discord_role, guild.dim_discord_user,
    guild.dim_player_account, guild.fact_api_fetch_attempt, guild.fact_war_attack,
    guild.observed_clan_membership_period
TO guild_runtime;

-- Column-level grants: assessment keys only, and single workflow pointers.
GRANT SELECT (account_assessment_key) ON guild.fact_clan_games_account_assessment TO guild_runtime;
GRANT SELECT (member_assessment_key) ON guild.fact_clan_games_member_assessment TO guild_runtime;
GRANT UPDATE (war_key) ON guild.cwl_clan_day TO guild_runtime;
GRANT UPDATE (completed_plan_key) ON guild.cwl_replan_request TO guild_runtime;
GRANT UPDATE (war_key) ON guild.cwl_round_war_reference TO guild_runtime;

-- Identity sequences do not expose private row contents. Grant only the
-- sequences behind tables the runtime may INSERT into; definer functions own
-- the others. This is derived from the INSERT grants above.
DO $$
DECLARE item record;
BEGIN
    FOR item IN SELECT c.relname, a.attname FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attidentity <> ''
        WHERE n.nspname = 'guild' AND has_table_privilege('guild_runtime', c.oid, 'INSERT')
    LOOP
        EXECUTE format('GRANT USAGE ON SEQUENCE %s TO guild_runtime',
            pg_get_serial_sequence(format('guild.%I', item.relname), item.attname));
    END LOOP;
END;
$$;

-- Named backend entry points, with their signatures. Trigger functions and
-- internal helpers stay owner-only.
GRANT EXECUTE ON FUNCTION
    guild.account_link_history_for(bigint, bigint),
    guild.attach_clan_games_member_input(bigint, bigint),
    guild.begin_notification_send(uuid, uuid),
    guild.can_configure(bigint),
    guild.can_manage_links(bigint),
    guild.can_moderate(bigint),
    guild.claim_moderation_action(bigint, text, integer),
    guild.claim_notification_dispatch(uuid, text, integer),
    guild.claim_notification_publication(uuid, text, integer),
    guild.clan_games_assessment_scope(bigint, text),
    guild.clan_games_observed_target(bigint, bigint, timestamp with time zone),
    guild.clan_games_results_for(bigint, bigint),
    guild.close_missed_clan_games_reads(bigint, timestamp with time zone),
    guild.coalesce_missed_war_reminders(bigint, bigint),
    guild.configuration_audit_for(bigint),
    guild.create_manual_clan_games(bigint, timestamp with time zone, timestamp with time zone, integer, text, text),
    guild.create_scheduled_clan_games(integer, integer),
    guild.credit_chat_xp(bigint, bigint, guild.discord_snowflake, timestamp with time zone),
    guild.custom_event_complete(bigint, uuid, bigint, text),
    guild.custom_event_create(bigint, uuid, text),
    guild.custom_event_result(bigint, uuid, bigint, bigint, text),
    guild.custom_event_roster(bigint, uuid, bigint, bigint[], text),
    guild.custom_event_signup(bigint, uuid, bigint, bigint, boolean),
    guild.cwl_assign_bench(bigint),
    guild.cwl_begin_plan(bigint, text, text),
    guild.cwl_close_signups(bigint),
    guild.cwl_create_cycle(bigint, uuid, date),
    guild.cwl_end_cycle(bigint, timestamp with time zone),
    guild.cwl_manual_plan(bigint, uuid, bigint, text),
    guild.cwl_override_bench(bigint, uuid, bigint, text),
    guild.cwl_pin(bigint, uuid, bigint, integer, integer, bigint, text),
    guild.cwl_publish_plan(bigint, boolean),
    guild.cwl_record_bench_service(bigint, smallint),
    guild.cwl_select_clan(bigint, uuid, bigint, bigint, integer),
    guild.cwl_set_assignment(bigint, uuid, bigint, integer, integer, bigint),
    guild.cwl_signup(bigint, uuid, bigint, bigint, integer[], integer, boolean),
    guild.cwl_unpin(bigint, uuid, bigint, integer, integer, text),
    guild.decide_account_transfer(bigint, bigint, boolean, timestamp with time zone),
    guild.delete_channel_binding(bigint, text, bigint, integer, text),
    guild.delete_chat_rank_role(bigint, integer, text),
    guild.delete_chat_xp_eligibility_role(bigint, bigint, text),
    guild.delete_clan_role(bigint, bigint, text, text),
    guild.delete_server_role(bigint, text, text),
    guild.delete_town_hall_role(bigint, integer, text),
    guild.delete_war_reminder(bigint, bigint, integer, text),
    guild.ensure_coc_season(timestamp with time zone),
    guild.ensure_leaderboard_monthly_period(timestamp with time zone),
    guild.expire_account_transfers(timestamp with time zone),
    guild.finish_notification_publication(uuid, uuid, text, text, integer, bigint, text),
    guild.has_bound_role(bigint, text[]),
    guild.is_developer(bigint),
    guild.issue_warning(bigint, bigint, text, timestamp with time zone),
    guild.issue_warning_command(uuid, bigint, bigint, text, timestamp with time zone),
    guild.link_player_account(bigint, bigint, bigint, boolean, bigint, timestamp with time zone),
    guild.manage_developer(bigint, bigint, boolean, text),
    guild.moderation_history(bigint, bigint),
    guild.queue_clan_games_reads(bigint, bigint),
    guild.queue_cwl_leadership_prompt(bigint, timestamp with time zone, timestamp with time zone),
    guild.queue_cwl_roster_report(bigint, smallint),
    guild.queue_notification_ping(text, text, bigint, timestamp with time zone, timestamp with time zone, text),
    guild.queue_notification_report(uuid, text, timestamp with time zone),
    guild.record_clan_member_observation(bigint, bigint, text, bigint, bigint),
    guild.record_manual_moderation_action(guild.discord_snowflake, text, bigint, bigint, timestamp with time zone, text, timestamp with time zone),
    guild.record_moderation_attempt(bigint, uuid, text, integer, text, timestamp with time zone),
    guild.record_notification_consumption(uuid, text, text, integer, bigint),
    guild.record_notification_report_message(uuid, guild.discord_snowflake),
    guild.record_notification_report_missing(uuid, uuid),
    guild.record_notification_result(uuid, uuid, text, guild.discord_snowflake, integer, text),
    guild.record_player_verification(bigint, bigint, text, bigint),
    guild.register_notification_report(text, text, bigint, text),
    guild.request_account_transfer(bigint, bigint, bigint, timestamp with time zone),
    guild.request_player_refresh(bigint, bigint, text),
    guild.revoke_warning(bigint, bigint, text, timestamp with time zone),
    guild.revoke_warning_command(uuid, bigint, bigint, text, timestamp with time zone),
    guild.schedule_war_reminders(bigint, bigint),
    guild.set_channel_binding(bigint, text, bigint, integer, bigint, text),
    guild.set_chat_rank_role(bigint, integer, bigint, text),
    guild.set_chat_xp_eligibility_role(bigint, bigint, text),
    guild.set_clan_collection(bigint, bigint, boolean, integer, integer, text),
    guild.set_clan_games_refresh(bigint, integer, text),
    guild.set_clan_games_schedule(bigint, boolean, integer, time without time zone, integer, integer, text),
    guild.set_clan_role(bigint, bigint, text, bigint, text),
    guild.set_cwl_clan_settings(bigint, bigint, integer, text, text),
    guild.set_kick_policy(bigint, integer, integer, text),
    guild.set_leaderboard_timezone(bigint, text, text, uuid),
    guild.set_new_joinee_days(bigint, integer, text),
    guild.set_notification_desired_roles(bigint, bigint[], text),
    guild.set_primary_account(bigint, bigint),
    guild.set_server_role(bigint, text, bigint, text),
    guild.set_town_hall_role(bigint, integer, bigint, text),
    guild.set_transfer_policy(bigint, integer, integer, text),
    guild.set_verification_policy(bigint, integer, text),
    guild.set_war_reminder(bigint, bigint, integer, text),
    guild.unlink_player_account(bigint, bigint, bigint, timestamp with time zone),
    guild.warning_history(bigint, bigint)
TO guild_runtime;
