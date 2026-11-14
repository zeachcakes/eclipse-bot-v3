-- Cross-feature views and every runtime grant.

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
COMMENT ON COLUMN guild.fact_role_change.notification_operation_key IS
    'Optional causal reference for an actually observed role change. A pending '
    'operation alone is not confirmation; unrelated gateway/manual events remain valid.';

-- ---------------------------------------------------------------------------
-- Runtime access. This is the only place that grants anything to guild_runtime,
-- the role of the guild service. The service reads every table and view, and
-- its permission checks protect the private histories (ADR 0012).
--
-- Facts are append-only: INSERT, and UPDATE only on named columns that a later
-- step fills in. Configuration, workflow, bridge and projection tables get the
-- writes the service makes, per table and column. No UPDATE grant reaches an
-- identity, a key or a measure. Reference data has no write grant. No sequence
-- is granted: PostgreSQL does not check sequence privileges for an identity
-- column's default, so INSERT alone fills it.
-- ---------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA guild FROM PUBLIC, guild_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA guild FROM PUBLIC, guild_runtime;
REVOKE ALL ON SCHEMA guild FROM PUBLIC, guild_runtime;
GRANT USAGE ON SCHEMA guild TO guild_runtime;

-- Every table and view, by name, so that the Flyway history stays private.
GRANT SELECT ON
    guild.account_link, guild.account_transfer_request, guild.active_warning_counts,
    guild.activity_command_operation, guild.channel_binding, guild.chat_member_rank_state,
    guild.chat_rank_role_binding, guild.chat_rank_role_removal, guild.chat_rank_tier,
    guild.chat_xp_all_time_totals, guild.chat_xp_current_member_all_time,
    guild.chat_xp_eligibility_role, guild.chat_xp_monthly_leaderboard,
    guild.chat_xp_monthly_totals_utc, guild.chat_xp_policy, guild.clan_collection_settings,
    guild.clan_games_collection_policy, guild.clan_games_counter_read,
    guild.clan_games_counter_value, guild.clan_games_member_account_input,
    guild.clan_games_member_expected_account, guild.clan_games_member_result,
    guild.clan_games_participation_evidence, guild.clan_games_read_request,
    guild.clan_games_schedule, guild.clan_member_season_donation, guild.clan_membership_poll,
    guild.clan_role_binding, guild.confirmed_moderation_kick, guild.current_account_link,
    guild.current_chat_xp_monthly_leaderboard, guild.current_clan_lifetime_war_stars,
    guild.current_clan_member_state, guild.current_custom_event_signup,
    guild.current_cwl_manual_pin, guild.current_cwl_participation, guild.current_cwl_signup,
    guild.current_observed_clan_member,
    guild.custom_event, guild.custom_event_signup, guild.custom_event_war,
    guild.custom_roster_account, guild.custom_roster_revision, guild.cwl_bench_assignment,
    guild.cwl_clan_day, guild.cwl_clan_settings, guild.cwl_cycle, guild.cwl_export_revision,
    guild.cwl_export_signup_input, guild.cwl_sheet_destination,
    guild.cwl_participating_clan, guild.cwl_plan_assignment, guild.cwl_plan_day,
    guild.cwl_plan_revision, guild.cwl_replan_request, guild.cwl_round_war_reference,
    guild.cwl_signup, guild.desired_chat_rank_role, guild.desired_clan_member_role,
    guild.desired_town_hall_role, guild.developer_allowlist, guild.dim_achievement,
    guild.dim_clan, guild.dim_clan_games_event, guild.dim_coc_season, guild.dim_discord_channel,
    guild.dim_discord_role, guild.dim_discord_user, guild.dim_guild,
    guild.dim_leaderboard_monthly_period, guild.dim_player_account, guild.dim_raid_weekend,
    guild.dim_war, guild.discord_member_role, guild.discord_member_state,
    guild.fact_api_fetch_attempt, guild.fact_chat_rank_change, guild.fact_chat_xp_award,
    guild.fact_chat_xp_decision, guild.fact_clan_games_account_assessment,
    guild.fact_clan_games_member_assessment, guild.fact_clan_games_progress,
    guild.fact_clan_member_observation, guild.fact_clan_membership_change,
    guild.fact_configuration_change, guild.fact_custom_event_signup_revision,
    guild.fact_cwl_bench_incident, guild.fact_cwl_bench_resolution, guild.fact_cwl_day_freeze,
    guild.fact_cwl_export_attempt, guild.fact_cwl_group_observation,
    guild.fact_cwl_manual_pin_revision, guild.fact_cwl_participation_revision,
    guild.fact_cwl_plan_input, guild.fact_cwl_registered_clan, guild.fact_cwl_registered_player,
    guild.fact_cwl_signup_revision, guild.fact_discord_accepted_join,
    guild.fact_discord_membership_event, guild.fact_manual_moderation_action,
    guild.fact_moderation_action_attempt, guild.fact_moderation_action_transition,
    guild.fact_moderation_attempt_resolution, guild.fact_moderation_event,
    guild.fact_moderation_notice, guild.fact_notification_delivery_attempt,
    guild.fact_notification_dispatch_attempt, guild.fact_notification_dispatch_authorization,
    guild.fact_notification_disposition,
    guild.fact_notification_dispatch_outcome, guild.fact_notification_publication_attempt,
    guild.fact_player_achievement_observation, guild.fact_player_counter_observation,
    guild.fact_primary_account_change, guild.fact_raid_member_observation,
    guild.fact_raid_weekend_observation, guild.raid_poll, guild.raid_weekend_coverage,
    guild.fact_role_change, guild.fact_war_attack, guild.fact_war_clan_observation,
    guild.fact_war_observation, guild.fact_war_roster_observation, guild.fact_warning_event,
    guild.guild_settings, guild.latest_clan_games_progress, guild.latest_player_counter,
    guild.latest_player_town_hall, guild.latest_raid_member_total,
    guild.leaderboard_calendar_policy, guild.leaderboard_calendar_state,
    guild.leaderboard_metric_definition, guild.metric_attribution_episode,
    guild.moderation_action, guild.notification_catchup_input,
    guild.notification_clan_games_report_assessment,
    guild.notification_clan_games_report_context, guild.notification_clan_games_report_progress,
    guild.notification_consumer_seen,
    guild.notification_cwl_context, guild.notification_cwl_signups_context,
    guild.notification_dispatch_state,
    guild.notification_kafka_receipt, guild.notification_managed_role,
    guild.notification_mention_role, guild.notification_mention_user,
    guild.notification_moderation_context, guild.notification_operation,
    guild.notification_outbox, guild.notification_raid_report_context,
    guild.notification_raid_start_context, guild.notification_report,
    guild.notification_role_generation, guild.notification_role_generation_requirement,
    guild.notification_role_source_requirement, guild.notification_role_target,
    guild.observed_clan_membership_period, guild.pending_moderation_action,
    guild.player_verification, guild.public_clan_games_progress, guild.role_binding,
    guild.server_role_binding, guild.town_hall_role_binding, guild.war_participant,
    guild.war_poll, guild.war_reminder_setting, guild.warning, guild.warning_revocation
