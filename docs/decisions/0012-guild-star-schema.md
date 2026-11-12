---
status: accepted
date: 2026-11-07
updated: 2026-11-12
decision-makers: Kanishk Gupta
---

# Guild-owned activity stars and explicit SQL preparation

## Context and Problem Statement

The bot has to record Clash of Clans activity and Discord utilities for one
server: clan membership, wars, Clan Games, raids, CWL, account links, chat XP,
warnings, notifications and leaderboards. The detailed requirements are in the
[feature specifications](../feature-specs/README.md), with their revised
[dimensional and workflow design](../design/guild-star-schema.md).

Much of that data is evidence, not state. A collection time is not the time
something happened in the game, a failed poll is not a departure, and a missing
read is not a zero. Several rules also cross features: one account can change
owner during an event, and a role or a link decides who may run a command.

ADR 0007 gives each service its own schema, and ADR 0009 keeps the Discord
service away from the database. Within those limits, how should this data be
modelled, and where should its invariants and permission checks be enforced?

## Considered Options

- A star schema in one guild-owned schema, with the invariants and the
  actor-aware command entry points written in PostgreSQL.
- The same tables, with the invariants and permission checks only in the Java
  service.
- A normalised operational model now, with a separate analytical store later.
- Separate schemas for each feature (wars, Clan Games, moderation and so on).

## Decision Outcome

Use one Java-owned guild schema with activity-specific facts and shared
dimensions, and enforce its invariants in the database: constraints, triggers
and `SECURITY DEFINER` entry points that take the acting Discord member.

The user selected the star-schema design. The rules live in PostgreSQL because
most of them are statements about stored evidence, and several writers will
touch the same rows: collectors, command handlers and delivery workers. A rule
kept only in service code holds for one writer; a constraint holds for all of
them, including an operator with a SQL prompt.

A Java-only implementation was not chosen for that reason. A separate
analytical store adds a second pipeline before any reporting need has been
measured. Separate schemas for each feature would put the shared dimensions
and the account links across ownership boundaries, which ADR 0007 rules out.

### One Discord server per database

A database serves one Discord server: `dim_guild` accepts one row. Only
`dim_guild` and `guild_settings` carry `guild_key`; no other table has a guild
column and no function takes a guild argument. The alternative, a
multi-server schema with `guild_key` on every table, was not chosen. The
schema already forbade a second server, so those columns and the composite
keys that compared them guarded nothing, while every function carried a guild
argument. A second community gets its own database, as development and
production already do.

### Ownership and preparation

Use one Java-owned guild database schema for the initial shared dimensions,
activity facts, temporal relationships, configuration, and constrained workflow
state. This ownership boundary follows ADR 0007 without introducing shared
tables across independently owned service schemas. The Discord interaction
service remains database-free as specified in ADR 0009.

The services/guild/schema module applies the existing schema convention.
Versioned, schema-qualified Flyway SQL files are authoritative. Roles and the
schema are created explicitly outside Gradle; preparation migrates and generates
jOOQ; ordinary builds and startup never prepare the database.

The service, SQL namespace, runtime grants, package, settings, and tasks use
guild consistently. The initial SQL series was renamed and revised before deployment with
the project owner's confirmation that only disposable validation databases had
applied it. Validation uses a fresh database without changing earlier migration
histories or checksums. Future applied migrations remain immutable. The series
has one file per domain: each function declares its own security attributes,
and the final file alone attaches configuration-change triggers and grants
runtime access.

### Model

The core dimensions identify the server, Discord users, player accounts, clans,
roles, channels, and activity periods. Facts distinguish observations, decisions,
attempts, and confirmed outcomes. Counter observations are nonadditive across
time. Actual account-link intervals are separate from attribution continuity so
first-link backfill and transfers preserve their different historical meaning.

Supporting control tables do not pretend to be analytical measurements.
Current configuration, active links, primary selection, and pending moderation
work have database constraints and transaction boundaries.

The project owner defined audit as activity history: war attacks, Clan Games
points, donations, clan joins and leaves, warnings, kicks and chat XP. The fact
tables are that history, so the schema does not copy each of their rows into a
change ledger. Change history with the values before and after is kept for the
configuration tables only, where a change overwrites the old value. Private
histories have capability-specific access functions.

The clan member list poll keeps one row per poll as proof that it ran. A
member's role and donation counters are stored only when they change, through
one entry point, instead of once for every poll: at a poll every 120 seconds
the full list would add about 52 million rows a year for four clans. Donations
come from that poll. The project owner chose a fixed season calendar to bound
a donation total: a season ends on the last Monday of the month at 05:00 UTC,
and the total is the last counter seen before that time.

