# Guild database schema

This module owns the PostgreSQL schema named guild. Its SQL migrations
implement the first CoC and Discord utility stars from the
[working plan](../../../docs/design/star-schema-working-plan.md).
It follows [ADR 0007](../../../docs/decisions/0007-per-service-database-schemas.md):
schema/role creation is explicit, migrations are versioned SQL, jOOQ is generated
only during preparation, and ordinary builds never migrate a database.

The Java backend owns persistence. The Node.js Discord interaction service does
not connect to this database ([ADR 0009](../../../docs/decisions/0009-discord-interaction-service.md)).
There is no dependency on the example catalog schema.

The [GitHub-rendered ER diagrams](../../../docs/design/guild-er-diagram.md)
show every persisted table and foreign key, grouped by domain.

## Files and ownership

| Migration | Contents |
| --- | --- |
| V1 | Shared dimensions, role/channel configuration, permissions, and sanitized collection/delivery metadata |
| V2 | Verification outcomes, account links, transfer approvals, primary-account constraints, attribution continuity |
| V3 | CoC membership evidence, wars, player/achievement observations, Clan Games, and raid-account totals |
| V4 | Discord membership/roles, provisional chat XP, warnings, and durable moderation decisions/attempts |
| V5 | Audit capture, authorized configuration/read functions, and runtime grants |
| V6 | Authorized, audited manual Clan Games creation with retry-safe event identity |
| V7 | Complete-poll evidence for membership closure and protection against history rewinds |
| V8 | Scoped human actors for link, transfer, and warning command audits |
| V9 | Definer search-path protection and current staff authority across Discord rejoins |

This initial migration series was renamed before deployment, after confirming
that no non-disposable database had applied it. Validate it in a fresh database;
do not relabel or repair an earlier experimental Flyway history.
Keep deployed migrations immutable. Add another version for later changes.
Generated jOOQ classes and local connection settings remain ignored.

Each fact has an explicit grain; counters remain observations rather than
being summed across repeated snapshots. Shared identity dimensions survive
renames, unlinking, and Discord departures. Temporal bridges represent actual
links and observed clan membership independently of metric attribution.

Mutable configuration and current-state projections support the activity stars.
They are not measures. History, constraints, permissions, and pending work are
part of the same service-owned schema; no cross-service schema ownership is
introduced.

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
raid snapshots, chat XP caps, UTC month boundaries, warnings, and runtime access.

CI bootstraps an isolated database, prepares both catalog and guild, runs
these assertions, and then runs the ordinary Java build. No live Discord or
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
| Read private link history | account_link_history_for |
| Change typed configuration | configure_setting |
| Manage developer allowlist | manage_developer |
| Read configuration audit | configuration_audit_for |
| Read general change audit | change_audit_for |
| Read explicit Clan Games results | clan_games_results_for |
| Request an own-account profile refresh | request_player_refresh |
| Create a manual Clan Games event | create_manual_clan_games |
| Credit a chat message | credit_chat_xp |
| Issue/revoke warnings | issue_warning / revoke_warning |
| Read own/moderator warning history | warning_history |
| Record a kick attempt/result | record_moderation_attempt |

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
configuration audit history. The first implementation conservatively allows
only an existing developer to change the developer allowlist, preserving that
visibility boundary. The database operator seeds the first developer ID.
This resolves a previously open management rule provisionally rather than
silently letting an Admin grant themselves developer-log access.

The moderation-log channel is just a configured channel ID. Discord's category
permissions control who can read its messages. SQL command permissions still
use the configured Leadership, Co-leader, and Admin roles. A developer allowlist
entry by itself does not grant moderation or private account-link access.
Leaving the server invalidates confirmed role authority. Rejoining requires
fresh role evidence; old role events cannot silently restore staff permissions.

Definer functions explicitly put the temporary schema last in their search
paths. Private command implementations are not executable by the runtime role.
This protects privileged functions from temporary-object shadowing while
retaining the configured command entry points.

## Measurement and lifecycle limits

- The provisional XP implementation uses fixed UTC minute buckets: 20 XP per
  credited message, at most five per member across channels. Duplicate message
  delivery is idempotent. Detailed earning rules, ranks, and leaderboard
  visibility for departed members remain open.
- Warning counts use GMT calendar months. Revocation references the original
  warning; the fifth valid warning creates one durable kick decision for that
  member/month. A recorded decision is not a completed Discord kick.
- New Joinee expiry records the configured policy on the selected Discord join
  occurrence. The initial policy is seven days. Later configuration changes do
  not rewrite existing history.
- Game membership intervals are observed evidence. Failed/partial polling
  cannot create a departure, and ongoing intervals do not extrapolate beyond
  their confirmed-through timestamp for Clan Games calculations.
- Clan Games account and member assessments are versioned. Unknown evidence
  yields insufficient_data. Member inputs identify the relevant attribution
  episode explicitly; unresolved gap/transfer/rounding policies are not
  silently inferred from today's account links.
- Current-clan leaderboard eligibility is independent of score provenance.
  Lifetime war stars use the latest profile counter, including stars from
  outside the tracked clan. Monthly/event scoring needs supported baselines
  and metric-specific rules; do not sum cumulative snapshots.
- Manual API refresh creates pending collection metadata. A future worker
  performs the request; a fresh response does not guarantee recovery of an
  earlier missed observation.
- Delivery attempts and moderation attempts preserve failure/uncertainty.
  These migrations do not send messages, assign live Discord roles, call the
  CoC API, or select a Kafka delivery architecture.

CWL roster optimization, custom events, detailed Raid Weekend attacks/districts,
the final XP/rank rules, and runtime delivery/RPC contracts remain deferred.
The supplied API mirror is an interim reference with known inconsistencies;
live API coverage, especially Clan Games points/calendar data, still needs
validation.
