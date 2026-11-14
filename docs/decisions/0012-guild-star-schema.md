---
status: accepted
date: 2026-11-13
decision-makers: Kanishk Gupta
---

# Guild-owned activity stars with business rules in Java

## Context and Problem Statement

The bot has to record Clash of Clans activity and Discord utilities for one
server: clan membership, wars, Clan Games, raids, CWL, account links, chat XP,
warnings, notifications and leaderboards. The detailed requirements are in the
[feature specifications](../feature-specs/README.md), with their
[dimensional and workflow design](../design/guild-star-schema.md).

Much of that data is evidence, not state. A collection time is not the time
something happened in the game, a failed poll is not a departure, and a missing
read is not a zero. Several rules also cross features: one account can change
owner during an event, and a role or a link decides who may run a command.

ADR 0007 gives each service its own schema. ADR 0009 keeps the Discord service
away from the database: Java owns persistence, Clash of Clans API calls,
scheduled jobs and Kafka. Within those limits, how should this data be
modelled, and where should its rules and permission checks live?

## Considered Options

- A star schema in one guild-owned schema. The guild service implements the
  business rules and permission checks in Java, and PostgreSQL enforces
  declarative constraints.
- The same schema, with the business rules and permission checks in PL/pgSQL
  functions and triggers.
- The same schema, with every rule in Java and no constraints beyond primary
  keys.
- A normalised operational model now, with a separate analytical store later.
- Separate schemas for each feature (wars, Clan Games, moderation and so on).

## Decision Outcome

Use one Java-owned guild schema with activity-specific facts and shared
dimensions. The guild service implements the business rules, workflows and
permission checks in Java. PostgreSQL enforces every invariant that a
declarative constraint can state, and privileges keep the facts append-only
for the runtime role. The schema contains no PL/pgSQL functions and no
triggers.

The project owner selected the star-schema design and Java for its rules. The
guild service is the only writer of its schema (ADR 0007), so a rule in its
domain layer applies to every writer it has: collectors, command handlers and
delivery workers. Java gives that code refactoring, debugging, type checking
and unit tests, and a rule change ships with the service instead of a
migration.

The declarative constraints stay because they cost nothing at runtime and hold
for any writer, including an operator with a SQL prompt. Rules in PL/pgSQL were
not chosen: every rule change would become a migration, the body of a function
would spread across versions once migrations are deployed, the tooling is
weaker, and each command would need its own database entry point and grant. A
separate analytical store adds a second pipeline before any reporting need has
been measured. Separate schemas for each feature would put the shared
dimensions and the account links across ownership boundaries, which ADR 0007
rules out.

### One Discord server per database

A database serves one Discord server: `dim_guild` accepts one row. Only
`dim_guild` and `guild_settings` carry `guild_key`; no other table has a guild
column. A multi-server schema with `guild_key` on every table was not chosen.
Each environment serves one server (invariant 1 of the feature
specifications), so the extra columns and the composite keys that compare them
would guard nothing. A second community gets its own database, as development
and production already do.

### Ownership and preparation

The schema follows ADR 0007. The `services/guild/schema` module holds
versioned, schema-qualified Flyway SQL files, one per domain. They contain
declarative schema only: tables, constraints, indexes, views and grants. The
last file grants all runtime access. Roles and the schema are created
explicitly outside Gradle; preparation migrates and generates jOOQ; ordinary
builds and startup never prepare the database. Deployed migrations are
immutable, so a schema change adds a version.

The service, SQL namespace, runtime grants, package, settings and tasks use
`guild` consistently. The Discord interaction service remains database-free,
as specified in ADR 0009.

### What the database enforces

PostgreSQL holds the invariants that one row or one index can state:

- primary keys, foreign keys and `NOT NULL`;
- unique and partial unique indexes, such as one current owner per account,
  one primary per member, one kick decision per member and month, and one send
  attempt per ping;
- `CHECK` constraints that keep the columns of a row consistent with its
  status;
- exclusion constraints, so that the link intervals of one account, its
  membership periods in one clan, Clan Games events and reporting periods
  cannot overlap (membership periods in different clans may, because each
  clan is polled on its own cycle);
- generated columns for values derived from the same row, such as the GMT
  month of a warning.

The runtime role receives `SELECT` and `INSERT` on fact tables. `UPDATE` is
granted only on named columns that a later step fills in, such as the
completion of a fetch or the last time an attack was seen, and never on
identities or measures. `DELETE` is not granted. Recorded activity therefore
stays append-only without a trigger. On configuration, workflow, temporal
bridge and projection tables, `UPDATE` and `DELETE` are granted per table and
column for the changes the service makes. Views serve read models and reports.

### What the guild service implements

Everything else is Java in the guild service:

- commands: account links and transfers, configuration, warnings, CWL and
  custom events;
- permission checks;
- current-state projections, such as Discord presence, held roles and chat
  rank;
- evidence rules, such as Clan Games checkpoint reads, participating-clan
  inference and CWL eligibility;
- workers: collectors, claims and leases, notification dispatch and role
  reconciliation;
- calculations: Clan Games proration and rounding, XP sampling, rank
  thresholds, GMT warning months and reporting periods.

Each command and each worker step runs in one JDBC transaction through jOOQ,
inside the blocking boundary that ADR 0007 defines. A rule that spans rows
locks the record it belongs to (`SELECT … FOR UPDATE`) or takes a
transaction-scoped advisory lock, and a unique or partial unique index decides
any race that remains. A retried command carries a stable operation ID. A
unique constraint on that ID stops a second application, and the service
returns the stored first result. Set computations, such as the union of
presence intervals, can remain SQL queries through jOOQ; the rule that uses
the result is Java.

### Model