TO guild_runtime;

-- Dimensions. Labels and sync columns change; identities do not. The operator
-- seeds dim_guild. A war becomes custom when staff attach it to a custom event.
GRANT INSERT ON
    guild.dim_achievement, guild.dim_clan, guild.dim_clan_games_event, guild.dim_coc_season,
    guild.dim_discord_channel, guild.dim_discord_role, guild.dim_discord_user,
    guild.dim_leaderboard_monthly_period, guild.dim_player_account, guild.dim_raid_weekend,
    guild.dim_war
TO guild_runtime;
GRANT UPDATE (display_name) ON guild.dim_discord_user TO guild_runtime;
GRANT UPDATE (player_name) ON guild.dim_player_account TO guild_runtime;
GRANT UPDATE (clan_name) ON guild.dim_clan TO guild_runtime;
GRANT UPDATE (role_name, last_synced_at, deleted_at) ON guild.dim_discord_role TO guild_runtime;
GRANT UPDATE (channel_name, last_synced_at, deleted_at) ON guild.dim_discord_channel TO guild_runtime;
GRANT UPDATE (war_kind) ON guild.dim_war TO guild_runtime;

-- Facts and other append-only records.
GRANT INSERT ON
    guild.clan_games_counter_read, guild.clan_games_member_account_input,
    guild.clan_games_participation_evidence, guild.clan_membership_poll,
    guild.custom_roster_account, guild.custom_roster_revision, guild.cwl_plan_assignment,
    guild.fact_api_fetch_attempt, guild.fact_chat_rank_change, guild.fact_chat_xp_decision,
    guild.fact_clan_games_account_assessment, guild.fact_clan_games_member_assessment,
    guild.fact_clan_games_progress, guild.fact_clan_member_observation,
    guild.fact_clan_membership_change, guild.fact_configuration_change,
    guild.fact_custom_event_signup_revision, guild.fact_cwl_bench_incident,
    guild.fact_cwl_bench_resolution, guild.fact_cwl_day_freeze, guild.fact_cwl_export_attempt,
    guild.fact_cwl_group_observation, guild.fact_cwl_manual_pin_revision,
    guild.fact_cwl_participation_revision, guild.fact_cwl_plan_input,
    guild.fact_cwl_registered_clan, guild.fact_cwl_registered_player,
    guild.fact_cwl_signup_revision, guild.fact_discord_accepted_join,
    guild.fact_discord_membership_event, guild.fact_manual_moderation_action,
    guild.fact_moderation_action_attempt, guild.fact_moderation_action_transition,
    guild.fact_moderation_attempt_resolution, guild.fact_moderation_notice,
    guild.fact_notification_dispatch_attempt, guild.fact_notification_disposition,
    guild.fact_notification_publication_attempt,
    guild.fact_player_achievement_observation, guild.fact_player_counter_observation,
    guild.fact_primary_account_change, guild.fact_raid_member_observation,
    guild.fact_raid_weekend_observation, guild.raid_poll,
    guild.fact_role_change, guild.fact_war_attack, guild.fact_war_clan_observation,
    guild.fact_war_observation, guild.fact_war_roster_observation,
    guild.notification_kafka_receipt, guild.player_verification, guild.war_participant,
    guild.war_poll, guild.warning, guild.warning_revocation
