---
status: proposed
date: 2026-11-07
decision-makers: Kanishk Gupta
---

# Guild-owned activity stars and explicit SQL preparation

The user selected a star-schema design for CoC activity and Discord utilities.
The detailed requirements are captured in the
[working plan](../design/star-schema-working-plan.md).

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
guild consistently. The initial SQL series was renamed before deployment with
the project owner's confirmation that only disposable validation databases had
applied it. Validation uses a fresh database without changing earlier migration
histories or checksums. Future applied migrations remain immutable.

The core dimensions identify the server, Discord users, player accounts, clans,
roles, channels, and activity periods. Facts distinguish observations, decisions,
attempts, and confirmed outcomes. Counter observations are nonadditive across
time. Actual account-link intervals are separate from attribution continuity so
first-link backfill and transfers preserve their different historical meaning.

Supporting control tables do not pretend to be analytical measurements.
Current configuration, active links, primary selection, and pending moderation
work have database constraints and transaction boundaries. Audits retain the
changes, while private histories have capability-specific access functions.

The first allowlist-management rule is deliberately conservative: existing
developers can change developer IDs; an Admin role alone cannot grant access
to developer-only configuration logs. Initial developer IDs are operator seeds.
This management detail was open during requirements gathering and remains
reviewable rather than weakening the agreed developer-only visibility rule.

SQL assertions execute against disposable PostgreSQL 18 databases in CI before
the ordinary Java build. Tests exercise runtime grants and rejected invalid
states in addition to successful inserts.

CWL planning, custom events, detailed raid attacks, final XP/rank rules, and
delivery architecture remain separate design work. This decision adds no Kafka
dependency, live Discord side effects, or CoC network calls.
