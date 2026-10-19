# eclipse-bot-v3

A utility bot for Reddit Eclipse to assist with clan activities using the Clash of Clans API.

The Java foundation uses local Gradle convention plugins, Spring Boot services,
and an externally provided PostgreSQL database. The catalog service is a small
example of the schema and runtime wiring; it does not yet expose a business API.
The implementation follows [the convention-plugin specification](CONVENTION-PLUGINS-REUSE.md)
and [ADR 0006](docs/decisions/0006-explicit-schema-conventions.md).

## Toolchain and layout

Use Java 21 and the checked-in Gradle 9.1.0 wrapper. The local
[mise configuration](mise.toml) pins Temurin `21.0.12+101.0.LTS`; Gradle's Java
toolchain accepts any suitable Java 21 vendor. Spring Boot is pinned to `4.0.3`,
jOOQ to `3.19.30`, and Flyway to `11.16.0` in the shared
[version catalog](gradle/libs.versions.toml).

```bash
mise install java
mise exec -- java -version
mise exec -- ./gradlew --version
```

With Java 21 already active, use `./gradlew` directly. The first run needs access
to the Gradle distribution and dependency repositories. No global Gradle install
is required. Configuration caching is disabled because the database adapters
configure their execution-time connection settings outside that contract.

The project group/base package is `com.clashofclans.eclipse`, and its version is
`0.1.0`; these values live in [Gradle properties](gradle.properties).

| Module or build | Purpose |
| --- | --- |
| [tools/gradle](tools/gradle) | Independent included build importing the same version catalog |
| [convention-plugins](tools/gradle/convention-plugins) | Three Groovy precompiled convention plugins |
| [libraries/common](libraries/common) | Java-only library with a small validation helper and Jupiter tests |
| [services/catalog/schema](services/catalog/schema) | Catalog migrations and verified generated jOOQ model |
| [services/catalog/server](services/catalog/server) | WebFlux, R2DBC, and JDBC/jOOQ example application |

Modules are listed explicitly in [root settings](settings.gradle). There is no
recursive module discovery. Consumers apply these local plugin IDs without a version:

- `java-core-conventions`: Java 21, strict compiler warnings, Error Prone,
  NullAway for the application's namespace, and standalone Jupiter test dependencies.
- `spring-boot-server-conventions`: the Java convention plus Boot, WebFlux,
  R2DBC, JDBC/jOOQ, drivers, and Reactor test support.
- `service-schema-conventions`: the Java convention plus explicit Flyway and
  jOOQ preparation, and verification of existing generated sources.

Existing [Compose configuration](compose.yaml) and local environment files
belong to the earlier repository setup and are not
dependencies of this foundation. Gradle does not load `.env`. No container,
image, scan, publishing, pipeline, CI, or coverage-gate workflow is introduced.

## Checks that need no database

```bash
./gradlew help projects
./gradlew -p tools/gradle :convention-plugins:build
./gradlew :libraries:common:test
./gradlew :services:catalog:schema:tasks --all
./gradlew :services:catalog:schema:compileJava --dry-run
./gradlew :services:catalog:schema:prepareSchema --dry-run
```

The compile graph contains `verifyGeneratedJooq` and no migration/generation.
The preparation graph is `validateSchemaDatabase` → `flywayMigrate` →
`generateJooq` → `prepareSchema`. Dry runs execute none of those actions.

A fresh checkout intentionally fails this command with the exact preparation
task to run:

```bash
./gradlew :services:catalog:schema:compileJava
```

Generated sources are untracked, so a fresh full build is not database-independent.
The build must fail clearly for absent or stale output; it must never prepare
the database automatically or compile an empty schema artifact.

## Database settings and ownership

Provision the development database, the `catalog` schema, a migration role,
and a separate application role outside Gradle. The migration role must have
rights only to its service schema; the application role needs its runtime grants.
No administrative account, embedded database, or container is assumed.

| Purpose | Environment variables | Gradle property alternative |
| --- | --- | --- |
| Migration/generation JDBC endpoint | `CATALOG_DB_URL` | `catalog.db.url` |
| Migration/generation username | `CATALOG_DB_USER` | `catalog.db.user` |
| Migration/generation password | `CATALOG_DB_PASSWORD` | `catalog.db.password` |
| Runtime JDBC endpoint | `CATALOG_DB_URL` | Not read from Gradle properties by the application |
| Runtime R2DBC endpoint | `CATALOG_R2DBC_URL` | Not read from Gradle properties by the application |
| Runtime username, both access paths | `CATALOG_APP_DB_USER` | Not read from Gradle properties by the application |
| Runtime password, both access paths | `CATALOG_APP_DB_PASSWORD` | Not read from Gradle properties by the application |