The core dimensions identify the server, Discord users, player accounts, clans,
roles, channels and activity periods. Facts distinguish observations,
decisions, attempts and confirmed outcomes. Counter observations are
nonadditive across time. Actual account-link intervals are separate from
attribution continuity, so first-link backfill and transfers keep their
different historical meaning.

Configuration, workflow and projection tables do not pretend to be analytical
measurements. Current configuration, active links, primary selection and
pending moderation work are constrained by the schema and changed in service
transactions.

The project owner defined audit as activity history: war attacks, Clan Games
points, donations, clan joins and leaves, warnings, kicks and chat XP. The fact
tables are that history, so the schema keeps no second copy of their rows.
Change history with the values before and after is kept for the configuration
tables only, where a change overwrites the old value. The guild service writes
that history in the same transaction as the change, through the one repository
that changes configuration. Private histories are read only through
permission-checked service queries.

The clan member list poll keeps one row per poll as proof that it ran. A
member's role and donation counters are stored only when they change, instead
of once for every poll: at a poll every 120 seconds the full list would add
about 52 million rows a year for four clans. Donations come from that poll. A
fixed season calendar bounds a donation total: a season ends on the last
Monday of the month at 05:00 UTC, and the total is the last counter seen before
that time.

Kick history includes what a leader does by hand in Discord. Kicks, bans,
unbans and timeouts are kept from the audit log, one row per entry. Entries
that the bot itself executed are left out, because its kicks are already kick
decisions. A manual kick or an unban followed by a rejoin in the same month
notifies leadership. The notice has its own kind, so it does not stop the
automatic kick of the fifth warning, as a rejoin after a kick by the bot does.

Shared settings and one-to-one workflow records share storage, and credited XP,
warning history and delivery analytics are views over their sources. The
[design](../design/guild-star-schema.md) records the table map. The model
covers CWL planning and evidence, custom events, rolling random XP and ranks,
timezone-versioned reporting, and the delivery path from the PostgreSQL outbox
through Kafka and a Java worker to the Discord service over gRPC. Native
Mermaid ER diagrams are generated from the migrated catalog, with every table
and declared foreign key.

A report keeps one Discord message, and every revision edits it in place.
Deleting and reposting the message, and posting a new message for each
revision, were not chosen: the channel then shows one current report, the
model keeps one message identity per report, and an edit is safe to repeat.
Only the latest revision is sent. If the message was deleted in Discord, the
same revision creates a new one. The cost is that an edit notifies nobody and
that revision history is only in the database.

### Authorization

Permission checks run in the guild service against current evidence:
confirmed Discord roles, presence in the server, the developer allowlist and
current account links. A historical role assignment never grants authority.
Actor IDs come only from Discord interactions that the Discord service relays
(ADR 0009).

Only the owner developer, the main developer named by the operator seed, can
manage developer IDs (CFG-004), and only developers can read the configuration
change history. An Admin role alone cannot grant itself that access. Initial
developer IDs and the owner are operator seeds. A staff capability needs a
confirmed present Discord state (CFG-010). Private account-link history,
Leadership-only Clan Games results and other members' moderation history each
have their own check.

The database role is a credential of the guild service, not of a Discord
member. Its privileges limit what a defect in the service can change; they do
not replace the permission checks.

### Verification

- Rules that need no database, such as proration, rounding, rank thresholds,
  bench rules, warning months and reporting periods, are unit tests in the
  ordinary build.
- Constraint, concurrency and repository tests run against a disposable
  PostgreSQL 18 database, as their own task and CI step. They are not part of
  the ordinary build, which must not depend on a database
  ([ADR 0007](0007-per-service-database-schemas.md),
  [ADR 0011](0011-schema-preparation-before-development-startup.md)).
- CI regenerates the ER diagrams and fails when the committed page differs.

### Scope

The schema module creates and validates the database objects. The guild
service implements the Clash of Clans collectors, the rules, the workers,
Kafka publishing and consumption, the CWL optimizer and Sheets
synchronization, and it calls Discord through the Discord service. Detailed
raid attacks and the policies that the feature specifications leave open are
outside this decision.

### Consequences

- Good, because the business rules live in one language, with refactoring,
  debugging, type checking and review support.
- Good, because a rule change ships with the service, and migrations change
  only the schema.
- Good, because rules such as proration, rounding and reporting periods are
  unit-tested without a database in the ordinary build.
- Good, because the constraints still hold for every writer, including an
  operator: identities, uniqueness, non-overlapping intervals, consistent rows
  and append-only facts.
- Good, because the generated jOOQ model has tables and views only, with no
  routine signatures to keep in step.
- Bad, because rules that span rows depend on correct transactions and locks in
  Java: the rolling XP limit, one kick for a fifth warning, one report revision
  in flight, one attempt per ping, and transfers that wait for a points read.
  Mistakes show only under concurrency, so these rules need tests against a
  real database.
- Bad, because those tests need a disposable database and run outside the
  ordinary build, as their own task and CI step.
- Bad, because a rule that only the service enforces does not bind SQL that an
  operator runs; the constraints catch structural damage only.
- Bad, because the configuration change history depends on every
  configuration write going through the repository that records it.
- Bad, because a command takes several statements instead of one function
  call. That is acceptable for one Discord server.
- Bad, because the schema precedes its consumers. Tables for CWL planning and
  notification delivery may change when the workers that use them are written.

## More Information

- [Guild schema guide](../../services/guild/schema/README.md): migrations and
  setup commands.
- [Design](../design/guild-star-schema.md) and
  [ER diagrams](../design/guild-er-diagram.md).
- [ADR 0007](0007-per-service-database-schemas.md) for schema ownership,
  explicit preparation and the blocking jOOQ boundary, and
  [ADR 0009](0009-discord-interaction-service.md) for the database-free Discord
  service.
