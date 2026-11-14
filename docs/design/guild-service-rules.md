# Guild service rules

Behavioral contracts for the Java guild service
([ADR 0012](../decisions/0012-guild-star-schema.md)). The service is not
written yet. These contracts describe its target behavior, not completed
runtime functionality. The migrations currently enforce only declarative
constraints and grants; **Backed by** describes that current protection.

The [working plan](star-schema-working-plan.md) is the entry point: it lists
the schema gaps (`GAP-…`), the decisions for the project owner (`DEC-…`) and
the order of the service workstreams. The
[feature specifications](../feature-specs/README.md) are the requirements, the
[design](guild-star-schema.md) explains the model, and the
[SQL reference map](guild-sql-reference-map.md) maps every function, trigger
and test check of the reference to a rule here.

## How to use this file

For a concrete starting task, use the working plan's
[Claude investigation packets](star-schema-working-plan.md#claude-handoff-what-to-inspect-next).
They point to the relevant files, symbols and regression cases; read only the
catalog sections needed by the selected packet.

- Each rule has an ID, such as `SR-ACC-09`. Cite it in code comments, commit
  messages and test names. Requirement IDs, such as `LINK-014`, come from the
  feature specifications.
- Each section starts with its **Specs**, **Tables** and **Checks**: the
  feature specifications behind it, the tables it writes with their
  migration, and the test files of the reference to port (see the
  [SQL reference map](guild-sql-reference-map.md#checks-of-the-sql-tests)).
- **Source** is historical provenance: a function or trigger at `c407abb`,
  tagged `guild-sql-reference`. Read it with
  `git show guild-sql-reference:services/guild/schema/src/main/resources/db/migration/V2__account_links.sql`.
  The tag keeps that commit reachable after the branch is squashed. Port its
  tests selectively; do not copy behavior that conflicts with the feature
  specifications or a corrected contract here.
- **Backed by** names the constraint that stays in the schema. The service
  still checks the rule first, so that the caller gets a clear failure; the
  constraint is the last line of defence and settles races.
- A failure is marked with its class: **[permission]**, **[rule]**,
  **[input]**, **[missing]** or **[conflict]**. [SR-CTX-05](#sr-ctx-05-failure-classes)
  maps the classes to the SQLSTATE codes that the SQL raised.
- **Change / target** marks a correction to the historical SQL or a required
  implementation change. A `GAP` can require schema work, service work, or
  both; use its classification in the working plan. A `DEC` is an unresolved
  owner decision: do not treat the reference's behavior as an approved answer.
- **Current schema** marks a limitation that remains in the migrations.
  Proposed tables or columns do not exist until their named gap is closed.
- **Acceptance** records required regression cases in addition to the feature
  specification's scenarios. A passing historical SQL test does not establish
  that a feature or its adapters are complete.

When adding or changing a rule, state its requirement IDs, actor/preconditions,
lock order, records and delivery intents written in the transaction, stable
retry identity and failure behavior, current database backstop, and acceptance
cases. Use prose or a short sequence; do not repeat section-wide defaults.
External I/O belongs between durable transaction steps, never inside a JDBC
transaction held open across a Discord, CoC, Kafka, or Sheets call.

## Sections

| Code | Section |
| --- | --- |
| SR-CTX | [Transactions, clock, locks, idempotency and failures](#sr-ctx-transactions-clock-locks-idempotency-and-failures) |
| SR-AUTH | [Permission checks](#sr-auth-permission-checks) |
| SR-CFG | [Configuration and its change history](#sr-cfg-configuration-and-its-change-history) |
| SR-ACC | [Verification, account links, transfers and refresh](#sr-acc-verification-account-links-transfers-and-refresh) |
| SR-MEM | [Clan membership, member list and seasons](#sr-mem-clan-membership-member-list-and-seasons) |
| SR-WAR | [Wars and attacks](#sr-war-wars-and-attacks) |
| SR-CG | [Clan Games](#sr-cg-clan-games) |
| SR-DSC | [Discord presence and roles](#sr-dsc-discord-presence-and-roles) |
| SR-XP | [Chat XP and ranks](#sr-xp-chat-xp-and-ranks) |
| SR-MOD | [Warnings, kicks and moderation notices](#sr-mod-warnings-kicks-and-moderation-notices) |
| SR-ACT | [Activity commands](#sr-act-activity-commands) |
| SR-CWL | [Clan War Leagues](#sr-cwl-clan-war-leagues) |
| SR-CUS | [Custom events](#sr-cus-custom-events) |
| SR-NTF | [Notifications and delivery](#sr-ntf-notifications-and-delivery) |
| SR-LB | [Leaderboard calendars and boards](#sr-lb-leaderboard-calendars-and-boards) |
| SR-GRANT | [Runtime grants](#sr-grant-runtime-grants) |
| SR-TEST | [Porting the SQL tests](#sr-test-porting-the-sql-tests) |

## Open changes

The working plan is the sole status register for
[gaps](star-schema-working-plan.md#schema-gaps) and
[owner decisions](star-schema-working-plan.md#decisions-for-the-project-owner).
This catalog links blockers where they change behavior; do not maintain a
second checklist here. For a task, read its feature specification, the plan's
feature/workstream row, then only the rule sections needed for that task.

Accepted choices must also reach their owning feature specification. The
specifications still call transfer expiry, kick recovery, and report
creation/replacement behavior open in places where ADR 0012 and this catalog
record selected behavior. Propagate those accepted choices before declaring
the corresponding workstream complete; keep genuinely unresolved `DEC` items
open. An ADR note alone cannot waive an agreed requirement such as MOD-009.

## SR-CTX: Transactions, clock, locks, idempotency and failures

**Specs:** NOTIFY-003, NOTIFY-004 and every requirement that names a retry, a
race or a restart. **Tables:** all. **Checks:** `090_security_hardening.sql`
and `150_runtime_paths.sql`, most of which were dropped with the functions
(SR-TEST).

### SR-CTX-01 One transaction per command

Every command and every worker step runs in one JDBC transaction through jOOQ,
inside the blocking boundary of
[ADR 0007](../decisions/0007-per-service-database-schemas.md): a
`TransactionTemplate` on `jdbcTransactionManager`, inside `Mono.fromCallable`
on `jdbcScheduler`. The checks, the writes and the derived writes of one rule
belong to that transaction. In the SQL, triggers made derived writes part of
the same statement; in Java, the method that writes the source row also writes
the derived rows, before the commit. Never split one rule across a JDBC and an
R2DBC transaction.

### SR-CTX-02 Clock

The SQL took the time from `clock_timestamp()` (the wall clock at the call) for
defaults and decisions, and from `statement_timestamp()` in a few checks, such
as "is this CWL day frozen" and "is this period in the future".

- Inject a `java.time.Clock`. Tests use a fixed or stepping clock.
- Take "now" after acquiring the locks of a rule whose result depends on order.
  Chat XP uses the processing time after the member lock (SR-XP-03).
- Several SQL commands accepted an explicit time, such as `p_linked_at` or
  `p_issued_at`, and defaulted it to now. Keep explicit times only where a
  worker records an observed time, such as a Clan Games boundary read. Commands
  from members use the service clock.
- Store `timestamptz`. GMT months, seasons and reporting periods are computed
  with `java.time` in UTC or the configured zone, never in the JVM default
  zone.

### SR-CTX-03 Locks

Use row locks and transaction-scoped advisory locks through jOOQ
(`SELECT … FOR UPDATE`, `SELECT pg_advisory_xact_lock(…)`). The table gives
lock scopes from the SQL reference; the ordering rules below correct its
moderation deadlock (GAP-14).

| Lock | Scope | Taken by |
| --- | --- | --- |
| `dim_player_account` row `FOR UPDATE` | One account | Link, unlink, transfer request |
| Advisory `guild.account-primary:<user>` | One member's primary | Link, unlink, set primary; take several in ascending user key |
| Advisory `discord-membership`, user | One member's presence, roles, XP and warnings | Membership events, role events, XP credit, warning issue, rejoin notices |
| Advisory `chat-xp-message`, message | One Discord message | XP credit |
| Advisory `warnings`, subject and GMT month | One member's warning month | Warning issue and revocation |
| Advisory `warning-command`, operation | One warning command | Issue and revoke commands with UUID |
| Advisory `clan-member-observation`, clan and player | One member list row | Member list store-on-change |
| Advisory `activity-operation`, operation | One activity command | CWL and custom-event commands |
| Advisory `cwl-signup`, cycle and player | One account's CWL signup | CWL signup |
| Advisory `cwl-plan`, participation | One clan's plan numbering | Begin plan |
| Advisory `cwl-roster-output`, participation and day | One roster report | Queue CWL roster report |
| Advisory `cwl-export`, participation and kind | One clan's export sequence | Create a CWL export revision |
| `cwl_sheet_destination` row `FOR UPDATE` | One Sheets destination | Claim, authorize and record a Sheets write |
| Advisory `leaderboard-calendar` | The calendar | Period creation, timezone change |
| `moderation_action` row `FOR NO KEY UPDATE` | One kick decision | Claim, attempt, cancellation |
| `account_transfer_request` row `FOR UPDATE` | One transfer | Decide, link |
| `notification_role_target` row, then the operation row | One member's role work | Claim, begin send, desired roles |
| `notification_report` row, then the operation row | One report | Claim, record result, report missing, queue revision |
| `cwl_cycle`, plan, incident and custom-event rows `FOR UPDATE` | One workflow record | Close signups, publish, bench, roster |
| `dim_war` row `FOR UPDATE` | One war's reminders | Schedule reminders, catch-up |

Keep role target before operation, report before operation, and player row
before member locks. For all moderation paths, take member, then warning
month, then action row; take several months/actions in a stable ascending
order. Discover immutable subject/month identifiers without locking the action,
then acquire this order and revalidate. Never lock the action and subsequently
request the member lock while deriving rejoin notices. Command-UUID locks are
outer locks and must use the same position in issue/revoke paths.

**Acceptance (GAP-14, MOD-004, MOD-006):** run warning issuance/rearming and
kick-result/rejoin processing in two connections. Both transactions complete
without a lock cycle, duplicate decision, or duplicate notice. Include
revocation racing with claim and result recording.

### SR-CTX-04 Idempotency

A retried call must not apply its effect twice. The SQL used these identities:

- Activity commands (CWL, custom events): an operation UUID in
  `activity_command_operation` (SR-ACT-01).
- Warning issue and revocation: an operation UUID on the warning or
  revocation row (SR-MOD-03, SR-MOD-05).
- Leaderboard timezone changes: an operation UUID on the policy row
  (SR-LB-04).
- Discord membership and role events: `operation_id`, unique per row. The
  collector must pass a stable ID for a redelivered gateway event; the column
  default is random and does not deduplicate.
- Chat XP: the Discord message ID (SR-XP-03). Manual moderation: the audit log
  entry ID (SR-MOD-12).
- Notifications: the logical key of an operation (SR-NTF-01) and the Kafka
  coordinate of a receipt (SR-NTF-04).
- Clan Games requests: the unique key of a read request (SR-CG-04).

The pattern: lock on the identity, read the stored row, compare the stored
arguments with the new call, then return the stored result or fail with
**[conflict]** when the arguments differ.

### SR-CTX-05 Failure classes

| Class | SQLSTATE in the SQL | Meaning | Suggested Java handling |
| --- | --- | --- | --- |
| [permission] | `42501` | The actor lacks the capability, or acts for an account that is not theirs | Permission-denied exception, shown to the user |
| [rule] | `23514` | A business rule rejects the request | Rule-violation exception with the reason |
| [input] | `22023` | An argument is invalid, missing or in the future | Invalid-argument exception |
| [missing] | `23503`, `P0002` | A referenced row does not exist | Not-found exception |
| [conflict] | `23514`, `23505`, `23P01` | A retry differs from the stored call, or a unique or exclusion constraint rejected the write | Conflict exception; translate constraint names to messages |

Catch `23505` (unique) and `23P01` (exclusion) from the database and translate
them. They are the backstop for every race that the service's own checks miss.

### SR-CTX-06 Append-only records

These tables never change after insert, apart from the columns named in
[SR-GRANT](#sr-grant-runtime-grants). The SQL rejected updates and deletes
with triggers; now the runtime role has no `UPDATE` or `DELETE` grant on
them, and the schema check `110_runtime_grants.sql` proves it.

- Account links: `fact_primary_account_change`.
- Discord: `fact_discord_membership_event`, `fact_discord_accepted_join`,
  `fact_role_change`, `fact_chat_xp_decision`, `fact_chat_rank_change`.
- Moderation: `warning`, `warning_revocation`,
  `fact_moderation_action_attempt`, `fact_manual_moderation_action`,
  `fact_moderation_notice`.
- CWL and custom events: `fact_cwl_group_observation`,
  `fact_cwl_registered_clan`, `fact_cwl_registered_player`,
  `fact_cwl_signup_revision`, `fact_cwl_plan_input`, `fact_cwl_bench_incident`,
  `fact_cwl_bench_resolution`, `fact_cwl_export_attempt`,
  `fact_cwl_manual_pin_revision`, `fact_cwl_day_freeze`, `fact_cwl_participation_revision`,
  `fact_custom_event_signup_revision`,
  `custom_roster_revision`, `custom_roster_account`; `cwl_round_war_reference`
  has no `DELETE` grant and only its `war_key` is updatable, which the
  service fills in once.
- Delivery: `fact_notification_dispatch_attempt` (no delete; its outcome is
  write-once, SR-NTF-09), `notification_kafka_receipt`,
  `notification_cwl_context`, `notification_mention_role`, `notification_mention_user`,
  `notification_raid_report_context`,
  `notification_clan_games_report_context`,
  `notification_clan_games_report_assessment`,
  `notification_clan_games_report_progress`.
- Configuration and calendars: `fact_configuration_change`,
  `leaderboard_calendar_policy`, `dim_leaderboard_monthly_period`.
- Reference data seeded by the migrations: `chat_xp_policy`, `chat_rank_tier`.
  The runtime role does not write them.

The views `fact_chat_xp_award` and `fact_warning_event` are read-only.

## SR-AUTH: Permission checks

**Specs:** CFG-003, CFG-004, CFG-005, CFG-009, CFG-010, CFG-011, and the
access tables of every feature. **Tables:** `developer_allowlist`,
`role_binding` (`V1`); `discord_member_role`, `discord_member_state` (`V4`).
**Checks:** `050_access.sql`.

### SR-AUTH-01 Actor identity

The actor of a command is the Discord user of an interaction that the Discord
service relayed ([ADR 0009](../decisions/0009-discord-interaction-service.md)).
Never take an actor ID from a payload field or from another service. Workers
act as the system and have no actor.

### SR-AUTH-02 Developer

Source: `is_developer` (V1).

A user is a developer when `developer_allowlist` has a row for them. The
operator seeds the first developer with `tools/postgres/seed-guild.sql`, which
also creates the guild row and its settings; after that the allowlist changes
only through SR-CFG-12.

### SR-AUTH-03 Held role

Source: `has_bound_role` (V1).

A user holds a capability when all of these are true:

- `discord_member_role` has a row for the user and a role;
- `server_role_binding` binds that role to one of the requested purposes;
- the role is not deleted (`dim_discord_role.deleted_at` is null);
- the held role has not expired (`expires_at` is null or later than now);
- the user is confirmed present: a `discord_member_state` row with
  `is_present = true`.

**Change (DEC-06, decided 2026-11-14, CFG-010):** the SQL also passed a user
with no `discord_member_state` row. Authority now fails closed: unknown
presence grants nothing, although the held-role projection (SR-DSC-03) can
hold a role before the first membership event. The Discord collector records
presence from the gateway member list at startup and after each reconnect, so
existing staff gain a state row without a join event.

**Acceptance:** a held `admin` role without a state row grants nothing; the
same role after a present state row grants Configure; after a departure it
grants nothing again.

Historical role events never grant authority; only the current projection
counts.

### SR-AUTH-04 Capabilities

| Capability | Who | Used by |
| --- | --- | --- |
| Configure | Developer, or held `admin` | Configuration commands, CWL cycle creation, manual Clan Games events, leaderboard timezone |
| Moderate | Held `leadership`, `co_leader` or `admin` | Warnings, other members' warning and moderation history |
| Manage links | Held `co_leader` or `admin` | Transfer decisions, account-link history |
| CWL and custom-event staff | Held `co_leader` or `admin` | Late signups, manual plans, assignments, pins, bench overrides, custom events |
| Select CWL clans | Held `leadership`, `co_leader` or `admin` | CWL clan selection |
| Read Clan Games results | Held `leadership` only | Member pass/fail results |
| Manage developers, read configuration history | Developer only | Allowlist changes, configuration change history |
| Own account | The member with a current link to the account | Profile refresh, CWL and custom-event signups for that account |
| Own history | The subject of the history | Own warning and moderation history |

A developer allowlist entry alone grants no moderation, link or CWL capability.

## SR-CFG: Configuration and its change history

**Specs:** CFG-001 to CFG-008, MEM-001, MEM-015, CG-001, CG-004.
**Tables:** `guild_settings`, `role_binding`, `channel_binding`,
`developer_allowlist` (`V1`); `clan_collection_settings`,
`war_reminder_setting` (`V3`); `chat_xp_eligibility_role`,
`chat_rank_role_binding` (`V4`); `fact_configuration_change` (`V5`).
**Checks:** `050_access.sql`, `080_command_actors.sql`,
`140_feature_integration.sql`.

### SR-CFG-01 Configuration command envelope

Source: `begin_configuration`, `begin_command_scope`, `end_command_scope` (V5).

- The actor must be able to configure (SR-AUTH-04). [permission]
- The reason must not be blank. [rule]
- The command writes only the columns it owns. It creates the guild settings
  row when it is missing, keyed by the single `dim_guild.guild_key`, and sets
  `guild_settings.updated_at` on every change.
- The command writes its change history in the same transaction (SR-CFG-13).
  The SQL kept the actor and reason in transaction-local settings and restored
  the previous values afterwards, so that a later collector statement in the
  same transaction was not attributed to the human. In Java, pass the actor and
  reason explicitly to the configuration repository; never keep them in
  ambient or thread state.

### SR-CFG-02 Guild settings commands

Source: `set_new_joinee_days`, `set_verification_policy`,
`set_transfer_policy`, `set_kick_policy`, `set_clan_games_schedule`,
`set_clan_games_refresh` (V5).

| Command | Columns it owns | Constraint |
| --- | --- | --- |
| New Joinee days | `new_joinee_days` (default 7) | `> 0` |
| Verification policy | `verification_max_age_seconds` (default 900) | `> 0` |
| Transfer policy | `transfer_pending_max_age_seconds` (172800), `transfer_approval_max_age_seconds` (86400) | `> 0` |
| Kick policy | `kick_max_attempts` (3), `kick_retry_seconds` (300) | `> 0` |
| Clan Games schedule | `clan_games_enabled` (true), `clan_games_start_day` (22), `clan_games_start_time_utc` (08:00), `clan_games_event_seconds` (518400), `clan_games_account_points_cap` (4000) | day 1–28; event longer than 86400 seconds; cap `> 0` |
| Clan Games reads | `clan_games_refresh_seconds` (900), `clan_games_checkpoint_tolerance_seconds` (1800, DEC-03) | `> 0`; the tolerance is shorter than the event minus 86400 seconds, so the T−24h window opens inside the event |

To change one value, the caller reads the current values and passes the
others back unchanged. No command deletes the guild settings row. The chat XP
policy key and the leaderboard calendar pointers have no configuration command
(SR-XP-01, SR-LB-04).

### SR-CFG-03 Role bindings

Source: `set_server_role`, `delete_server_role`, `set_clan_role`,
`delete_clan_role`, `set_town_hall_role`, `delete_town_hall_role` (V5).

- Server bindings: purposes `applicant`, `member`, `new_joinee`, `admin`,
  `co_leader`, `leadership`. One role per purpose; setting replaces the role.
- Clan bindings: purposes `member`, `war`, `cwl`, one role per clan and
  purpose. The clan is required. [rule]
- Town hall bindings: one role per level (`> 0`). The level is required.
  [rule]
- A command never reaches a binding of another scope: a clan or town hall
  command without its clan or level fails instead of touching a server
  binding.
- Backed by: one `role_binding` table with
  `UNIQUE NULLS NOT DISTINCT (purpose, clan_key, town_hall_level)`, a check that
  a row has at most one of clan and level, and a check of the purposes allowed
  in each scope.

### SR-CFG-04 Channel bindings

Source: `set_channel_binding`, `delete_channel_binding` (V5).

- Purposes: `welcome`, `clan_games`, `raid_weekend`, `clan_logs`,
  `moderation_logs`, `leadership_notifications`, `war`, `cwl_signups`,
  `cwl_roster`.
- `war`, `cwl_signups` and `cwl_roster` need a clan; the others must not have
  one. `cwl_roster` also needs a War Day from 1 to 7; the others must not have
  one.
- Setting replaces the channel of the same purpose, clan and day. Deleting
  matches purpose, clan and day, treating absent values as equal.
- Several purposes may share a channel. Discord's channel permissions decide
  who reads it; the schema keeps no copy of the channel ACL.

### SR-CFG-05 Tracked clans

Source: `set_clan_collection` (V5).

- Upsert `enabled` and the cadences, each `> 0` (CFG-001; defaults agreed on
  2026-11-14, DEC-04):

  | Column | Default (seconds) | Collector |
  | --- | ---: | --- |
  | `membership_poll_seconds` | 120 | Member list (MEM-002) |
  | `war_poll_seconds` | 120 | Current war (WAR) |
  | `player_profile_seconds` | 3600 | Profiles and town halls outside Clan Games (MEM-009) |
  | `cwl_group_poll_seconds` | 900 | CWL group and registration (CWL) |
  | `cwl_war_poll_seconds` | 120 | CWL round wars (CWL) |
  | `raid_poll_seconds` | 900 | Raid weekend state (RAID-003) |
  | `raid_report_seconds` | 28800 | Raid report revision (RAID-003) |

  The Clan Games refresh stays a guild setting (`clan_games_refresh_seconds`,
  default 900, CG-004).
- No command deletes a tracked clan. Collected facts reference its settings
  row; switch it off with `enabled = false`.
- **Change (GAP-04, closed 2026-11-14):** before DEC-04 only the member list
  and raid report cadences existed per clan.

### SR-CFG-06 CWL clan settings

Source: `set_cwl_clan_settings` (V5).

- Upsert `automatic_freeze_minutes` (default 60, `>= 0`) and
  `sheet_document_id` on the clan's collection settings row. Other columns of
  that row are preserved.
- The clan must already be tracked: its `clan_collection_settings` row must
  exist. [missing] The command never creates that row.
- **Change (DEC-07, decided 2026-11-14, CFG-012):** the SQL created the
  collection settings row when it was missing, which also started tracking the
  clan with default settings. Staff now add the clan through SR-CFG-05 first.

### SR-CFG-07 War reminders

Source: `set_war_reminder`, `delete_war_reminder` (V5).

- A reminder is a number of seconds before the war ends (`> 0`) for one
  tracked clan. Adding an existing offset changes nothing. Initial
  configuration should add 28800 and 14400.
- Backed by: primary key `(clan_key, seconds_before_end)` and a foreign key to
  the tracked clan.

### SR-CFG-08 Chat XP eligibility roles

Source: `set_chat_xp_eligibility_role`, `delete_chat_xp_eligibility_role` (V5).

Any number of roles; holding any one of them qualifies (SR-XP-03). Adding an
existing role changes nothing.

### SR-CFG-09 Rank roles

Source: `set_chat_rank_role`, `delete_chat_rank_role` (V5).

One role per rank (ranks 1–10), and a role serves at most one rank. Setting
replaces the role of the rank. Backed by: primary key on the rank and a unique
role.

### SR-CFG-10 Configuration change history reader

Source: `configuration_audit_for` (V5).

Only developers read `fact_configuration_change`. [permission] An Admin role
alone does not grant this (CFG-005).

### SR-CFG-11 Clan Games results reader

Source: `clan_games_results_for` (V5).

Only holders of the `leadership` role read member pass/fail results
(`clan_games_member_result`), optionally for one event. [permission]

### SR-CFG-12 Developer allowlist

Source: `manage_developer` (V5).

- Only the owner developer (`guild_settings.owner_developer_user_key`) can
  add or remove a developer (CFG-004). [permission] Another developer cannot,
  not even to remove themselves.
- The decision (add or remove) and a non-blank reason are required. [rule]
- Adding records who added the developer; adding an existing developer changes
  nothing. Removing deletes the row. Removing the owner is refused. [rule]
- The change is recorded as a configuration change with the actor and reason.
- Backed by: the owner column references the allowlist, so the owner's row
  cannot be deleted; the runtime role has no `UPDATE` grant on the owner
  column, so only an operator changes the owner (SR-CFG-13 operator procedure).
  `tools/postgres/seed-guild.sql` makes the first developer the owner.
- **Change (DEC-08, decided 2026-11-14):** the SQL let any developer add or
  remove developers, including themselves or the last one. Only the main
  developer manages the allowlist now.

**Acceptance:** the owner adds and removes a developer; another developer's
add or remove fails [permission]; removing the owner fails, also through a
direct runtime `DELETE` (foreign key); the runtime role cannot change the owner.

### SR-CFG-13 Configuration change history

Source: `record_configuration_change` (V5), attached in V9.

Every insert, update and delete on these tables writes one row to
`fact_configuration_change`: `guild_settings`, `role_binding`,
`channel_binding`, `clan_collection_settings`, `war_reminder_setting`,
`developer_allowlist`, `chat_xp_eligibility_role`, `chat_rank_role_binding`,
`leaderboard_calendar_policy`, and `dim_clan_games_event` rows created by
hand (`schedule_source = 'manual'`; scheduled events are not recorded). The
SQL also covered `chat_xp_policy` and `leaderboard_metric_definition`. The
service cannot write that reference data (SR-GRANT), so only a migration
changes it, and it has no change history.

| Column | Value |
| --- | --- |
| `actor_user_key` | The command actor; null for an operator change |
| `source` | `command` when a command made the change, otherwise `operator` |
| `changed_at` | Now |
| `entity_type` | The table name |
| `entity_identity` | JSON object of the table's primary-key columns and values |
| `previous_value` | JSON of the whole row before the change; null for an insert |
| `new_value` | JSON of the whole row after the change; null for a delete |
| `reason` | The command reason; `Migration/operator configuration change` for other changes |
| `transaction_id` | The database transaction ID |

- Backed by: `source = 'command'` requires an actor; a row needs a previous
  or a new value. Rows are never updated or deleted (SR-CTX-06).
- All configuration writes go through the one repository that records them.
- **Change (DEC-09, decided 2026-11-14, CFG-013):** the trigger also recorded
  changes that an operator made with SQL outside the service. No trigger
  exists now, so an operator who edits configuration with direct SQL, for an
  emergency or bootstrap only, inserts the `operator` row in the same
  transaction: null actor, the entity, the values before and after, and a
  reason. `tools/postgres/seed-guild.sql` follows this procedure, and the
  [schema guide](../../services/guild/schema/README.md#operator-configuration-changes)
  describes it. An unrecorded direct edit is a procedure violation.

## SR-ACC: Verification, account links, transfers and refresh

**Specs:** LINK-001 to LINK-017, CG-013, CG-014, CG-017. **Tables:**
`player_verification`, `account_link`, `metric_attribution_episode`,
`account_transfer_request`, `fact_primary_account_change` (`V2`);
`fact_api_fetch_attempt` (`V1`). **Checks:** `020_account_links.sql`, and the
transfer checks of `100_clan_games.sql`.

### SR-ACC-01 Record a verification

Source: `record_player_verification` (V5).

- Status is `verified`, `rejected` or `error`. `checked_at` is now.
- When a fetch attempt is given, it must be for the same player, requested by
  the same user, with endpoint `verify_player`, and a `verified` status needs
  a fetch with outcome `succeeded`. [rule]
- Never store the supplied token or the token that the API echoes, in any
  column, payload, reason, log or correlation ID (LINK-004).

### SR-ACC-02 Matching verification

Source: `link_player_account`, `request_account_transfer` (V2).

A link or a transfer request needs a verification row with the given key, for
the same user and player, with status `verified` and `checked_at` not after
the action time. [rule] Backed by: a composite foreign key
`(verification_key, user_key, player_key, status = 'verified')` from
`account_link` and `account_transfer_request`.

### SR-ACC-03 Recent verification

Source: `require_recent_verification` (V2).

A verification can start a first link or a transfer request only while
`checked_at > action time − verification_max_age_seconds` (default 900).
[rule: verify the account again] An approved transfer completes later with the
verification its request recorded, without this age check; the transfer
limits (SR-ACC-06) apply instead.

### SR-ACC-04 Request a transfer

Source: `request_account_transfer` (V2).

1. Lock the player row.
2. The player must have a current link owned by a different member. [rule]
3. The recipient's verification must match (SR-ACC-02) and be recent
    (SR-ACC-03).
4. Expire the lapsed requests of this source link (SR-ACC-07), so that a
    lapsed request does not block a new one.
5. Insert a `pending` request with the current owner, the recipient, the
    source link and the verification.

Any member can request; the recipient's verification proves control of the
account. Backed by: one `pending` request per source link and recipient
(partial unique index), `from_user_key <> to_user_key`, and the status check
of SR-ACC-08.

### SR-ACC-05 Decide a transfer

Source: `decide_account_transfer` (V2).

Checked in this order:

1. The decision (approve or reject) is required. [input]
2. The request must exist; lock it. [input]
3. The actor must be able to manage links (SR-AUTH-04). [permission]
4. A request that is `expired`, or `pending` past its limit at the decision
    time, fails. [rule: the recipient must request again]
5. The request must still be `pending`. [rule: already decided]
6. The source link must still be current. [rule]
7. Set `approved` or `rejected`, `decided_by` and `decided_at`.

### SR-ACC-06 Transfer limits

Source: `account_transfer_expires_at`, `clan_games_transfer_wait_until` (V2,
V3).

| Status | Expires at |
| --- | --- |
| `pending` | `requested_at + transfer_pending_max_age_seconds` (two days) |
| `approved` | `decided_at + transfer_approval_max_age_seconds` (one day) |
| `awaiting_points` | `max(decided_at, wait_until) + transfer_approval_max_age_seconds` |
| other | none: the request is closed |

`wait_until` is infinity while any Clan Games read request for the transfer is
`pending`; otherwise it is the latest `observed_at` of a counter read for the
transfer, or nothing when there is none. A slow boundary read therefore never
expires an approved transfer, and the approval limit restarts when the read
arrives.

### SR-ACC-07 Expire transfers

Source: `expire_account_transfers`, `_expire_account_transfers` (V2).

- The as-of time is required and must not be in the future. [input]
- Every open request (`pending`, `approved`, `awaiting_points`) whose expiry
  (SR-ACC-06) is at or before the as-of time becomes `expired`, with
  `expired_at` set to that expiry. Earlier decisions stay as history.
- Idempotent; returns the number of requests expired. The decide and link
  commands apply the same limit themselves, so a request that the scheduler
  has not reached yet still cannot be used.

### SR-ACC-08 Transfer request states

Backed by the status check on `account_transfer_request`:

| Status | Required columns |
| --- | --- |
| `pending` | no decision, consumption or cancellation |
| `approved`, `awaiting_points`, `rejected` | `decided_by`, `decided_at >= requested_at`; not consumed or cancelled |
| `consumed` | decided, `consumed_at >= decided_at`; not cancelled |
| `cancelled` | `cancelled_at`; not consumed; decision fields both set or both empty |
| `expired` | `expired_at >= requested_at`; not consumed or cancelled |

A request is used at most once (unique `account_link.transfer_request_key`).

### SR-ACC-09 Link an account

Source: `link_player_account`, `ensure_clan_games_transfer_read` (V2, V3).

1. Lock the player row; the player must exist. [input]
2. If the player is already linked to this user, return that link and stop.
3. Take the primary lock (SR-CTX-03) for the user and, when the account is
    linked to someone else, for the current owner, in ascending user key.
4. The player must be currently tracked (SR-MEM-04). [rule] This applies to
    transfers too.
5. The verification must match (SR-ACC-02).
6. Without a current owner, the verification must be recent (SR-ACC-03), and
    a transfer key must not be given. [rule]
7. With a current owner (a transfer):
    - The transfer request must exist (lock it), be `approved` or
      `awaiting_points`, name this user as recipient, this player, the
      current link as source, and this verification. [permission]
    - The request must not have expired at the link time. [rule]
    - When the owner's link is their primary and the owner has other current
      links, the transfer still completes and leaves the owner without a
      primary (DEC-02); nobody else chooses a replacement (LINK-002).
    - Clan Games gate: when an event is running at the link time
      (`starts_at <= time < ends_at`), the link needs a transfer counter read
      for this request observed exactly at the link time and not before the
      decision. Without one, queue a `transfer` read request due at the link
      time (idempotent), set the request to `awaiting_points`, change no link
      and return nothing. Without a running event there is no gate.
    - End the owner's link at the link time.
8. Attribution: lock the account's open attribution episode. Reuse it when it
    belongs to this user. Otherwise close it at the link time (when there is
    one) and open a new episode at the link time. The new episode may backfill
    earlier history (`include_prelink_history`) only when the account never
    had an episode before.
9. Primary: when the caller asks for primary, demote the user's current
    primary. The new link is primary when asked, or when the user has no other
    current link. Retain the old primary identity for the history row.
10. Insert the link with the verification, the episode, the transfer key and
    the boundary read, when there is one; obtain its generated link key.
    If the new link becomes primary, only then record the change
    (SR-ACC-16): `first_link` without another current link, otherwise `choice`.
    Adding an alt without changing primary writes no primary-change fact.
    The history's new-link foreign key is immediate, so writing history
    before the link fails (GAP-18, corrected).
11. For a transfer: mark the request `consumed` at the link time and cancel
    every other open request of the old source link (SR-ACC-12). When the old
    link was the owner's primary and the owner keeps other current links,
    record `primary_transferred` for the owner (SR-ACC-16). When the old
    link was the owner's last current link, record `link_ended` for the owner
    (SR-ACC-16).

Backed by: no overlapping link intervals per account (exclusion constraint);
one current owner per account and one current primary per member (partial
unique indexes); a link's boundary read must match its transfer, player and
link time (composite foreign key).

**Acceptance (LINK-002, LINK-017):** first-link and make-primary commands
commit the new link and its matching history together; failure of either
write rolls back both. Adding an alt preserves the existing primary and its
history. None of these paths requires deferring a foreign key.

**Change (LINK-014):** a transfer in `awaiting_points` must complete
from database state when its read arrives, after a restart too: call the link
step again with the read's `observed_at` as the link time. Staff also need a
list of open requests (LINK-005).

**Change (DEC-02, decided 2026-11-14, LINK-002):** the SQL required the owner
to choose another primary first, so an absent owner blocked the transfer. The
transfer now completes and the owner has no primary until they choose one
with SR-ACC-10. **Acceptance:** owner with a primary and two alts, transfer of
the primary approved and completed (also through `awaiting_points`): both alts
stay linked, none is primary, a `primary_transferred` row has no new link,
and the owner's later choice writes `choice` without a previous link.

### SR-ACC-10 Choose the primary account

Source: `set_primary_account` (V2).

Take the user's primary lock. The account must be one of the user's current
links. [rule] Demote the current primary and promote the account, and record
a `choice` (SR-ACC-16). Only the member themself chooses (the service checks
that the actor is the user).

### SR-ACC-11 Unlink an account

Source: `unlink_player_account` (V2).

1. Lock the player row and the user's primary lock.
2. The account must be the user's current link. [permission: members unlink
    only their own accounts]
3. When it is the user's primary and the user has other links, a replacement
    is required, must differ from the account and must be one of the user's
    current links. [rule] Otherwise a replacement must not be given. [rule]
4. End the link now, cancel its open transfer requests (SR-ACC-12) and
    promote the replacement. Record `unlink_replacement`, or `link_ended`
    when the primary was the user's last link (SR-ACC-16).

The attribution episode stays open, so that a relink by the same member
continues it (LINK-010).

**Decided (DEC-01, 2026-11-14, LINK-010, CG-013):** the episode stays open,
so an account that stays unlinked keeps counting toward its former owner's
Clan Games target and points (SR-CG-03) until a different owner links it,
which closes the episode at that link (step 8 of SR-ACC-09).

### SR-ACC-12 Cancel the open requests of an ended link

Source: `cancel_open_account_transfers` (V2).

When a link ends, by unlink or by another recipient's completed transfer, its
`pending`, `approved` and `awaiting_points` requests become `cancelled` with
`cancelled_at` set. A consumed request is never cancelled. An earlier decision
stays as history.

### SR-ACC-13 At most one primary

Source: `require_one_primary_account`, a deferred constraint trigger (V2).

A member has at most one current primary; the partial unique index enforces
it. A member with current links has exactly one primary, except after an
approved transfer took their primary (DEC-02, LINK-002), until they choose
one. Check at the end of every link, unlink and primary transaction, for both
the owner and the recipient, that no other path leaves a member with links
and no primary. [rule]

**Change (DEC-02, decided 2026-11-14):** the SQL required exactly one primary
for every member with a current link.

### SR-ACC-14 Link history

Source: `account_link_history_for` (V2).

Only members who can manage links read all links of an account, ordered by
`linked_at` and link key, with the primary changes of SR-ACC-16. [permission]
The public view `current_account_link` shows only current links and the
primary flag; it never reveals a previous owner (LINK-015, LINK-016).

### SR-ACC-15 Profile refresh

Source: `request_player_refresh`, `require_manual_fetch_ownership` (V5).

- A member can request a refresh only for an account currently linked to them.
  [permission]
- The request is a `pending` `player_profile` fetch attempt with the requester
  and a correlation ID (default `manual:<uuid>`). A worker performs it.
- Ownership is checked when the request is created and when its requester,
  player or endpoint changes. A `verify_player` fetch needs only a player.
  Recording the outcome is not checked, so that the collector can finish a
  request after the member unlinked or transferred the account.
- Backed by: `pending` exactly when `completed_at` is null;
  `completed_at >= started_at`; HTTP status 100–599; a unique, non-blank
  correlation ID; the endpoint kinds `clan_members`, `player_profile`,
  `current_war`, `war_log`, `raid_seasons`, `verify_player`, `cwl_group`,
  `cwl_war`.

### SR-ACC-16 Primary history

No SQL source; the table was added for LINK-017. `account_link.is_primary`
holds only the current primary,
so every change of a member's primary is also a row in
`fact_primary_account_change`, written in the transaction that changes it:

| Cause | When | Previous | New |
| --- | --- | --- | --- |
| `first_link` | A link becomes primary because the member had no current link | none | the new link |
| `choice` | Another current link is chosen as primary, also while linking | the old primary | the chosen link |
| `unlink_replacement` | The primary is unlinked and its replacement named | the unlinked primary | the replacement |
| `link_ended` | The member's last current link ends, by unlink or transfer | the ended link | none |
| `primary_transferred` | An approved transfer takes the primary while the member keeps other current links (DEC-02) | the transferred link | none |

A `choice` made by a member who has links but no primary (after
`primary_transferred`) has no previous link.

The actor is who made the change; a worker that completes a transfer has
none. The primary of a member at any time is the new link of their latest
change before it. Backed by: both links belong to the member and name their
accounts (composite foreign keys); `first_link` without a previous link;
only `first_link` and `choice` without a previous link; `link_ended` and
`primary_transferred` exactly without a new one; previous and new differ.
Rows never change (SR-CTX-06).

## SR-MEM: Clan membership, member list and seasons

**Specs:** MEM-002 to MEM-005, MEM-008, LINK-003, LINK-008, LB-002, LB-003.
**Tables:** `clan_membership_poll`, `fact_clan_member_observation`,
`fact_clan_membership_change`, `observed_clan_membership_period`,
`dim_coc_season`, `fact_player_counter_observation`,
`fact_player_achievement_observation` (`V3`). **Checks:** `030_coc.sql`,
`070_membership_closing.sql`.

### SR-MEM-01 Polls

Every member list poll stores one `clan_membership_poll` row with outcome
`complete`, `incomplete` or `failed`; `failed` needs a failure code. The
correlation ID is unique. The row proves that the poll ran, even when no
member row changed.

### SR-MEM-02 Joins and departures

Source: `require_complete_membership_poll` (V3).

An observed join or departure needs a `complete` poll whose `observed_at`
equals the change's `observed_at`. [rule] Failed or incomplete polls never
create a departure (MEM-003). Backed by: unique `(poll, player, kind)`;
`previous_success_at <= observed_at`.

### SR-MEM-03 Membership periods

Source: `validate_membership_period_evidence`,
`require_membership_closing_evidence`, `membership_has_closing_evidence` (V3).

- The first poll must be `complete` and observed at or before
  `observed_since`; the last poll must be `complete` and observed exactly at
  `confirmed_through`. [rule]
- Player, clan, `observed_since` and the first poll never change. [rule]
- `confirmed_through` never moves back. [rule]
- A closed period's `observed_until` never changes. [rule]
- Closing a period (setting `observed_until`) needs an `observed_departure`
  for that clan and player at exactly `observed_until`, from a `complete` poll
  at that time. [rule]
- Backed by: `observed_until > observed_since`,
  `confirmed_through >= observed_since`, `confirmed_through <= observed_until`
  when closed, and no overlapping periods for one player in one clan
  (exclusion constraint on player, clan and interval).
- Periods of one player in different clans may overlap (GAP-12, MEM-003,
  MEM-004). Two clans poll on independent cycles, so a move can be observed in
  the new clan before the old clan observes the departure. Store each clan's
  real poll boundaries in either ingestion order. Never move a departure
  timestamp to make the evidence fit, and never close the old clan's period
  without its own `observed_departure` (SR-MEM-02).
- `current_observed_clan_member` resolves at most one current clan per
  account: among its open periods, the latest `confirmed_through` wins, then
  the later `observed_since`, then the later period key. The member list,
  lifetime war-stars board and desired clan roles read this view.
- Historical presence (SR-CG-03) uses the union of all periods, each clipped
  to `confirmed_through`, so overlapping supported time counts once.

Periods are observations, not exact game times. An open period never extends
beyond `confirmed_through` in a calculation.

**Acceptance:** B observes the account at 12:01 and A first observes its
departure at 12:02. Both boundaries are stored in either ingestion order, the
current clan is B, and overlapping supported presence counts once
(`030_coc.sql`). Failed/incomplete A polls still cannot invent its departure;
that rule and the out-of-order poll handling stay service tests (SR-MEM-02,
SR-MEM-05).

### SR-MEM-04 Currently tracked account

Source: `is_currently_tracked_player` (V3).

An account is currently tracked when its resolved current period
(`current_observed_clan_member`, SR-MEM-03) has coverage `adequate` in a
tracked clan whose settings are `enabled`.

### SR-MEM-05 Member list store-on-change

Source: `record_clan_member_observation` (V3).

The collector calls this once for every member of every poll that returned
members.

1. The poll must exist and not be `failed`. [rule] An `incomplete` poll may
    still store the members it returned.
2. The player and both donation counters are required. [rule]
3. Take the member list lock for the clan and player.
4. Find the season of the poll time (SR-MEM-06).
5. Find the member's latest stored row in this clan from a poll observed
    before this one.
6. Store nothing (return false) when that row exists, belongs to the current
    season, has the same role, donations and donations received, and no
    observed departure of the member from this clan lies after that row and at
    or before this poll.
7. Otherwise insert the row (ignore a duplicate) and return whether it was
    stored.

A member without a row for a poll had the state of their latest earlier row.
The first poll of each season stores every member, so that a member who
donated nothing has an explicit zero.

**Change:** a poll that arrives out of order can store an older
state after a newer, unchanged poll was skipped. Apply polls in observation
order, or store the next later state again when a late poll stores a change.

### SR-MEM-06 Seasons

Source: `coc_season_end`, `ensure_coc_season` (V3).

- A season ends on the last Monday of a month at 05:00 UTC: take the last day
  of the month, move back to the Monday of that ISO week, add five hours.
- A season is named by the month in which it ends. It starts at the end of the
  previous month's season.
- For a time `t`: when a stored season contains `t`, return it. Otherwise the
  season month is the month of `t` when `t` is before that month's season end,
  else the next month. Create the row idempotently.
- Backed by: `season_month` on day 1, `starts_at < ends_at`, unique month, no
  overlapping seasons. A row can be corrected if the game departs from the
  rule.

### SR-MEM-07 Member list views

- `current_clan_member_state`: each current member with their latest stored
  role and counters.
- `clan_member_season_donation`: per clan, season and account, the last
  counters that a poll saw before the season ended. The counters are what the
  game reports; a reset inside a season is not added back.

**Donations board (GAP-09, closed 2026-11-14, LB-004):** the metric catalog
supports `donations` for the `season` period only, by `latest_season_counter`:
per clan and account, the `clan_member_season_donation` counter of that CoC
season. There is no monthly or all-time donations board.

### SR-MEM-08 Profile counters and war stars

- Profile observations are snapshots and are never summed.
  `clan_capital_contributions` is a donation counter, not raid loot.
- `latest_player_counter`: the newest profile observation per account.
- `current_clan_lifetime_war_stars`: current members of a clan with their
  latest lifetime war stars, ranked with `dense_rank` per clan, with the
  counter and membership times so that freshness stays visible.
- **Change:** these views scan all history when joined (about 350 ms at one
  million profile rows). Rewrite them as per-account lookups or keep a latest
  projection.

## SR-WAR: Wars and attacks

**Specs:** WAR-001, WAR-004, WAR-006, WAR-007, and the war evidence of
CWL-007, CWL-012 and CUSTOM-005. **Tables:** `dim_war`, `war_poll`,
`war_participant`, `fact_war_observation`, `fact_war_roster_observation`,
`fact_war_clan_observation`, `fact_war_attack` (`V3`). **Checks:**
`030_coc.sql`. War roles are in SR-DSC-06 and reminders in SR-NTF-11.

### SR-WAR-01 War identity

Backed by the checks on `dim_war`, which stay:

- the clan pair is ordered (`clan_a_key < clan_b_key`) and unique with the
  preparation start;
- `preparation_started_at <= started_at < ends_at`; team size and attacks per
  member are positive;
- `war_kind` is `regular`, `cwl` or `custom`; a source war tag is unique and
  not blank;
- identity source `cwl_war_tag` needs a CWL war with a tag; attack allowance
  source `game_format` needs a CWL war with one attack per member.

Do not invent a war tag or an attack allowance that the response does not
supply. Do not assume a 24-hour battle day.

**Current schema / GAP-10 (WAR-006):** preparation/start timestamps are
required, and `identity_source` has no war-log-only variant. Validate the
actual war-log response before designing backfill. If it lacks those times,
define a representation for incomplete identity or an explicit collection
limitation; do not fabricate timestamps to satisfy `dim_war`.

### SR-WAR-02 Participants and clan observations

Source: `require_war_side` (V3).

A participant's clan, and the clan of a war clan observation, must be one of
the war's two clans. [rule]

### SR-WAR-03 Attacks

Source: `require_opposing_war_accounts` (V3).

- Attacker and defender must be participants of the war on different clans.
  [rule]
- Backed by: both are participants (foreign keys); attacker differs from
  defender; unique `(war_key, attack_order)`, so that reading the same attack
  again does not add a second attack; stars 0–3; destruction 0–100;
  `first_observed_at <= last_observed_at`.
- `occurred_at` stays null unless the source supplies it. Attack duration and
  observation time are not occurrence times.
- A later read may move `last_observed_at`. It never changes stars,
  destruction, attacker, defender or order (SR-GRANT).

### SR-WAR-04 Observations

- `fact_war_observation` keeps the sanitized response; a check rejects any
  `token` key at any depth, and it stays.
- Roster observations keep the roster's own TH and map position; positions
  are not contiguous. Historical analysis uses them, never the account's
  current TH.
- Every war poll of a tracked clan stores one `war_poll` row
  (WAR-006): `war` with the identified war, `not_in_war`, or `failed` with a
  failure code. The row proves that the poll ran; a failed poll is no
  evidence about the war.
- Store a response in `fact_war_observation` only when it differs from the
  latest stored response of the war, a roster row only when the account's
  roster values changed, and clan totals only when they changed. Each stored
  observation names its poll. A war without a row for a poll had the state of
  its latest earlier rows. Backed by: an observation's poll is of the same
  war and at the same time (composite foreign keys); one poll row per
  correlation ID.

## SR-CG: Clan Games

**Specs:** CG-001 to CG-020, LINK-013, LINK-014. **Tables:**
`dim_clan_games_event`, `clan_games_read_request`, `clan_games_counter_read`,
`clan_games_participation_evidence`, `fact_clan_games_progress`,
`fact_clan_games_account_assessment`, `fact_clan_games_member_assessment`,
`clan_games_member_account_input` (`V3`). **Checks:** `030_coc.sql`,
`060_manual_events.sql`, `100_clan_games.sql`. Reports are in SR-NTF-13.

### SR-CG-01 Scheduled events

Source: `create_scheduled_clan_games` (V3).

- An enabled schedule is required. [rule]
- Start: day `clan_games_start_day` of the given month at
  `clan_games_start_time_utc`, in UTC. End: start plus
  `clan_games_event_seconds`. Cap: `clan_games_account_points_cap`. Source
  `configured_schedule`, correlation `schedule:<year>:<month>`.
- Idempotent by start time: an event that already starts then is returned,
  even if its end or cap differ from the current settings. Changing the
  schedule never rewrites an existing event.
- Backed by: unique start; end more than 24 hours after the start; no
  overlapping events (exclusion constraint).

### SR-CG-02 Manual events

Source: `create_manual_clan_games` (V3).

- The actor must be able to configure. [permission]
- A non-blank reason and correlation ID are required. [rule]
- An event that already starts at that time is returned only when its end and
  cap are the same. [rule]
- A manual event is recorded in the configuration change history
  (SR-CFG-13). There is no manual score path.

### SR-CG-03 Requirement targets

Source: `clan_games_observed_target`, `clan_games_attributed_target` (V3).

For one account at a checkpoint:

```text
presence = union of the account's membership periods, each clipped to
  [ max(observed_since, lower bound),
    min(observed_until or confirmed_through, confirmed_through, upper bound) )
required = 0.10 × event cap × presence seconds ÷ event duration seconds
```

- Without attribution: lower bound = event start; upper bound = min(event end,
  checkpoint).
- With an attribution episode: lower bound = max(event start, event start when
  the episode may backfill, otherwise the episode's first link); upper bound =
  min(event end, checkpoint, the episode's close, when closed). When the upper
  bound is before the lower bound, the episode has no slice.
- Periods in all tracked clans are unioned, so time in two clans counts once.
- The target stays unrounded per account. Earned points are never
  time-prorated.

**Decided (DEC-01, 2026-11-14, CG-013):** an episode stays open after its
owner unlinks the account (SR-ACC-11), so the account keeps counting toward
that owner's target and points while it stays unlinked.

**Acceptance:** an alt unlinked mid-event and not relinked before the final
checkpoint keeps its points and prorated requirement in the former owner's
assessment; a different owner's link at a later time closes the slice there.

### SR-CG-04 Read requests

Source: `validate_clan_games_read_request` (V3).

- `due_at` is the checkpoint that the read supplies; `collect_from` opens the
  window in which the collector may take it. Purposes, due times and windows:
  [rule]

  | Purpose | `due_at` | `collect_from` |
  | --- | --- | --- |
  | `baseline` | the event start | the end of the previous event, or the creation of the event when there is none; the counter does not move between events |
  | `t_minus_24h` | the event end minus 24 hours | `due_at` minus `clan_games_checkpoint_tolerance_seconds` (default 1800, DEC-03) |
  | `final` | the event end | `due_at` |
  | `regular`, `transfer` | inside `[start, end)` | `due_at` |

  The window is fixed when the request is created; a later change of the
  tolerance does not move it.
- A `transfer` request references its transfer request, and only that purpose
  does. The transfer must be for the same account, `approved`,
  `awaiting_points` or `consumed`, and decided at or before the due time.
  [rule]
- Closing a request as `missed` without changing its identity is always
  allowed, even when its transfer has since been cancelled.
- Backed by: unique `(event, player, purpose, due, transfer)`; at most one
  `pending` `regular` request per event and player (partial unique index);
  status `pending`, `succeeded` or `missed`; `missed` exactly when `missed_at`
  is set; `collect_from <= due_at`, and only a `baseline` or `t_minus_24h`
  request opens before its `due_at` (`CHECK`).

### SR-CG-05 Queue reads

Source: `queue_clan_games_reads` (V3).

1. Insert the `baseline`, `t_minus_24h` and `final` requests once, with their
    windows (SR-CG-04).
2. The next regular read is due at
    `max(event start, the account's latest counter read in the event, the due
    time of its latest closed regular request) + clan_games_refresh_seconds`
    (default 900).
3. When that time is before the event end and the account has no `missed`
    regular request, insert the single pending regular request or move its
    `due_at` and `collect_from` together.
4. Return the number of requests added or moved, so that a repeated call
    returns 0. The scheduler never creates a row for every interval.

The collector takes `pending` requests whose `collect_from` has passed
(index `clan_games_read_request_collectable`), so a boundary read can finish
before its checkpoint (CG-005).

### SR-CG-06 Counter reads

Source: `validate_clan_games_counter_read` (V3).

A counter read is a successful Games Champion observation for one request:

- It must match its request's event, player and transfer. `boundary_at` must
  equal the request's due time, or the observation time for a `transfer`
  read. [rule]
- The achievement must be `Games Champion` in the `home` village. [rule]
- The source fetch must be for the same player, endpoint `player_profile`,
  outcome `succeeded`, HTTP 200, completed exactly at the observation time.
  [rule]
- Time limits: the read is observed at or after its request's
  `collect_from`; a `baseline` at or before the event start; a `t_minus_24h`
  read at or before its checkpoint; a `final` read at or after the event end;
  a `transfer` read at or after its due time; and no read observed after a
  later event started. [rule: a current response cannot reconstruct a missed
  past checkpoint]
- Backed by: the achievement observation exists (foreign key);
  `source_as_of <= observed_at`; a known observed clan exactly when its status
  is `known`.
- `observed_at` is collection time. `source_as_of` stays null unless the API
  supplies it. Freshness adequacy follows a versioned collector policy.

**Change (CG-005, CG-012):** the SQL had an upper bound only, and its
requests fell due at that bound, so a read that completed seconds after the
start was rejected, and a read taken a day before the event was accepted as
its T−24h counter. The lower bound `collect_from` replaces that. The owner set
the T−24h default to 1,800 seconds on 2026-11-14 (DEC-03, CG-005), replacing
the proposed 900.

### SR-CG-07 Complete and close reads

Source: `complete_clan_games_read_request`, `close_missed_clan_games_reads`
(V3).

- Storing a valid counter read marks its request `succeeded` and clears
  `missed_at`. A valid read that was observed in time but ingested after the
  request was closed still wins.
- Closing: the as-of time is required and not in the future. [input] A
  `pending` request becomes `missed` when:
  - `baseline` and the as-of time is after the start;
  - `t_minus_24h` and the as-of time is after its due time;
  - `regular` and the as-of time is at or after the event end;
  - `transfer` and its transfer is `rejected`, `cancelled` or `expired`;
  - any purpose, once a later event has started.
- `final` and `transfer` reads otherwise stay retryable until the next event
  starts. Idempotent; returns the number closed. A missed read is absent
  evidence, never a zero.

### SR-CG-08 Participating clan inference

Source: `infer_clan_games_participation` (V3).

Inputs: the account's baseline read and the read of its first increase. The
clan is inferred only when all of these are true:

- the baseline read is the `baseline` request at the event start;
- both reads have freshness `adequate`;
- the second read's counter is greater than the baseline's, and no read in the
  event before it is greater (it really is the first increase);
- the second read's observed clan is `known`;
- a membership period with coverage `adequate`, `observed_since` at or before
  the start, `confirmed_through` at or after the first increase, and not
  closed before it, is in the same clan as the observed clan;
- every read from the start through the first increase observed that same
  clan.

Otherwise the result is `insufficient_data` with no clan. A caller cannot
supply a different clan, and cannot claim `inferred` without the evidence.
[rule] The stored row is the computed result; later membership changes do not
rewrite it.

### SR-CG-09 Progress

Source: `validate_clan_games_progress` (V3).

- The only method is `achievement_delta`; there is no manual score. [rule]
- `adequate` progress needs: a baseline read for the `baseline` request at
  the event start; an ending read observed exactly at the progress time; both
  freshness `adequate`; a delta from 0 to the event cap; points, if given,
  equal to the delta; and, for a positive delta, an `inferred` participation
  row built on the same baseline read. [rule]
- Points are the delta. `insufficient_data` progress has no points.
- A measured zero from valid baseline and ending reads proves zero
  contribution even without an inferred clan. Missing reads never prove zero.
- The baseline and ending achievement keys and times are copied from the
  reads. Unique per event, account and observation time.
- `public_clan_games_progress` shows the latest progress per event and
  account: points, evidence status and method. Members may read it.

### SR-CG-10 Account assessments

Source: `validate_clan_games_assessment` (V3).

One row is one owner's slice of one account at one checkpoint.

1. `checkpoint_at` is the event end for `final`, or the end minus 24 hours for
    `t_minus_24h`. [rule]
2. With an attribution episode: the episode must belong to the account;
    [rule] the member is the episode's user; the scope, presence seconds and
    required points come from the attributed target (SR-CG-03); no slice at
    this checkpoint fails. [rule]
3. Without an episode: no member; the scope is the event start to the
    checkpoint with the unattributed target; attribution status `adequate` is
    not allowed. [rule]
4. Membership status `adequate` is not allowed when any overlapping period
    in the scope has coverage other than `adequate`. [rule]
5. Points status `adequate` needs a start read and an end read with a delta
    from 0 to the cap, both freshness `adequate`, eligible points (if given)
    equal to the delta, and an `inferred` participation for a positive delta.
    [rule]
6. The reads must support both ends of the slice. [rule]
    - Scope starting at the event start: the start read is the `baseline`
      read at the start.
    - Scope starting later (a link boundary): the start read is observed
      exactly at the scope start.
    - Scope ending before the checkpoint: the end read is observed exactly at
      the scope end.
    - Scope ending at the checkpoint: the end read is the `final` or
      `t_minus_24h` read of that checkpoint.
7. Eligible points are the delta; without adequate points they are empty.

The result is computed: `insufficient_data` when any status is not
`adequate` or eligible points are empty; `pass` when eligible points reach
the required points; otherwise `fail`. Unique per event, account, checkpoint,
calculation version and episode.

### SR-CG-11 Member assessments

Source: `capture_clan_games_member_scope`,
`validate_clan_games_member_input`, `attach_clan_games_member_input`, the
view `clan_games_member_result` (V3).

- Creating a member assessment freezes its expected accounts: one input row
  per attribution episode of the member whose account has presence inside
  the episode's slice before the checkpoint. A later first-link backfill needs
  a new calculation version; it never changes a frozen cohort.
- Inputs cannot be deleted; their identity cannot change; an attached account
  assessment cannot be replaced. [rule] The input's member is the member
  assessment's member. [rule]
- Attaching: set the account assessment on the input row of the same episode,
  only when it is empty or already the same. [rule: fill the frozen scope
  exactly once] An exact retry is accepted.
- Result per member version: eligible points are the sum of the slices;
  required points are `10 × ceil(sum of unrounded slice targets ÷ 10)`,
  rounded once on the member total; the result is `insufficient_data` when the
  member's attribution status is not `adequate`, no slice is attached, any
  attached slice is insufficient, or any expected input has no slice;
  otherwise `pass` or `fail`.
- No staff exemption exists (CG-016).

### SR-CG-12 Assessment worker input

Source: `clan_games_assessment_scope` (V9).

For an event and a checkpoint (`final` or `t_minus_24h`, otherwise [input]),
return every attribution episode with presence seconds greater than zero: the
member, account, episode, checkpoint time, scope, presence seconds and
unrounded required points.

### SR-CG-13 Readers

Members read points (SR-CG-09). Only Leadership reads pass/fail results
(SR-CFG-11); a shared activity channel, a leaderboard or a general log never
shows them (LB-011).

## SR-DSC: Discord presence and roles

**Specs:** MEM-006, MEM-007, MEM-009 to MEM-016, WAR-003, XP-008, CFG-010.
**Tables:** `fact_discord_membership_event`, `discord_member_state`,
`fact_role_change`, `discord_member_role`, `fact_discord_accepted_join`
(`V4`); the desired-role views (`V4`, `V9`). **Checks:** `040_discord.sql`,
`140_feature_integration.sql`, and the role checks of
`090_security_hardening.sql`. Role reconciliation is in SR-NTF-10.

### SR-DSC-01 Membership events

Source: `capture_discord_join_policy` (V4).

- A `join` records the New Joinee policy: `new_joinee_policy_days` from the
  guild settings at that moment (default 7). A `departure` has none. Backed
  by: a policy exactly on joins.
- `new_joinee_expires_at` is computed: the join time plus that many days, in
  UTC. Later settings changes do not rewrite it.
- `occurred_at` is the source time; `observed_at` and `recorded_at` are
  collection times.

### SR-DSC-02 Presence projection

Source: `project_discord_membership` (V4).

Take the member lock. Accept an event only when `(occurred_at, event key)` is
newer than the stored `(last_event_at, last event key)`, so that a delayed
gateway event cannot revive an old stay. On an accepted event:

- set `is_present` and the last event;
- delete every held role;
- for a join, rebuild the held roles from role events of this stay: role
  events changed at or after the join time, without an origin join or with
  this join as origin, taking the latest event per role (by change time, then
  key) and keeping the roles whose latest event is `add`.

Roles of an earlier stay are never restored.

### SR-DSC-03 Held-role projection

Source: `project_discord_role` (V4).

Take the member lock.

1. An origin join, when given, must be a `join` of the same user. [rule] An
    expiry, when given, must equal that join's New Joinee expiry. [rule]
    Backed by: an expiry needs an origin join.
2. Ignore the event for the projection (keep the fact) when the member is
    known absent, the event is older than the last membership event, or its
    origin join is not the current stay's join.
3. Apply it only when it is the latest event for that role in the current
    stay. `remove` deletes the held role; `add` inserts or updates it with the
    event's time, key and expiry.

### SR-DSC-04 Role-change provenance

Source: `validate_role_operation_provenance` (V9).

A role event may name the notification operation that caused it. That
operation must be a `role_reconcile` operation for the same user whose
generation lists this role with `is_desired` equal to (`change_kind = 'add'`).
[rule] Events without an operation, such as manual changes, are always valid.

### SR-DSC-05 Accepted joins

Source: `record_accepted_join_moderation_notice` (V4).

After the presence projection, a join that became the member's current state
is recorded as an accepted join (idempotent), and the rejoin notices are
derived again (SR-MOD-13). A join that lost to a newer event is not an
accepted join.

### SR-DSC-06 Desired roles

Source: views `desired_clan_member_role`, `desired_town_hall_role`,
`desired_chat_rank_role`, `chat_rank_role_removal` (V4, V9).

- Clan member roles: for each present member, the union over their current
  links of the member roles of the enabled tracked clans the accounts are
  currently in. A primary change alone never removes an alt's role. The last
  supported open membership counts through failed polls.
- Town hall roles: for each present member, the roles of every distinct
  latest TH across their current links. A profile observation without a TH
  does not erase an earlier supported TH.
- Rank roles: the role of the member's current rank; removal targets only held
  roles bound to other ranks.
- Deleted roles are never desired.
- War, CWL and onboarding roles have no view yet; the service computes them
  (WAR-003, MEM-010, MEM-011).

**Onboarding (DEC-17, decided 2026-11-14, MEM-010 to MEM-012):** the
member's latest accepted join (SR-DSC-05) governs New Joinee; its
`new_joinee_expires_at` is the deadline, and a role event's origin join is
that join (SR-DSC-03). A stay's first eligible link is the earliest moment in
the stay when the member has a current eligible link: the first link made
during the stay, or the accepted rejoin itself when links were retained (no
new verification). At that moment remove Applicants and desire Eclipse, the
clan and TH roles, and New Joinee only while the join's expiry is still in the
future. A first link after the expiry desires no New Joinee.

**Acceptance:** first link two days after join (New Joinee until join plus
seven days); first link ten days after join (no New Joinee); rejoin with
retained eligible links (Applicants removed and New Joinee until rejoin plus
seven days at the rejoin); and a delayed role event naming the earlier stay's
join is ignored.

## SR-XP: Chat XP and ranks

**Specs:** XP-001 to XP-010, LB-005, LB-006. **Tables:** `chat_xp_policy`,
`chat_xp_eligibility_role`, `chat_rank_tier`, `chat_rank_role_binding`,
`fact_chat_xp_decision`, `chat_member_rank_state`, `fact_chat_rank_change`
(`V4`). **Checks:** `040_discord.sql`, `105_discord_policies.sql`.

### SR-XP-01 Policy

`chat_xp_policy` holds the one agreed version, `rolling_60s_v1`: 15 to 25 XP,
five credited messages per 60 seconds, rolling processing time, not
provisional. Checks pin every value; `guild_settings.chat_xp_policy_key`
selects it and has no command.

### SR-XP-02 Sampling

Source: `sample_chat_xp` (V4).

Each credited message earns a uniform integer from 15 through 25 from an
unpredictable server-side source (XP-002). The SQL sampled a random UUID byte
with rejection sampling to avoid modulo bias. In Java,
`15 + secureRandom.nextInt(11)` meets the same contract.

### SR-XP-03 Credit a message

Source: `credit_chat_xp`, `enforce_chat_xp_policy` (V4).

1. Take the member lock (shared with presence, roles and warnings), then the
    message lock.
2. When a decision exists for the message, its user, channel and sent time
    must equal the call's [conflict]; return the stored decision. A retry never
    rerolls, adds XP again or uses another slot.
3. Processing time is now, taken after the locks.
4. Decide the outcome in this order:
    - `not_present`: the member has no present state row;
    - `missing_eligible_role`: the member holds no configured eligibility role
      that is not deleted and not expired at processing time;
    - `rate_limited`: the member has five or more credited messages with a
      processing time in the last 60 seconds, across all channels;
    - `credited`: sample the XP (SR-XP-02) and record the eligibility role
      (the lowest role key among the qualifying roles).
5. Insert the decision with the source sent time, the processing time and the
    policy key.

Rejected decisions are final too: a retry returns them, it never credits them
later. Backed by: a unique message ID; XP present exactly on credited
decisions; a credited decision names its eligibility role; XP 15–25. The
rolling limit has no database backstop: the trigger that rechecked it at
insert is gone, so the member lock is the only protection. Test it with
concurrent workers.

**Change (XP-004):** return the outcome and the XP with the award
key.

### SR-XP-04 Ranks

Source: `project_chat_rank` (V4).

On every credited decision, in the same transaction:

- add the XP to the member's cumulative total;
- the rank is the highest tier whose minimum is at or below the total
  (Stardust 0, Stargazer 4,000, Orbiter 12,000, Lunar Drift 28,000, Solar
  Wanderer 60,000, Penumbra 120,000, Corona 240,000, Umbra 400,000, Totality
  650,000, Eclipse Ascendant 1,000,000);
- update `chat_member_rank_state` (total, rank, last award, time);
- when the rank changed, or on the first award, insert `fact_chat_rank_change`
  with the previous rank, the new rank, the total and the award. Backed by:
  the previous rank is lower than the new rank.

XP and rank survive role loss and departure (XP-005, XP-006).

**Decided (DEC-13, 2026-11-14, XP-007):** a member has no rank state, rank
and rank role until their first credited message; that award creates
`chat_member_rank_state` and the first `fact_chat_rank_change` (Stardust, or
the rank its XP reaches). The schema already requires an award for both rows;
never create a synthetic award. Only the eligibility roles of XP-001 (Eclipse
and Friends initially) let a message earn, so Applicants and New Joinee alone
never start a rank. **Acceptance:** an eligible member with no credited
message has no desired rank role; the first credited message desires Stardust.

### SR-XP-05 Totals and boards

- All-time totals cover every member, present or not. Monthly totals in UTC
  exist for internal use.
- The all-time board shows present members only, ranked with `dense_rank`.
- The monthly board sums credited XP whose source sent time falls in a
  reporting period (SR-LB-02), for present members.
- **Change:** the monthly board computes every period before filtering to the
  current one (about 380 ms at one million messages). Filter the period
  first.

## SR-MOD: Warnings, kicks and moderation notices

**Specs:** MOD-001 to MOD-010. **Tables:** `warning`, `warning_revocation`,
`moderation_action`, `fact_moderation_action_transition`,
`fact_moderation_action_attempt`, `fact_moderation_attempt_resolution`,
`fact_manual_moderation_action`, `fact_moderation_notice`; view
`confirmed_moderation_kick` (`V4`).
**Checks:** `040_discord.sql`, `105_discord_policies.sql`.

### SR-MOD-01 Issue a warning

Source: `authorize_warning_issue`, `record_warning_issue` (V4).

1. The issuer must be able to moderate. [permission] The reason must not be
    blank. [rule]
2. Take the member lock, then the warning-month lock for the subject and the
    GMT month of the issue time.
3. Insert the warning. Its GMT month is computed from the issue time.
4. Count the subject's active (unrevoked) warnings in that month, including
    this one.
5. When a `kick_rejoin` notice exists for the subject in that month at or
    before the issue time, insert a `post_rejoin_warning` notice for this
    warning (deduplicated) and stop: no automatic kick after a rejoin.
6. Otherwise, when the count is five or more, insert the month's kick
    decision with `kick_max_attempts` attempts (default 3), due now. When a
    decision for the month exists and is `cancelled`, arm it again: `pending`,
    a fresh set of attempts, this warning as trigger, decided now. Any other
    existing decision stays as it is.
7. In the same transaction, append a `fact_moderation_action_transition`:
    `decided` for a new decision or `rearmed` for a cancelled one, origin
    `system`, this warning as trigger, the attempts granted and the time. The
    current row in `moderation_action` is a projection; the transitions are
    the history (MOD-009).

Backed by: one kick decision per member, kind and month (unique key); one
`decided` transition per decision (partial unique index); a transition's
warnings belong to the decision's member; `cancelled` names a revoked warning
and no trigger; `decided`/`rearmed` name a trigger and the attempts granted;
origin `staff` exactly when an actor is named. `060_moderation.sql` checks warning five, revocation below five and another fifth warning: three
transitions beside one current decision.

### SR-MOD-02 Warning months

Warnings count in the GMT calendar month of their issue time. The month resets
at 00:00 GMT on the first; history remains. The leaderboard timezone never
changes warning months (MOD-010).

### SR-MOD-03 Warning commands

Source: `issue_warning`, `issue_warning_command` (V4).

- The command form needs an operation UUID. [rule]
- Take the warning-command lock on the UUID. When a warning with that UUID
  exists: subject, issuer and reason must be equal, and the issue time too
  when given [conflict]; return the stored warning without a permission
  check, as activity commands do (SR-ACT-01).
- Otherwise the issuer must be able to moderate [permission]; insert the
  warning (SR-MOD-01), at the given time or now.
- The form without a UUID always inserts; it exists for callers without an
  operation ID.
- **Change (DEC-10, decided 2026-11-14):** the SQL checked permission before
  the retry lookup, so a retry after the issuer lost the role failed although
  the warning existed. The retry lookup now comes first for issue and
  revocation commands with a UUID; a retry applies nothing new. Acceptance:
  issuer loses the role, then an identical retry returns the stored warning and
  a different-argument retry fails [conflict].

### SR-MOD-04 Revoke a warning

Source: `authorize_warning_revocation`, `record_warning_revocation` (V4).

1. The warning must exist. [missing] The revoker must be able to moderate.
    [permission] The reason must not be blank. [rule]
2. The revocation time must not be before the issue time. [rule]
3. Take the member lock, then the warning-month lock for the original month;
    take the action lock only afterwards (SR-CTX-03, GAP-14).
4. Insert the revocation; a warning has at most one (primary key).
5. Cancel the month's kick decision when it is no longer supported
    (SR-MOD-08).

A revocation in another month never subtracts from that other month: the
count uses the original month (MOD-003).

### SR-MOD-05 Revocation commands

Source: `revoke_warning`, `revoke_warning_command` (V4).

- Without a UUID: insert the revocation, or, when the warning is already
  revoked, accept the call only when revoker and reason are equal, and the
  time too when given. [conflict]
- With a UUID: the UUID is required [rule]; the warning must exist [missing];
  the revoker must be able to moderate [permission]; take the
  warning-command lock; a revocation with that UUID must have the same
  warning, revoker, reason and time when given [conflict] and is returned; a
  warning already revoked by another operation fails [rule].

### SR-MOD-06 Warning history

Source: `warning_history` (V4).

The requester must be the subject or able to moderate. [permission] Return
issued and revoked events with actor, reason and times, ordered by time,
warning and kind.

### SR-MOD-07 Kick decision states

Backed by the checks on `moderation_action`:

- status `pending` (no attempt yet), `succeeded`, `failed`, `uncertain`
  (latest attempt's outcome) or `cancelled`;
- `cancelled` exactly when `cancelled_at` is set;
- `next_attempt_at` only for `pending`, `failed` or `uncertain`, and required
  for `pending`; an owed attempt needs `attempts_remaining > 0`;
- a lease owner exactly when a lease expiry is set; a claim token is unique.

`pending_moderation_action` lists the decisions that still owe an attempt.

### SR-MOD-08 Cancel an unsupported kick

Source: `_cancel_unsupported_moderation_action` (V4).

Under member, then warning-month, then decision locks, cancel it only when it
still owes an attempt, no lease is active, and the subject has fewer than five
active warnings in its month: set
`cancelled`, `cancelled_at`, clear the next attempt and the lease, and keep the
claim token, so that a worker holding the kick may still report what
happened. Append a `cancelled` transition with the revoked warning, origin
`staff` and the revoker as actor. Cancellation does not erase an
authorization, an external attempt, or a later observed outcome.

### SR-MOD-09 Claim a kick

Source: `claim_moderation_action` (V4).

**Storage (GAP-13):** each claim inserts one `fact_moderation_action_attempt`
row before any external I/O: attempt number, claim token, worker, lease expiry
and the targeted accepted join (`target_membership_event_key`). `started_at`
records the consumed send permission; the result columns are set once and
only after it. `moderation_action` keeps the current lease and token as a
projection. The reference's `check_member` recovery treated absence as kick
success; that is not the contract below (MOD-005, MOD-006, MOD-009).

1. Validate lease 1–3600 seconds (default 300) and worker ID
    `^[A-Za-z0-9_.:-]{1,100}$`. [rule] Find the decision [missing]; acquire
    member, warning-month, then action locks and revalidate (GAP-14).
2. Return nothing when no attempt is due or an active lease prevents a claim.
    Apply pending revocation/cancellation before authorizing another kick.
3. Commit the authorization row before external I/O: action, member,
    attempt number, worker, token/lease and the member's current accepted join.
    Then set `started_at` in its own committed transaction and only then call
    Discord. A restarted worker never calls Discord for an authorization whose
    `started_at` is set; an expired authorization without it proves that
    Discord was not called.
4. For an uncertain prior send or an expired unreported claim, reconcile
    evidence first. Absence alone can mean voluntary departure or manual
    removal; it does not confirm a bot kick. Presence after a newer join does
    not authorize repeating the old kick against that new stay.
5. Keep the outcome uncertain unless kick-specific evidence resolves it:
    a `fact_moderation_attempt_resolution` row, `succeeded` only with the
    bot's audit log entry for the kick, `failed` only when the member is still
    present in the targeted stay after the attempt. Only an `uncertain`
    attempt can be resolved, and a resolved attempt's outcome cannot change
    (foreign key on the outcome). Define the Java/Node recovery and
    correlation protocol before enabling the worker, including configured
    attempt-budget handling. A lease takeover
    fences current-state updates; it neither erases the old attempt nor proves
    its external call did not happen. Do not claim exactly-once Discord kicks.

**Acceptance:** crash before I/O, lost success response, voluntary/manual
departure during uncertainty, and successful kick followed by rejoin before
recovery. None fabricates a confirmed kick or repeats the old action against
the new join. Exercise takeover with a late real success response.

### SR-MOD-10 Record a kick attempt

Source: `record_moderation_attempt`, `project_moderation_attempt` (V4).

**Change / target (GAP-13, GAP-14, MOD-005, MOD-009):** record outcomes
against the durable authorization of SR-MOD-09, not a newly invented attempt
at result time.

1. Acquire member, warning-month, then action locks; find the authorization
    by its immutable identity. A missing authorization fails [missing].
2. An identical repeated result returns the stored result; conflicting
    evidence fails [conflict] or is retained as a separately typed observation
    under the recovery protocol. Never silently overwrite a terminal result.
3. Retain a late outcome for its original authorization even after a takeover.
    Its stale token must not clear a newer lease, spend a newer attempt, or
    overwrite the newer action projection. Confirmed late kick evidence must
    still reconcile history/notices under the member lock.
4. For the current authorized attempt, update the decision once:
    - account for the configured attempt budget without counting a duplicate
      result twice;
    - status = the outcome, except that a cancelled decision stays `cancelled`
      unless the outcome is `succeeded`; success clears `cancelled_at`;
    - next attempt = attempt time + `kick_retry_seconds` (default 300), only
      when the outcome is not `succeeded`, the decision is not cancelled and
      attempts remain;
    - clear only this authorization's lease/token.
5. Derive rejoin notices only from confirmed kick evidence (SR-MOD-13).
    After failure/uncertainty, apply cancellation under the same lock order.
    Retain sanitized status and diagnostic evidence; never retain response
    bodies or verification tokens.

Database backstop: unique attempt number and token; the target is an
accepted join of the same member; a result needs `started_at`; a succeeded
attempt needs a 2xx HTTP status; result columns are the only updatable ones
(`060_moderation.sql`). Write-once results and the stale-token fence stay
service rules.

After the last attempt the kick stays `failed` or `uncertain` for leadership.
A decision is never a completed kick until an attempt succeeded.

### SR-MOD-11 Kick history

Source: `moderation_history`, view `fact_moderation_event` (V4).

The requester must be the subject or able to moderate. [permission] The
history is the bot's confirmed kicks (`confirmed_moderation_kick`: a
succeeded attempt, or an uncertain attempt resolved by its audit log entry)
plus the manual actions (SR-MOD-12), ordered by time and origin.

### SR-MOD-12 Manual moderation from the audit log

Source: `record_manual_moderation_action` (V4).

- One row per audit log entry: kick, ban, unban or timeout, with the subject,
  the executor, the time, the audit log reason and, for a timeout, its end.
- The same entry again must be identical [conflict] and returns the stored
  row.
- Manual-history rows leave out entries whose executor is the bot's own user
  to avoid double counting. Under GAP-13, bot audit-log evidence may still be
  needed to reconcile an uncertain attempt: record it as that attempt's
  `fact_moderation_attempt_resolution` (unique audit log entry ID) instead of
  discarding the only available confirmation or inserting a second manual
  action. The recovery protocol must define how an entry is matched to an
  attempt.
- A kick or an unban derives the rejoin notices again, because the audit log
  is read after the event and the rejoin may already be recorded.
- Backed by: unique entry ID; a timeout end exactly on timeouts and after the
  occurrence; a reason, when present, not blank and at most 512 characters.

### SR-MOD-13 Rejoin notices

Source: `record_moderation_rejoin_notices`, `validate_moderation_notice` (V4).

Derived for one member, idempotently under the lock order of SR-CTX-03
(GAP-14); do not enter this method holding an action lock without the outer
member/month locks:

1. For each accepted join and each of `kick` and `unban`: the latest manual
    action of that kind at or before the join, in the same UTC month, gives a
    `manual_kick_rejoin` or `unban_rejoin` notice.
2. For each accepted join: the latest confirmed bot kick
    (`confirmed_moderation_kick`) at or before the join, in the same UTC
    month, gives a `kick_rejoin` notice.
3. For each warning: the latest `kick_rejoin` notice in the warning's month at
    or before its issue time gives a `post_rejoin_warning` notice for that
    warning.

Each notice must be consistent [rule]: the join is a `join` of the subject at
or after the removal; the removal and the join are in the notice's month; a
manual notice's action has the matching kind; a bot notice's attempt is a
confirmed kick; a rejoin notice's time is the join time; a warning notice's warning
is in the month, issued at or after the join, and its time is the issue time.

Only `kick_rejoin` stops the automatic kick for the rest of the month. Bans
and timeouts create no notice.

**Change (MOD-006, NOTIFY-003):** queue the leadership ping for each new
notice in the same transaction (SR-NTF-02, kind `moderation`, audience
`leadership`, channel `leadership_notifications`, logical key from the
notice's `operation_id`), with a `notification_moderation_context` row
naming the notice. The warning, revocation, kick transition and kick attempt
messages for the `moderation_logs` channel (MOD-007) name their source the
same way.

## SR-ACT: Activity commands

**Specs:** CWL-017, CUSTOM-006. **Tables:** `activity_command_operation`
(`V6`). **Checks:** `110_cwl_and_custom_events.sql`.

### SR-ACT-01 Command envelope

Source: `activity_replay`, `activity_start`, `activity_finish` (V6).

Every CWL and custom-event command follows these steps:

1. The actor and the operation UUID are required. [rule]
2. Take the activity-operation lock on the UUID.
3. When the operation exists, its actor, action and arguments must equal the
    call's [conflict]; return its stored result. The retry is answered before
    any permission check, so losing a role later does not turn a retry into
    an error.
4. Check the command's permission.
5. Store the operation: actor, action and the typed arguments as JSON. Never
    store tokens or request bodies there.
6. Do the work.
7. Store the result key on the operation.

### SR-ACT-02 Staff and own-account checks

Source: `activity_require_staff`, `activity_require_account` (V6).

- Staff: the actor holds `co_leader` or `admin`. [permission]
- Own account: the actor is staff, or has a current link to the account.
  [permission] The check also tells the command whether the actor is staff.

## SR-CWL: Clan War Leagues

**Specs:** CWL-001 to CWL-017. **Tables:** `cwl_cycle`,
`cwl_participating_clan`, `fact_cwl_participation_revision`, `cwl_clan_day`, `fact_cwl_day_freeze`,
`fact_cwl_group_observation`, `fact_cwl_registered_clan`,
`fact_cwl_registered_player`, `cwl_round_war_reference`, `cwl_signup`,
`fact_cwl_signup_revision`, `cwl_plan_revision`, `fact_cwl_plan_input`,
`cwl_plan_assignment`, `fact_cwl_manual_pin_revision`, `cwl_replan_request`,
`fact_cwl_bench_incident`, `fact_cwl_bench_resolution`,
`cwl_bench_assignment`, `cwl_export_revision`, `cwl_export_signup_input`,
`cwl_sheet_destination`, `fact_cwl_export_attempt` (`V6`). **Checks:** `110_cwl_and_custom_events.sql`. The prompt and the
roster and signup-list reports are in SR-NTF-14 to SR-NTF-17.

### SR-CWL-01 Create a cycle

Source: `cwl_create_cycle` (V6).

The actor must be able to configure. [permission] A cycle is one calendar
month (day 1), unique, starting in state `signups`. Signups close at 00:00 UTC
on the first day of that month (generated column).

**Change (CWL-001):** the scheduler creates each month's cycle and
queues the leadership prompt (SR-NTF-15), without a human actor.

### SR-CWL-02 Select, correct or withdraw a participating clan

Source: `cwl_select_clan` (V6). The SQL had no correction or withdrawal.

Each command follows the activity envelope (SR-ACT-01) and writes one
revision to `fact_cwl_participation_revision`: the next number, the lineup
size (15 or 30), the withdrawn flag, the actor and the operation.

1. The actor holds `leadership`, `co_leader` or `admin`. [permission]
2. The cycle must exist [missing], be in `signups`, and signups must not have
    closed. [rule]
3. The clan must be an enabled tracked clan. [rule]
4. Select: create the participation row and its seven War Days with no war
    yet when they are missing, and insert revision 1. A clan whose current
    revision is not withdrawn is already selected [rule]; selecting a
    withdrawn clan again inserts the next revision with `withdrawn = false`.
5. Correct: insert the next revision with the new lineup size (CWL-005).
6. Withdraw: insert the next revision with `withdrawn = true`. Refuse while a
    current signup that is not withdrawn targets the clan [rule]; staff move or
    withdraw those signups first (SR-CWL-03), so that no signup loses its
    target silently. Confirmed by the owner on 2026-11-14 (DEC-12, CWL-001).

`current_cwl_participation` is the latest revision of each clan. A withdrawn
clan takes no signup, and closing signups begins no plan for it (SR-CWL-12).
Every rule that needs the lineup size uses the current revision.

Backed by: one participation per cycle and clan; one revision number per
participation and one revision per operation (unique keys); lineup size 15 or
30; a first revision is never a withdrawal (`CHECK`). Revisions never change
(SR-CTX-06).

### SR-CWL-03 Sign up

Source: `cwl_signup`, `valid_cwl_availability` (V6).

1. Own account or staff (SR-ACT-02). [permission]
2. The target participation and its cycle must exist [missing], and the
    target's current revision must not be withdrawn (SR-CWL-02). [rule]
3. An ended cycle accepts no signup; a member who is not staff cannot sign up,
    edit or move a signup after the close or outside state `signups`.
    [permission]
4. Take the CWL signup lock for the cycle and account.
5. Availability is 1–7 War Days, each from 1 to 7, distinct and not null.
    [rule] It is stored sorted. Backed by: a `CHECK` for one dimension, one to
    seven elements and every element in 1–7, which also rejects a null; the
    service keeps the days distinct and sorted.
6. An account has one signup per cycle, and each revision names its target
    clan. A revision with another target moves the signup (CWL-002, CWL-004);
    staff may move it after the close. The target may differ from the
    account's current clan.
7. Create the signup row (cycle and account) when missing, and insert a
    revision: the next number, the target, the days, the TH, the withdrawn
    flag, the actor and the operation.
8. Insert an export revision for the target's signups and a replan request
    for the target. After a move, do both for the clan the signup left too.

Backed by: one signup per cycle and account (unique key); the revision's
signup and target belong to the same cycle (composite foreign keys); one
export revision per clan and signup revision (unique key).
`current_cwl_signup` is the latest revision of each signup, with its target.

### SR-CWL-04 Registration status

Source: `cwl_registration_status` (V6).

From the latest complete league-group observation of the cycle that registers
the participating clan: `registered` when the account is in that clan's
registered pool, `not_registered` otherwise. `unknown` when no complete
observation registers the clan. Registration is not current clan membership
and not a daily lineup.

### SR-CWL-05 Frozen days

Source: `cwl_day_is_frozen` (V6).

A War Day is frozen once its war is known and now is at or after the war's
actual start minus `automatic_freeze_minutes`. A day without a known war is
not frozen. Never derive start times from a fixed 24-hour cadence.

The first time a freeze applies, insert it into `fact_cwl_day_freeze` with the
day's war, the cutoff used and the time it took effect (CWL-017).
Once a day has a freeze row it is frozen, whatever the cutoff says later.
Backed by: one freeze per day (primary key); the freeze names the day's war,
and that war cannot change after the freeze (composite foreign key).

### SR-CWL-06 Current-season performance

Source: `cwl_current_performance` (V6).

For one account in one participation: over the participation's CWL wars, the
sum of stars, the number of attacks, the average destruction and the wars with
attacks. Regular wars, earlier seasons and other linked accounts never count
(CWL-007).

### SR-CWL-07 War Day references

Source: `cwl_validate_war_reference`, `cwl_pending_war_reference` (V6).

- A War Day's war must be a CWL war with the participating clan on one side,
  team size equal to the current lineup size (SR-CWL-02), and referenced by a
  round war reference
  whose round equals the War Day, in a group observation of this cycle that
  registers the clan. [rule]
- A round war reference keeps its group, round and tag forever; its war key
  can be filled in once and must be a CWL war; it is never deleted. A `#0` tag
  has no war. [rule]

### SR-CWL-08 Bench incidents

Source: `cwl_validate_bench_incident` (V6).

- The account must be on the participating clan's side of the war, and the
  war must be one of the participation's CWL War Days. [rule]
- `poor_attack`: the referenced attack is this account's in this war with at
  most one star. [rule]
- `missed_attack`: a `warEnded` clan observation at the incident's source time
  whose reported attack count equals the attack rows of that clan, a roster at
  that observation with exactly the team size, the account on that roster, and
  no attack by the account in the war. [rule] Incomplete or ongoing evidence
  never creates a missed attack.
- Backed by: one incident per participation, account and war; an attack
  exactly on `poor_attack`.

### SR-CWL-09 Next bench day

Source: `cwl_next_bench_day` (V6).

For an open incident (no resolution) in a cycle that has not ended:

- when the incident has an assigned day that is now frozen, still in the
  account's availability with the signup not withdrawn, and the account is not
  `not_registered`, that day;
- otherwise the earliest War Day after the incident's war day that is in the
  account's availability, not frozen, and where the account is not
  `not_registered`;
- otherwise none.

An unavailable day never consumes the bench.

**Registration (DEC-15, decided 2026-11-14, CWL-012, CWL-013):** unknown
registration may reserve a provisional bench day, as the reference did, but
only confirmed registration lets the day serve the bench (SR-CWL-16). Keep
provisional reservation separate from that service decision.

### SR-CWL-10 Plan assignments

Source: `cwl_validate_assignment` (V6).

Checked for every assignment, in this order:

1. The cycle has not ended. [rule]
2. A manual plan's assignment needs a current staff actor. [permission]
3. A published plan is immutable. [rule]
4. The slot is within the clan's current lineup size (SR-CWL-02). [rule]
5. A plan may carry forward, on a frozen day, the exact slot and account of
    the latest published plan without new current-signup, availability,
    performance or bench checks. It still needs an input and retained
    historical provenance (SR-CWL-11, GAP-15). An automatic plan can only
    preserve that frozen result; a manual replacement must pass the remaining
    checks. Copying unaffected frozen rows into a manual plan does not
    retroactively revalidate their old eligibility.
6. The account's current signup targets the plan's clan and is not
    withdrawn, the day is in its availability, and the account is not
    `not_registered`. [rule]
7. An automatic plan cannot otherwise change a frozen day. [rule]
8. The row cannot conflict with a pin of that day: same slot with another
    account, or same account in another slot. [rule]
9. An account with more than one open incident needs staff resolution first;
    no stacking rule is chosen. [rule]
10. A day on which the account served a bench stays excluded. [rule]
11. The account's next bench day is blocked. [rule]

Backed by: primary key `(plan, day, slot)`; unique `(plan, day, account)`; the
account must have an input row in the plan (foreign key); slot 1–30.

### SR-CWL-11 Begin a plan

Source: `cwl_begin_plan` (V6).

Take the plan lock for the participation. The participation must exist in a
cycle that has not ended. [missing] Insert the next automatic revision with
its algorithm and phase (`initial_th_availability` or
`current_season_performance`).

**Change / target (GAP-15, CWL-004, CWL-010, CWL-017):** snapshot the union
of current candidates targeting this clan and accounts needed to carry forward
the latest published frozen assignments. A signup moved to another clan must
not make its already frozen assignment impossible to retain.

- Current candidates reference their current signup revision for this
  participation/account and current-season performance (SR-CWL-06).
- For an account absent from the current candidate set but required by a
  frozen assignment, retain the prior plan's signup/performance input. That
  historical revision must belong to this participation/account, but need not
  still be current. Do not require its performance to equal a new computation.
- With one input per plan/account, an account in both sets can use its current
  input for future planning. Its frozen assignment remains explained by the
  prior published plan and its original input; do not rewrite that old plan.
- Carrying a historical input grants no eligibility on an unfrozen day.
  Apply current-signup checks to those assignments (SR-CWL-10, SR-CWL-14).

Current schema retains these inputs and old plans. Backed by: an input's
signup revision targets the plan's clan (composite foreign keys through
`fact_cwl_plan_input.participation_key`), so a moved signup's later revision
cannot explain the old clan's input, while its earlier revision can. The
missing piece is the input-selection/validation workflow.
`080_cwl_and_custom_events.sql` traces Day 1 freezing, the move A→B and a
carried-forward plan; the service acceptance below remains.

**Acceptance:** after Day 1 freezes, move a signup A→B and regenerate both
clans. A preserves its frozen assignment and historical input, excludes that
account from future candidacy unless supported by a current A signup, and
exports the new revisions without changing the old plan.

### SR-CWL-12 Close signups

Source: `cwl_close_signups` (V6).

Lock the cycle. The close time must have passed. [rule] When the cycle is
still in `signups`: set it to `planning`, begin a plan per participation
whose current revision is not withdrawn (`initial-input-snapshot-v1`) and queue
a replan request (`signup_close`).
Otherwise do nothing. The provisional seven-day plan exists before in-game
registration is known (CWL-003).

### SR-CWL-13 Manual plans and assignments

Source: `cwl_manual_plan`, `cwl_set_assignment` (V6).

- Manual plan: staff [permission]; begin a plan in phase
  `current_season_performance`, then mark it `manual` with the actor.
- Assignment: staff [permission]; the plan must be manual [missing]; insert the
  assignment (SR-CWL-10).

**Change / target (GAP-16, CWL-010, CWL-011):** a staff replacement on a
frozen day uses this manual path. Start from the latest published assignments,
retain unaffected frozen days, apply the authorized replacement and pin, and
validate/publish a manual revision with actor and reason. Commit its pin,
published plan and resulting export/notification intents together. Do not
route that replacement through an automatic replan that forbids the change.
This path still checks signup availability, registration and bench rules;
a pin is never an implicit bench override.

### SR-CWL-14 Publish a plan

Source: `cwl_publish_plan`, `cwl_validate_plan_publication` (V6).

1. Lock the plan. A published plan returns at once.
2. Complete means all seven days have exactly the clan's current lineup size.
3. When completeness is required and the plan is incomplete, or a new/current
    assignment is not `registered`, fail. [rule] Copied frozen rows retain the
    prior published plan's validation context; their historical registration
    evidence is not replaced by today's signup or membership state.
4. Revalidate before publishing:
    - an automatic plan cannot change any frozen day compared with the
      previous published plan [rule];
    - a manual plan's actor must still be staff [permission];
    - every assignment, except unchanged copied rows on frozen days, must still match
      the current signup (not withdrawn, available, and the input's signup
      revision is the current one), registration, and bench state [rule];
    - every applicable pin must be in the plan. A new pin replacing a frozen
      assignment must first publish through the manual path (GAP-16), not
      make an automatic plan satisfy contradictory frozen/pin checks. [rule]
5. Set `published_at` and the quality: `incomplete` when not complete,
    `provisional` when an account is not `registered`, otherwise `complete`.
6. Insert an export revision for the lineups.

The plan's participation and revision never change, and a published plan
never changes. [rule]

**Change:** lock the plan before validating an assignment, so that a
concurrent assignment cannot enter a plan that is being published.

**Acceptance (GAP-15, GAP-16):** a signup move does not drop a frozen account;
a post-cutoff staff replacement publishes as manual; the next automatic plan
copies that manual frozen result unchanged. Unfrozen days still revalidate
current inputs, pins, eligibility, and bench state.

### SR-CWL-15 Pins

Source: `cwl_pin`, `cwl_unpin`, `cwl_validate_pin` (V6).

- Staff only [permission]; a pin needs a reason [rule]; the cycle must not
  have ended [rule].
- The account must have an available signup that is not withdrawn, the slot
  must fit the lineup size, and the account must not be `not_registered`.
  [rule]
- A pin cannot sit on the account's next bench day or a served bench day; a
  pin never implies a bench override. [rule]
- Pinning inserts the next revision of the day and slot with the account;
  unpinning inserts one without an account (CWL-017). Both keep the actor,
  the reason and the operation. For unfrozen days they queue an automatic
  replan request. For a frozen-day replacement they use SR-CWL-13's manual
  revision path (GAP-16), then regenerate eligible future days around it.
  The current pin of a slot is its latest revision (`current_cwl_manual_pin`).
  Pins survive regeneration (SR-CWL-14). Staff may pin after the automatic
  cutoff (CWL-011); authority for that change remains explicit.
- An account holds at most one current pin per War Day. [rule] No constraint
  can see which revision is current, so check it under the plan lock; moving
  an account is an unpin and a pin in one command.
- Backed by: one revision number per slot (unique key); slots 1–30; the day
  must be a War Day of the participating clan (foreign key).

### SR-CWL-16 Benches

Source: `cwl_assign_bench`, `cwl_record_bench_service`, `cwl_end_cycle`,
`cwl_override_bench`, `cwl_validate_resolution` (V6).

- Assign: lock the incident; more than one open incident for the account
  fails [rule]; assign the next bench day (SR-CWL-09) or nothing; queue a
  replan request (`mandatory_bench`).
- Serve: lock the incident; a resolved incident returns at once. The day must
  be the assigned day and the next bench day [rule], in the account's
  availability [rule], and its war must have ended with a complete final
  roster (`warEnded`, roster size equal to the team size) that does not
  contain the account [rule]. Registration must be confirmed: the latest
  complete group observation of the cycle observed at or before that war's end
  lists the account in the participating clan's `fact_cwl_registered_player`
  pool [rule]. Unknown registration leaves the incident open, and the next
  bench day is assigned again. Insert a `served` resolution.
- Override: staff [permission]; insert a `staff_override` resolution with the
  actor and reason. An override is separate from a pin.
- End the cycle: the end time is required, not in the future, and not before
  any known war of the cycle ends [rule]; set `ended`; every open incident
  expires (`season_expiry`).
- Resolutions [rule]: an override needs a staff actor; an expiry needs an
  ended cycle; a service needs an assignment on that day and only one open
  incident. Backed by: one resolution per incident; a day exactly on
  `served`; an actor exactly on `staff_override`.

**Acceptance (DEC-15, decided 2026-11-14):** a provisionally reserved day
whose registered pool was never confirmed does not serve and the incident
stays open; a confirmed eligible available day serves; an unavailable day
does not consume the bench; an incident still open at the cycle end expires.

### SR-CWL-17 Exports

Source: `cwl_project_export_attempt` (V6).

- An export revision exists per signup revision and per published plan.
- Each CSV or Sheets attempt is a row with a format, an attempt number, an
  outcome and an artifact reference or error code.
- The latest Sheets attempt sets the revision's `sheets_state`. A failed
  synchronization never changes the plan (CWL-016).

**Export contract (GAP-19, closed 2026-11-14, CWL-016, CWL-017):**

- Create: take the advisory `cwl-export` lock on the participation and kind,
  then insert the export revision with `export_sequence` = the
  latest of that clan and kind plus one, the destination copied from the
  clan's settings (`sheet_document_id`, and the tab for the kind), or none
  when no Sheet is configured. A signup-list export also inserts one
  `cwl_export_signup_input` row per included signup naming its selected
  revision at that moment; a lineup export names its published plan. Inputs
  and destination never change afterwards.
- CSV: write the file from the frozen inputs and insert the attempt with its
  outcome (no fence).
- Sheets: one writer at a time per clan and kind through
  `cwl_sheet_destination`. Claim: lock the row, take the lease when it is
  free or expired, with a new `fence`. Pick the highest-sequence revision of
  that clan and kind above `confirmed_sequence`; older pending revisions are
  never written (their `sheets_state` stays `pending`, superseded by order).
  Authorize: insert the attempt with the fence and a `lease_expires_at` no
  later than the destination lease, before any external call. Write: only
  when the remaining lease exceeds the Sheets request timeout; write the
  sequence into the Sheet with the data and skip the write when the Sheet
  already shows a higher sequence. Result: with the fence still current,
  complete the attempt once (`outcome`, `completed_at`), set the revision's
  `sheets_state`, and on success raise `confirmed_sequence`.
- Takeover after an expired lease or an `uncertain` result: the new holder
  takes a new fence and writes only after the old lease plus the request
  timeout has passed, so an old in-flight write has landed or failed first;
  it re-reads the Sheet's sequence before writing. A late result from an old
  fence is recorded on its own attempt but never changes `sheets_state` or
  `confirmed_sequence`.
- Backed by: unique sequence per clan and kind; inputs only on a signup
  export, once per signup, each naming a revision of that signup; a Sheets
  attempt has a fence and a lease, a CSV attempt has its outcome at once;
  only the outcome columns of an attempt are updatable.

**Acceptance:** delay export N while N+1 is queued, then resume N; the final
Sheet shows N+1. Repeat after a destination change and after a lost write
response. CSV and Sheets retain independent outcomes, stable retry identities,
and exact input/destination provenance; sync failures never mutate the plan.

## SR-CUS: Custom events

**Specs:** CUSTOM-001 to CUSTOM-007. **Tables:** `custom_event`,
`custom_event_signup`, `fact_custom_event_signup_revision`,
`custom_roster_revision`, `custom_roster_account` (`V6`). **Checks:**
`110_cwl_and_custom_events.sql`.

### SR-CUS-01 Commands

Source: `custom_event_create`, `custom_event_signup`, `custom_event_roster`,
`custom_event_result`, `custom_event_complete`,
`custom_validate_war_association` (V6).

All follow the activity envelope (SR-ACT-01).

- Create: staff [permission]; a non-blank name; state `signups`.
- Sign up: own account or staff [permission]; the event must not be
  `completed` [rule]; one signup per event and account (unique key). Every
  change inserts the next revision with the withdrawn flag, the actor and
  the operation (`fact_custom_event_signup_revision`, CUSTOM-006), one
  revision per operation (unique key). `current_custom_event_signup` is the
  latest revision.
- Roster: staff [permission]; lock the event; not `completed` [rule]; a
  non-blank reason; insert the next roster revision; every account must have
  a signup that is not withdrawn [missing]; set the state to `roster`. One
  roster per event; there are no rounds (CUSTOM-004).
- Result: staff [permission]; the event must have no war yet [rule]; the war
  must be a `custom` war [rule]; set the war, the actor, the operation and the
  reason together. The association is write-once, and an event with a war
  cannot be deleted. [rule]
- Complete: staff [permission]; set the state to `completed`.

**Change:** let the result command reclassify a war from `regular`
to `custom`, because the collector cannot know a friendly war in advance
(CUSTOM-005).

## SR-NTF: Notifications and delivery

**Specs:** NOTIFY-001 to NOTIFY-016, WAR-005, WAR-008, RAID-001, RAID-003,
RAID-008, MEM-013, MEM-014, CG-018, CG-019, CWL-001, CWL-009. **Tables:**
`notification_operation`, `notification_mention_role`,
`notification_mention_user`, `notification_report`, the
`notification_role_*` tables, `fact_notification_publication_attempt`,
`notification_kafka_receipt`, `fact_notification_dispatch_attempt`,
`notification_catchup_input` and the typed context tables (`V7`).
**Checks:** `120_notification_delivery.sql`, `140_feature_integration.sql`.

### SR-NTF-01 Operations and logical keys

Source: `_enqueue_notification` (V7).

- Insert an operation by logical key (`^[A-Za-z0-9_:./-]{1,200}$`). An
  existing key must have the same notification kind, channel, audience, due
  and expiry times, war, clan, offset, target, generation and report
  [conflict]; it returns the stored operation. For ping/role work, its kind
  must match too. For report work, compare the report/revision identity and
  immutable content context (SR-NTF-13); a dispatch changing the action
  between create and edit is not a different queued revision. Commit the
  operation with the domain decision that caused it (NOTIFY-003).
- Kinds: `ping`, `role_reconcile`, `report_create`, `report_edit`.
  Notification kinds: `welcome`, `war_reminder`, `war_catchup`,
  `clan_games_report`, `raid_start`, `raid_report`, `moderation`,
  `role_reconcile`, `cwl_leadership`, `cwl_roster`, `cwl_signups`. Audience `members` or
  `leadership`.
- Backed by: expiry after the due time; role work exactly with a target and a
  generation and without a channel; war kinds exactly with a war and a clan;
  `war_reminder` exactly with an offset; report kinds exactly with a report
  and a revision; one reminder per war, clan and offset; one catch-up per war
  and clan; one operation per report revision; `event_version` 1.

- Suppression evidence (NOTIFY-016): whenever the service sets `expired` or
  `superseded`, it inserts `fact_notification_disposition` in the same
  transaction: the disposition, its cause (`expiry_passed`, `war_inactive`,
  `newer_report_revision`, `coalesced_into_catchup`,
  `role_generation_replaced`, `member_absent`, `no_unused_attacks`), the
  time and, for a
  supersession, the replacing operation. Backed by: one disposition per
  operation; expiry causes only for `expired`; a newer revision or catch-up
  names its replacement; nothing supersedes itself. `status` is the latest
  state only; do not describe a pending operation as attempted merely because
  it was published or consumed.

### SR-NTF-02 Pings

Source: `queue_notification_ping` (V7).

Only `welcome`, `raid_start`, `moderation`, `clan_games_report` and
`raid_report` can be queued directly. [rule] War reminders, catch-ups, CWL
prompts and rosters have their own steps.

Queuing an operation also stores whom it mentions (NOTIFY-014): a
`notification_mention_role` row per role and a `notification_mention_user`
row per member, fixed in the same transaction. Delivery mentions exactly
these targets; an operation without them mentions nobody. A `raid_start`
ping names its clan, and its mention is that clan's member role (RAID-001).
Backed by: one row per operation and target (primary keys); the targets
exist (foreign keys); `raid_start` needs a clan (`CHECK`). Rows never change.

Typed source context (MOD-006, MOD-007, RAID-001, NOTIFY-016), queued with
the operation and the source decision; the renderer never parses a logical
key:

- `moderation`: one `notification_moderation_context` row naming exactly one
  source: the warning (`warning_issued`), its revocation (`warning_revoked`),
  a kick decision transition (`kick_transition`), a kick attempt
  (`kick_attempt`) or a rejoin notice (`rejoin_notice`). Backed by: one
  source per row, of the kind it states (`CHECK`), and foreign keys.
- `raid_start`: one `notification_raid_start_context` row naming the weekend;
  a weekend is announced once (unique). The weekend's clan is the operation's
  clan. [rule]
- The context belongs to an operation of the matching notification kind.
  [rule]

### SR-NTF-03 Outbox publication

Source: `claim_notification_publication`, `finish_notification_publication`
(V7).

- Claim: lease 1–300 seconds (default 30) and a valid worker ID [rule]; lock
  the operation; nothing to do when published or leased with an active lease;
  otherwise lease it with a new fence.
- Finish: lock the operation; it must be leased with the same fence and an
  active lease [rule: stale fence]; insert the publication attempt (a
  `published` attempt needs topic, partition and offset); set `published`, or
  back to `pending` after a failure; clear the lease.
- Publication is not delivery. A repeated publication keeps the logical ID.

### SR-NTF-04 Kafka consumption

Source: `record_notification_consumption` (V7).

Lock the operation (it must exist [missing]). Store every distinct Kafka
coordinate per consumer group. The first receipt per group and operation is
marked. The same coordinate again returns false; a coordinate already stored
for another operation fails. [conflict] Dispatch requires a first receipt
(SR-NTF-06), so work never bypasses Kafka.

### SR-NTF-05 Active war

Source: `_notification_war_active` (V7).

A war is active for a clan when the clan is a side, now is within
`[started_at, ends_at)`, and the clan's latest war observation, if any, is not
`warEnded`.

### SR-NTF-06 Claim a dispatch

Source: `claim_notification_dispatch` (V7).

1. Lease 1–300 seconds and a valid worker ID. [rule]
2. Lock in order: the role target (role work), the report (report work),
    then the operation.
3. Return nothing for `expired` or `superseded` operations, and for
    `delivered` ones other than role work. Role reconciliation can run again.
4. A ping that already has an authorization never gets another: when it is
    `in_flight` with an expired lease, close that attempt as `uncertain`
    (`lease_expired`) and set the ping `uncertain`; return nothing.
5. When the operation has expired, or its war is no longer active, set it
    `expired` and return nothing.
6. Role work: when the member is known absent, or the operation's generation
    is no longer current, set it `superseded` and return nothing.
7. An earlier authorization with an active lease while `in_flight` blocks the
    claim. One without an outcome is closed as `uncertain`
    (`lease_expired`).
8. Report work: a revision older than the report's latest revision becomes
    `superseded`; while another revision of the same report is in flight with
    an active lease, return nothing.
9. Return nothing when the operation is not due or has no first Kafka
    receipt.
10. For report work, choose `report_create` when the report has no message,
    otherwise `report_edit`. Preserve `ping` and `role_reconcile` for their
    respective operations. Insert the authorization (next attempt number,
    ping flag, worker, lease), set the operation `in_flight` with the new
    fence and selected action, and return the fence. The authorization
    stores its own `dispatch_action` and, for an edit, the
    `requested_message_id` (the report's message at claim time). A create
    after a missing message names the failed edit in
    `replaced_dispatch_key`.

Backed by: one authorization per ping (partial unique index); the ping flag
matches the action; an edit exactly with a requested message; a replacement
only on a create and only of an attempt of the same operation.

### SR-NTF-07 Begin a send

Source: `begin_notification_send` (V7).

Lock the role target (role work), then the operation. The operation must be
`in_flight` with this fence; the lease must be active; the operation must not
have expired; its war must be active; the permit must not have been used.
Role work also checks presence (absent: `superseded`) and the current
generation. War work resolves its mentions now (SR-NTF-11); when no roster
account has an unused attack, set the operation `expired` with a
`no_unused_attacks` disposition and return false without consuming the
permit. Then set `started_at` once and, for war work, the remaining
seconds until the war ends. Return true only when this call consumed the
permit. Node calls Discord only after a true result, and no layer resends a
ping automatically (NOTIFY-006).

### SR-NTF-08 Record a result

Source: `record_notification_result`, `_close_notification_dispatch` (V7).

Lock the report (report work), then the operation. It must be `in_flight`
with this fence [rule] and the lease must be active [rule]. A `succeeded`
outcome needs a 2xx HTTP status, a Discord message ID for channel work, and a
started send [rule]. Close the attempt (write-once). A succeeded report
revision also records the report's message (SR-NTF-13). The operation becomes
`delivered`, `failed` or `uncertain`.

Interpret the result with the attempt's own `dispatch_action` and
`requested_message_id` (NOTIFY-013, NOTIFY-016), never with the operation's
latest `operation_kind` or the report's current message. A succeeded edit
must return the requested message (`CHECK`).

### SR-NTF-09 Attempt records

Source: `guard_notification_authorization` (V7).

- An authorization's operation, fence, number, ping flag, worker, time and
  lease never change. Its outcome is set once, its send start is set once, and
  `succeeded` needs a started send. [rule]
- On insert, the ping flag matches the operation kind, and no start, finish or
  outcome is set. [rule]
- Backed by: one authorization number per operation; a unique fence; the lease
  after the authorization; outcome, finish and record times set together; a
  `succeeded` outcome with a started send and a 2xx status.

- The action, requested message and replaced attempt are fixed at
  authorization (no update grant), separate from the response's
  `discord_message_id`. Clearing or replacing the report's current message
  keeps every attempt's original target.

**Acceptance (NOTIFY-013, NOTIFY-016):** edit message M, record Unknown
Message, then retry as create and receive N. The first attempt still says
edit M; the second says create with response N (`090_notification_delivery.sql`).
Replaying either result must not rewrite the other attempt; write-once
results stay a service rule.

### SR-NTF-10 Desired roles

Source: `set_notification_desired_roles` (V7).

1. The source key matches the logical key pattern, the role set is given, and
    it has no null role. [rule] Every role exists and is not deleted. [rule]
2. Ensure the member's target row and lock it.
3. Replace this source's requirements with the new set, and add the roles to
    the member's managed set.
4. Desired roles are the union of all sources; compare them with the desired
    roles of the current generation.
5. Reuse the current generation when the sets are equal and that generation's
    operation can still apply them: not `superseded` or `expired`, and not
    delivered before the member's latest presence event.
6. Otherwise create the next generation with one requirement row per managed
    role (`is_desired` when in the union), point the target to it, supersede
    the member's open role operations, and queue `role:<user>:<generation>`
    due now.

Only managed roles are ever removed; unrelated manual roles are preserved.

### SR-NTF-11 War reminders

Source: `schedule_war_reminders` (V7).

Lock the war. The clan must be a side and an enabled tracked clan [rule]; its
`war` channel must be bound [missing]. For each configured offset, queue
`war:<war>:clan:<clan>:offset:<seconds>`: a `war_reminder` ping due at the war
end minus the offset and expiring at the war end.

**Change (WAR-005, CUSTOM-005):** schedule reminders only for a war
of kind `regular`, and expire the pending reminders of a war that staff
attach to a custom event. A reminder is queued long before it is due, so the
members with unused attacks are not known then. Store its mentions when the
send begins (SR-NTF-07), from the roster and the attacks at that moment, not
when it is queued (SR-NTF-02).

**Decided (DEC-05, 2026-11-14, WAR-005):** a reminder mentions each Discord
member with a current link to a roster account that still has an unused
attack, once per member however many of their accounts qualify, and lists
unlinked roster accounts with unused attacks by in-game name. It never
mentions the war role. A member whose accounts used all attacks is not
mentioned. When no roster account has an unused attack at send time, the
reminder or catch-up is not sent (owner decision, 2026-11-14): SR-NTF-07
expires it with a `no_unused_attacks` disposition instead of consuming its
permit. Suppress only on supported attack evidence; a failed or incomplete
war observation is not proof that every attack was used (WAR-004).
**Acceptance:** a 4 h reminder after every roster account attacked is expired
with `no_unused_attacks` and no send attempt; one remaining unlinked account
still sends the reminder with its in-game name listed.

### SR-NTF-12 Catch-up after downtime

Source: `coalesce_missed_war_reminders` (V7).

Call during recovery, before dispatch resumes. Each outage may produce its
own catch-up (DEC-14, decided 2026-11-14, NOTIFY-011).

1. Lock the war. When the war is no longer active for the clan, expire its
    pending operations and return nothing.
2. Collect every `pending` reminder of the war and clan whose due time has
    passed and that never had an authorization. When there is none, return
    nothing.
3. When an unfinished catch-up (`pending` without an authorization) exists,
    reuse it. When one is `in_flight` or authorized, return nothing; the next
    recovery takes the reminders. Otherwise queue catch-up number n + 1
    (`war:<war>:clan:<clan>:catchup:<n>`, due now, expiring at the war end,
    same channel and audience), where n counts the earlier catch-ups.
4. Link each collected reminder to that catch-up and supersede it, with a
    `coalesced_into_catchup` disposition naming the catch-up (SR-NTF-01).
5. Set the catch-up's remaining seconds to the actual time left.

A reminder that was attempted, failed or uncertain is never relabeled as
catch-up work (NOTIFY-011). Repeating recovery reuses the same catch-up.
Backed by: at most one `pending` or `in_flight` catch-up per war and clan
(partial unique index); each reminder feeds at most one catch-up (unique
source in `notification_catchup_input`).

**Acceptance (DEC-14):** outage 1 misses the 8 h reminder, recovery sends
catch-up 1; outage 2 misses the 4 h reminder, recovery queues catch-up 2 for
only that reminder; repeating recovery 2 queues nothing new; an attempted 4 h
reminder is never coalesced.

### SR-NTF-13 Reports

Source: `register_notification_report`, `record_notification_report_message`,
`record_notification_report_missing`, `queue_notification_report` (V7).

- Register: one report per logical key; the same key must have the same kind
  (`clan_games_report`, `raid_report`, `cwl_roster`, `cwl_signups`), channel and audience.
  [conflict]
- Queue a revision: lock the report; an existing logical key must name the
  same report and due time [conflict]; otherwise the revision is the latest
  plus one, every older `pending`, `failed` or `uncertain` revision becomes
  `superseded` with a `newer_report_revision` disposition naming the new
  revision, and the operation is queued as `report_create` or
  `report_edit` by the current message.
- Record the message: a message ID is required [rule]; a report keeps its
  first message, accepts the same one again, and rejects another [rule].
- Message missing: lock the report, then the operation; it must be in flight
  with this fence, an active lease, an edit and a started send [rule]; close
  the attempt as failed (404, `report_message_missing`), forget the report's
  message and set the operation `failed`. The next claim of the same revision
  creates a new message.
- Report work may be claimed again after a failed or uncertain attempt; a
  create whose result was lost can post a second message, which a worker can
  adopt as the report's message.

Each dispatch retains its own create/edit action and requested target. A queue retry compares stable report/revision identity and
content context, not an old expectation of create/edit against the operation's
latest mutable dispatch action. A report's current-message projection does
not replace its attempt history.

Every revision of a raid or Clan Games report records its typed context when
it is queued (RAID-003, CG-019, CG-020). [rule] Context rows never
change.

- Raid report: `notification_raid_report_context` with the weekend, the
  latest successful `raid_poll` of that weekend and its `observed_at` as
  `observed_through`; member totals are the latest stored at or before it.
- Clan Games report: `notification_clan_games_report_context` with the
  event, and one `notification_clan_games_report_assessment` row for each
  member assessment version that the revision publishes. A points report
  publishes no assessment; it records one
  `notification_clan_games_report_progress` row for each account it shows,
  naming the exact `fact_clan_games_progress` row published (DEC-16, CG-020).
- The context belongs to an operation of the matching notification kind.
  [rule] Backed by: one context per operation (primary key); a published
  assessment belongs to the context's event and names its checkpoint; a
  published progress row belongs to the context's event and account, once
  per account in a revision (composite foreign keys, primary key).

**Decided (DEC-16, 2026-11-14, CG-018, CG-020):** a public points revision
freezes explicit progress rows, not an as-of cutoff, so a late-ingested
observation cannot change a replay. Render an old revision only from its own
progress rows. **Acceptance:** two revisions of one event with different
progress per account each replay their own values; progress of another event
or account is rejected.

**Raid collection (GAP-11, closed 2026-11-14, RAID-003, RAID-007):** every
raid poll of a tracked clan, every `raid_poll_seconds` (default 900), stores
one `raid_poll` row: `weekend` with the weekend, `no_weekend`, or `failed`
with a failure code. Weekend state (`fact_raid_weekend_observation`) and
account totals (`fact_raid_member_observation`) are stored only when they
differ from the latest stored value and name their poll; the successful polls
in between prove the unchanged values. `raid_weekend_coverage` gives each
weekend's `observed_through`, its latest successful poll.

- A failed poll is no evidence: the next report revision keeps the earlier
  `observed_through`, never a newer time, and never a zero.
- Measured zero: an account the same poll time's member list shows in the
  clan but absent from a successful weekend poll's member list did not raid
  (zero loot). Without membership or raid coverage, the total is unknown.
- Backed by: a poll names a weekend exactly on `weekend` and a failure code
  exactly on `failed`; the weekend belongs to the polled clan; state, totals
  and report contexts name a poll of the same weekend at the same time
  (composite foreign keys).

### SR-NTF-14 CWL notification context

Source: `validate_notification_cwl_context` (V7).

A prompt context (no plan) belongs to a `cwl_leadership` operation for the
`leadership` audience; a plan context belongs to a `cwl_roster` operation for
`members`. [rule] Context rows never change. Backed by: one prompt per cycle;
one roster operation per plan and War Day.

### SR-NTF-15 CWL leadership prompt

Source: `queue_cwl_leadership_prompt` (V7).

The cycle must exist [missing], and the `leadership_notifications` channel
must be bound [rule]. Queue `cwl:leadership:<cycle>`: a `cwl_leadership` ping
due seven days (168 hours) before signups close and expiring at the close,
unless explicit times are given, with its context row.

### SR-NTF-16 CWL roster reports

Source: `queue_cwl_roster_report` (V7).

Take the roster-output lock for the participation and War Day. A plan and day
already queued return their operation. The plan must be published and the day
valid [rule]; the clan's `cwl_roster` channel for that day must be bound
[rule]. When a newer plan revision is already queued for that day, queue
nothing and return nothing, so that an older roster never replaces a newer
one. Otherwise register the report `cwl:roster:<participation>:<day>` and
queue the revision `cwl:plan:<plan>:<day>`, due at the plan's creation, with
its context row.

### SR-NTF-17 CWL signup-list reports

GAP-08, closed 2026-11-14 (owner decision, CWL-016): the clan's `cwl_signups`
channel shows one edit-in-place report per participating clan and cycle,
`cwl:signups:<participation>`, of kind `cwl_signups` for `members`.

Each signup export revision of the clan (SR-CWL-17) also queues a report
revision `cwl:signups:<participation>:export:<export revision>` with a
`notification_cwl_signups_context` row naming that export, so the post shows
exactly the export's frozen signup inputs. Queue under the report lock; when
a higher export sequence is already queued, queue nothing, so an older list
never replaces a newer one. No bound `cwl_signups` channel: queue nothing.
Backed by: the context names a signup export (composite foreign key), once
per operation and once per export.

## SR-LB: Leaderboard calendars and boards

**Specs:** LB-001 to LB-011. **Tables:** `leaderboard_calendar_policy`,
`dim_leaderboard_monthly_period`, `leaderboard_metric_definition`, and the
calendar columns of `guild_settings` (`V8`). **Checks:**
`130_leaderboard_calendars.sql`.

### SR-LB-01 Timezones

Source: `validate_leaderboard_timezone` (V8).

A policy's timezone must be a named zone. [input] The SQL checked
`pg_timezone_names`; in Java use `ZoneId.of`, and compute every boundary with
that `ZoneId`, so that validation and calculation use the same rules.

### SR-LB-02 Reporting periods

Source: `validate_leaderboard_period` (V8).

Take the calendar lock. With the canonical start and end of the period's month
in its zone:

- The first period has sequence 1, is the only period, starts at its
  canonical start and is not a transition. [rule]
- A later period has the next sequence and the next month, and starts exactly
  where its predecessor ends. [rule]
- Every period ends at its canonical end, and is a transition exactly when its
  start differs from its canonical start (a timezone change shortened or
  extended it). [rule]

Backed by: unique sequence, month and predecessor; a month on day 1;
`starts_at < ends_at`; no overlapping periods. Periods and policies never
change.

### SR-LB-03 Materialize a period

Source: `ensure_leaderboard_monthly_period` (V8).

1. The time is required and not in the future. [input] The guild must exist.
    [missing]
2. Take the calendar lock. Return the period that contains the time.
3. Without a selected policy, create `Etc/UTC` ("Initial GMT leaderboard
    calendar") and select it in the guild settings.
4. Without any period, create the first one for the month of the time in the
    selected zone.
5. A time before the first period fails. [input]
6. Otherwise add periods one at a time after the last, in the selected zone,
    until one contains the time. Future periods are never created.

### SR-LB-04 Change the timezone

Source: `set_leaderboard_timezone` (V8).

1. The actor must be able to configure. [permission]
2. A named zone, a reason and an operation UUID are required. [input]
3. Take the calendar lock. An existing policy with that UUID must have the same
    actor, zone and reason [conflict] and is returned.
4. Materialize the current period first (SR-LB-03), so that it keeps the old
    policy.
5. Insert the policy and select it for the next period. Both writes are
    configuration changes (SR-CFG-13).

A change applies to the next period only; past and current periods are never
recalculated. Warning months and CWL deadlines stay GMT.

### SR-LB-05 Metric catalog

`leaderboard_metric_definition` lists which metric and period combinations are
supported. A combination that `needs_definition` uses the calculation method
`requires_definition`, and nothing may publish it as a score. Cumulative
snapshots are never summed into a period score (LB-009). A
`latest_season_counter` metric uses the last counter seen in the clan before
the CoC season ended; it is a per-season value, never a monthly one.

## SR-GRANT: Runtime grants

`V9` grants these privileges to `guild_runtime`, and nothing else grants to it.
Every table and view gets `SELECT`, by name, so the Flyway history stays
private. No `EXECUTE`, no sequence privilege, no ownership, no DDL. No `UPDATE` grant reaches a key,
an identity or a measure, outside the projections that the service rebuilds.

| Group | Tables | Writes |
| --- | --- | --- |
| Dimensions | `dim_discord_user`, `dim_player_account`, `dim_clan`, `dim_discord_role`, `dim_discord_channel` | `INSERT`; `UPDATE` of labels and sync columns only: `display_name`, `player_name`, `clan_name`, `role_name`, `channel_name`, `last_synced_at`, `deleted_at` |
| Dimensions | `dim_war` | `INSERT`; `UPDATE (war_kind)`, so that staff can attach a regular war to a custom event (SR-CUS-01) |
| Dimensions | `dim_achievement`, `dim_raid_weekend`, `dim_clan_games_event`, `dim_coc_season`, `dim_leaderboard_monthly_period` | `INSERT` |
| Dimensions | `dim_guild` | none: the operator seed creates it |
| Facts | every `fact_*` table, `player_verification`, `war_participant`, `warning`, `warning_revocation`, `clan_membership_poll`, `war_poll`, `raid_poll`, `clan_games_counter_read`, `clan_games_participation_evidence`, `custom_roster_revision`, `custom_roster_account`, `cwl_plan_assignment`, `notification_kafka_receipt` | `INSERT` only, except the columns below |
| Fact columns | `fact_api_fetch_attempt` | `UPDATE (completed_at, http_status, outcome, error_code)` |
| Fact columns | `fact_war_attack` | `UPDATE (last_observed_at)` |
| Fact columns | `fact_notification_dispatch_attempt` | `UPDATE (started_at, finished_at, outcome, recorded_at, discord_message_id, http_status, error_code)`, each set once (SR-NTF-09) |
| Fact columns | `fact_cwl_export_attempt` | `UPDATE (outcome, artifact_reference, error_code, completed_at)`, set once after a Sheets write (SR-CWL-17) |
| Fact columns | `clan_games_member_account_input` | `INSERT`; `UPDATE (account_assessment_key)`, set once |
| Bridges | `account_link` | `INSERT`; `UPDATE (unlinked_at, is_primary)` |
| Bridges | `metric_attribution_episode` | `INSERT`; `UPDATE (closed_at)` |
| Bridges | `observed_clan_membership_period` | `INSERT`; `UPDATE (observed_until, confirmed_through, last_poll_key, coverage_status)` |
| Projections | `discord_member_state`, `discord_member_role`, `chat_member_rank_state` | `INSERT`, `UPDATE`, `DELETE` |
| Workflow | `account_transfer_request` | `INSERT`; `UPDATE (status, decided_by, decided_at, consumed_at, cancelled_at, expired_at)` |
| Workflow | `moderation_action` | `INSERT`; `UPDATE (status, attempts_remaining, next_attempt_at, lease_owner, lease_expires_at, claim_token, cancelled_at, trigger_warning_key, decided_at)` |
| Workflow | `clan_games_read_request` | `INSERT`; `UPDATE (due_at, collect_from, status, missed_at)` |
| Workflow | `cwl_cycle` | `INSERT`; `UPDATE (state, ended_at)` |
| Workflow | `cwl_participating_clan`, `cwl_signup`, `custom_event_signup`, `cwl_plan_revision` | `INSERT`; plan `UPDATE (published_at, quality, source_kind, actor_user_key)` |
| Workflow | `cwl_clan_day`, `cwl_round_war_reference` | `INSERT`; `UPDATE (war_key)` |
| Workflow | `cwl_replan_request` | `INSERT`; `UPDATE (completed_plan_key)` |
| Workflow | `cwl_bench_assignment` | `INSERT`; `UPDATE (war_day, assigned_at)` |
| Workflow | `cwl_export_revision` | `INSERT`; `UPDATE (sheets_state)` |
| Workflow | `cwl_export_signup_input` | `INSERT` |
| Workflow | `cwl_sheet_destination` | `INSERT`; `UPDATE (lease_owner, lease_expires_at, fence, confirmed_sequence)` |
| Workflow | `custom_event` | `INSERT`; `UPDATE (state, war_key, associated_by, association_operation_id, association_reason)` |
| Workflow | `activity_command_operation` | `INSERT`; `UPDATE (result_key)` |
| Delivery | `notification_operation` | `INSERT`; `UPDATE (status, current_fence, operation_kind, remaining_seconds, publication_state, publication_fence, publication_lease_expires_at, publication_worker_key)` |
| Delivery | `notification_report` | `INSERT`; `UPDATE (discord_message_id, message_confirmed_at, latest_revision)` |
| Delivery | `notification_role_target` | `INSERT`; `UPDATE (generation)` |
| Delivery | `notification_role_source_requirement` | `INSERT`, `DELETE` |
| Delivery | `notification_managed_role`, `notification_role_generation`, `notification_role_generation_requirement`, `notification_catchup_input`, `notification_cwl_context`, `notification_mention_role`, `notification_mention_user`, `notification_raid_report_context`, `notification_clan_games_report_context`, `notification_clan_games_report_assessment`, `notification_clan_games_report_progress`, `notification_cwl_signups_context` | `INSERT` |
| Configuration | `guild_settings` | `INSERT`; `UPDATE` of every setting column except `guild_key`, `chat_xp_policy_key`, which has no command (SR-XP-01), and `owner_developer_user_key`, which only an operator changes (SR-CFG-12); no `DELETE` |
| Configuration | `clan_collection_settings` | `INSERT`; `UPDATE` of every column except `clan_key`; no `DELETE` |
| Configuration | `role_binding`, `chat_rank_role_binding` | `INSERT`, `UPDATE (role_key)`, `DELETE` |
| Configuration | `channel_binding` | `INSERT`, `UPDATE (channel_key)`, `DELETE` |
| Configuration | `war_reminder_setting`, `chat_xp_eligibility_role`, `developer_allowlist` | `INSERT`, `DELETE` |
| Configuration | `leaderboard_calendar_policy` | `INSERT` |
| Reference | `chat_xp_policy`, `chat_rank_tier`, `leaderboard_metric_definition` | none |

A binding command replaces the role or channel of a purpose; it never moves a
binding to another purpose, clan, level or War Day, so the configuration
tables have no `UPDATE` on those columns.

`V9` grants no privilege on the identity sequences. PostgreSQL does not check
sequence privileges for an identity column's default, so `INSERT` alone fills
it; the service never calls `nextval` itself.

The schema check `110_runtime_grants.sql` holds the `UPDATE` and `DELETE`
lists of this table and fails on any difference. It also proves that the
runtime role reads every table and view but not the Flyway history, inserts
into every table except `dim_guild` and the reference tables, cannot update or
delete a fact, has no `UPDATE` on a key or identity column, holds no
privilege on a sequence, and fills an identity column with `INSERT` alone.

## SR-TEST: Porting the SQL tests

The 16 SQL test files at `c407abb` hold 586 checks, listed in the
[SQL reference map](guild-sql-reference-map.md#checks-of-the-sql-tests). Each
check either moves to a Java test, stays as a schema check, or is dropped
with a reason.

Schema checks in `services/guild/schema/src/test/sql` replaced those files,
one file per migration domain. They test keys, unique and partial unique
indexes, `CHECK` and exclusion constraints, generated columns and the grants
of [SR-GRANT](#sr-grant-runtime-grants).
Their fixtures write as `guild_runtime`, so a missing grant fails them. A
check of the map that a schema check now covers ends with "schema check in"
and the file; the schema checks also cover constraints that no check of the
reference tested. Every other check of the map moves to a Java test or is
dropped as the table says.

| File at `c407abb` | Covers | Target |
| --- | --- | --- |
| `010_dimensions.sql` | Snowflake range, tag formats, one guild, binding scopes | Schema checks in `010_dimensions.sql` |
| `020_account_links.sql` | Verification, links, transfers, primary, attribution, expiry, cancellation | Keys and status checks in `020_account_links.sql`; the rest Java database tests (SR-ACC), with unit tests for the limits of SR-ACC-06 |
| `030_coc.sql` | Membership evidence, overlaps, counters, event idempotency, proration, war integrity, raids, member list, season donations | Constraints in `030_coc.sql` and `040_clan_games.sql`; rules as Java tests (SR-MEM, SR-WAR, SR-CG); unit tests for proration and seasons |
| `040_discord.sql` | Presence, roles, New Joinee, XP, ranks, warnings | Generated columns and immutability in `050_discord.sql` and `060_moderation.sql`; the rest Java database tests (SR-DSC, SR-XP, SR-MOD) |
| `050_access.sql` | Private readers, configuration commands, permissions | History constraints in `070_configuration_history.sql`, grants in `110_runtime_grants.sql`; readers and permissions are Java permission tests (SR-AUTH, SR-CFG). Dropped: the runtime role now reads private tables, and no trigger records configuration changes |
| `060_manual_events.sql` | Manual Clan Games events | Event keys in `040_clan_games.sql`; the rest Java tests (SR-CG-02) |
| `070_membership_closing.sql` | Departure and closing evidence | Period identity grants in `030_coc.sql`; the rest Java tests (SR-MEM-02, SR-MEM-03) |
| `080_command_actors.sql` | Actors on commands and configuration history | Java tests (SR-CFG-01, SR-CFG-13) |
| `090_security_hardening.sql` | Definer `search_path`, `PUBLIC` execute, role epochs, retention | Dropped: definer and `EXECUTE` checks, since `110_runtime_grants.sql` proves that the schema has no routines or triggers and `PUBLIC` has no privilege. Role epochs move to Java (SR-DSC-02); retention is the grant checks |
| `100_clan_games.sql` | Counters, inference, checkpoints, transfers, slices, rounding | Keys and generated results in `040_clan_games.sql`; unit tests for calculations; Java database tests for evidence (SR-CG) |
| `105_discord_policies.sql` | Rolling XP, decisions, ranks, kick claims, rejoins, manual moderation | Seeded tiers, XP and attempt keys in `050_discord.sql` and `060_moderation.sql`; Java database tests with concurrent workers (SR-XP, SR-MOD) |
| `110_cwl_and_custom_events.sql` | Signups, plans, freezes, pins, benches, exports, custom rosters | Keys and row checks in `080_cwl_and_custom_events.sql`; Java database tests (SR-CWL, SR-CUS, SR-ACT) |
| `120_notification_delivery.sql` | Outbox, Kafka receipts, one ping attempt, uncertainty, catch-up, reports, roles | Keys and row checks in `090_notification_delivery.sql`; Java database tests with concurrent workers (SR-NTF) |
| `130_leaderboard_calendars.sql` | Periods, transitions, timezone changes | Selection, overlaps and immutability in `100_leaderboard_calendars.sql`; unit tests with `java.time`; Java database tests (SR-LB) |
| `140_feature_integration.sql` | Desired roles, provenance, settings, reminders | Binding and reminder keys in `010_dimensions.sql` and `030_coc.sql`; Java tests (SR-DSC-06, SR-NTF) |
| `150_runtime_paths.sql` | What the runtime role can and cannot do | `110_runtime_grants.sql`; the entry-point checks are dropped with the functions |

Rules that need no database (SR-ACC-06, SR-CG-03, SR-CG-11 rounding, SR-XP-02,
SR-XP-04 thresholds, SR-MEM-06, SR-LB-02, SR-MOD-02) are unit tests in the
ordinary build. Everything that relies on locks, constraints or concurrent
workers runs against a disposable database as its own task and CI step.
