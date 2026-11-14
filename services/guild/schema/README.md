# Guild database schema

The [feature specifications](../../../docs/feature-specs/README.md) record the
agreed requirements. The [revised design](../../../docs/design/guild-star-schema.md)
describes their dimensional and workflow model, and
[ADR 0012](../../../docs/decisions/0012-guild-star-schema.md) records where
their rules live.

This module owns the PostgreSQL schema named guild. Its SQL migrations define
the CoC and Discord utility stars, the configuration, workflow and projection
tables that support them, and the constraints and grants on all of them. The
guild service implements the business rules, workflows and permission checks
in Java. The module follows
[ADR 0007](../../../docs/decisions/0007-per-service-database-schemas.md):
schema/role creation is explicit, migrations are versioned SQL, jOOQ is
generated only during preparation, and ordinary builds never migrate a
database.

The Java backend owns persistence. The Node.js Discord interaction service does
not connect to this database ([ADR 0009](../../../docs/decisions/0009-discord-interaction-service.md)).
There is no dependency on the example catalog schema.

The [GitHub-rendered ER diagrams](../../../docs/design/guild-er-diagram.md)
show every persisted table and foreign key, grouped by domain.

The [rule catalog](../../../docs/design/guild-service-rules.md) lists every
business rule that the guild service enforces, with the constraint behind it
where one exists. The
[working plan](../../../docs/design/star-schema-working-plan.md) lists the
schema gaps and the decisions that are still open, the working rules for a
change, and the order of the service work.

## Files and ownership

| Migration | Contents |
| --- | --- |
| V1 | Shared dimensions, typed role and channel bindings, the developer allowlist, and sanitized collection metadata |
| V2 | Verification outcomes, account links, transfer requests, primary-account constraints and history, and attribution episodes |
| V3 | CoC membership polls and periods, member state stored on change, the season calendar, war polls and wars with observations stored on change, player and achievement observations, Clan Games events, read requests, evidence and assessments, and raid polls with weekend state and account totals stored on change |
| V4 | Discord membership and role events and their projections, chat XP decisions and ranks, warnings, kick decisions with their transitions, authorized kick attempts and their resolutions, manual moderation from the audit log, and leadership notices |
| V5 | Configuration change history |
| V6 | CWL cycles with the revisions of their signup close, league-group polls with registration and round references stored on change, revisions of participating clans and of signups with their target clan, versioned plans, pin revisions, freeze records, bench incidents with assignment revisions, and ordered exports with frozen inputs and Sheets writer leases, custom events with signup revisions, and activity command operations |
| V7 | Notification operations with their mention targets and outbox state, Kafka receipts, dispatch attempts, catch-up, reports with their typed context, and desired-role generations |
| V8 | Leaderboard calendar policies, reporting periods, the metric catalog, and current-member boards |
| V9 | Cross-feature views and every runtime grant |

This initial migration series is unreleased. Validate it in a fresh database;
do not relabel or repair an earlier experimental Flyway history.
Keep deployed migrations immutable. Add another version for later changes.
Each file owns one domain and holds declarative schema only: tables,
constraints, indexes, views and grants. No migration creates a function or a
trigger. V9 is the only file that grants anything to the runtime role, by
table and by column.
Generated jOOQ classes and local connection settings remain ignored.

One database serves one Discord server. `dim_guild` accepts a single row, and
only `dim_guild` and `guild_settings` carry `guild_key`; the views over
`guild_settings` expose it too. No other table has a guild column. A second
community gets its own database, as dev and prod already do. Hosting several
servers in one database would mean adding `guild_key` back to the tables.

Each fact has an explicit grain; counters remain observations rather than
being summed across repeated snapshots. Shared identity dimensions survive
renames, unlinking, and Discord departures. Temporal bridges represent actual
links and observed clan membership independently of metric attribution.

Mutable configuration and current-state projections support the activity stars.
They are not measures. History, constraints, permissions, and pending work are
part of the same service-owned schema; no cross-service schema ownership is
introduced.