For preparation, an explicitly present per-service Gradle property takes
precedence over its environment variable. An empty property fails validation;
it does not fall back. There are no global `DB_*` fallbacks or default endpoints.
Passwords are preserved exactly, including spaces. Connections are resolved
only when an explicit database task executes, so listing/configuring the build
needs no credentials.

Supply secrets through an approved local mechanism or a protected user-level
Gradle properties file. Do not put real passwords in tracked files or command-line
`-P` arguments. Use a PostgreSQL JDBC URL without embedded credentials, for example
`jdbc:postgresql://localhost:5432/eclipse_dev`; supply the R2DBC URL separately,
for example `r2dbc:postgresql://localhost:5432/eclipse_dev`. These are illustrative
endpoint shapes, not provisioned defaults; do not derive one by replacing a URL prefix.

Transient Gradle/jOOQ files can contain connection information. Build/cache
directories are ignored; avoid debug logging or sharing those local artifacts.
Generic Flyway overrides that could redirect execution or change safety policy
are rejected. `flywayClean` cannot delete data, and the foundation does not provide
administrative repair or baseline procedures.

## Prepare, build, and run

After providing approved non-production migration settings:

```bash
./gradlew :services:catalog:schema:validateSchemaDatabase
./gradlew :services:catalog:schema:flywayInfo
./gradlew :services:catalog:schema:prepareSchema
./gradlew :services:catalog:schema:flywayValidate
```

`validateSchemaDatabase` checks settings without opening a connection. Preparation
runs migrations from the schema module's [migration directory](services/catalog/schema/src/main/resources/db/migration),
then generates only that schema's application tables, excluding Flyway history.
Flyway does not create the schema, clean it, automatically repair it, or baseline it.
Keep applied migrations immutable; add a new versioned migration for changes.

Generated Java is written to `services/catalog/schema/build/generated-src/jooq/main`.
Successful preparation writes `services/catalog/schema/build/jooq/generation-state.json`,
containing a deterministic input fingerprint and sorted Java-file hashes.
The fingerprint covers migrations, schema/package, tool versions, and generator settings.

Preparation invalidates the old marker before migration and clears only its
own generated output before generation. A failed migration/generation leaves
no valid success marker. Verification checks the marker, input fingerprint,
and complete output manifest without credentials or a database connection.
Missing, changed, added, or deleted generated files require preparation again.
The marker records local preparation consistency; it cannot prove the live
database has not drifted.

After successful preparation:

```bash
./gradlew :services:catalog:schema:verifyGeneratedJooq
./gradlew :libraries:common:test :services:catalog:server:test
./gradlew :services:catalog:server:bootJar
```

These build/test commands run no migrations, generation, or live database tests
and do not need migration credentials while the generated state remains valid.
`prepareSchema build` is also ordered correctly when explicitly requested together.
For a clean rebuild, make each step explicit:

```bash
./gradlew clean
./gradlew :services:catalog:schema:prepareSchema
./gradlew build
```

`clean` deletes generated output/state. Prepare each required service schema
again before building its consumers.

With a prepared schema and the separate runtime settings, launch manually:

```bash
./gradlew :services:catalog:server:bootRun
```

This launch requires the real runtime database and is not a unit test.
[Application configuration](services/catalog/server/src/main/resources/application.yaml)
disables Flyway and startup SQL initialization. An explicit Spring-managed Hikari
data source and `jdbcTransactionManager` coexist with Boot's R2DBC
`connectionFactoryTransactionManager`. Boot supplies jOOQ's Spring transaction provider.
The [example adapter](services/catalog/server/src/main/java/com/clashofclans/eclipse/catalog/server/JdbcItemRepository.java)
defers its entire JDBC transaction onto a bounded elastic scheduler; it does not
block the reactive request thread. JDBC and R2DBC transactions are distinct;
select the appropriate named manager when adding transactional operations.

## Dependency alignment

```bash
./gradlew -p tools/gradle :convention-plugins:dependencyInsight \
  --configuration runtimeClasspath --dependency org.jooq
./gradlew -p tools/gradle :convention-plugins:dependencyInsight \
  --configuration runtimeClasspath --dependency flyway-core
./gradlew :services:catalog:schema:dependencyInsight \
  --configuration jooqGenerator --dependency org.jooq
./gradlew :services:catalog:server:dependencyInsight \
  --configuration runtimeClasspath --dependency org.jooq
./gradlew :services:catalog:schema:dependencies --configuration flywayMigration
./gradlew :services:catalog:server:dependencies --configuration runtimeClasspath
```

