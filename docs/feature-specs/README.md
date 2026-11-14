# Feature requirements

Agreed requirements from the planning discussion through 9 November 2026. These
documents consolidate the earlier requirements and follow-up decisions into
feature-sized specifications for future GitHub issues and the next star-schema
revision.

The specifications describe target behavior. They do not claim that any SQL
migrations or running services implement every requirement. The
[guild star-schema design](../design/guild-star-schema.md) maps the requirements
to implemented persistence and database invariants. Live service implementation
and GitHub issue creation remain separate work.

## Feature catalog

| Feature | Requirement prefix | Specification |
| --- | --- | --- |
| Configuration, permissions, and audit | CFG | [Configuration and access](configuration-and-access.md) |
| Account verification, links, transfers, and attribution | LINK | [Account linking and attribution](account-linking-and-attribution.md) |
| Clan membership, Discord onboarding, and roles | MEM | [Membership and role automation](membership-and-role-automation.md) |
| Regular-war tracking and reminders | WAR | [Regular wars](regular-wars.md) |
| Clan Games collection and assessment | CG | [Clan Games](clan-games.md) |
| Raid Weekend announcements and account totals | RAID | [Raid Weekends](raid-weekends.md) |
| CWL sign-ups, planning, and substitutions | CWL | [Clan War Leagues](clan-war-leagues.md) |
| Custom-event sign-ups and results | CUSTOM | [Custom events](custom-events.md) |
| Chat XP, eligibility, and ranks | XP | [Chat XP and ranks](chat-xp-and-ranks.md) |
| Warnings, kicks, and leadership notifications | MOD | [Warnings and moderation](warnings-and-moderation.md) |
| Leaderboard eligibility, metrics, and reporting periods | LB | [Leaderboards](leaderboards.md) |
| Kafka-backed notifications and Discord delivery | NOTIFY | [Notifications and delivery](notifications-and-delivery.md) |

[CoC API evidence and limitations](api-evidence.md) records what the supplied
Postman collection and response samples establish. It is a reference for these
features, not a verified contract for every live API response.

## Using these documents

- Requirement IDs identify accepted behavior and can be cited by future issues,
  acceptance criteria, schema decisions, and migrations.
- Acceptance scenarios describe expected outcomes, not current automated test
  coverage.
- Data requirements identify logical grains, identity, evidence, and retention
  needs. Physical tables, indexes, and DDL remain subsequent design work.
- Suggested workstreams are possible issue boundaries, not created GitHub issues
  or additional approved product rules.
- Open decisions and deferred scope remain explicitly identified. A proposed
  implementation default must not become an accepted requirement silently.
- These specifications replaced the requirements draft that the
  [star-schema working plan](../design/star-schema-working-plan.md) held
  until 14 November 2026. Where a specification says that it supersedes or
  extends "the working plan", it means that draft; the plan's History
  section says how to read it. The plan now lists the schema gaps, the open
  decisions and the order of the service work.

## Cross-feature invariants

1. Each environment serves one Discord server and supports multiple tracked CoC
    clans. Development and production use separate servers and databases.
2. PostgreSQL is the source of truth for bot-managed configuration, workflows,
    and retained evidence. Bootstrap credentials are supplied securely outside
    ordinary application configuration records.
3. The selected analytical model is a star schema with shared dimensions and
    activity-specific facts, supported by temporal bridges, current projections,
    configuration, and constrained operational state.
4. Retain activity and audit history indefinitely. Stable identities survive
    renames, departures, and account-link changes.
5. Source account facts and Discord-member attribution are separate. Moving a
    link preserves source facts and earlier attribution.
6. Distinguish source event time, observation time, ingestion time, and uncertain
    coverage. Missing evidence is not zero activity or proof of failure.
7. Cumulative counters and repeated snapshots are nonadditive across time. Select
    supported snapshots or deltas rather than summing lifetime totals.
8. Keep activity history as facts with their actor or system origin, and
    configuration changes with their values before and after. Exclude
    credentials and player verification tokens from payload archives, jobs,
    Kafka messages, and logs.
9. Java owns persistence, CoC API access, jobs, and Kafka processing. The
    discord.js service owns Discord interactions and API operations. Internal
    Java-to-Discord requests use gRPC.
10. An accepted Kafka message or gRPC request is not proof of a Discord action.
    Preserve confirmed, failed, and uncertain outcomes separately.

## Schema revision and issue planning

After reviewing the requirements:

1. Map requirement IDs to existing tables, constraints, and authorization
    functions; identify gaps without treating current SQL as the final behavior.
2. Define fact grains, conformed dimensions, temporal attribution, and supporting
    operational state for the new requirements.
3. Resolve open product decisions where an implementation depends on them; keep
    deferred features outside the initial scope.
4. Plan migrations and ER-diagram changes under the repository's
    [schema conventions](../decisions/0007-per-service-database-schemas.md).
5. Create feature issues referencing the requirements and scenarios. The
    [notification specification](notifications-and-delivery.md) includes proposed
    parent-issue and sub-issue workstreams.

The [schema guide](../../services/guild/schema/README.md) and
[ER diagrams](../design/guild-er-diagram.md) describe the persistence
implementation. Runtime workers and external delivery remain separate from
creating and validating database objects.

## Deliberately open boundaries

- Detailed Raid Weekend attacks and districts are deferred.
- Custom events have one roster; multi-round support is deferred.
- Members cannot edit CWL availability after sign-up closure for now; the policy
  can be revisited later.
- Exact CWL rating weights and optimizer implementation, production Kafka
  operations, and live API cache/reset behavior need design or validation.
- Metric-specific monthly calculations retain explicit open decisions in their
  feature specs. Onboarding after a rejoin or a late first link and war-reminder
  mentions were decided on 2026-11-14 (MEM-012, regular wars).
- A later API read cannot guarantee recovery of a missing historical baseline,
  checkpoint, or transfer boundary. Preserve evidence limitations.
