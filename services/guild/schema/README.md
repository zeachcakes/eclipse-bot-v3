# Guild database schema

The [feature specifications](../../../docs/feature-specs/README.md) record the
agreed requirements. The [revised design](../../../docs/design/guild-star-schema.md)
describes their dimensional and workflow model. These migrations implement the
persistence foundation and database invariants; external workers and clients
remain separate runtime work.

This module owns the PostgreSQL schema named guild. Its SQL migrations
implement the CoC and Discord utility stars and their constrained control state.
It follows [ADR 0007](../../../docs/decisions/0007-per-service-database-schemas.md):
schema/role creation is explicit, migrations are versioned SQL, jOOQ is generated
only during preparation, and ordinary builds never migrate a database.

The Java backend owns persistence. The Node.js Discord interaction service does
not connect to this database ([ADR 0009](../../../docs/decisions/0009-discord-interaction-service.md)).
There is no dependency on the example catalog schema.

The [GitHub-rendered ER diagrams](../../../docs/design/guild-er-diagram.md)
show every persisted table and foreign key, grouped by domain.

[FOLLOW-UPS.md](FOLLOW-UPS.md) lists the review findings that are still open,
with the decisions they need and how to verify a change locally.

## Files and ownership

| Migration | Contents |
| --- | --- |
| V1 | Shared dimensions, typed role/channel configuration, permissions, sanitized collection metadata, and private-by-default function privileges |
| V2 | Verification outcomes, account links, transfer approval, cancellation and expiry, primary-account constraints, attribution continuity, and link commands |
| V3 | CoC membership evidence and closing proof, member state stored on change, the season calendar and season donations, wars, player/achievement observations, Clan Games events and read requests, and raid-account totals |
| V4 | Discord membership/roles and rejoin authority, rolling random XP, ranks, warnings, moderation decisions, manual moderation from the audit log, and leadership notices |
| V5 | Configuration change history and its capture function, authorized configuration and private read functions |
| V6 | CWL registration, signups, versioned plans, freezes, benches, exports, and custom events |
| V7 | Kafka outbox, consumption/dispatch evidence, one-attempt pings, catch-up, reports edited in place, and desired-role generations |
| V8 | Immutable leaderboard calendars, next-period timezone changes, and current-member boards |
| V9 | Cross-feature projections, causal role evidence, configuration-change triggers, and every runtime grant |

This initial migration series was renamed and revised before deployment, after
the user confirmed that no retained database had applied it. Validate it in a
fresh database;
do not relabel or repair an earlier experimental Flyway history.
Keep deployed migrations immutable. Add another version for later changes.
Each file owns one domain. Every function declares its own `SECURITY DEFINER`
and `search_path`; no migration alters a function from another file. V9 is the
only file that grants anything to the runtime role, by table and by function
signature.
Generated jOOQ classes and local connection settings remain ignored.

One database serves one Discord server. `dim_guild` accepts a single row, and
only `dim_guild` and `guild_settings` carry `guild_key`; the views over
`guild_settings` expose it too. No other table has a guild column, and no
function takes a guild argument. A second community gets its own database, as
dev and prod already do. Hosting several servers in one database would mean
adding `guild_key` back to the tables and the functions.

Each fact has an explicit grain; counters remain observations rather than
being summed across repeated snapshots. Shared identity dimensions survive
renames, unlinking, and Discord departures. Temporal bridges represent actual
links and observed clan membership independently of metric attribution.

Mutable configuration and current-state projections support the activity stars.
They are not measures. History, constraints, permissions, and pending work are
part of the same service-owned schema; no cross-service schema ownership is
introduced.