The model has 122 persisted tables. Consolidation reduced 115 tables to 97 by
sharing configuration and one-to-one workflow storage and deriving duplicate
records through views. Later additions are the season calendar
`dim_coc_season`, the manual moderation history
`fact_manual_moderation_action`, the primary-account history
`fact_primary_account_change`, the revisions of custom-event signups and CWL
pins, which replaced the in-place pin table, the CWL freeze records
`fact_cwl_day_freeze`, the typed context of raid and Clan Games reports, the
mention targets of notification operations, the war polls `war_poll`, and the
revisions of CWL participating clans `fact_cwl_participation_revision`. The
review gaps added kick transitions and attempt resolutions, notification
dispositions, typed moderation, raid-start, CWL-signup and Clan Games progress
context, raid polls and weekend observations, and CWL Sheets destinations with
their signup inputs. The schema review added the CWL group polls
`cwl_group_poll`, the schedule revisions of CWL cycles
`fact_cwl_cycle_schedule_revision`, and the bench assignment revisions
`fact_cwl_bench_assignment_revision`, which replaced the in-place bench
assignment. The [consolidation map](../../../docs/design/guild-star-schema.md#physical-consolidation)
records the changes. Views preserve useful source-specific interfaces; the ER
diagram shows physical storage only.

"Audit" in this project means activity history: war attacks, Clan Games
points, donations, clan joins and leaves, warnings, kicks and chat XP. The
fact tables are that history, and each row names its own actor where one
exists. The schema keeps no second copy of those rows. Change history, with
the values before and after, is kept only for the configuration tables,
because a settings change overwrites the old value. The guild service writes
that history in the same transaction as the change.

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

The bootstrap also stops PostgreSQL granting `EXECUTE` on new functions of the
migration role to `PUBLIC`. The migrations create no functions; the setting
keeps any later one private. That default belongs to the role, not to the
schema, so no migration sets it.

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

## Seed the guild row and the first developer

The guild service cannot create the row of its Discord server or its first
developer: every configuration command needs both. After preparation, seed
them as the database administrator. The script reads `DISCORD_GUILD_ID` and
`GUILD_FIRST_DEVELOPER_ID` from the root .env:

~~~sh
mise exec -- docker compose exec -T \
  -e DISCORD_GUILD_ID -e GUILD_FIRST_DEVELOPER_ID postgres \
  sh -c 'exec psql -X --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"' \
  < tools/postgres/seed-guild.sql
~~~

Running it again changes nothing. It refuses a database that already serves
another Discord server, and it adds no developer when the allowlist already
lists others: the owner developer adds more through the guild service. With
an empty allowlist it restores the first developer, and it makes that
developer the owner when no owner is set. It records its
configuration changes as operator changes in `fact_configuration_change`. Do
not seed the disposable database of the checks below before they run.

## Database checks

These checks are a separate task and a CI step. They are not part of the
Gradle build, because an ordinary build must not depend on a database
([ADR 0007](../../../docs/decisions/0007-per-service-database-schemas.md)).

They test what this module owns: keys, unique and partial unique indexes,
`CHECK` and exclusion constraints, generated columns, and the runtime grants,
including that the runtime role cannot update or delete a fact. The business
rules are tested in the guild service: unit tests in its ordinary build, and
concurrency and repository tests against a disposable database as their own
task and CI step ([ADR 0012](../../../docs/decisions/0012-guild-star-schema.md)).

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

Fixtures write as `guild_runtime`, the role of the service, so a missing grant
fails the check. They switch to the database administrator with `RESET ROLE`
only for setup that the runtime role may not do. When `GUILD_APP_DB_USER` is
set, the runner then connects as that login role and checks that it inherits
the runtime grants and nothing more.

CI bootstraps an isolated database, prepares both catalog and guild, runs
these checks, checks that the ER diagrams are current, and then runs the
ordinary Java build. No live Discord or Clash of Clans credentials are required
for those checks.

### Full check in a throwaway container

This repeats the CI build job against a container that you remove afterwards.
Never use the developer's own `eclipse-bot-postgres-1` container for it; the
first command only reads its image name. Docker Desktop must be running
(`open -a Docker`). No local `psql` is needed. A git worktree has no `.env`,
so the settings are passed inline. Run from the repository root:

~~~sh
image="$(docker inspect eclipse-bot-postgres-1 --format '{{.Image}}')"
docker run -d --rm --name guild-check -p 127.0.0.1:55432:5432 \
  -e POSTGRES_USER=eclipse -e POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
  -e POSTGRES_DB=eclipse_bot "$image"
until docker exec guild-check pg_isready -U eclipse -d eclipse_bot -q; do sleep 1; done

export MISE_NO_ENV=1 \
  CATALOG_DB_URL=jdbc:postgresql://localhost:55432/eclipse_bot \
  CATALOG_DB_USER=catalog_migration CATALOG_DB_PASSWORD=local_only \
  GUILD_DB_URL=jdbc:postgresql://localhost:55432/eclipse_bot \
  GUILD_DB_USER=guild_migration GUILD_DB_PASSWORD=local_only \
  GUILD_APP_DB_USER=guild_application GUILD_APP_DB_PASSWORD=local_only

docker exec -i guild-check psql -X --set ON_ERROR_STOP=1 -U eclipse -d eclipse_bot \
  -c "CREATE ROLE catalog_migration LOGIN PASSWORD 'local_only'" \
  -c "CREATE SCHEMA catalog AUTHORIZATION catalog_migration"
docker exec -i -e GUILD_DB_USER -e GUILD_DB_PASSWORD -e GUILD_APP_DB_USER \
  -e GUILD_APP_DB_PASSWORD guild-check \
  psql -X --set ON_ERROR_STOP=1 -U eclipse -d eclipse_bot < tools/postgres/bootstrap-guild.sql

mise exec -- ./gradlew :services:catalog:schema:prepareSchema --no-configuration-cache
mise exec -- ./gradlew :services:guild:schema:prepareSchema --no-configuration-cache
GUILD_TEST_CONTAINER=guild-check bash tools/postgres/test-guild.sh
for _ in 1 2; do
  docker exec -i -e DISCORD_GUILD_ID=100000000000000001 \
    -e GUILD_FIRST_DEVELOPER_ID=100000000000000002 guild-check \
    psql -X --set ON_ERROR_STOP=1 -U eclipse -d eclipse_bot < tools/postgres/seed-guild.sql
done
mise exec -- python tools/postgres/generate-guild-erd.py \
  --container guild-check --database eclipse_bot --user guild_migration
git diff --exit-code -- docs/design/guild-er-diagram.md
mise exec -- ./gradlew build
mise exec -- ./gradlew -p tools/gradle :convention-plugins:check
mise exec -- pre-commit run --all-files --show-diff-on-failure
docker rm -f guild-check
~~~

## Runtime access

Only the guild service receives database credentials. Discord members never
receive SQL access. Actor IDs come only from Discord interactions that the
Discord service relays; a user key in a query is not an authentication
mechanism on its own.

The service connects as a login role that inherits `guild_runtime`:

- `SELECT` on the tables and views the service reads, private histories
  included. Link history, warnings, moderation history, Clan Games results and
  configuration change history are protected by the service's permission
  checks, not by grants.
- `INSERT` on fact tables. No `UPDATE` or `DELETE`, except `UPDATE` on named
  columns that a later step fills in, such as the completion of a fetch or the
  last time an attack was seen. Identities and measures never change.
- `INSERT`, `UPDATE` and `DELETE` on configuration, workflow, temporal-bridge
  and projection tables, per table and column, for the changes the service
  makes.
- No ownership, no DDL, no migration rights and no access to the Flyway
  history.

The service records a verification as the outcome of its API call. Neither a
supplied token nor an echoed token is a column or a persisted payload. Do not
put tokens into free-text reasons, source identifiers, application logs, or
correlation metadata.

Role IDs are stable identifiers; display names are cached labels. Configuration
binds Applicants, Eclipse, New Joinee, staff capabilities, clan membership/war
roles, and TH roles to their actual Discord IDs. A person can hold multiple TH
and clan roles. Selected role events project confirmed Discord state, while
desired-role reconciliation remains a service responsibility.

Configuration authorization and audit visibility are separate. Admin-role
members and developers can configure the bot; only developers can read
configuration audit history. Only the owner developer can change the
developer allowlist (CFG-004). This is the accepted permanent rule, not a
provisional fallback. The database operator seeds the first developer ID with
`tools/postgres/seed-guild.sql`, which also makes that developer the owner
(`guild_settings.owner_developer_user_key`). The owner's allowlist row cannot
be deleted while it is the owner, and the runtime role cannot change the
owner; only an operator does, following the procedure below.

The guild service records every insert, update and delete on the configuration
tables, and every Clan Games event that staff create by hand, in
`fact_configuration_change`: actor, reason and the values before and after, in
the same transaction as the change. All configuration writes go through the
one repository that records them, so a new configuration table needs no other
step. The runtime role cannot update or delete a recorded change. Activity
history has its own readers in the service, such as warning history and
account-link history.

### Operator configuration changes

The schema has no trigger, so a direct SQL change records nothing by itself.
Change configuration through the guild service. Use direct SQL only for a
bootstrap or an emergency, such as changing the owner developer, and record
the change in the same transaction (CFG-013):

~~~sql
BEGIN;
WITH before AS (
    SELECT * FROM guild.guild_settings
), changed AS (
    UPDATE guild.guild_settings SET owner_developer_user_key = 42, updated_at = clock_timestamp()
    RETURNING *
)
INSERT INTO guild.fact_configuration_change
    (source, entity_type, entity_identity, previous_value, new_value, reason)
SELECT 'operator', 'guild_settings', jsonb_build_object('guild_key', c.guild_key),
    to_jsonb(b), to_jsonb(c), 'Owner developer handed over'
FROM changed c JOIN before b USING (guild_key);
COMMIT;
~~~

`source` is `operator` and the actor is null. Give the entity's primary-key
columns as `entity_identity`, the whole row before and after (null for an
insert or a delete), and a real reason. `tools/postgres/seed-guild.sql`
follows the same procedure. A direct change without its history row is a
procedure violation.

The moderation-log channel is just a configured channel ID. Discord's category
permissions control who can read its messages. Command permissions still use
the configured Leadership, Co-leader, and Admin roles. A developer allowlist
entry by itself does not grant moderation or private account-link access.
Leaving the server invalidates confirmed role authority. Rejoining requires
fresh role evidence; old role events cannot silently restore staff permissions.

Server, clan, and TH bindings share `role_binding`, with scope-specific views
and typed constraints. A clan or TH binding without its clan or level is
rejected rather than read as a server binding.

A configuration command writes only the columns it owns, so unrelated settings
are preserved. No command deletes the guild settings row or a tracked clan;
switch a clan off with its `enabled` flag. The XP policy key has one agreed
version and no command. Calendar pointer fields change only through the
timezone workflow.

An activity command (CWL and custom events) carries a stable operation UUID.
The first call stores the actor, the action and the arguments in
`activity_command_operation`. A retry with the same UUID returns the stored
result before any permission check, and a retry with different arguments is
rejected.

## Rules the guild service enforces

The schema relies on the service for every rule that spans rows. Where a
constraint backs a rule, the rule names it. This is a summary; the
[rule catalog](../../../docs/design/guild-service-rules.md) has every check
with its source, failure class and tests.

- **Chat XP.** A credited message earns a uniform integer from 15 through 25
  from an unpredictable source. A member earns from at most five messages per
  rolling 60 seconds of processing time across channels, decided under a
  per-member lock. Eligibility needs current presence and any configured
  eligibility role. A message has one decision, credited or rejected (unique
  message ID), and a retry returns that decision. XP and rank survive
  departure; current-member boards hide absent members.
- **Warnings.** Warning counts use GMT calendar months. A revocation
  references the original warning. Issue and revoke commands carry stable
  operation UUIDs (unique columns). The fifth valid warning creates one kick
  decision per member and month (unique key). A confirmed kick and a
  same-month rejoin create a leadership notice; later warnings that month
  notify without another automatic kick. A decision is not a completed Discord
  kick.
- **Kick worker.** A worker takes a kick that still owes an attempt and claims
  it with a lease and a token before it calls Discord. A result is accepted
  once, and only with the token of the latest claim, so a worker whose claim
  was taken over cannot spend an attempt or release the newer claim. A failed
  or uncertain kick is tried again: `kick_max_attempts` attempts in all, 3 by
  default, and `kick_retry_seconds` between them, 300 by default. The attempt
  limit is fixed when the kick is decided. After an uncertain attempt, or a
  claim that expired without a result, the worker first checks that the member
  is still in the server and records a succeeded attempt if they are gone.
  After the last attempt the kick stays failed or uncertain for leadership.
- **Revocations and kicks.** A revoked warning cancels a kick that still owes
  an attempt when the member has fewer than five active warnings in that
  month. An attempt that a worker already holds finishes; its failure cancels
  the kick instead of scheduling another attempt. A fifth active warning in
  the same month arms a cancelled kick again with a fresh set of attempts. A
  confirmed kick is recorded even for a cancelled decision.
- **Manual moderation.** The collector reads kicks, bans, unbans and timeouts
  from Discord's audit log and stores each entry once (unique entry ID). It
  leaves out every entry whose executor is the bot's own user, because those
  kicks are already kick decisions. Moderation history returns the kicks that
  the bot confirmed and the manual actions together: a member reads their own
  entries, a moderator reads any member's. A manual kick, or an unban,
  followed by a rejoin in the same GMT month creates a leadership notice
  (`manual_kick_rejoin`, `unban_rejoin`), also when the audit log entry
  arrives after the rejoin. A ban or a timeout creates none. These notices do
  not change warnings: only a rejoin after a kick by the bot stops the
  automatic kick for the month.
- **Transfers.** A transfer request is bound to its source link. Unlinking, or
  another recipient's completed transfer, cancels the remaining open requests
  and keeps any earlier decision as history. A request that staff do not
  decide expires `transfer_pending_max_age_seconds` after it was made, 172800
  (two days) by default. An approval that the recipient does not use expires
  `transfer_approval_max_age_seconds` after the decision, 86400 (one day) by
  default. While an approved transfer waits for a Clan Games boundary read,
  the approval limit does not run; it restarts when the read arrives. An
  expired request keeps any earlier decision as history, and the recipient can
  request the transfer again.
- **Verification and links.** A successful verification can start a link or a
  transfer request for `verification_max_age_seconds`, 900 by default. An
  approved transfer completes with the verification its request recorded, so
  staff approval and a points read can come later. A new link needs current
  membership in a tracked clan. A member with links has exactly one primary: a
  partial unique index allows at most one, and the service makes it exactly
  one. Every change of a member's primary is kept in
  `fact_primary_account_change`. An account's first-ever link can backfill its earlier history, the same
  member's relink continues their attribution episode, and a different member
  starts a new one.
- **Discord presence and roles.** The newest join or departure by source time
  wins. A departure clears held roles; a join rebuilds them only from role
  events of that stay. Authority uses confirmed held roles and current
  presence only. A join records the New Joinee policy that the guild settings
  hold at that time; later configuration changes do not rewrite it. At
  startup and after a reconnect the service compares the gateway member list
  with the stored presence and records the joins and departures that the
  gateway did not deliver, marked `member_list_sync`. Such a join carries the
  member's `joined_at`; such a departure has no source time, and its
  `occurred_at` is only an upper bound. A join found this way sends the
  welcome only when the member joined at most
  `welcome_sync_max_age_seconds` before the sync, 86400 by default, so the
  first sync of an existing server welcomes nobody who joined long ago.
- **Membership periods.** A period closes only with an observed departure from
  a complete poll at the exact boundary; failed or partial polls never create a
  departure. Periods of one account overlap only across clans, when a move is
  observed in the new clan first; `current_observed_clan_member` then resolves
  one current clan by the latest positive observation. `confirmed_through` never moves back, and ongoing intervals do not
  extrapolate beyond it for Clan Games calculations.
- **Member list.** Every member list poll has one row in
  `clan_membership_poll`, which proves that it ran. The service stores a
  member's row only when the member is new to the clan, when the role or a
  donation counter changed, when the member left and came back, or when the
  member's latest row belongs to an earlier season, through one write path. A
  member without a row for a poll had the state of their latest earlier row;
  `current_clan_member_state` shows that state for the current members.
- **Wars.** Every war poll has one row in `war_poll`, which proves that it
  ran, whatever it returned. The service stores a war response, a roster row
  or clan totals only when they changed since the latest stored one, and each
  stored observation names the poll that saw it, at the same time and for the
  same war (composite foreign key). A failed poll is no evidence about the
  war.
- **Donations.** Donations come from the member list poll, and the game resets
  the counters at the end of a season. A season ends on the last Monday of the
  month at 05:00 UTC; the service creates `dim_coc_season` rows from that
  rule. `clan_member_season_donation` gives the last counters that a poll saw
  before the season ended, per clan, season and account. The first poll of a
  season stores a row for every member, so a member who donated nothing has a
  total of zero, not a missing row. The counters are the values that the game
  reports: when the game resets a counter inside a season, nothing adds the
  earlier value back.
- **Clan Games.** Points come only from Games Champion observations of the
  home village; there is no manual score. Baseline, T−24h, final and transfer
  reads are separate requests. A request's `due_at` is its checkpoint and
  `collect_from` opens the window in which the collector takes it: a baseline
  from the end of the previous event, a T−24h read from the checkpoint minus
  `clan_games_checkpoint_tolerance_seconds` (default 1800), so both can finish
  before their checkpoint. Every other purpose opens at its `due_at` (`CHECK`).
  Each player has one pending regular read per
  event (partial unique index), due one refresh interval after their latest
  read and closed as missed when the event ends. A read stays pending while a
  current response could still satisfy it and becomes missed afterwards; a
  missed read is absent evidence, never a zero. A participating clan is
  inferred only from consistent tracked-clan membership from the event start
  through the first observed increase. A measured zero needs valid baseline
  and ending reads. Owner-specific slices split points and targets at
  attribution boundaries, and transfers wait for boundary evidence. A member
  assessment freezes its expected episodes and rounds the combined target up
  to a multiple of ten once; unknown data stays `insufficient_data`. An event
  is never edited. When the game moves Clan Games, or an event has wrong
  dates, staff reschedule it: the stored event is voided (`voided_at`), which
  stops its collection and keeps its rows, and a manual event that names it
  (`replaces_event_key`) takes the new dates. The schedule does not create
  the month of a voided event again.
- **Leaderboards.** Current-clan eligibility is independent of score
  provenance. Lifetime war stars use the latest profile counter, including
  stars from outside the tracked clan. Monthly and event scoring needs
  supported baselines and metric-specific rules; cumulative snapshots are
  never summed.
- **Manual refresh.** A member can request a profile refresh only for an
  account that is linked to them when they ask. The collector can record the
  result after the member unlinked or transferred the account; a fresh
  response does not recover an earlier missed observation.
- **CWL.** Signups, registered pools, planned lineups, and actual
  participation stay separate. Plans respect availability, pins, freezes, and
  bench evidence. A provisional seven-day plan is not an optimized schedule or
  proof that staff applied it in game. Participating clans, signups and pins
  change only by revision. The signup close of a cycle is a revision too:
  00:00 UTC on the first day of the month for the scheduled cycle, and a
  further revision when staff reschedule it (`current_cwl_cycle`). A month
  can have a further cycle (`month_sequence`) for a second CWL, created after
  the first ended: only one cycle is open at a time (partial unique index). A
  leadership prompt names one schedule revision; a reschedule supersedes a
  prompt that was not attempted and always queues one for the new close. A participating clan's lineup size and withdrawal
  are revisions (`current_cwl_participation`). A signup's target clan is part
  of each revision, so staff move a signup to another participating clan of
  the cycle with a revision (`current_cwl_signup`). An unpin is a revision
  without an account, and `current_cwl_manual_pin` shows the latest revision
  of each pinned slot.
  The first freeze of a War Day is recorded with the cutoff it used, so a
  later cutoff change does not unfreeze it. Every league-group poll has one
  row in `cwl_group_poll`; the group, its registered pools and its round
  references are stored only when they changed, and a round reference keeps
  its position, because an unscheduled round repeats the tag `#0`. The bench
  day reserved for an incident changes only by revision, and
  `current_cwl_bench_assignment` shows the latest one.
- **Custom events.** A signup keeps every change as a revision with its actor
  and operation; `current_custom_event_signup` shows the latest one.
- **Reporting periods.** Periods keep their policy and boundaries and do not
  overlap (exclusion constraint). A timezone change applies to the next
  period, with explicit transition bounds and no historical recalculation.
  GMT warning months and CWL deadlines stay independent of it.
- **Delivery.** The service, the Kafka relay, the gRPC calls and the Discord
  service follow one path. Each ping gets one dispatch authorization (unique
  index) and one send permit; a failed or uncertain send is final and is never
  sent again automatically. External clients must suppress hidden ping
  retries themselves. Role reconciliation applies only the latest generation.
  An unchanged role set reuses its generation only while that generation's
  operation can still apply it; after the member was absent, the same set
  gets a new generation and a new operation. An operation stores the roles
  and members it mentions when it is queued, and delivery mentions nobody
  else. A `raid_start` announcement names its clan, so each clan's
  announcement mentions that clan's role.
- **Reports.** A report is one Discord message that is edited in place. Each
  revision is one operation, and only the latest revision is sent. The claim
  decides the action: create when the report has no message, edit otherwise.
  A delivered revision records or confirms the message identity. When Discord
  no longer has the message, the report forgets it and the next claim of the
  same revision creates a new message. Report work can be claimed again after
  a failed or uncertain attempt, so a create whose result was lost can post a
  second message that the report does not know. All plans of one CWL clan and
  War Day share one roster report and are queued one at a time; a plan older
  than one already queued for that day is not queued. A raid report revision
  records its weekend and the latest observation it shows, and a Clan Games
  report revision records its event and the member assessment versions it
  publishes, so no report needs its logical key parsed.

The [API evidence reference](../../../docs/feature-specs/api-evidence.md)
distinguishes real response samples from generated collection examples and live
validation still required. Detailed Raid Weekend attacks and districts and the
policies that the specifications leave open remain follow-up work.

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

## Generated jOOQ code

Discord IDs use the `discord_snowflake` domain, an unsigned 64-bit integer held
as `numeric`. The schema build maps it to `BigInteger` in the generated jOOQ
model.

The generated tables have implicit join paths to one row and to many rows,
named after the table they reach. Many-to-many paths are off, because jOOQ
treats every table with two foreign keys as a bridge and their names
collided. Where two paths still reach the same table, a matcher in
[build.gradle](build.gradle) names them by their meaning, such as
`AccountLink.transferRequest()` and `AccountLink.outgoingTransferRequest()`.
`prepareSchema` must print no `Ambiguous key name` warning: jOOQ drops one of
the colliding methods. When a new foreign key causes one, add a matcher for it
in the same change.
