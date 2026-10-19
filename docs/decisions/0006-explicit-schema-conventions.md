---
status: accepted
date: 2026-10-19
decision-makers: Kanishk Gupta
---

# Explicit schema preparation and portable Java convention plugins

## Context and Problem Statement

The [convention-plugin specification](../../CONVENTION-PLUGINS-REUSE.md) defines a
reproducible Java/Spring foundation with external PostgreSQL, one schema per
service, and explicit Flyway/jOOQ preparation. The earlier runtime and build
decisions describe a Java 25/Gradle 9.7.1 starting point, automatic project
discovery, and enabled configuration caching. Those choices need to be reconciled
with the selected compatibility baseline and execution-time database configuration.

This decision supersedes the Java version in
[ADR 0001](0001-language-runtimes.md), the Gradle version in
[ADR 0002](0002-gradle-build-tool.md), the generated convention names/toolchain
and enabled configuration cache in
[ADR 0004](0004-gradle-version-catalog-and-convention-plugins.md), and the included
build root and automatic module discovery in
[ADR 0005](0005-convention-plugins-included-build.md). Their remaining decisions,
including the other language runtimes, Groovy DSL, and centralized version catalog,
remain applicable. Earlier ADRs are preserved as the historical record.

## Decision Outcome

- Use Java 21 with the checksum-pinned Gradle `9.1.0` wrapper and Spring Boot
  `4.0.3`. The local [mise configuration](../../mise.toml) pins Temurin
  `21.0.12+101.0.LTS`, while Gradle accepts Java 21 from any suitable vendor.
- Keep project identity `eclipse-bot-v3`, group/base package
  `com.clashofclans.eclipse`, and version `0.1.0`, centrally configured in
  [Gradle properties](../../gradle.properties).
- Include the independent [tools/gradle build](../../tools/gradle) through
  `pluginManagement.includeBuild('tools/gradle')`. It contains the
  [convention-plugins project](../../tools/gradle/convention-plugins) and imports
  the root [version catalog](../../gradle/libs.versions.toml).
- List application modules explicitly in [root settings](../../settings.gradle).
  Do not recursively discover nested builds, fixtures, or caches.
- Provide exactly three public conventions: `java-core-conventions`,
  `spring-boot-server-conventions`, and `service-schema-conventions`.
  The Java convention supplies strict compiler checks, Error Prone, NullAway
  configured for our namespace, and independently versioned Jupiter test support.
- Disable Gradle configuration caching for this implementation. Execution-time
  Flyway/jOOQ adapters are not claimed to support it. Database preparation and
  generation must not reuse cached outputs or skip explicit execution as up to date.
- Retain externally provisioned PostgreSQL with separate service schemas.
  Provision each schema and migration/application roles outside Gradle. Do not
  add database containers or embedded substitutes to the foundation.

### Explicit preparation and generated artifacts

Each schema module supplies `schemaDatabase.schemaName`, `generatedPackage`,
and `connectionKey`. Connection resolution occurs only during an explicit
database task: per-service Gradle properties override matching environment
variables, empty explicit properties fail, and no global connection defaults
exist. The application uses separate runtime-role credentials. Gradle does not
read `.env` files.

The preparation graph is:

```text
prepareSchema -> generateJooq -> flywayMigrate -> validateSchemaDatabase
compileJava  -> verifyGeneratedJooq
check        -> verifyGeneratedJooq
```

Verification runs after generation when both are explicitly requested, without
creating an implicit generation dependency. Ordinary build/test/package/run
tasks never schedule migrations or generation. Application launch still requires
valid runtime database settings.

Flyway uses the module's filesystem migrations, only its service schema, and a
dedicated migration classpath. Schema creation, cleaning, automatic repair, and
automatic baselining are excluded. Conflicting generic Flyway configuration
cannot redirect the per-service target or relax the safety policy.

jOOQ `3.19.30` is aligned across build-logic metadata/codegen, the generator, and
application runtime; Flyway core and PostgreSQL support use `11.16.0`. Generated
Java stays untracked under each schema module's build directory. A successful
generation records a deterministic input fingerprint and complete Java-file
manifest in a module-local state file. Preparation invalidates the prior marker
before migration; generation clears only that module's generated output; a
failure leaves no valid success marker.

Compilation and checks reject missing, malformed, changed, or stale generated
state without reading connection settings. A fresh checkout or schema clean
therefore requires explicit preparation before compiling consumers. This local
marker does not establish that the external database has never drifted.

### Runtime database access

Services use WebFlux and R2DBC plus JDBC-backed jOOQ. An explicit Spring-managed
Hikari data source and JDBC transaction manager coexist with Boot's reactive
transaction manager. Boot supplies jOOQ's Spring transaction integration.
Blocking JDBC work, including its complete transaction boundary, executes only
after subscription on a bounded blocking-work scheduler. JDBC and R2DBC
transactions remain independent and must use the appropriate named manager.

Flyway and SQL initialization are disabled at application startup. Normal unit
tests use fake collaborators and focused application contexts, without a live
database, sleeps, containers, or missing-infrastructure fallbacks.

### Scope and validation

The initial examples are [common](../../libraries/common),
[catalog schema](../../services/catalog/schema), and
[catalog server](../../services/catalog/server). Existing
[Compose configuration](../../compose.yaml) and environment files remain legacy
repository content, not dependencies of this foundation. Container/image tooling,
scanners, publishing, batch pipelines, CI, and coverage enforcement are excluded.

Five application/common tests passed with strict Java 21 compilation in an
isolated temporary fixture using a synthetic generated table API. That establishes
the unit-level runtime behavior, not real PostgreSQL introspection or compatibility
of actual generated output. Database preparation, repeatability, isolation,
real model compilation, packaging, and both runtime connection paths still require
explicit acceptance against an approved external development database. No measured
coverage is claimed. The [README runbook](../../README.md) records commands and
verification status.

## Consequences

- Libraries can compile/test with no Spring Boot or database setup, and ordinary
  service builds never mutate a shared database.
- Per-service configuration, output, history, and state remain independent even
  when services share a development database endpoint.
- Missing or stale generated output fails early with an actionable preparation
  command instead of silently producing an incomplete schema artifact.
- Fresh full builds need approved database access for explicit preparation;
  generated output cannot be recovered from committed source or a build cache.
- Configuration-cache performance benefits are deferred until these execution
  adapters have a supported and verified design.
- Database provisioning, production migration orchestration, cross-service schema
  ownership, deployment, and secret-manager integration require separate decisions.