TO guild_runtime;
-- Columns that a later step fills in. The service sets each of them once,
-- except the last observation time of an attack.
GRANT UPDATE (completed_at, http_status, outcome, error_code)
    ON guild.fact_api_fetch_attempt TO guild_runtime;
GRANT UPDATE (last_observed_at) ON guild.fact_war_attack TO guild_runtime;
GRANT UPDATE (started_at, attempted_at, recorded_at, outcome, http_status, diagnostic_code)
    ON guild.fact_moderation_action_attempt TO guild_runtime;
GRANT UPDATE (started_at, finished_at, outcome, recorded_at, discord_message_id, http_status,
        error_code)
    ON guild.fact_notification_dispatch_attempt TO guild_runtime;
GRANT UPDATE (account_assessment_key) ON guild.clan_games_member_account_input TO guild_runtime;

-- Temporal bridges: an interval closes, and a link changes its primary flag.
GRANT INSERT ON
    guild.account_link, guild.metric_attribution_episode, guild.observed_clan_membership_period
TO guild_runtime;
GRANT UPDATE (unlinked_at, is_primary) ON guild.account_link TO guild_runtime;
GRANT UPDATE (closed_at) ON guild.metric_attribution_episode TO guild_runtime;
GRANT UPDATE (observed_until, confirmed_through, last_poll_key, coverage_status)
    ON guild.observed_clan_membership_period TO guild_runtime;

-- Current-state projections, rebuilt from their facts.
GRANT INSERT, UPDATE, DELETE ON
    guild.chat_member_rank_state, guild.discord_member_role, guild.discord_member_state
TO guild_runtime;

-- Workflow records.
GRANT INSERT ON
    guild.account_transfer_request, guild.activity_command_operation,
    guild.clan_games_read_request, guild.custom_event, guild.custom_event_signup,
    guild.cwl_bench_assignment, guild.cwl_clan_day, guild.cwl_cycle, guild.cwl_export_revision,
    guild.cwl_export_signup_input, guild.cwl_sheet_destination, guild.cwl_participating_clan, guild.cwl_plan_revision, guild.cwl_replan_request,
    guild.cwl_round_war_reference, guild.cwl_signup, guild.moderation_action
TO guild_runtime;
GRANT UPDATE (status, decided_by, decided_at, consumed_at, cancelled_at, expired_at)
    ON guild.account_transfer_request TO guild_runtime;
GRANT UPDATE (result_key) ON guild.activity_command_operation TO guild_runtime;
GRANT UPDATE (due_at, collect_from, status, missed_at) ON guild.clan_games_read_request TO guild_runtime;
GRANT UPDATE (state, war_key, associated_by, association_operation_id, association_reason)
    ON guild.custom_event TO guild_runtime;
