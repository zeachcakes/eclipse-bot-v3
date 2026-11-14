# Guild SQL reference map

Companion to the [rule catalog](guild-service-rules.md). Until commit
`c407abb`, tagged `guild-sql-reference`, the guild migrations enforced the
business rules in PL/pgSQL, and 16 SQL test files checked them. This file maps
that code to the rules of the catalog, so that nothing is lost while the guild
service takes the rules over:

- [Functions and triggers](#functions-and-triggers): every function and
  trigger of the reference, with the rule that carries its behaviour.
- [Checks of the SQL tests](#checks-of-the-sql-tests): every check of the
  reference tests, to port to a Java test or to drop with a reason.

Read a function with
`git show guild-sql-reference:services/guild/schema/src/main/resources/db/migration/V2__account_links.sql`,
and a test with
`git show guild-sql-reference:services/guild/schema/src/test/sql/020_account_links.sql`.
The **File** and **Line** columns name the migration and the line at that
commit.

This file shrinks as the service grows. When a workstream of the
[working plan](star-schema-working-plan.md#service-workstreams) is done,
delete the rows and checks that it ported. Delete the file when it is empty.

## Functions and triggers

Every function and trigger that `V1` to `V9` had at `c407abb`. The migrations
no longer contain any of them. A row is done when the service implements its
rule, or when a grant or a constraint replaced it.

### Functions (169)

| File | Line | Function | Kind | Rule |
| --- | --- | --- | --- | --- |
| V1 | 124 | `is_developer` | SQL function | [SR-AUTH-02](guild-service-rules.md#sr-auth-02-developer) |
| V1 | 131 | `has_bound_role` | PL/pgSQL function | [SR-AUTH-03](guild-service-rules.md#sr-auth-03-held-role) |
| V1 | 147 | `can_configure` | SQL function | [SR-AUTH-04](guild-service-rules.md#sr-auth-04-capabilities) |
| V1 | 152 | `can_moderate` | SQL function | [SR-AUTH-04](guild-service-rules.md#sr-auth-04-capabilities) |
| V1 | 157 | `can_manage_links` | SQL function | [SR-AUTH-04](guild-service-rules.md#sr-auth-04-capabilities) |
| V2 | 23 | `require_recent_verification` | PL/pgSQL function | [SR-ACC-03](guild-service-rules.md#sr-acc-03-recent-verification) |
| V2 | 155 | `account_transfer_expires_at` | PL/pgSQL function | [SR-ACC-06](guild-service-rules.md#sr-acc-06-transfer-limits) |
| V2 | 188 | `_expire_account_transfers` | PL/pgSQL function | [SR-ACC-07](guild-service-rules.md#sr-acc-07-expire-transfers) |
| V2 | 204 | `expire_account_transfers` | PL/pgSQL function | [SR-ACC-07](guild-service-rules.md#sr-acc-07-expire-transfers) |
| V2 | 224 | `cancel_open_account_transfers` | PL/pgSQL function | [SR-ACC-12](guild-service-rules.md#sr-acc-12-cancel-the-open-requests-of-an-ended-link) |
| V2 | 250 | `require_one_primary_account` | trigger function | [SR-ACC-13](guild-service-rules.md#sr-acc-13-exactly-one-primary) |
| V2 | 283 | `request_account_transfer` | PL/pgSQL function | [SR-ACC-04](guild-service-rules.md#sr-acc-04-request-a-transfer) |
| V2 | 322 | `decide_account_transfer` | PL/pgSQL function | [SR-ACC-05](guild-service-rules.md#sr-acc-05-decide-a-transfer) |
| V2 | 364 | `link_player_account` | PL/pgSQL function | [SR-ACC-09](guild-service-rules.md#sr-acc-09-link-an-account) |
| V2 | 502 | `set_primary_account` | PL/pgSQL function | [SR-ACC-10](guild-service-rules.md#sr-acc-10-choose-the-primary-account) |
| V2 | 525 | `unlink_player_account` | PL/pgSQL function | [SR-ACC-11](guild-service-rules.md#sr-acc-11-unlink-an-account) |
| V2 | 579 | `account_link_history_for` | PL/pgSQL function | [SR-ACC-14](guild-service-rules.md#sr-acc-14-link-history) |
| V3 | 56 | `require_complete_membership_poll` | trigger function | [SR-MEM-02](guild-service-rules.md#sr-mem-02-joins-and-departures) |
| V3 | 95 | `validate_membership_period_evidence` | trigger function | [SR-MEM-03](guild-service-rules.md#sr-mem-03-membership-periods) |
| V3 | 121 | `membership_has_closing_evidence` | SQL function | [SR-MEM-03](guild-service-rules.md#sr-mem-03-membership-periods) |
| V3 | 136 | `require_membership_closing_evidence` | trigger function | [SR-MEM-03](guild-service-rules.md#sr-mem-03-membership-periods) |
| V3 | 176 | `is_currently_tracked_player` | SQL function | [SR-MEM-04](guild-service-rules.md#sr-mem-04-currently-tracked-account) |
| V3 | 202 | `coc_season_end` | SQL function | [SR-MEM-06](guild-service-rules.md#sr-mem-06-seasons) |
| V3 | 210 | `ensure_coc_season` | PL/pgSQL function | [SR-MEM-06](guild-service-rules.md#sr-mem-06-seasons) |
| V3 | 243 | `record_clan_member_observation` | PL/pgSQL function | [SR-MEM-05](guild-service-rules.md#sr-mem-05-member-list-store-on-change) |
| V3 | 365 | `require_war_side` | trigger function | [SR-WAR-02](guild-service-rules.md#sr-war-02-participants-and-clan-observations) |
| V3 | 426 | `require_opposing_war_accounts` | trigger function | [SR-WAR-03](guild-service-rules.md#sr-war-03-attacks) |
| V3 | 515 | `create_scheduled_clan_games` | PL/pgSQL function | [SR-CG-01](guild-service-rules.md#sr-cg-01-scheduled-events) |
| V3 | 541 | `create_manual_clan_games` | PL/pgSQL function | [SR-CG-02](guild-service-rules.md#sr-cg-02-manual-events) |
| V3 | 594 | `clan_games_observed_target` | SQL function | [SR-CG-03](guild-service-rules.md#sr-cg-03-requirement-targets) |
| V3 | 643 | `validate_clan_games_read_request` | trigger function | [SR-CG-04](guild-service-rules.md#sr-cg-04-read-requests) |
| V3 | 686 | `queue_clan_games_reads` | PL/pgSQL function | [SR-CG-05](guild-service-rules.md#sr-cg-05-queue-reads) |
| V3 | 765 | `validate_clan_games_counter_read` | trigger function | [SR-CG-06](guild-service-rules.md#sr-cg-06-counter-reads) |
| V3 | 809 | `complete_clan_games_read_request` | trigger function | [SR-CG-07](guild-service-rules.md#sr-cg-07-complete-and-close-reads) |
| V3 | 825 | `close_missed_clan_games_reads` | PL/pgSQL function | [SR-CG-07](guild-service-rules.md#sr-cg-07-complete-and-close-reads) |
| V3 | 876 | `clan_games_transfer_wait_until` | SQL function | [SR-ACC-06](guild-service-rules.md#sr-acc-06-transfer-limits) |
| V3 | 890 | `ensure_clan_games_transfer_read` | PL/pgSQL function | [SR-ACC-09](guild-service-rules.md#sr-acc-09-link-an-account) |
| V3 | 931 | `infer_clan_games_participation` | trigger function | [SR-CG-08](guild-service-rules.md#sr-cg-08-participating-clan-inference) |
| V3 | 987 | `clan_games_attributed_target` | SQL function | [SR-CG-03](guild-service-rules.md#sr-cg-03-requirement-targets) |
| V3 | 1048 | `validate_clan_games_progress` | trigger function | [SR-CG-09](guild-service-rules.md#sr-cg-09-progress) |
| V3 | 1140 | `validate_clan_games_assessment` | trigger function | [SR-CG-10](guild-service-rules.md#sr-cg-10-account-assessments) |
| V3 | 1258 | `capture_clan_games_member_scope` | trigger function | [SR-CG-11](guild-service-rules.md#sr-cg-11-member-assessments) |
| V3 | 1283 | `validate_clan_games_member_input` | trigger function | [SR-CG-11](guild-service-rules.md#sr-cg-11-member-assessments) |
| V3 | 1316 | `attach_clan_games_member_input` | PL/pgSQL function | [SR-CG-11](guild-service-rules.md#sr-cg-11-member-assessments) |
| V4 | 6 | `discord_reject_history_mutation` | trigger function | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 40 | `capture_discord_join_policy` | trigger function | [SR-DSC-01](guild-service-rules.md#sr-dsc-01-membership-events) |
| V4 | 58 | `project_discord_membership` | trigger function | [SR-DSC-02](guild-service-rules.md#sr-dsc-02-presence-projection) |
| V4 | 137 | `project_discord_role` | trigger function | [SR-DSC-03](guild-service-rules.md#sr-dsc-03-held-role-projection) |
| V4 | 287 | `sample_chat_xp` | PL/pgSQL function | [SR-XP-02](guild-service-rules.md#sr-xp-02-sampling) |
| V4 | 299 | `enforce_chat_xp_policy` | trigger function | [SR-XP-03](guild-service-rules.md#sr-xp-03-credit-a-message) |
| V4 | 321 | `credit_chat_xp` | PL/pgSQL function | [SR-XP-03](guild-service-rules.md#sr-xp-03-credit-a-message) |
| V4 | 410 | `project_chat_rank` | trigger function | [SR-XP-04](guild-service-rules.md#sr-xp-04-ranks) |
| V4 | 659 | `validate_moderation_notice` | trigger function | [SR-MOD-13](guild-service-rules.md#sr-mod-13-rejoin-notices) |
| V4 | 710 | `record_moderation_rejoin_notices` | PL/pgSQL function | [SR-MOD-13](guild-service-rules.md#sr-mod-13-rejoin-notices) |
| V4 | 788 | `record_manual_moderation_action` | PL/pgSQL function | [SR-MOD-12](guild-service-rules.md#sr-mod-12-manual-moderation-from-the-audit-log) |
| V4 | 824 | `record_accepted_join_moderation_notice` | trigger function | [SR-DSC-05](guild-service-rules.md#sr-dsc-05-accepted-joins) |
| V4 | 854 | `_cancel_unsupported_moderation_action` | PL/pgSQL function | [SR-MOD-08](guild-service-rules.md#sr-mod-08-cancel-an-unsupported-kick) |
| V4 | 877 | `project_moderation_attempt` | trigger function | [SR-MOD-10](guild-service-rules.md#sr-mod-10-record-a-kick-attempt) |
| V4 | 922 | `record_moderation_attempt` | PL/pgSQL function | [SR-MOD-10](guild-service-rules.md#sr-mod-10-record-a-kick-attempt) |
| V4 | 956 | `claim_moderation_action` | PL/pgSQL function | [SR-MOD-09](guild-service-rules.md#sr-mod-09-claim-a-kick) |
| V4 | 996 | `authorize_warning_issue` | trigger function | [SR-MOD-01](guild-service-rules.md#sr-mod-01-issue-a-warning) |
| V4 | 1012 | `record_warning_issue` | trigger function | [SR-MOD-01](guild-service-rules.md#sr-mod-01-issue-a-warning) |
| V4 | 1056 | `authorize_warning_revocation` | trigger function | [SR-MOD-04](guild-service-rules.md#sr-mod-04-revoke-a-warning) |
| V4 | 1076 | `record_warning_revocation` | trigger function | [SR-MOD-04](guild-service-rules.md#sr-mod-04-revoke-a-warning) |
| V4 | 1090 | `issue_warning` | PL/pgSQL function | [SR-MOD-03](guild-service-rules.md#sr-mod-03-warning-commands) |
| V4 | 1106 | `issue_warning_command` | PL/pgSQL function | [SR-MOD-03](guild-service-rules.md#sr-mod-03-warning-commands) |
| V4 | 1144 | `revoke_warning` | PL/pgSQL function | [SR-MOD-05](guild-service-rules.md#sr-mod-05-revocation-commands) |
| V4 | 1166 | `revoke_warning_command` | PL/pgSQL function | [SR-MOD-05](guild-service-rules.md#sr-mod-05-revocation-commands) |
| V4 | 1203 | `warning_history` | PL/pgSQL function | [SR-MOD-06](guild-service-rules.md#sr-mod-06-warning-history) |
| V4 | 1231 | `moderation_history` | PL/pgSQL function | [SR-MOD-11](guild-service-rules.md#sr-mod-11-kick-history) |
| V5 | 36 | `record_configuration_change` | trigger function | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V5 | 74 | `begin_command_scope` | PL/pgSQL function | [SR-CFG-01](guild-service-rules.md#sr-cfg-01-configuration-command-envelope) |
| V5 | 89 | `end_command_scope` | PL/pgSQL function | [SR-CFG-01](guild-service-rules.md#sr-cfg-01-configuration-command-envelope) |
| V5 | 100 | `begin_configuration` | PL/pgSQL function | [SR-CFG-01](guild-service-rules.md#sr-cfg-01-configuration-command-envelope) |
| V5 | 120 | `set_new_joinee_days` | PL/pgSQL function | [SR-CFG-02](guild-service-rules.md#sr-cfg-02-guild-settings-commands) |
| V5 | 134 | `set_verification_policy` | PL/pgSQL function | [SR-CFG-02](guild-service-rules.md#sr-cfg-02-guild-settings-commands) |
| V5 | 150 | `set_transfer_policy` | PL/pgSQL function | [SR-CFG-02](guild-service-rules.md#sr-cfg-02-guild-settings-commands) |
| V5 | 169 | `set_kick_policy` | PL/pgSQL function | [SR-CFG-02](guild-service-rules.md#sr-cfg-02-guild-settings-commands) |
| V5 | 185 | `set_clan_games_schedule` | PL/pgSQL function | [SR-CFG-02](guild-service-rules.md#sr-cfg-02-guild-settings-commands) |
| V5 | 208 | `set_clan_games_refresh` | PL/pgSQL function | [SR-CFG-02](guild-service-rules.md#sr-cfg-02-guild-settings-commands) |
| V5 | 228 | `set_server_role` | PL/pgSQL function | [SR-CFG-03](guild-service-rules.md#sr-cfg-03-role-bindings) |
| V5 | 242 | `delete_server_role` | PL/pgSQL function | [SR-CFG-03](guild-service-rules.md#sr-cfg-03-role-bindings) |
| V5 | 254 | `set_clan_role` | PL/pgSQL function | [SR-CFG-03](guild-service-rules.md#sr-cfg-03-role-bindings) |
| V5 | 272 | `delete_clan_role` | PL/pgSQL function | [SR-CFG-03](guild-service-rules.md#sr-cfg-03-role-bindings) |
| V5 | 288 | `set_town_hall_role` | PL/pgSQL function | [SR-CFG-03](guild-service-rules.md#sr-cfg-03-role-bindings) |
| V5 | 306 | `delete_town_hall_role` | PL/pgSQL function | [SR-CFG-03](guild-service-rules.md#sr-cfg-03-role-bindings) |
| V5 | 323 | `set_channel_binding` | PL/pgSQL function | [SR-CFG-04](guild-service-rules.md#sr-cfg-04-channel-bindings) |
| V5 | 338 | `delete_channel_binding` | PL/pgSQL function | [SR-CFG-04](guild-service-rules.md#sr-cfg-04-channel-bindings) |
| V5 | 354 | `set_clan_collection` | PL/pgSQL function | [SR-CFG-05](guild-service-rules.md#sr-cfg-05-tracked-clans) |
| V5 | 374 | `set_cwl_clan_settings` | PL/pgSQL function | [SR-CFG-06](guild-service-rules.md#sr-cfg-06-cwl-clan-settings) |
| V5 | 391 | `set_war_reminder` | PL/pgSQL function | [SR-CFG-07](guild-service-rules.md#sr-cfg-07-war-reminders) |
| V5 | 404 | `delete_war_reminder` | PL/pgSQL function | [SR-CFG-07](guild-service-rules.md#sr-cfg-07-war-reminders) |
| V5 | 417 | `set_chat_xp_eligibility_role` | PL/pgSQL function | [SR-CFG-08](guild-service-rules.md#sr-cfg-08-chat-xp-eligibility-roles) |
| V5 | 430 | `delete_chat_xp_eligibility_role` | PL/pgSQL function | [SR-CFG-08](guild-service-rules.md#sr-cfg-08-chat-xp-eligibility-roles) |
| V5 | 442 | `set_chat_rank_role` | PL/pgSQL function | [SR-CFG-09](guild-service-rules.md#sr-cfg-09-rank-roles) |
| V5 | 455 | `delete_chat_rank_role` | PL/pgSQL function | [SR-CFG-09](guild-service-rules.md#sr-cfg-09-rank-roles) |
| V5 | 467 | `manage_developer` | PL/pgSQL function | [SR-CFG-12](guild-service-rules.md#sr-cfg-12-developer-allowlist) |
| V5 | 500 | `configuration_audit_for` | PL/pgSQL function | [SR-CFG-10](guild-service-rules.md#sr-cfg-10-configuration-change-history-reader) |
| V5 | 510 | `clan_games_results_for` | PL/pgSQL function | [SR-CFG-11](guild-service-rules.md#sr-cfg-11-clan-games-results-reader) |
| V5 | 526 | `require_manual_fetch_ownership` | trigger function | [SR-ACC-15](guild-service-rules.md#sr-acc-15-profile-refresh) |
| V5 | 548 | `request_player_refresh` | PL/pgSQL function | [SR-ACC-15](guild-service-rules.md#sr-acc-15-profile-refresh) |
| V5 | 566 | `record_player_verification` | PL/pgSQL function | [SR-ACC-01](guild-service-rules.md#sr-acc-01-record-a-verification) |
| V6 | 85 | `valid_cwl_availability` | SQL function | [SR-CWL-03](guild-service-rules.md#sr-cwl-03-sign-up) |
| V6 | 276 | `cwl_registration_status` | SQL function | [SR-CWL-04](guild-service-rules.md#sr-cwl-04-registration-status) |
| V6 | 292 | `cwl_day_is_frozen` | SQL function | [SR-CWL-05](guild-service-rules.md#sr-cwl-05-frozen-days) |
| V6 | 301 | `cwl_current_performance` | SQL function | [SR-CWL-06](guild-service-rules.md#sr-cwl-06-current-season-performance) |
| V6 | 311 | `cwl_next_bench_day` | SQL function | [SR-CWL-09](guild-service-rules.md#sr-cwl-09-next-bench-day) |
| V6 | 330 | `cwl_validate_war_reference` | trigger function | [SR-CWL-07](guild-service-rules.md#sr-cwl-07-war-day-references) |
| V6 | 346 | `cwl_validate_bench_incident` | trigger function | [SR-CWL-08](guild-service-rules.md#sr-cwl-08-bench-incidents) |
| V6 | 382 | `cwl_validate_assignment` | trigger function | [SR-CWL-10](guild-service-rules.md#sr-cwl-10-plan-assignments) |
| V6 | 433 | `cwl_begin_plan` | PL/pgSQL function | [SR-CWL-11](guild-service-rules.md#sr-cwl-11-begin-a-plan) |
| V6 | 457 | `cwl_close_signups` | PL/pgSQL function | [SR-CWL-12](guild-service-rules.md#sr-cwl-12-close-signups) |
| V6 | 475 | `cwl_publish_plan` | PL/pgSQL function | [SR-CWL-14](guild-service-rules.md#sr-cwl-14-publish-a-plan) |
| V6 | 500 | `cwl_assign_bench` | PL/pgSQL function | [SR-CWL-16](guild-service-rules.md#sr-cwl-16-benches) |
| V6 | 519 | `cwl_record_bench_service` | PL/pgSQL function | [SR-CWL-16](guild-service-rules.md#sr-cwl-16-benches) |
| V6 | 550 | `cwl_end_cycle` | PL/pgSQL function | [SR-CWL-16](guild-service-rules.md#sr-cwl-16-benches) |
| V6 | 565 | `cwl_validate_input_snapshot` | trigger function | [SR-CWL-11](guild-service-rules.md#sr-cwl-11-begin-a-plan) |
| V6 | 583 | `cwl_validate_resolution` | trigger function | [SR-CWL-16](guild-service-rules.md#sr-cwl-16-benches) |
| V6 | 607 | `cwl_validate_pin` | trigger function | [SR-CWL-15](guild-service-rules.md#sr-cwl-15-pins) |
| V6 | 632 | `custom_validate_war_association` | trigger function | [SR-CUS-01](guild-service-rules.md#sr-cus-01-commands) |
| V6 | 665 | `activity_replay` | PL/pgSQL function | [SR-ACT-01](guild-service-rules.md#sr-act-01-command-envelope) |
| V6 | 688 | `activity_start` | PL/pgSQL function | [SR-ACT-01](guild-service-rules.md#sr-act-01-command-envelope) |
| V6 | 700 | `activity_finish` | PL/pgSQL function | [SR-ACT-01](guild-service-rules.md#sr-act-01-command-envelope) |
| V6 | 711 | `activity_require_staff` | PL/pgSQL function | [SR-ACT-02](guild-service-rules.md#sr-act-02-staff-and-own-account-checks) |
| V6 | 723 | `activity_require_account` | PL/pgSQL function | [SR-ACT-02](guild-service-rules.md#sr-act-02-staff-and-own-account-checks) |
| V6 | 738 | `cwl_create_cycle` | PL/pgSQL function | [SR-CWL-01](guild-service-rules.md#sr-cwl-01-create-a-cycle) |
| V6 | 760 | `cwl_select_clan` | PL/pgSQL function | [SR-CWL-02](guild-service-rules.md#sr-cwl-02-select-correct-or-withdraw-a-participating-clan) |
| V6 | 797 | `cwl_signup` | PL/pgSQL function | [SR-CWL-03](guild-service-rules.md#sr-cwl-03-sign-up) |
| V6 | 855 | `cwl_manual_plan` | PL/pgSQL function | [SR-CWL-13](guild-service-rules.md#sr-cwl-13-manual-plans-and-assignments) |
| V6 | 881 | `cwl_set_assignment` | PL/pgSQL function | [SR-CWL-13](guild-service-rules.md#sr-cwl-13-manual-plans-and-assignments) |
| V6 | 903 | `cwl_pin` | PL/pgSQL function | [SR-CWL-15](guild-service-rules.md#sr-cwl-15-pins) |
| V6 | 937 | `cwl_unpin` | PL/pgSQL function | [SR-CWL-15](guild-service-rules.md#sr-cwl-15-pins) |
| V6 | 962 | `cwl_override_bench` | PL/pgSQL function | [SR-CWL-16](guild-service-rules.md#sr-cwl-16-benches) |
| V6 | 985 | `custom_event_create` | PL/pgSQL function | [SR-CUS-01](guild-service-rules.md#sr-cus-01-commands) |
| V6 | 1004 | `custom_event_signup` | PL/pgSQL function | [SR-CUS-01](guild-service-rules.md#sr-cus-01-commands) |
| V6 | 1035 | `custom_event_roster` | PL/pgSQL function | [SR-CUS-01](guild-service-rules.md#sr-cus-01-commands) |
| V6 | 1075 | `custom_event_result` | PL/pgSQL function | [SR-CUS-01](guild-service-rules.md#sr-cus-01-commands) |
| V6 | 1102 | `custom_event_complete` | PL/pgSQL function | [SR-CUS-01](guild-service-rules.md#sr-cus-01-commands) |
| V6 | 1135 | `cwl_pending_war_reference` | trigger function | [SR-CWL-07](guild-service-rules.md#sr-cwl-07-war-day-references) |
| V6 | 1153 | `cwl_project_export_attempt` | trigger function | [SR-CWL-17](guild-service-rules.md#sr-cwl-17-exports) |
| V6 | 1165 | `cwl_validate_plan_publication` | trigger function | [SR-CWL-14](guild-service-rules.md#sr-cwl-14-publish-a-plan) |
| V7 | 199 | `guard_notification_authorization` | trigger function | [SR-NTF-09](guild-service-rules.md#sr-ntf-09-attempt-records) |
| V7 | 233 | `_enqueue_notification` | PL/pgSQL function | [SR-NTF-01](guild-service-rules.md#sr-ntf-01-operations-and-logical-keys) |
| V7 | 266 | `queue_notification_ping` | PL/pgSQL function | [SR-NTF-02](guild-service-rules.md#sr-ntf-02-pings) |
| V7 | 279 | `claim_notification_publication` | PL/pgSQL function | [SR-NTF-03](guild-service-rules.md#sr-ntf-03-outbox-publication) |
| V7 | 298 | `finish_notification_publication` | PL/pgSQL function | [SR-NTF-03](guild-service-rules.md#sr-ntf-03-outbox-publication) |
| V7 | 319 | `record_notification_consumption` | PL/pgSQL function | [SR-NTF-04](guild-service-rules.md#sr-ntf-04-kafka-consumption) |
| V7 | 349 | `_notification_war_active` | SQL function | [SR-NTF-05](guild-service-rules.md#sr-ntf-05-active-war) |
| V7 | 359 | `_close_notification_dispatch` | PL/pgSQL function | [SR-NTF-08](guild-service-rules.md#sr-ntf-08-record-a-result) |
| V7 | 373 | `claim_notification_dispatch` | PL/pgSQL function | [SR-NTF-06](guild-service-rules.md#sr-ntf-06-claim-a-dispatch) |
| V7 | 481 | `begin_notification_send` | PL/pgSQL function | [SR-NTF-07](guild-service-rules.md#sr-ntf-07-begin-a-send) |
| V7 | 524 | `record_notification_result` | PL/pgSQL function | [SR-NTF-08](guild-service-rules.md#sr-ntf-08-record-a-result) |
| V7 | 560 | `set_notification_desired_roles` | PL/pgSQL function | [SR-NTF-10](guild-service-rules.md#sr-ntf-10-desired-roles) |
| V7 | 624 | `schedule_war_reminders` | PL/pgSQL function | [SR-NTF-11](guild-service-rules.md#sr-ntf-11-war-reminders) |
| V7 | 649 | `coalesce_missed_war_reminders` | PL/pgSQL function | [SR-NTF-12](guild-service-rules.md#sr-ntf-12-catch-up-after-downtime) |
| V7 | 695 | `register_notification_report` | PL/pgSQL function | [SR-NTF-13](guild-service-rules.md#sr-ntf-13-reports) |
| V7 | 712 | `record_notification_report_message` | PL/pgSQL function | [SR-NTF-13](guild-service-rules.md#sr-ntf-13-reports) |
| V7 | 736 | `record_notification_report_missing` | PL/pgSQL function | [SR-NTF-13](guild-service-rules.md#sr-ntf-13-reports) |
| V7 | 768 | `queue_notification_report` | PL/pgSQL function | [SR-NTF-13](guild-service-rules.md#sr-ntf-13-reports) |
| V7 | 831 | `validate_notification_cwl_context` | trigger function | [SR-NTF-14](guild-service-rules.md#sr-ntf-14-cwl-notification-context) |
| V7 | 851 | `queue_cwl_leadership_prompt` | PL/pgSQL function | [SR-NTF-15](guild-service-rules.md#sr-ntf-15-cwl-leadership-prompt) |
| V7 | 876 | `queue_cwl_roster_report` | PL/pgSQL function | [SR-NTF-16](guild-service-rules.md#sr-ntf-16-cwl-roster-reports) |
| V8 | 64 | `validate_leaderboard_timezone` | trigger function | [SR-LB-01](guild-service-rules.md#sr-lb-01-timezones) |
| V8 | 80 | `reject_leaderboard_history_mutation` | trigger function | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V8 | 95 | `validate_leaderboard_period` | trigger function | [SR-LB-02](guild-service-rules.md#sr-lb-02-reporting-periods) |
| V8 | 137 | `ensure_leaderboard_monthly_period` | PL/pgSQL function | [SR-LB-03](guild-service-rules.md#sr-lb-03-materialize-a-period) |
| V8 | 221 | `set_leaderboard_timezone` | PL/pgSQL function | [SR-LB-04](guild-service-rules.md#sr-lb-04-change-the-timezone) |
| V9 | 4 | `clan_games_assessment_scope` | PL/pgSQL function | [SR-CG-12](guild-service-rules.md#sr-cg-12-assessment-worker-input) |
| V9 | 65 | `validate_role_operation_provenance` | trigger function | [SR-DSC-04](guild-service-rules.md#sr-dsc-04-role-change-provenance) |

### Triggers (86)

Rows that share a line were created by one loop in that migration.

| File | Line | Trigger | Table | Timing | Function | Rule |
| --- | --- | --- | --- | --- | --- | --- |
| V2 | 278 | `account_link_primary_consistency` | `account_link` | AFTER INSERT OR UPDATE OR DELETE | `require_one_primary_account` | [SR-ACC-13](guild-service-rules.md#sr-acc-13-exactly-one-primary) |
| V3 | 71 | `membership_change_complete_poll` | `fact_clan_membership_change` | BEFORE INSERT OR UPDATE | `require_complete_membership_poll` | [SR-MEM-02](guild-service-rules.md#sr-mem-02-joins-and-departures) |
| V3 | 110 | `membership_period_evidence` | `observed_clan_membership_period` | BEFORE INSERT OR UPDATE | `validate_membership_period_evidence` | [SR-MEM-03](guild-service-rules.md#sr-mem-03-membership-periods) |
| V3 | 165 | `membership_period_closing_evidence` | `observed_clan_membership_period` | BEFORE INSERT OR UPDATE | `require_membership_closing_evidence` | [SR-MEM-03](guild-service-rules.md#sr-mem-03-membership-periods) |
| V3 | 375 | `war_participant_side` | `war_participant` | BEFORE INSERT OR UPDATE | `require_war_side` | [SR-WAR-02](guild-service-rules.md#sr-war-02-participants-and-clan-observations) |
| V3 | 402 | `war_clan_observation_side` | `fact_war_clan_observation` | BEFORE INSERT OR UPDATE | `require_war_side` | [SR-WAR-02](guild-service-rules.md#sr-war-02-participants-and-clan-observations) |
| V3 | 436 | `war_attack_opposing_sides` | `fact_war_attack` | BEFORE INSERT OR UPDATE | `require_opposing_war_accounts` | [SR-WAR-03](guild-service-rules.md#sr-war-03-attacks) |
| V3 | 677 | `clan_games_read_request_boundary` | `clan_games_read_request` | BEFORE INSERT OR UPDATE | `validate_clan_games_read_request` | [SR-CG-04](guild-service-rules.md#sr-cg-04-read-requests) |
| V3 | 807 | `clan_games_counter_source` | `clan_games_counter_read` | BEFORE INSERT | `validate_clan_games_counter_read` | [SR-CG-06](guild-service-rules.md#sr-cg-06-counter-reads) |
| V3 | 820 | `clan_games_counter_completed` | `clan_games_counter_read` | AFTER INSERT | `complete_clan_games_read_request` | [SR-CG-07](guild-service-rules.md#sr-cg-07-complete-and-close-reads) |
| V3 | 980 | `clan_games_participation_inference` | `clan_games_participation_evidence` | BEFORE INSERT OR UPDATE | `infer_clan_games_participation` | [SR-CG-08](guild-service-rules.md#sr-cg-08-participating-clan-inference) |
| V3 | 1087 | `clan_games_progress_evidence` | `fact_clan_games_progress` | BEFORE INSERT OR UPDATE | `validate_clan_games_progress` | [SR-CG-09](guild-service-rules.md#sr-cg-09-progress) |
| V3 | 1218 | `clan_games_assessment_evidence` | `fact_clan_games_account_assessment` | BEFORE INSERT OR UPDATE | `validate_clan_games_assessment` | [SR-CG-10](guild-service-rules.md#sr-cg-10-account-assessments) |
| V3 | 1281 | `clan_games_member_scope_snapshot` | `fact_clan_games_member_assessment` | AFTER INSERT | `capture_clan_games_member_scope` | [SR-CG-11](guild-service-rules.md#sr-cg-11-member-assessments) |
| V3 | 1313 | `clan_games_member_input_attribution` | `clan_games_member_account_input` | BEFORE INSERT OR UPDATE OR DELETE | `validate_clan_games_member_input` | [SR-CG-11](guild-service-rules.md#sr-cg-11-member-assessments) |
| V4 | 51 | `capture_discord_join_policy` | `fact_discord_membership_event` | BEFORE INSERT | `capture_discord_join_policy` | [SR-DSC-01](guild-service-rules.md#sr-dsc-01-membership-events) |
| V4 | 101 | `project_discord_membership` | `fact_discord_membership_event` | AFTER INSERT | `project_discord_membership` | [SR-DSC-02](guild-service-rules.md#sr-dsc-02-presence-projection) |
| V4 | 193 | `project_discord_role` | `fact_role_change` | AFTER INSERT | `project_discord_role` | [SR-DSC-03](guild-service-rules.md#sr-dsc-03-held-role-projection) |
| V4 | 274 | `reject_award_view_mutation` | `fact_chat_xp_award` | INSTEAD OF INSERT OR UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 317 | `enforce_chat_xp_policy` | `fact_chat_xp_decision` | BEFORE INSERT | `enforce_chat_xp_policy` | [SR-XP-03](guild-service-rules.md#sr-xp-03-credit-a-message) |
| V4 | 438 | `project_chat_rank` | `fact_chat_xp_decision` | AFTER INSERT | `project_chat_rank` | [SR-XP-04](guild-service-rules.md#sr-xp-04-ranks) |
| V4 | 502 | `reject_warning_history_view_mutation` | `fact_warning_event` | INSTEAD OF INSERT OR UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 707 | `validate_moderation_notice` | `fact_moderation_notice` | BEFORE INSERT | `validate_moderation_notice` | [SR-MOD-13](guild-service-rules.md#sr-mod-13-rejoin-notices) |
| V4 | 841 | `zz_record_moderation_rejoin_notice` | `fact_discord_membership_event` | AFTER INSERT | `record_accepted_join_moderation_notice` | [SR-DSC-05](guild-service-rules.md#sr-dsc-05-accepted-joins) |
| V4 | 913 | `project_moderation_attempt` | `fact_moderation_action_attempt` | AFTER INSERT | `project_moderation_attempt` | [SR-MOD-10](guild-service-rules.md#sr-mod-10-record-a-kick-attempt) |
| V4 | 1051 | `authorize_warning_issue` | `warning` | BEFORE INSERT | `authorize_warning_issue` | [SR-MOD-01](guild-service-rules.md#sr-mod-01-issue-a-warning) |
| V4 | 1053 | `record_warning_issue` | `warning` | AFTER INSERT | `record_warning_issue` | [SR-MOD-01](guild-service-rules.md#sr-mod-01-issue-a-warning) |
| V4 | 1074 | `authorize_warning_revocation` | `warning_revocation` | BEFORE INSERT | `authorize_warning_revocation` | [SR-MOD-04](guild-service-rules.md#sr-mod-04-revoke-a-warning) |
| V4 | 1087 | `record_warning_revocation` | `warning_revocation` | AFTER INSERT | `record_warning_revocation` | [SR-MOD-04](guild-service-rules.md#sr-mod-04-revoke-a-warning) |
| V4 | 1262 | `reject_history_mutation` | `fact_discord_membership_event` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `fact_discord_accepted_join` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `fact_role_change` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `chat_xp_policy` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `chat_rank_tier` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `fact_chat_xp_decision` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `fact_chat_rank_change` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `warning` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `warning_revocation` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `fact_moderation_action_attempt` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `fact_manual_moderation_action` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V4 | 1262 | `reject_history_mutation` | `fact_moderation_notice` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V5 | 545 | `manual_fetch_owner` | `fact_api_fetch_attempt` | BEFORE INSERT OR UPDATE | `require_manual_fetch_ownership` | [SR-ACC-15](guild-service-rules.md#sr-acc-15-profile-refresh) |
| V5 | 592 | `reject_configuration_change_mutation` | `fact_configuration_change` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 345 | `cwl_day_war` | `cwl_clan_day` | BEFORE INSERT OR UPDATE | `cwl_validate_war_reference` | [SR-CWL-07](guild-service-rules.md#sr-cwl-07-war-day-references) |
| V6 | 381 | `cwl_bench_incident_evidence` | `fact_cwl_bench_incident` | BEFORE INSERT | `cwl_validate_bench_incident` | [SR-CWL-08](guild-service-rules.md#sr-cwl-08-bench-incidents) |
| V6 | 431 | `cwl_assignment_eligibility` | `cwl_plan_assignment` | BEFORE INSERT OR UPDATE | `cwl_validate_assignment` | [SR-CWL-10](guild-service-rules.md#sr-cwl-10-plan-assignments) |
| V6 | 582 | `cwl_input_current_season` | `fact_cwl_plan_input` | BEFORE INSERT | `cwl_validate_input_snapshot` | [SR-CWL-11](guild-service-rules.md#sr-cwl-11-begin-a-plan) |
| V6 | 606 | `cwl_bench_resolution_valid` | `fact_cwl_bench_resolution` | BEFORE INSERT | `cwl_validate_resolution` | [SR-CWL-16](guild-service-rules.md#sr-cwl-16-benches) |
| V6 | 631 | `cwl_pin_eligibility` | `cwl_manual_pin` | BEFORE INSERT OR UPDATE | `cwl_validate_pin` | [SR-CWL-15](guild-service-rules.md#sr-cwl-15-pins) |
| V6 | 655 | `custom_war_kind` | `custom_event` | BEFORE INSERT OR UPDATE OR DELETE | `custom_validate_war_association` | [SR-CUS-01](guild-service-rules.md#sr-cus-01-commands) |
| V6 | 1130 | `reject_history_mutation` | `fact_cwl_group_observation` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1130 | `reject_history_mutation` | `fact_cwl_registered_clan` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1130 | `reject_history_mutation` | `fact_cwl_registered_player` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1130 | `reject_history_mutation` | `fact_cwl_signup_revision` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1130 | `reject_history_mutation` | `fact_cwl_plan_input` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1130 | `reject_history_mutation` | `fact_cwl_bench_incident` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1130 | `reject_history_mutation` | `fact_cwl_bench_resolution` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1130 | `reject_history_mutation` | `fact_cwl_export_attempt` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1130 | `reject_history_mutation` | `custom_roster_revision` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1130 | `reject_history_mutation` | `custom_roster_account` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1149 | `cwl_pending_reference` | `cwl_round_war_reference` | BEFORE INSERT OR UPDATE | `cwl_pending_war_reference` | [SR-CWL-07](guild-service-rules.md#sr-cwl-07-war-day-references) |
| V6 | 1151 | `cwl_reference_no_delete` | `cwl_round_war_reference` | BEFORE DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V6 | 1163 | `cwl_export_outcome` | `fact_cwl_export_attempt` | AFTER INSERT | `cwl_project_export_attempt` | [SR-CWL-17](guild-service-rules.md#sr-cwl-17-exports) |
| V6 | 1212 | `cwl_plan_publication` | `cwl_plan_revision` | BEFORE UPDATE | `cwl_validate_plan_publication` | [SR-CWL-14](guild-service-rules.md#sr-cwl-14-publish-a-plan) |
| V7 | 226 | `notification_authorization_policy` | `fact_notification_dispatch_attempt` | BEFORE INSERT OR UPDATE | `guard_notification_authorization` | [SR-NTF-09](guild-service-rules.md#sr-ntf-09-attempt-records) |
| V7 | 228 | `notification_dispatch_history` | `fact_notification_dispatch_attempt` | BEFORE DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V7 | 230 | `notification_receipt_history` | `notification_kafka_receipt` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V7 | 846 | `notification_cwl_context_scope` | `notification_cwl_context` | BEFORE INSERT | `validate_notification_cwl_context` | [SR-NTF-14](guild-service-rules.md#sr-ntf-14-cwl-notification-context) |
| V7 | 848 | `notification_cwl_context_history` | `notification_cwl_context` | BEFORE UPDATE OR DELETE | `discord_reject_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V8 | 76 | `leaderboard_policy_timezone` | `leaderboard_calendar_policy` | BEFORE INSERT | `validate_leaderboard_timezone` | [SR-LB-01](guild-service-rules.md#sr-lb-01-timezones) |
| V8 | 88 | `leaderboard_policy_immutable` | `leaderboard_calendar_policy` | BEFORE UPDATE OR DELETE | `reject_leaderboard_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V8 | 91 | `leaderboard_period_immutable` | `dim_leaderboard_monthly_period` | BEFORE UPDATE OR DELETE | `reject_leaderboard_history_mutation` | [SR-CTX-06](guild-service-rules.md#sr-ctx-06-append-only-records) |
| V8 | 133 | `leaderboard_period_boundaries` | `dim_leaderboard_monthly_period` | BEFORE INSERT | `validate_leaderboard_period` | [SR-LB-02](guild-service-rules.md#sr-lb-02-reporting-periods) |
| V9 | 85 | `role_operation_provenance` | `fact_role_change` | BEFORE INSERT | `validate_role_operation_provenance` | [SR-DSC-04](guild-service-rules.md#sr-dsc-04-role-change-provenance) |
| V9 | 120 | `record_configuration_change` | `guild_settings` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `role_binding` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `channel_binding` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `clan_collection_settings` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `war_reminder_setting` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `chat_xp_policy` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `developer_allowlist` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `chat_xp_eligibility_role` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `chat_rank_role_binding` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `leaderboard_calendar_policy` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `leaderboard_metric_definition` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |
| V9 | 120 | `record_configuration_change` | `dim_clan_games_event` | AFTER INSERT OR UPDATE OR DELETE | `record_configuration_change` | [SR-CFG-13](guild-service-rules.md#sr-cfg-13-configuration-change-history) |

## Checks of the SQL tests

The 586 checks of the 16 SQL test files at `c407abb`, in file order. Each
line is the message that a check prints when it fails. Most messages name
the wrong outcome that the check guards against; messages with "must" name
the expected behaviour. "Error expected" marks a check that runs an action
and passes only when that action fails. A line that ends with "schema check
in" and a file is already covered by that schema check. Port every other
check to a Java test, or record why it no longer applies
([SR-TEST](guild-service-rules.md#sr-test-porting-the-sql-tests)).

### `010_dimensions.sql`

- Unsigned 64-bit Discord ID was not preserved — schema check in `010_dimensions.sql`
- Multiple guilds accepted in one environment — schema check in `010_dimensions.sql`
- A table other than dim_guild and guild_settings carries guild_key — schema check in `010_dimensions.sql`
- Out-of-range snowflake accepted — schema check in `010_dimensions.sql`
- Fractional snowflake silently rounded — schema check in `010_dimensions.sql`
- Noncanonical player tag accepted — schema check in `010_dimensions.sql`
- Duplicate player identity accepted — schema check in `010_dimensions.sql`
- Role rename broke its purpose binding — schema check in `010_dimensions.sql`
- Duplicate server-wide channel purpose accepted — schema check in `010_dimensions.sql`
- Clan-scoped war channel accepted without a clan — schema check in `010_dimensions.sql`
- A TH binding accepted a staff capability purpose — schema check in `010_dimensions.sql`
- Duplicate server binding bypassed its shared scope — schema check in `010_dimensions.sql`

### `020_account_links.sql`

- The first linked account must automatically become primary
- First-ever link must permit collected-history backfill
- Adding an alt must not replace or duplicate the primary
- Error expected: Rejected verification unexpectedly linked an account
- Error expected: An untracked account unexpectedly linked
- Error expected: A member reused a verification proof belonging to another member — schema check in `020_account_links.sql`
- Error expected: An account transferred without staff approval
- Error expected: A member without a Co-leader/Admin role approved a transfer
- Error expected: Transfer left the original member with alts but no primary
- A completed transfer must cancel other open requests for the ended source link
- Error expected: A cancelled transfer request was decided
- A transfer must start a new attribution episode
- A transfer must not inherit the first owner history
- The old attribution episode must end at the transfer boundary
- Transfer approval must be consumed once — schema check in `020_account_links.sql`
- A transferred account must have exactly one current owner — schema check in `020_account_links.sql`
- Error expected: A member selected another owner account as primary
- Error expected: An ordinary member read private account-link history
- Co-leaders must be able to read retained link history
- Error expected: A member unlinked somebody else account
- Error expected: A stale verification started a transfer request
- Unlinking must cancel every open transfer request for the ended link
- Cancellation must keep the earlier approval as history
- No open transfer request may outlive its source link
- A consumed transfer must never be cancelled
- Error expected: A stale verification created a link
- Error expected: The configured verification limit was ignored
- Same-member relinking without an intervening owner must preserve metric continuity
- Returning after a different owner must start fresh, not reopen an earlier episode
- Error expected: A primary was unlinked without choosing a replacement
- The chosen replacement must become primary atomically
- Error expected: Direct SQL left linked accounts without a primary
- Error expected: Direct SQL created overlapping link intervals — schema check in `020_account_links.sql`
- Error expected: Direct SQL attached a rejected verification outcome — schema check in `020_account_links.sql`
- Link and verification tables must not have a token column — schema check in `020_account_links.sql`
- The transfer limits must default to two days pending and one day approved — schema check in `020_account_links.sql`
- The earlier fixture must leave no open transfer request
- A pending request must lapse two days after it was made
- Error expected: A lapsed pending request was approved
- A request inside its limit must stay open
- The scheduler must expire the lapsed pending request
- Expiring transfer requests must be idempotent
- An expired request must record the moment its limit passed
- Error expected: An expired request was decided
- A transfer request was declared expired in the future
- Asking again must expire the recipient's lapsed request for the same link
- Error expected: A lapsed approval completed a transfer
- A lapsed approval must leave the account with its owner
- An approval inside the configured limit must complete the transfer
- An approval inside its limit must stay usable
- The scheduler must expire the unused approval
- Expiry must keep the earlier approval as history
- A request that is no longer open has no expiry
- Error expected: An expired approval completed a transfer
- A transfer limit of zero seconds was accepted — schema check in `020_account_links.sql`

### `030_coc.sql`

- Error expected: Failed polling was incorrectly accepted as departure evidence
- Current tracked membership eligibility is incorrect
- Error expected: Overlapping membership in two clans was incorrectly accepted — schema check in `030_coc.sql`
- Lifetime stars must take latest snapshot, not sum
- Non-current account incorrectly appeared on clan leaderboard
- Current clan leaderboard must include exactly the two eligible accounts
- Scheduled event creation must be idempotent
- Moving tracked clans must produce six days and one full-account target: %, %
- T-24 must use only elapsed membership, divided by full event duration
- Half-event account must owe 200 points
- Open membership must stop at event/confirmed boundary
- Error expected: Repeated attack fetch was incorrectly accepted as a second attack — schema check in `030_coc.sql`
- Error expected: Same-clan attack was incorrectly accepted
- Observation time must not silently become attack occurrence time — schema check in `030_coc.sql`
- Raid total must select latest rather than sum snapshots
- Season calendar does not end on the last Monday at 05:00 UTC
- Runtime can store member state without the change check
- Error expected: A failed poll was accepted as member state
- The first state of a member was not stored exactly once
- An unchanged member state was stored again
- A changed donation counter was not stored
- A changed role was not stored
- The last state before the season end was not stored
- The first poll of a season did not store a baseline for every member
- The season baseline was stored a second time
- A member who left and returned did not get a new state row
- Member state rows do not match the changes that the polls saw
- Season donation totals are not the last counters of each season
- Current member state does not follow current membership

### `040_discord.sql`

- selected join provenance and New Joinee expiry were not retained — schema check in `050_discord.sql`
- incorrect New Joinee expiry accepted — schema check in `050_discord.sql`
- one of first five XP awards was denied
- sixth cross-channel message was credited
- message retry was not idempotent
- duplicate message changed XP recipient
- rejected/retried messages changed earning allowance
- source minute/month boundary bypassed rolling limit
- October aggregation did not contain four 15..25 XP awards
- source XP month was affected by session timezone
- credited/rejected message decisions were not both persisted
- out-of-order join replaced a newer departure
- departure erased XP
- departure erased the cumulative rank projection
- rejoin did not restore member projection
- out-of-order role add restored a removed role
- developer without moderation role issued warning
- blank warning reason accepted — schema check in `060_moderation.sql`
- kick was requested before fifth valid monthly warning
- kick request was incorrectly marked executed
- pending kick decision was not visible to the worker view — schema check in `060_moderation.sql`
- runtime must read pending kicks through the view, not the private ledgers
- revocation did not remove exactly one warning
- a revoked warning did not cancel the waiting kick
- a cancelled kick was offered to the worker
- cross-month revocation reduced the wrong month
- conflicting revocation retry was accepted
- duplicate kick decision created for same month — schema check in `060_moderation.sql`
- a new fifth active warning did not arm the cancelled kick again
- new GMT month retained earlier active count
- revocation command replay created % decisions
- revocation command left its warning active
- revocation operation UUID was reused with other arguments
- a second operation revoked an already revoked warning — schema check in `060_moderation.sql`
- non-moderator used the revocation command
- issuance and revocation facts not both retained
- warning history must derive from its immutable source records
- derived warning events lost stable distinct identities
- derived revocation history lost actor/reason/time evidence
- member could not read own warning history
- developer privilege exposed another member warning history
- a kick result was accepted without its claim
- an armed kick was not offered with a claim token
- uncertain Discord outcome became success
- an uncertain kick was not scheduled for another attempt
- an uncertain kick was offered before its retry delay
- an uncertain kick was not offered with a member check
- moderation attempt retry history was not retained
- confirmed successful attempt not projected
- historical warning evidence was editable — schema check in `060_moderation.sql`

### `050_access.sql`

- runtime could read private entity % directly
- public current links were not readable
- authorized Admin command did not configure typed row
- ordinary member configured settings
- configuration accepted a blank reason — schema check in `070_configuration_history.sql`
- Admin configuration permission exposed developer audit
- developer could not read configuration audit
- Admin escalated to developer
- runtime bypassed configuration helper
- Co-leader could not read account history
- developer alone could read account-link history
- configuration history exposed link or assessment rows
- Leadership could not read member assessment
- Admin alone bypassed configured Leadership gate
- staff refreshed another member account
- collector manual fetch bypassed ownership trigger
- member could not read own warning through runtime helper
- developer bypassed moderation role requirement
- departed user retained authority from stale role projection
- a refresh request was moved to another requester
- the collector could not finish a refresh after the account was unlinked
- a refresh was requested for an unlinked account
- configuration change history is attached to: %
- configuration trigger out of step with the primary key on: %
- recorded identity did not hold exactly the composite primary key
- configuration command evidence missing its values before and after
- an activity row was copied into the configuration change history
- configuration change history was mutable — schema check in `070_configuration_history.sql`

### `060_manual_events.sql`

- Ordinary member manually created a Clan Games event
- Manual event metadata was not retained
- Manual retry duplicated an event
- Schedule recovery duplicated a manual event
- Manual retry duplicated a scheduled event — schema check in `040_clan_games.sql`
- Retry silently changed frozen event evidence — schema check in `040_clan_games.sql`
- Manual creation did not record its actor and configuration decision
- Manual event command leaked its audit actor into later work

### `070_membership_closing.sql`

- Error expected: Failed-poll time incorrectly closed current membership
- Error expected: Incomplete-poll time incorrectly closed current membership
- Error expected: Failed poll incorrectly supplied explicit departure evidence
- Error expected: Incomplete poll incorrectly supplied explicit departure evidence
- Error expected: An unprocessed member-observation table was incorrectly treated as departure proof
- Rejected closure changed current membership
- Supported closure left an account in current membership
- Closing evidence must not overwrite the last positive confirmation
- Error expected: Out-of-order departure incorrectly rewound newer positive evidence
- Error expected: Another clan departure incorrectly closed this clan membership
- Error expected: Reassigning the row incorrectly hid current membership without closure evidence — schema check in `030_coc.sql`
- Error expected: A closed historical interval was incorrectly reopened in place
- Stale or unrelated evidence changed current membership
- Internal evidence helper must not expose additional runtime authority
- Error expected: Runtime collector incorrectly closed membership without matching evidence

### `080_command_actors.sql`

- a member without the moderation role issued a warning
- a member command left a configuration actor behind
- transfer lost its recipient, previous owner or deciding staff member
- link history lost the initial owner or the transfer that replaced it
- warning issuance/revocation lost its moderator actor
- a member command was copied into the configuration change history

### `090_security_hardening.sql`

- Curated runtime configuration grant must survive hardening
- A definer executed attacker-controlled temporary catalog views
- Every definer must explicitly place pg_temp after trusted namespaces
- PUBLIC must not execute guild functions
- The initial confirmed Admin role should authorize its member
- Departure must clear confirmed role state
- A delayed old event revived departed authority
- Rejoining without a fresh role confirmation restored staff authority
- A pre-rejoin role confirmation must remain historical
- Departure erased chat XP
- Departure erased account links
- Projection repair erased source role facts — schema check in `050_discord.sql`
- Fresh role confirmation did not restore valid authority
- An out-of-order departure erased current authority
- An old add overrode a newer role removal
- A role event must not authorize a member while observed as departed
- A fresh source confirmation arriving before its join event was not reconciled
- An earlier join occurrence removed a role confirmed for the current stay
- Expired role evidence authorized staff commands
- Future migration-owned functions regained default PUBLIC EXECUTE
- Catalog shadow views were invoked during a hardened operation

### `100_clan_games.sql`

- Active-event cadence must default to fifteen minutes — schema check in `040_clan_games.sql`
- Checkpoint queue must be idempotent — schema check in `040_clan_games.sql`
- Boundary reads must exist independently from regular refresh requests
- Only the next regular read may be queued, one interval after the event start
- Participation must be inferred from consistent event-start membership and first increase
- Missing affiliation must not be guessed
- Error expected: A late current read reconstructed a missed baseline
- Error expected: An unrelated achievement supplied Clan Games points
- A contradictory profile clan must prevent participation inference
- Error expected: Manual points were accepted — schema check in `040_clan_games.sql`
- Same-user relink must retain the gap and first-link backfill episode
- Transfer activated before the points refresh
- Waiting for points must be explicit
- Waiting must preserve the old effective owner
- Error expected: An API failure was accepted as transfer-boundary evidence
- API failure must leave the checkpoint retryable
- Effective transfer must retain its counter evidence
- Event points must be the actual difference, not a lifetime total or milestone
- Error expected: Unknown freshness was silently accepted as adequate
- Old owner must keep actual 100 points and half-event target including gap/backfill
- New owner must receive actual 200 points, not an even guessed split
- Error expected: A time-prorated invented points split was accepted
- T-24 must not project the final day or include the earlier owner time
- Expected evidence starts missing
- Error expected: Another owner filled a frozen member scope — schema check in `040_clan_games.sql`
- Error expected: Frozen attribution scope was deleted — schema check in `040_clan_games.sql`
- Old owner result must not move to the new owner
- New owner should pass using only their supported slice
- Targets must combine before rounding to ten
- Missing evidence must occupy a frozen expected row
- Omitting a known eligible account must not produce a complete result
- Missing historical evidence must not become zero-point success or failure — schema check in `040_clan_games.sql`
- Real baseline/end zero must fail a supported positive target without inventing affiliation
- Error expected: Missing baseline was replaced by an asserted zero
- Only the unread baseline may be closed shortly after the event starts
- A baseline with no read at the event start must become missed
- Future checkpoints must stay retryable
- Closing missed reads must be idempotent
- A completed regular read must queue the next one
- The next regular read must be due one interval after the latest read
- Queueing the same regular read must be idempotent
- An interval change must move the pending read
- The pending regular read must follow the new interval
- Restoring the interval must move the pending read back
- Error expected: A second pending regular read was accepted — schema check in `040_clan_games.sql`
- A late regular read must queue the next one
- The next regular read must follow the late read, not the old due time
- A pending regular read must stay retryable while the event runs
- Regular requests must grow with reads, not with the event length
- A valid late-ingested baseline must replace the missed state
- A transfer read for an approved request must stay retryable
- Only the cancelled transfer read may be closed
- A cancelled transfer must close its boundary read
- The transfer must wait for its boundary read
- A transfer with a pending boundary read must not have an expiry
- A slow read must not expire the waiting transfer
- The approval limit must restart when the boundary read arrives
- A late boundary read must still complete the transfer
- The waiting transfer must take effect at its boundary read
- The second transfer must wait for its boundary read
- The waiting transfer must stay open while its read is retryable
- The event end must close the pending regular read and the T-24h checkpoint
- No regular read may be queued after its event
- No in-event checkpoint may stay pending after the event
- The final read must stay retryable until the next event starts
- The next event start must close the unread final checkpoint and the unanswered transfer read
- No request of a superseded event may stay pending
- A transfer whose boundary read was missed must expire
- The missed transfer must expire one day after its approval
- An expired transfer must leave the account with its owner
- reads were declared missed in the future

### `105_discord_policies.sql`

- XP decisions must remain the persisted source
- Credited awards must be a projection, not a second persisted message
- XP fell outside the approved range — schema check in `050_discord.sql`
- Award replay changed identity
- Award replay rerolled XP
- A credited message acquired a separate persisted award identity
- The award projection allowed XP history rewrites — schema check in `050_discord.sql`
- The second eligibility role did not qualify without a CoC account
- Holding both roles failed OR eligibility
- Role loss did not pause earning
- Missing roles became a departure
- Role loss erased rank/XP
- Previously rejected message earned retroactively after roles changed
- A rejected message identity was reused by another member — schema check in `050_discord.sql`
- A role without current Discord presence qualified
- A rejected decision became addressable as a credited award — schema check in `050_discord.sql`
- Expired/deleted roles qualified
- An expired processing-time award still consumed the rolling window
- A source-time calendar boundary bypassed the shared rolling limit
- An expired rejected decision was reconsidered
- Random XP sampling behaved as a fixed award
- Seeded cumulative rank thresholds differ from the approved schedule — schema check in `050_discord.sql`
- Seeded rank names differ from the approved schedule
- Rank was granted below its cumulative threshold
- Exact cumulative threshold did not grant the approved rank
- Rank projection did not select exactly one highest bound role
- Rank reconciliation did not target exactly the stale rank role
- Rank reconciliation targeted an unrelated role
- Departure erased XP
- Departure erased desired highest rank
- Command replay without an explicit issue time created another warning
- Stable warning command UUID was not unique — schema check in `060_moderation.sql`
- Canonical warning command lost its actor/source audit context
- Warning operation UUID accepted a different reason
- Warning operation UUID accepted a different subject
- Uncertain kick became a confirmed rejoin notice
- An uncertain kick must be offered with a member check
- Late success receipt did not correlate the accepted execution-month rejoin
- Late evidence did not backfill exactly one warning notice, or replay duplicated notices
- Post-rejoin warnings did not each create a durable leadership notice
- Post-rejoin warnings created another automatic kick job
- Stale join was treated as an accepted rejoin
- Later-month or stale rejoin generated another same-month notice
- GMT monthly threshold did not reset
- Failed kick created a confirmed-kick notice
- A failed kick must be scheduled five minutes after its attempt
- An unbounded worker identity claimed a kick
- A failed kick that is due must be offered as a plain kick with a claim token
- A second worker claimed a kick that is already held
- Recording an attempt must release the claim and schedule the last attempt
- An uncertain kick must be offered with a member check
- A kick that used all its attempts was offered again
- The last failed attempt must leave the kick failed for leadership
- A new kick must be offered as a plain kick
- A kick whose claim expired unreported must be offered with a member check and a new token
- A report from a claim that was taken over was accepted
- A rejected report must not spend an attempt or release the current claim
- A succeeded kick was offered again
- A claim token was accepted for a second report — schema check in `060_moderation.sql`
- A rejected report was stored as an attempt
- The configured attempt limit and retry delay were not applied
- A later settings change altered the attempts of an open kick
- An attempt limit of zero was accepted — schema check in `060_moderation.sql`
- The in-flight kick must be claimable
- A revocation cancelled a kick while a worker held it
- A failed attempt on an unsupported kick must cancel it, not schedule a retry
- The second in-flight kick must be claimable
- An unsupported kick was offered after its claim expired
- The next claim must cancel a kick that lost its fifth active warning
- An uncertain report reopened a cancelled kick
- A confirmed kick must replace the cancelled state
- The late report must be retained
- Runtime must use the entry point and the history reader for manual moderation
- A replayed audit log entry created a second action
- One audit log entry was accepted as two different actions — schema check in `060_moderation.sql`
- A timeout without its end was accepted — schema check in `060_moderation.sql`
- A rejoin after a manual kick in the same month must create one leadership notice
- A manual kick and rejoin suppressed the automatic kick of the fifth warning
- An unban without a rejoin created a notice
- A rejoin after an unban must create its own notice and no bot-kick notice
- A late audit log entry must create the notice of the earlier rejoin, and only that one
- Manual moderation history was mutable — schema check in `060_moderation.sql`
- A member could not read their own manual moderation history
- A moderator could not read a confirmed kick of the bot
- A member read the moderation history of another member

### `110_cwl_and_custom_events.sql`

- Tracked clans share collection and CWL settings without a second configuration row
- Signup command retries must not duplicate revisions
- Current Clan A membership is retained while signing up to target Clan B
- One stable operation produces one signup revision — schema check in `080_cwl_and_custom_events.sql`
- Signup edits automatically queue an export revision
- Error expected: Operation identity accepted changed arguments — schema check in `080_cwl_and_custom_events.sql`
- Error expected: Unlinked stranger signed up another account
- Error expected: Invalid War Days were accepted
- A command stores exactly its typed arguments
- Error expected: Member availability edit accepted after deadline
- Closing signups immediately creates seven provisional War Days
- A new empty plan still exposes every day
- Initial plan has explicit provisional TH/availability provenance
- Absent API registration remains unknown
- Initial snapshot has no fabricated stars
- Error expected: Derived plan days allowed an eighth day — schema check in `080_cwl_and_custom_events.sql`
- Error expected: Assignment ignored strict selected availability
- Error expected: An incomplete seven-day roster was reported complete
- Shortage stays explicit
- Published lineups queue Sheets/CSV revision
- Registration reconciles to actual clan pool
- Another clan pool does not confer eligibility
- Error expected: Repeated source attack duplicated penalty — schema check in `080_cwl_and_custom_events.sql`
- Frozen Day3 and unavailable Day4 must not consume a bench
- Next eligible available day is stored separately from completed service
- Assignment is not proof a war was served
- New staff unavailability must not consume the previously assigned Day5
- Restored earlier availability replans the earliest still-changeable bench
- Current-cycle CWL evidence enters input snapshot
- Error expected: Benched account selected on assigned skipped day
- Error expected: Automatic assignment changed frozen lineup
- Error expected: Future war falsely proved completed bench service
- Error expected: Developer allowlist alone overrode a staff-only bench
- Error expected: Manual pin implicitly waived penalty
- Error expected: Automatic regeneration overwrote pin
- Error expected: Missing attack in ongoing/incomplete roster created a penalty
- Regular-war stars must not enter the CWL performance scope
- Failed Sheet attempt projects failure rather than claiming success
- Custom roster retains account identities, not one Discord aggregate
- Error expected: Ordinary member manually selected a custom roster
- Error expected: A regular war was attached to a custom event
- Error expected: A game-war association omitted its actor, operation and reason — schema check in `080_cwl_and_custom_events.sql`
- A retried custom-result command returns its original association
- Available custom result association persists separately from signup roster
- The custom event stores its single typed game-war association
- Error expected: Inline association history was rewritten
- Error expected: Inline association history was erased
- Error expected: Deleting its event erased a retained association — schema check in `080_cwl_and_custom_events.sql`
- Error expected: A new command silently replaced the write-once association
- Error expected: Season expired while its known war is still in the future
- Available otherwise eligible Day4 is assigned for the new missed attack
- Complete ended actual roster proves one-war bench service
- Unserved penalty expires at season end
- Human command actor must not leak into later collector operations
- Runtime cannot bypass staff pin command
- PUBLIC has no activity command authority
- The untyped activity command transport is gone
- Error expected: Departed staff retained manual selection authority
- Error expected: Runtime directly inserted a staff pin

### `120_notification_delivery.sql`

- rolled-back domain decision left delivery work
- logical notification retry duplicated its intent/outbox — schema check in `090_notification_delivery.sql`
- dispatch bypassed the Kafka consumption stage
- publication lease did not serialize workers
- Kafka broker acknowledgment was treated as Discord delivery
- Kafka replay did not deduplicate its logical operation — schema check in `090_notification_delivery.sql`
- logical deduplication discarded replay evidence or another consumer group — schema check in `090_notification_delivery.sql`
- Kafka coordinate was reassigned to another logical operation — schema check in `090_notification_delivery.sql`
- multiple ping dispatch attempts were authorized — schema check in `090_notification_delivery.sql`
- RPC acceptance became delivery before send authorization — schema check in `090_notification_delivery.sql`
- send permit was not one-use
- uncertain ping was automatically retried
- uncertainty/authorization facts were not retained separately — schema check in `090_notification_delivery.sql`
- terminal uncertainty was rewritten after dispatch
- consumed one-use permit could be reopened — schema check in `090_notification_delivery.sql`
- message delivery success had no Discord message ID
- confirmed delivery was not terminal
- expired unattempted ping was dispatched
- expired ping authorization was reused
- publication fence did not advance
- stale publisher could confirm another worker lease — schema check in `090_notification_delivery.sql`
- missed eight/four hour checkpoints were not coalesced exactly once — schema check in `090_notification_delivery.sql`
- superseded checkpoint remained dispatchable
- active-war catch-up was not dispatchable
- catch-up used an old checkpoint label instead of current remaining time
- attempted checkpoint was relabeled as never-attempted catch-up
- ended war produced catch-up ping
- superseded desired-role generation remained applicable
- withdrawing one source erased another source role requirement
- reconciliation claimed an unrelated manually held role
- last source withdrawal retained desired role
- latest desired roles were not reconcilable
- ping one-attempt policy was wrongly applied to role reconciliation
- role retry did not fence out its stale worker
- stale role worker recorded current success
- role work for an absent member was not superseded
- unchanged desired roles were not queued again after the member returned
- an unchanged role set with deliverable work got another generation
- requeued desired roles were not reconcilable
- delivered roles of a present member got another generation
- delivered roles were not queued again after the member left and returned
- replayed report revision was queued twice — schema check in `090_notification_delivery.sql`
- first report revision was not queued as a pending create
- report create could not be dispatched
- delivered report create did not confirm its message once
- older waiting report revision remained sendable
- later report revision was not claimed as an edit
- two revisions of one report were in flight together
- report edit in flight lost its send permit
- report edit replaced the report message
- report message was declared missing before any edit was sent
- report edit could not be dispatched
- missing report message was kept
- report with a missing message was not recreated
- recreated report message was not recorded
- expired older report revision was claimed after a newer one
- expired older report revision was sent after a newer one
- latest report revision was blocked by an expired older one
- failed report edit could not be sent again
- adopted report message was replaced
- revision of a report with a known message was not an edit
- one logical key was accepted for two reports — schema check in `090_notification_delivery.sql`

### `130_leaderboard_calendars.sql`

- Calendar selection must be an uninitialized guild-settings projection — schema check in `100_leaderboard_calendars.sql`
- Initial reporting period did not use the GMT default
- Initial calendar policy was not selected in guild settings — schema check in `100_leaderboard_calendars.sql`
- Partial calendar selection was accepted — schema check in `100_leaderboard_calendars.sql`
- Calendar selection disagreed with its policy — schema check in `100_leaderboard_calendars.sql`
- Repeated period materialization was not idempotent
- Timezone transition introduced a gap or changed the old boundary
- Historical reporting period changed during timezone transition
- Named timezone did not retain the daylight-saving boundary
- Eastward timezone transition was not explicit and contiguous
- Period after a timezone transition did not return to local boundaries
- Historical period boundary was mutable — schema check in `100_leaderboard_calendars.sql`
- A reporting-period gap was accepted
- A future period could be frozen prematurely
- An ordinary member configured the calendar
- An invalid timezone was accepted
- Timezone request retry was not idempotent
- A stale request retry replaced the newer next-period policy
- Timezone configuration changed an active reporting period
- Timezone command leaked its scoped audit context
- Conflicting timezone operation identity accepted — schema check in `100_leaderboard_calendars.sql`
- An existing calendar policy was mutable — schema check in `100_leaderboard_calendars.sql`
- Eligible member did not earn the leaderboard fixture
- Current member score did not use retained period boundaries
- Departed member remained on current-member leaderboards
- Departure erased retained XP evidence
- Rejoin did not restore current-member leaderboard eligibility
- Unsupported monthly counter formula was silently invented — schema check in `100_leaderboard_calendars.sql`
- Runtime can bypass the authorized timezone setter

### `140_feature_integration.sql`

- A missing field in another profile observation erased a supported TH
- Error expected: Unmanaged role was attributed to another role operation
- A repeated reminder must not duplicate — schema check in `030_coc.sql`
- A deleted reminder must be gone
- Transfer limits must be configurable guild settings
- Updating CWL settings replaced unrelated clan collection settings
- new_joinee
- war
- Error expected: Null clan scope escaped into a server role binding — schema check in `010_dimensions.sql`
- Error expected: Clan-scope deletion removed a server capability
- Partial feature configuration overwrote another shared setting
- A shared binding write must produce one classified configuration audit record
- The untyped configuration transport is gone
- No runtime entry point takes a JSON argument
- INSERT
- EXECUTE
- final
- A trusted worker cannot obtain supported owner scopes without raw link-ledger access
- SELECT
- Error expected: Admin granted developer status
- Error expected: Admin viewed developer-only configuration history
- chat_xp_eligibility_role
- EXECUTE
- EXECUTE
- INSERT
- UPDATE
- UPDATE
- Change history must cover the configuration tables and no activity table
- leadership
- report_create
- Error expected: Output accepted an invalid CWL day
- An older plan was queued after a newer plan of the same clan and War Day
- The newest plan must stay the latest revision of the roster report
- A replayed plan must return its own operation
- Unlinking one account removed another account requirement
- A known Discord departure did not suppress queued role work
- superseded

### `150_runtime_paths.sql`

- runtime configured a tracked clan directly
- runtime member state did not go through its entry point exactly once
- runtime could not read the membership it recorded
- runtime could not read the lifetime war-star board
- runtime could not credit an eligible message
- runtime could not read the credited XP total
- runtime could not read the current monthly board
- first Kafka receipt was not recognised
- runtime worker could not obtain its send permit
- runtime could not read the delivered operation
- runtime read private table %
- runtime was allowed to run: %
- command replay returned % instead of its stored result %
- a new command ran without its permission
- a start day missing from February was accepted — schema check in `040_clan_games.sql`
- a disabled schedule did not report a clear error
- the XP policy catalog was offered as a setting — schema check in `050_discord.sql`
- a guild function is executable by PUBLIC
- the schema owner still grants EXECUTE on new functions to PUBLIC