Kick history includes what a leader does by hand in Discord. Kicks, bans,
unbans and timeouts are kept from the audit log, one row per entry. Entries
that the bot itself executed are left out, because its kicks are already kick
decisions. A manual kick or an unban followed by a rejoin in the same month
notifies leadership; the notice has its own kind, so it does not stop the
automatic kick of the fifth warning as a rejoin after a bot kick does.

The unreleased schema is consolidated from 115 to 97 persisted tables; the
season calendar and the manual moderation history, added later, make 99.
Shared
settings and one-to-one workflow records use typed common storage; credited XP,
warning events, and delivery analytics use views over retained sources. This reduces duplicated writes while preserving distinct
source facts, attribution, assessment versions, roster revisions, and external
attempts. The current design documents the consolidation map.

The revised persistence model includes CWL planning and evidence, custom events,
rolling random XP and ranks, timezone-versioned reporting, and the selected
PostgreSQL-outbox/Kafka/Java-worker/gRPC/Discord-service delivery boundary.
Private commands, worker interfaces, and every new persisted feature table retain
curated grants. Native Mermaid ER diagrams are generated from
the migrated catalog, including every table and declared foreign key.

A report keeps one Discord message and every revision edits it in place. The
project owner chose this on 2026-11-11 over deleting and reposting the message
and over posting a new message for each revision: the channel then shows one
current report, the stored model already had one message identity per report,
and an edit is safe to repeat. Only the latest revision is sent. If the
message was deleted in Discord, the same revision creates a new one. The cost
is that an edit notifies nobody, and that revision history is only in the
database.

### Authorization

The runtime role is the trusted Java backend, not an end user. Entry points
take the acting member's key and check it against confirmed Discord roles, the
developer allowlist and current account links. This is defence in depth, not a
security boundary: the backend supplies the actor key, and the same role
records the role evidence those checks read. The checks stop a backend defect
from crossing a capability; they do not replace authenticating the Discord
interaction.

Only existing developers can manage developer IDs; an Admin role alone cannot
grant access to developer-only configuration logs. This is now an explicitly
accepted rule. Initial developer IDs are operator seeds.

### Verification

SQL assertions execute against disposable PostgreSQL 18 databases in CI before
the ordinary Java build. Tests exercise runtime grants and rejected invalid
states in addition to successful inserts. CI also regenerates the ER diagrams
and fails when the committed page differs.

### Scope

The SQL does not deploy Kafka, execute an optimizer, synchronize Sheets, or make
live Discord/CoC calls. Those workers and clients remain runtime work. Detailed
raid attacks and the feature specifications' explicitly open policies remain
outside the implemented scope.

### Consequences

- Good, because an invariant holds for every writer, including collectors,
  workers and operators, not only for the code path that remembered it.
- Good, because evidence rules such as complete-poll departures and measured
  zeros are checked where the evidence is stored.
- Good, because private ledgers are unreachable without an entry point, so a
  missing check in the service cannot expose them.
- Good, because the checks run without live Discord or Clash of Clans access.
- Good, because every command is a typed function, so the generated jOOQ
  model carries argument types and a bad argument fails at compile time, not
  as a cast error in PL/pgSQL.
- Bad, because a large share of the business rules is PL/pgSQL, which has
  weaker tooling, refactoring and review support than Java.
- Bad, because the rules are tested by SQL scripts outside the Gradle build, so
  a local `java:build` does not run them. This is accepted: the scripts need an
  empty, disposable database, and an ordinary build must not depend on one
  ([ADR 0007](0007-per-service-database-schemas.md),
  [ADR 0011](0011-schema-preparation-before-development-startup.md)). They run
  as `mise run guild:test` and as a required CI step.
- Bad, because the typed commands are many small functions: about 35 for
  configuration and activity, each with its own grant in V9.
- Bad, because the schema precedes its consumers. Tables for CWL planning and
  notification delivery may change when the workers that use them are written.

## More Information

- [Guild schema guide](../../services/guild/schema/README.md): migrations, setup
  commands, backend entry points and lifecycle limits.
- [Design](../design/guild-star-schema.md) and
  [ER diagrams](../design/guild-er-diagram.md).
- [ADR 0007](0007-per-service-database-schemas.md) for schema ownership and
  explicit preparation, and [ADR 0009](0009-discord-interaction-service.md) for
  the database-free Discord service.