GRANT UPDATE (war_day, assigned_at) ON guild.cwl_bench_assignment TO guild_runtime;
GRANT UPDATE (war_key) ON guild.cwl_clan_day TO guild_runtime;
GRANT UPDATE (state, ended_at) ON guild.cwl_cycle TO guild_runtime;
GRANT UPDATE (sheets_state) ON guild.cwl_export_revision TO guild_runtime;
GRANT UPDATE (lease_owner, lease_expires_at, fence, confirmed_sequence)
    ON guild.cwl_sheet_destination TO guild_runtime;
-- A Sheets attempt's result is completed once after the write (SR-CWL-17).
GRANT UPDATE (outcome, artifact_reference, error_code, completed_at)
    ON guild.fact_cwl_export_attempt TO guild_runtime;
GRANT UPDATE (published_at, quality, source_kind, actor_user_key)
    ON guild.cwl_plan_revision TO guild_runtime;
GRANT UPDATE (completed_plan_key) ON guild.cwl_replan_request TO guild_runtime;
GRANT UPDATE (war_key) ON guild.cwl_round_war_reference TO guild_runtime;
GRANT UPDATE (status, attempts_remaining, next_attempt_at, lease_owner, lease_expires_at,
        claim_token, cancelled_at, trigger_warning_key, decided_at)
    ON guild.moderation_action TO guild_runtime;

-- Notification delivery.
GRANT INSERT ON
    guild.notification_catchup_input, guild.notification_clan_games_report_assessment,
    guild.notification_clan_games_report_context, guild.notification_clan_games_report_progress,
    guild.notification_cwl_context, guild.notification_cwl_signups_context,
    guild.notification_managed_role, guild.notification_mention_role,
    guild.notification_mention_user, guild.notification_moderation_context,
    guild.notification_operation, guild.notification_raid_report_context,
    guild.notification_raid_start_context, guild.notification_report,
    guild.notification_role_generation, guild.notification_role_generation_requirement,
    guild.notification_role_source_requirement, guild.notification_role_target
TO guild_runtime;
GRANT UPDATE (status, current_fence, operation_kind, remaining_seconds, publication_state,
        publication_fence, publication_lease_expires_at, publication_worker_key)
    ON guild.notification_operation TO guild_runtime;
GRANT UPDATE (discord_message_id, message_confirmed_at, latest_revision)
    ON guild.notification_report TO guild_runtime;
GRANT UPDATE (generation) ON guild.notification_role_target TO guild_runtime;
GRANT DELETE ON guild.notification_role_source_requirement TO guild_runtime;

-- Configuration. Settings rows are never deleted; a tracked clan is switched
-- off with enabled = false. The XP policy key has no command.
GRANT INSERT ON
    guild.channel_binding, guild.chat_rank_role_binding, guild.chat_xp_eligibility_role,
    guild.clan_collection_settings, guild.developer_allowlist, guild.guild_settings,
    guild.leaderboard_calendar_policy, guild.role_binding, guild.war_reminder_setting
TO guild_runtime;
GRANT UPDATE (new_joinee_days, updated_at, verification_max_age_seconds,
        transfer_pending_max_age_seconds, transfer_approval_max_age_seconds,
        clan_games_enabled, clan_games_start_day, clan_games_start_time_utc,
        clan_games_event_seconds, clan_games_account_points_cap, clan_games_refresh_seconds,
        clan_games_checkpoint_tolerance_seconds, kick_max_attempts, kick_retry_seconds,
        leaderboard_next_policy_key, leaderboard_next_timezone_name, leaderboard_policy_selected_at)
    ON guild.guild_settings TO guild_runtime;
GRANT UPDATE (enabled, membership_poll_seconds, war_poll_seconds, player_profile_seconds,
        cwl_group_poll_seconds, cwl_war_poll_seconds, raid_poll_seconds, raid_report_seconds,
        automatic_freeze_minutes, sheet_document_id)
    ON guild.clan_collection_settings TO guild_runtime;
GRANT UPDATE (role_key) ON guild.role_binding, guild.chat_rank_role_binding TO guild_runtime;
GRANT UPDATE (channel_key) ON guild.channel_binding TO guild_runtime;
GRANT DELETE ON
    guild.channel_binding, guild.chat_rank_role_binding, guild.chat_xp_eligibility_role,
    guild.developer_allowlist, guild.role_binding, guild.war_reminder_setting
TO guild_runtime;