The model has 99 persisted tables. Consolidation reduced 115 tables to 97 by
sharing configuration and one-to-one workflow storage and deriving duplicate
records through views. Two were added later: the season calendar
`dim_coc_season` and the manual moderation history
`fact_manual_moderation_action`. The [consolidation map](../../../docs/design/guild-star-schema.md#physical-consolidation)
records the changes. Views preserve useful source-specific interfaces; the ER
diagram shows physical storage only.

"Audit" in this project means activity history: war attacks, Clan Games
points, donations, clan joins and leaves, warnings, kicks and chat XP. The
fact tables are that history, and each row names its own actor where one
exists. The schema keeps no second copy of those rows. Change history, with
the values before and after, is kept only for the configuration tables,
because a settings change overwrites the old value.

## Prepare an existing Compose database

Keep the existing root .env and PostgreSQL Compose configuration. Add the
GUILD_DB_URL, GUILD_DB_USER, GUILD_DB_PASSWORD,
GUILD_APP_DB_USER, and GUILD_APP_DB_PASSWORD settings from the root
[template](../../../.env.example). Use different migration and runtime roles.
Dev and production should use separate databases with the same migrations.

Start PostgreSQL if it is not already running:

~~~sh
mise run db:up
~~~

As the database administrator, bootstrap the schema, the two login roles, and
the shared NOLOGIN runtime-grant role. The script also installs btree_gist,
needed for non-overlapping link/membership intervals:

~~~sh
mise exec -- docker compose exec -T \
  -e GUILD_DB_USER -e GUILD_DB_PASSWORD \
  -e GUILD_APP_DB_USER -e GUILD_APP_DB_PASSWORD postgres \
  sh -c 'exec psql -X --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"' \
  < tools/postgres/bootstrap-guild.sql
~~~

The bootstrap preserves existing role passwords and refuses privileged existing
roles or a schema owned by somebody else. Repeating it does not replace data,
reset a schema, or overwrite credentials.

The bootstrap also stops PostgreSQL granting `EXECUTE` on the migration role's
new functions to `PUBLIC`. That default belongs to the role, not to the schema,
so no migration sets it. The first migration checks for it and stops with a hint
to run the bootstrap again when it is missing, for example on a database that
was bootstrapped with an older copy of the script.

Run preparation explicitly:

~~~sh
mise run guild:prepare
mise exec -- ./gradlew :services:guild:schema:build
~~~

The first command applies the SQL files through Flyway and generates jOOQ.
Preparation uses the migration role and disables the Gradle configuration cache.
Builds use the generated model without accessing the database.
For a full-root java:build, also prepare catalog using its separate role/settings;
each schema module verifies its own generated sources.

Runtime logins inherit the guild_runtime group's curated grants. They do
not own the schema and cannot run migrations.

## SQL regression checks

These checks are a separate task and a CI step. They are not part of the
Gradle build, because an ordinary build must not depend on a database
([ADR 0007](../../../docs/decisions/0007-per-service-database-schemas.md)).

Run these checks only against an empty, disposable database prepared with the
same bootstrap and migrations:

~~~sh
mise run guild:test
~~~

The runner uses the configured Compose postgres service. To validate an isolated
container instead:

~~~sh
GUILD_TEST_CONTAINER=my-validation-postgres bash tools/postgres/test-guild.sh
~~~

The test container needs POSTGRES_USER and POSTGRES_DB in its own environment.
GUILD_TEST_DATABASE can select a different, already-migrated disposable
database in that container. It never creates or resets a database.
The runner does not print passwords, reset schemas, or remove volumes.
Each SQL fixture runs in a transaction and rolls back; identity sequences can
still advance, which is another reason to use a disposable database.

Assertions cover unsigned Discord IDs, dimension identity, configuration scope,
approved transfers and primary changes, link continuity, membership evidence,
war-attack deduplication, nonadditive counters, Clan Games proration/unknown data,
raid snapshots, rolling XP/ranks, GMT warnings and rejoin notices, CWL/custom
workflows, notification failure windows, timezone periods, role requirements,
configuration change history, and runtime access. The fixtures call the backend paths as
`guild_runtime`, the role of the backend, so a missing grant fails the check.
Files 020, 030, 040, 100, 105, 120 and 130 run as that role throughout. They
switch to the database administrator with `RESET ROLE` only for what the
runtime role may not do: configuration, private-ledger fixtures, and checks
that read a private ledger. The other files switch to `guild_runtime` for
their runtime sections, and `150_runtime_paths.sql` also proves what that role
is refused. When `GUILD_APP_DB_USER` is set, the
runner then connects as that login role and checks that it inherits the runtime
grants and nothing more.

CI bootstraps an isolated database, prepares both catalog and guild, runs
these assertions, checks that the ER diagrams are current, and then runs the
ordinary Java build. No live Discord or
Clash of Clans credentials are required for those checks.

## Backend entry points

Only the trusted Java backend receives database credentials. Discord members
never receive SQL access. Actor/user keys passed to SQL functions must be
resolved from authenticated Discord interactions or verified service messages;
they are not an authentication mechanism on their own.

| Operation | SQL interface |
| --- | --- |
| Record an actual API verification outcome | record_player_verification |
| Link/unlink an account | link_player_account / unlink_player_account |
| Choose primary | set_primary_account |
| Request/decide a transfer | request_account_transfer / decide_account_transfer |
| Expire transfer requests that passed their limit | expire_account_transfers |
| Read private link history | account_link_history_for |
| Change guild settings | set_new_joinee_days / set_verification_policy / set_transfer_policy / set_kick_policy / set_clan_games_schedule / set_clan_games_refresh |
| Bind or unbind roles | set_server_role / set_clan_role / set_town_hall_role and their delete_ counterparts |
| Bind or unbind channels | set_channel_binding / delete_channel_binding |
| Change tracked clan, CWL and war reminder settings | set_clan_collection / set_cwl_clan_settings / set_war_reminder / delete_war_reminder |
| Change chat XP eligibility and rank roles | set_chat_xp_eligibility_role / set_chat_rank_role and their delete_ counterparts |
| Manage developer allowlist | manage_developer |
| Read configuration change history | configuration_audit_for |
| Read explicit Clan Games results | clan_games_results_for |
| Request an own-account profile refresh | request_player_refresh |
| Store a clan member's polled role and donation counters | record_clan_member_observation |
| Find or create the game season of an instant | ensure_coc_season |
| Read the current member list/season donation totals | current_clan_member_state / clan_member_season_donation (views) |
| Create a manual Clan Games event | create_manual_clan_games |
| Credit a chat message | credit_chat_xp |
| Issue/revoke warnings | issue_warning_command / revoke_warning_command |
| Read own/moderator warning history | warning_history |
| Find kicks that still owe an attempt | pending_moderation_action (view) |
| Claim a kick for one worker | claim_moderation_action |
| Record a kick attempt/result | record_moderation_attempt |
| Record a kick, ban, unban or timeout that a person made | record_manual_moderation_action |
| Read own/moderator kick and moderation history | moderation_history |
| Queue the boundary Clan Games reads and the next regular read | queue_clan_games_reads |
| Close Clan Games reads that can no longer be satisfied | close_missed_clan_games_reads |
| Obtain event-scoped assessment-worker inputs | clan_games_assessment_scope |
| Attach account evidence to a frozen member assessment | attach_clan_games_member_input |
| Run CWL commands | cwl_create_cycle / cwl_select_clan / cwl_signup / cwl_manual_plan / cwl_set_assignment / cwl_pin / cwl_unpin / cwl_override_bench |
| Run custom event commands | custom_event_create / custom_event_signup / custom_event_roster / custom_event_result / custom_event_complete |
| Create/publish CWL plans and serve/expire benches | cwl_begin_plan / cwl_publish_plan / cwl_record_bench_service / cwl_end_cycle |
| Materialize a reporting period/change next timezone | ensure_leaderboard_monthly_period / set_leaderboard_timezone |
| Persist, publish, consume, and dispatch notifications | Named notification worker entry points in V7, granted in V9 |
| Register a report and queue a revision of it | register_notification_report / queue_notification_report |
| Record that a report message was deleted in Discord/adopt a found message | record_notification_report_missing / record_notification_report_message |
| Reconcile per-source desired role requirements | set_notification_desired_roles |

The verification ingestion function records a trusted backend's API outcome.
It does not verify a token itself. Neither a supplied token nor an echoed token
is a column or a persisted payload. Do not put tokens into free-text reasons,
source identifiers, application logs, or correlation metadata.

Role IDs are stable identifiers; display names are cached labels. Configuration
binds Applicants, Eclipse, New Joinee, staff capabilities, clan membership/war
roles, and TH roles to their actual Discord IDs. A person can hold multiple TH
and clan roles. Selected role events project confirmed Discord state, while
desired-role reconciliation remains a backend responsibility.

Configuration authorization and audit visibility are separate. Admin-role
members and developers can configure the bot; only developers can read
configuration audit history. Only an existing developer can change the
developer allowlist. This is the accepted permanent rule, not a provisional
fallback. The database operator seeds the first developer ID.

`fact_configuration_change` records every insert, update and delete on the
eleven configuration tables, and a Clan Games event that staff created by
hand, with actor, reason and the values before and after. It is append-only
and only `configuration_audit_for` reads it. A new configuration table needs
an entry in the trigger list in V9; the regression checks compare that list.
Activity history has its own readers, such as `warning_history` and
`account_link_history_for`.

The moderation-log channel is just a configured channel ID. Discord's category
permissions control who can read its messages. SQL command permissions still
use the configured Leadership, Co-leader, and Admin roles. A developer allowlist
entry by itself does not grant moderation or private account-link access.
Leaving the server invalidates confirmed role authority. Rejoining requires
fresh role evidence; old role events cannot silently restore staff permissions.

Server, clan, and TH bindings share `role_binding`, with scope-specific views
and typed constraints. Each scope has its own commands; a clan or TH command
without its clan or level is rejected rather than read as a server binding.

Every command entry point is a typed function; none takes a JSON argument.
A configuration command takes the actor, the full set of values it owns and a
reason, and writes only those columns, so unrelated settings are preserved.
To change one Clan Games schedule value, read the `clan_games_schedule` view
and pass the other values back unchanged. No command deletes the guild
settings row or a tracked clan; switch a clan off with its `enabled` flag.
The XP policy key has one agreed version and no command. Calendar pointer
fields require the authorized timezone workflow.

An activity command takes the actor, a stable operation UUID and its typed
arguments. The first call stores the arguments in `activity_command_operation`;
a retry with the same UUID returns the stored result before any permission
check, and a retry with different arguments is rejected. The command sets the
actor for the transaction, which the CWL lineup trigger reads to accept a
manual lineup only from staff.

Definer functions explicitly put the temporary schema last in their search
paths. Private command implementations are not executable by the runtime role.
This protects privileged functions from temporary-object shadowing while
retaining the configured command entry points.

## Measurement and lifecycle limits

- XP uses unpredictable uniform integers from 15 through 25 and five earning
  messages per rolling 60 processing-time seconds across channels. Eligibility
  uses current presence and configured roles with OR semantics. Credited and
  rejected decisions are durable. Retained XP/rank survives departure; current
  member boards hide absent members.
- Warning counts use GMT calendar months. Revocation references the original
  warning; the fifth valid warning creates one durable kick decision for that
  member/month. Confirmed kicks and same-month rejoins create leadership notices;
  later warnings notify without another automatic kick. A decision is not a
  completed Discord kick. Use the UUID-bearing issue and revoke commands for
  transport idempotency; the signatures without a UUID remain for callers that
  have none.
- A kick worker reads `pending_moderation_action`, which lists the kicks that
  still owe an attempt, and takes one with `claim_moderation_action` before it
  calls Discord. The claim is a lease for one worker. It returns an action and
  a claim token, and `record_moderation_attempt` takes that token and releases
  the claim. A token is accepted for one report, and only until another worker
  claims the kick: a worker whose claim expired and was taken over cannot
  report late, so it cannot spend an attempt or release the newer claim. A
  rejected report raises `23514`. A failed or uncertain kick is tried
  again: `kick_max_attempts` attempts in all, 3 by default, and
  `kick_retry_seconds` between them, 300 by default. Both are guild settings;
  the attempt limit is fixed for a kick when it is decided. The action is
  `kick`, or `check_member` after an uncertain attempt or a claim that expired
  without a report. For `check_member` the worker first checks that the member
  is still in the server, and records a succeeded attempt if they are gone.
  After the last attempt the kick stays failed or uncertain for leadership.
- A revoked warning cancels a kick that still owes an attempt when the member
  has fewer than five active warnings in that month. An attempt that a worker
  already holds is left to finish; its failure cancels the kick instead of
  scheduling another attempt. A fifth active warning in the same month arms a
  cancelled kick again with a fresh set of attempts. A confirmed kick is
  recorded even for a cancelled decision: a cancellation does not take the
  claim token from the worker that held the kick.
- Kick history includes what a leader does by hand in Discord. The collector
  reads kicks, bans, unbans and timeouts from Discord's audit log and stores
  each entry with `record_manual_moderation_action`; the same entry is stored
  once. The bot's own kicks also appear in the audit log. They are already
  kick decisions, so the collector leaves out every entry whose executor is
  the bot's own user, and no kick is counted twice. `moderation_history`
  returns the kicks that the bot confirmed and the manual actions together,
  under the rule of `warning_history`: a member reads their own entries, a
  moderator reads any member's.
- A manual kick, or an unban, followed by a rejoin in the same GMT month
  creates a leadership notice (`manual_kick_rejoin`, `unban_rejoin`). A ban
  or a timeout creates none. The notice is also created when the audit log
  entry arrives after the rejoin. These notices do not change warnings: only
  a rejoin after a kick of the bot stops the automatic kick for the month.
- A transfer request is bound to its source link. Unlinking, or another
  recipient's completed transfer, cancels the remaining open requests and keeps
  any earlier decision as history.
- An open transfer request expires on a clock. A request that staff do not
  decide expires `transfer_pending_max_age_seconds` after it was made, 172800
  (two days) by default. An approval that the recipient does not use expires
  `transfer_approval_max_age_seconds` after the decision, 86400 (one day) by
  default. Both are guild settings. While an approved transfer waits for a
  Clan Games boundary read, the approval limit does not run; it restarts when
  the read arrives. The decide and link commands refuse an expired request, and
  `expire_account_transfers` marks such requests `expired` for the scheduler.
  An expired request keeps any earlier decision as history, and the recipient
  can request the transfer again.
- A successful verification can start a link or a transfer request for a
  limited time: `verification_max_age_seconds` in the guild settings, 900 by
  default. An approved transfer is completed with the verification its request
  recorded, so staff approval and a points read can come later.
- New Joinee expiry records the configured policy on the selected Discord join
  occurrence. The initial policy is seven days. Later configuration changes do
  not rewrite existing history.
- Game membership intervals are observed evidence. Failed/partial polling
  cannot create a departure, and ongoing intervals do not extrapolate beyond
  their confirmed-through timestamp for Clan Games calculations.
- Every member list poll has one row in `clan_membership_poll`, which proves
  that it ran. The collector calls `record_clan_member_observation` for every
  member of every poll that returned members. The function stores a row only
  when the member is new to the clan, when the role or a donation counter
  changed, when the member left and came back, or when the member's latest
  row belongs to an earlier season. The runtime role cannot insert member
  rows directly. A member without a row for a poll had the state of their
  latest earlier row; `current_clan_member_state` shows that state for the
  current members.
- Donations come from the member list poll. The game resets the counters at
  the end of a season. A season ends on the last Monday of the month at
  05:00 UTC; `dim_coc_season` stores the seasons and `ensure_coc_season`
  creates them from that rule. `clan_member_season_donation` gives the last
  counters that a poll saw before the season ended, per clan, season and
  account. The first poll of a season stores a row for every member, so a
  member who donated nothing has a total of zero, not a missing row. The
  counters are the values that the game reports: when the game resets a
  counter inside a season, the view does not add the earlier value back.
- Clan Games uses actual Games Champion observations, inferred participating
  clans, separate checkpoints, and owner-specific point/target slices. Transfers
  wait for boundary evidence; no manual scores are accepted. A measured zero
  differs from missing evidence. A read request stays pending while a current
  response could still satisfy it and becomes missed afterwards; a missed read
  is absent evidence, never a zero. Each player has one pending regular read,
  due one refresh interval after their latest read; it is closed as missed
  only when the event ends. Member versions freeze expected episodes and
  round the combined target upward to ten; unknown data remains insufficient_data.
- Current-clan leaderboard eligibility is independent of score provenance.
  Lifetime war stars use the latest profile counter, including stars from
  outside the tracked clan. Monthly/event scoring needs supported baselines
  and metric-specific rules; do not sum cumulative snapshots.
- Manual API refresh creates pending collection metadata. A future worker
  performs the request; a fresh response does not guarantee recovery of an
  earlier missed observation. Ownership of the account is checked when the
  request is made and when its requester, player, guild or endpoint changes.
  The collector can record the result after the member unlinked or
  transferred the account.
- CWL stores signups, registered pools, planned lineups, and actual participation
  separately. Plans validate availability, pins, freezes, and bench evidence.
  A provisional seven-day artifact is not an optimized schedule or proof that
  staff applied it in game.
- Reporting periods preserve their policy and boundaries. Timezone changes
  affect the next period, with explicit transition bounds and no historical
  recalculation. GMT warning months and CWL deadlines remain independent.
- Delivery state supports Java/outbox/Kafka/Java-worker/gRPC/Node. Pings have one
  consumable send authorization with terminal uncertainty. Role reconciliation
  uses fenced source unions. External clients must honor these contracts and
  suppress hidden ping retries themselves.
- `set_notification_desired_roles` returns the current generation for an
  unchanged role set only while the operation of that generation can still
  apply it. Role work that is claimed while its member is absent is
  superseded. After the member returns, the same role set gets a new
  generation and a new operation. The same holds for roles that were
  delivered before the member's latest join.
- A report is one Discord message that is edited in place. Each revision is
  one operation, and only the latest revision is sent. The claim decides the
  action: `report_create` when the report has no message, `report_edit`
  otherwise. A delivered revision records or confirms the message identity in
  the same call. When Discord no longer has the message, the worker calls
  `record_notification_report_missing` and claims the same revision again; it
  then creates a new message. Report work can be claimed again after a failed
  or uncertain attempt, so a create whose result was lost can post a second
  message that the report does not know.
- All plans of one CWL clan and War Day share one roster report.
  `queue_cwl_roster_report` queues them one at a time and returns NULL,
  queuing nothing, for a plan that is older than one already queued for that
  day. A newer roster is therefore never replaced by an older one.

The SQL does not perform live CoC calls, execute an optimizer, synchronize
Sheets, operate Kafka, or send Discord requests. Runtime contracts, explicitly
open policies, and detailed Raid Weekend attacks/districts remain follow-up work.
The [API evidence reference](../../../docs/feature-specs/api-evidence.md)
distinguishes real response samples from generated collection examples and live
validation still required.

## Regenerate the ER diagrams

After migrating a disposable validation database, query its catalog with:

~~~sh
mise exec -- python tools/postgres/generate-guild-erd.py \
  --container YOUR_POSTGRES_CONTAINER --database YOUR_DATABASE \
  --user YOUR_MIGRATION_USER --output docs/design/guild-er-diagram.md
~~~

The generator reads schema metadata, includes every persisted guild table and
declared foreign key, and groups native Mermaid diagrams for GitHub. It does not
migrate, reset, or change the selected database. CI runs the same generator
after preparing the schema and fails when the committed page differs, so
regenerate it in the same change as a migration.

Discord IDs use the `discord_snowflake` domain, an unsigned 64-bit integer held
as `numeric`. The schema build maps it to `BigInteger` in the generated jOOQ
model.