jOOQ runtime, metadata, and codegen must resolve to `3.19.30`; Flyway core and
PostgreSQL support must resolve to `11.16.0`. PostgreSQL JDBC is pinned to
`42.7.10`; R2DBC PostgreSQL uses the Boot BOM version. The server runtime must not
inherit Flyway tooling, Testcontainers, WebMVC, or JPA. Dependency resolution
alone does not prove database or generated-model compatibility.

## Add another service

For `orders`, provision a separate schema and roles, then:

1. Explicitly include `:services:orders:schema` and `:services:orders:server`
    in [root settings](settings.gradle).
2. Apply `service-schema-conventions` in its schema module and configure:

    ```groovy
    schemaDatabase {
        schemaName = 'orders'
        generatedPackage = 'com.clashofclans.eclipse.orders.jooq'
        connectionKey = 'orders'
    }
    ```

3. Add schema-qualified, orders-owned SQL migrations under its own migration
    directory. Do not share catalog history, state, or generated sources.
4. Apply `spring-boot-server-conventions` in the server module, declare
    `implementation project(':services:orders:schema')`, and set its own
    `springBoot.mainClass`.
5. Configure independent `ORDERS_DB_*` migration settings and
    `ORDERS_APP_DB_*` / `ORDERS_R2DBC_URL` runtime settings, plus the `orders`
    schema in both JDBC and R2DBC runtime configuration.
6. Run `./gradlew :services:orders:schema:prepareSchema`, then its tests/package task.

Schema and connection keys must match `[a-z][a-z0-9_]*`; generated packages must
be valid Java packages beneath `com.clashofclans.eclipse`. The two services may
share a database endpoint while retaining independent ownership, migration
history, generated packages, output, and state. Cross-service schema ownership
requires a separate architecture decision.

## Verification status and troubleshooting

Database-free verification completed on 2026-10-20 with Gradle 9.1.0 and Java 21:

| Check | Result |
| --- | --- |
| Independent convention build, including plugin validation | Passed |
| Java-only common library build and tests | Passed; 2 tests |
| Root help/projects and schema task listing | Passed without database settings |
| Compile and combined preparation/build dry runs | Correct dependency and ordering relationships |
| Real, unprepared schema compilation | Expected actionable failure; no database task executed |
| Dependency inspection | jOOQ runtime/metadata/codegen `3.19.30`, Flyway core/PostgreSQL `11.16.0`, JDBC `42.7.10`, R2DBC `1.1.1.RELEASE` |

The independent build check is `./gradlew -p tools/gradle :convention-plugins:build`;
the library check is `./gradlew :libraries:common:build`. Inspection confirmed
no Flyway, Testcontainers, WebMVC, or JPA dependency in the server runtime.

Five application/common tests also passed under Java 21 with strict compiler
warnings, Error Prone, and NullAway in an isolated temporary fixture. That fixture used a
synthetic generated table API solely to compile and exercise the server tests;
it did not create generated output or a success marker in the real schema module.
The tests cover text validation, deferred transaction success/failure, application-role
binding, both transaction managers and Spring jOOQ integration, disabled startup
SQL, and resource disposal. Fixture dependency inspection resolved jOOQ `3.19.30`.
No measured coverage percentage is claimed.

Live database acceptance remains pending: supply an approved external development
database/schema and scoped credentials, then verify migration repeatability and
schema isolation, real generated tables/records/immutable POJOs, generated-model
compilation, server packaging, failure invalidation, and runtime connectivity
through both access paths. The implementation is not yet end-to-end verified.

| Symptom | Action |
| --- | --- |
| Missing/stale generated sources | Run the exact module's `prepareSchema`; do not disable verification |
| No Java 21 toolchain | Activate/install Java 21 and check `./gradlew --version` |
| Plugin not found | Check the included-build wiring and plugin ID |
| Listing tasks asks for a password | Treat this as a regression: credentials must resolve during database-task execution |
| Build starts migration/generation | Check task dependencies; ordinary build/test must only verify output |
| Tests try to connect to PostgreSQL | Use isolated collaborators/context tests instead of full application startup |
| Missing JDBC transaction manager with R2DBC | Retain the explicit JDBC configuration and named transaction selection |
| Database drift despite valid local state | Explicitly inspect/validate migrations against the controlled service schema |

See [the specification's runbook and troubleshooting](CONVENTION-PLUGINS-REUSE.md#15-command-runbook-and-expected-outcomes)
for the complete acceptance contract. Production migration orchestration,
deployment, authentication, backups, and secret-manager integration are separate decisions.
