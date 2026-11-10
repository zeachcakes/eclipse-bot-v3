---
status: accepted
date: 2026-11-10
decision-makers: Kanishk Gupta
---

# Schema preparation before development startup

Current getting-started and startup instructions are in the
[development guide](../development.md). This decision records the configuration
and lifecycle behind that workflow.

## Context and Problem Statement

[ADR 0007](0007-per-service-database-schemas.md) separates database preparation
from compilation and startup. [ADR 0010](0010-centralized-development-workflow.md)
wraps those operations with root mise tasks. A developer must therefore run
`catalog:prepare` before `catalog:dev`, including after a fresh checkout or clean.

Service startup should perform the required preparation automatically while
preserving existing tables and data. Ordinary builds must still work without a
live database once their generated sources have been prepared. jOOQ produces
Java source, so generation must finish before compilation and before the Spring
Boot main class starts.

## Considered Options

- Run Flyway and jOOQ from a Spring application startup callback.
- Make every compilation depend on database preparation.
- Connect Gradle development startup to the existing schema preparation tasks.

## Decision Outcome

Connect development startup to schema preparation through reusable conventions
in `tools/gradle/convention-plugins`. This supersedes only the startup policy in
ADRs 0007 and 0010. Schema ownership, configuration precedence, separate roles,
and ordinary build behavior remain unchanged.

### Startup lifecycle

A participating server identifies its schema module in its Gradle configuration:

```groovy
schemaPreparation {
    schemaProjectPath = ':services:catalog:schema'
}
```

The schema module declares the required base tables, using unqualified names
within its configured schema:

```groovy
schemaDatabase {
    schemaName = 'catalog'
    generatedPackage = 'com.clashofclans.eclipse.catalog.jooq'
    connectionKey = 'catalog'
    requiredTables = ['item']
}
```

`requiredTables` must be a nonempty list. The server still declares its schema
module as a project dependency. The server convention connects `bootRun` to that
module's `prepareSchema` task. The ordered execution is:

```text
validate connection settings
  -> Flyway migration validation and pending migrations
  -> read-only required-table checks
  -> jOOQ generation
  -> generated-source verification and compilation
  -> bootRun
  -> Spring Boot main class
```

Preparation must finish before compilation can inspect generated sources, even
when Gradle executes tasks in parallel. A failed migration, table check or
generation prevents the service from starting. Preparing one service does not
prepare unrelated service schemas.

`mise run catalog:dev` invokes the integrated Gradle launcher with
`--no-configuration-cache`, because the database tasks resolve credentials only
at execution time and do not support configuration caching. See the
[catalog development workflow](../development.md#catalog-service) for setup and
launch commands.

`catalog:prepare` remains available for explicit preparation. Ordinary
`compileJava`, `test`, `check`, `jar`, `bootJar` and `build` invocations do not
schedule migrations or generation. They still fail clearly when generated
sources are missing or stale, until explicit preparation has succeeded.

### Preserving the database

Create the service schema and its migration/application roles outside Gradle.
Flyway initializes a fresh schema through versioned migrations and applies only
pending migrations on later starts. An up-to-date schema receives validation
and read-only table checks; startup does not drop or recreate existing tables,
truncate data or replay applied migrations.

Flyway history validation checks migration versions and checksums, not whether
a table was manually deleted. Required tables are therefore inspected through
read-only `information_schema` queries in `verifySchemaTables`, after
`flywayMigrate` and before `generateJooq`. Missing tables after a migration has already been
applied are an error, with no attempt to reconstruct them. Existing schemas
without a valid Flyway history also fail instead of being silently baselined.

Retain `cleanDisabled=true`, `baselineOnMigrate=false`, `createSchemas=false`,
migration validation, and the restrictions on generic Flyway overrides.
`flywayClean`, `flywayRepair`, `flywayBaseline` and `flywayUndo` remain disabled.
A migration change is a new reviewed versioned file, not an edit to an applied
migration.

### Configuration and runtime

Gradle preparation uses the service's migration credentials; the running service
continues to connect with its application role. Root `.env` loading and
per-service connection precedence remain as defined in ADR 0010. No connection
values are printed or stored in the configuration cache.

The catalog runtime configuration is `application.yml`. Spring Flyway and SQL
initialization remain disabled there, since Gradle completes preparation before
launching the application.

Starting the main class directly from an IDE or executing an already-built JAR
does not execute these Gradle tasks. Such launches need a prepared database and
compiled generated classes. Configure an IDE to run the Gradle launcher to use
automatic preparation. A packaged application cannot compile a changed jOOQ
model into itself during startup; production migration orchestration remains a
separate deployment concern.

### Consequences

- Good, because one development command prepares and starts the service.
- Good, because existing table data and the separation of migration/runtime
  credentials are preserved.
- Good, because ordinary builds remain independent of a live database.
- Bad, because development startup now requires migration credentials and a
  reachable database, and does not support the configuration cache.
- Bad, because direct main-class and packaged-JAR launches do not provide the
  same preparation behavior as the Gradle development launcher.

## More Information

- [Issue 102](https://github.com/zeachcakes/eclipse-bot-v3/issues/102)
- [ADR 0006: Layered convention plugins](0006-layered-convention-plugins.md)
- [ADR 0007: Per-service database schemas](0007-per-service-database-schemas.md)
- [ADR 0010: Centralized development workflow](0010-centralized-development-workflow.md)
