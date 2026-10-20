---
status: accepted
date: 2026-10-20
decision-makers: Kanishk Gupta
---

# Per-service database schemas with explicit preparation

Updated by [ADR 0010](0010-centralized-development-workflow.md): local settings
now come from the single root `.env` through mise, environment variables take
precedence over legacy Gradle properties, and root tasks wrap the commands below.
Schema ownership and explicit database preparation remain unchanged.

## Context and Problem Statement

Services keep their data in PostgreSQL ([ADR 0003](0003-postgresql-datastore.md)). Each service changes its tables with Flyway migrations and queries them through jOOQ classes generated from the migrated schema. The services are reactive (Spring WebFlux), but jOOQ runs on blocking JDBC.

When do migrations run and sources get generated, so that an ordinary build never needs or changes a database? How are credentials supplied without leaking them? How do reactive services use blocking jOOQ safely?

## Considered Options

* Generate jOOQ sources during compilation, migrating the database as part of the build.
* Migrate at application startup with Spring Boot's Flyway integration.
* Run migration and generation only in explicit preparation tasks, and verify the generated sources in every build.

## Decision Outcome

Chosen option: "Run migration and generation only in explicit preparation tasks", because an ordinary build must never start, migrate or depend on a database, and a missing or stale generated model must fail clearly instead of compiling something incomplete.

* Generating during compilation needs a live database for every build and migrates a shared database as a side effect.
* Migrating at startup needs the migration role's rights in every running service. Services only get the application role.

### Schemas and roles

* Each service owns one PostgreSQL schema. Services can share a development database, but never a schema.
* Each schema has a migration role that owns it and a separate application role with only runtime grants. Create the schema and both roles outside Gradle, for example in the local Compose database. Flyway never creates, cleans, repairs or baselines a schema.
* Migrations are schema-qualified SQL files in the schema module's `src/main/resources/db/migration`. An applied migration never changes; a change is a new versioned migration.
* Cross-service schema ownership or generation needs its own decision.

### Schema modules

A schema module applies `service-schema-conventions` ([ADR 0006](0006-layered-convention-plugins.md)) and configures it:

```groovy
schemaDatabase {
    schemaName = 'catalog'
    generatedPackage = 'com.clashofclans.eclipse.catalog.jooq'
    connectionKey = 'catalog'
}
```

All three settings are required and have no defaults. `schemaName` and `connectionKey` must match `[a-z][a-z0-9_]*`, and `generatedPackage` must be a Java package within `baseJavaPackage`. A server declares its dependency on its schema module itself; the schema plugin never changes the server.

### Database settings

The connection key selects the settings. For `catalog`:

| Setting | Gradle property | Environment variable |
| --- | --- | --- |
| JDBC URL | `catalog.db.url` | `CATALOG_DB_URL` |
| Migration role | `catalog.db.user` | `CATALOG_DB_USER` |
| Migration password | `catalog.db.password` | `CATALOG_DB_PASSWORD` |

* As updated by ADR 0010, a present environment variable wins over its Gradle property, even when blank. An invalid or blank supplied value is an error, not a fallback. The property is used only when the environment variable is absent. There are no global `DB_*` settings and no default endpoint.
* Settings are read only when a database task runs, so listing or configuring the build needs no credentials.
* The URL must be a PostgreSQL JDBC URL without credentials in it. The password is used exactly as given.
* Errors name the missing settings, never their values, and nothing prints a resolved setting.
* Keep local settings in the untracked root `.env`, loaded into the process environment by mise (ADR 0010). Legacy `~/.gradle/gradle.properties` settings are a fallback only when environment variables are absent. Never put secrets in tracked files or `-P` arguments. Gradle does not read dotenv files itself.
* Gradle and jOOQ can write connection details into files under `build/`, so build directories stay ignored and are never shared.

### Tasks

| Task | What it does |
| --- | --- |
| `validateSchemaDatabase` | Checks the settings without connecting |
| `flywayInfo`, `flywayValidate` | Shows or validates this schema's migration history |
| `flywayMigrate` | Applies this schema's migrations |
| `generateJooq` | Migrates, then generates the jOOQ sources |
| `prepareSchema` | Runs the whole preparation |
| `verifyGeneratedJooq` | Checks the generated sources against the migrations, without a database |

```text
prepareSchema -> generateJooq -> flywayMigrate -> validateSchemaDatabase
flywayInfo, flywayValidate -> validateSchemaDatabase
compileJava, check -> verifyGeneratedJooq
```

* Nothing in `compileJava`, `test`, `check`, `jar`, `bootJar`, `build` or `bootRun` depends on migration or generation. `verifyGeneratedJooq` runs after `generateJooq` when both are requested, so `prepareSchema build` works.
* Database tasks read credentials at run time and refuse to run with the configuration cache, which is otherwise on ([ADR 0004](0004-gradle-version-catalog-and-convention-plugins.md)). Run them with `--no-configuration-cache`.
* Migration and generation always run when asked. They are never up to date and never come from the build cache, because the database is an input Gradle cannot see.

### Flyway

* Flyway reads only the module's migration directory, as an absolute `filesystem:` location. It works only in the service schema, as both `schemas` and `defaultSchema`, and keeps `flyway_schema_history` there.
* `createSchemas`, `outOfOrder` and `baselineOnMigrate` are off. `validateOnMigrate`, `validateMigrationNaming` and `cleanDisabled` are on.
* `flywayClean`, `flywayRepair`, `flywayBaseline` and `flywayUndo` fail. A repair or baseline needs a separate, deliberate procedure.
* Generic Flyway settings cannot redirect a task or relax this policy. The build rejects `FLYWAY_*` environment variables, `flyway.*` system and Gradle properties, Flyway config files, and `flyway.conf` files.
* The migration classpath is the `flywayMigration` configuration, which holds the PostgreSQL JDBC driver. Flyway's PostgreSQL support is on the plugin classpath (ADR 0006).

### jOOQ

* jOOQ OSS runs at the catalog's version, with the PostgreSQL meta database and the default generator. `generateSchemaSourceOnCompilation` is off and logging is at `WARN`.
* It generates only the service schema, excluding `flyway_schema_history`, into `build/generated-src/jooq/main` under `generatedPackage`.
* It generates records, POJOs, immutable POJOs and fluent setters, without index metadata or deprecated members.
* Generated sources stay untracked. Error Prone and NullAway skip them; handwritten code keeps every check.

### Generated-source state

* `build/jooq/generation-state.json` records a format version, a SHA-256 fingerprint of the generation inputs, and a sorted SHA-256 manifest of the generated Java files.
* The fingerprint covers the schema, the generated package, the jOOQ and Flyway versions, the generator settings, and every migration's path and content. It holds no timestamps, absolute paths or credentials.
* Preparation deletes the old state file before migrating and clears only its own output before generating. It writes the new state file atomically, and only after everything succeeds. A failure leaves no valid state file.
* `verifyGeneratedJooq` fails if the state file is missing or malformed, if the output is empty, or if migrations, settings, tool versions or generated files changed. The error names the `prepareSchema` task to run. It never reads credentials or connects to a database.
* The state file proves that the sources match the last local preparation, not that the database has not drifted. `flywayValidate` checks the database.

### Runtime access

* Services use R2DBC for non-blocking access and JDBC-backed jOOQ for the generated model. These are two separate access paths.
* When an R2DBC `ConnectionFactory` exists, Spring Boot backs off its JDBC `DataSource`. Its JDBC transaction manager also backs off when any transaction manager exists. So each service defines a Hikari data source bound to `app.jdbc` and a `jdbcTransactionManager`. Boot still supplies the reactive `connectionFactoryTransactionManager` and jOOQ's Spring transaction integration.
* Blocking jOOQ work runs inside `Mono.fromCallable`, subscribed on a dedicated bounded scheduler (`jdbcScheduler`), with the whole JDBC transaction inside that boundary. No code calls `.block()` on a request thread.
* Transactional code names its manager, `jdbcTransactionManager` or `connectionFactoryTransactionManager`. A JDBC transaction and an R2DBC transaction are never one atomic unit.
* Flyway and SQL initialization are off at startup. The application connects with the application role, through `CATALOG_DB_URL` for JDBC, `CATALOG_R2DBC_URL` for R2DBC, and `CATALOG_APP_DB_USER` and `CATALOG_APP_DB_PASSWORD` for both.
* The R2DBC URL is written out in full, not derived by swapping the JDBC prefix, because the two drivers' URL options differ.
* Unit tests never touch a database. They use fakes, controllable schedulers and focused contexts, not a full `@SpringBootTest` against PostgreSQL.

### Consequences

* Good, because libraries and services build and test without a database, and an ordinary build never changes one.
* Good, because each service keeps its own settings, migration history, generated sources and state, even when services share a database.
* Good, because missing or stale generated sources fail early with the exact command that fixes them.
* Bad, because a fresh checkout, a `clean` or a migration change needs database access and `prepareSchema` before consumers compile. Generated sources cannot come from git or the build cache.
* Bad, because database tasks need `--no-configuration-cache`.
* Bad, because the state file cannot detect drift in the live database.
* Open: production migration orchestration, deployment, secret managers, backups and authentication need their own decisions.

## More Information

### Commands

These are the underlying Gradle commands. Prefer the root `catalog:prepare`,
`java:build` and `catalog:dev` mise tasks for the shared environment and toolchain
described in ADR 0010. Build and startup tasks still never run preparation.

```sh
# Check the settings, inspect the history, prepare, then validate.
./gradlew :services:catalog:schema:validateSchemaDatabase --no-configuration-cache
./gradlew :services:catalog:schema:flywayInfo --no-configuration-cache
./gradlew :services:catalog:schema:prepareSchema --no-configuration-cache
./gradlew :services:catalog:schema:flywayValidate --no-configuration-cache

# After preparation, builds need no database or credentials.
./gradlew build

# Clean rebuild.
./gradlew clean
./gradlew :services:catalog:schema:prepareSchema --no-configuration-cache
./gradlew build

# Run the server. It needs the runtime settings above.
./gradlew :services:catalog:server:bootRun
```

### Adding a service

For a service named `orders`:

1. Create `services/orders/schema` and `services/orders/server`, each with a `build.gradle`. The root build discovers them (ADR 0005).
2. Apply `service-schema-conventions` in the schema module, with `schemaName = 'orders'`, `connectionKey = 'orders'` and `generatedPackage = 'com.clashofclans.eclipse.orders.jooq'`.
3. Create the `orders` schema and its two roles, and add orders-only migrations to the schema module.
4. Apply `spring-boot-server-conventions` in the server module, declare `implementation project(':services:orders:schema')`, and set its main class.
5. Supply `ORDERS_DB_*` for migration, `ORDERS_APP_DB_*` and `ORDERS_R2DBC_URL` for runtime, and set the `orders` schema in the runtime configuration.
6. Run `./gradlew :services:orders:schema:prepareSchema --no-configuration-cache`, then build.

### Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Generated jOOQ sources ... are missing or stale` | Run the module's `prepareSchema`. Never disable verification |
| `Database preparation does not support the configuration cache` | Add `--no-configuration-cache` |
| `No Flyway database plugin found` | Keep `flyway-database-postgresql` on the plugin classpath (ADR 0006) |
| Migration fails because the schema does not exist | Create the schema and its roles first. Flyway never creates them |
| Listing tasks asks for a password | A regression: settings must only be read when a database task runs |
| A plain build starts migration or generation | A regression: check the task graph above |
| No JDBC `DataSource` or `DSLContext` at runtime | Keep the explicit JDBC configuration. R2DBC makes Boot back off |

### References

* [Spring Boot SQL and R2DBC documentation](https://docs.spring.io/spring-boot/4.0/reference/data/sql.html)
* [Flyway Gradle task configuration](https://github.com/flyway/flyway/blob/flyway-11.16.0/flyway-plugins/flyway-gradle-plugin/src/main/java/org/flywaydb/gradle/task/AbstractFlywayTask.java)
* [jOOQ Gradle plugin task wiring](https://github.com/etiennestuder/gradle-jooq-plugin/blob/v10.1.1/src/main/groovy/nu/studer/gradle/jooq/JooqPlugin.java)
* [Reactor guidance for wrapping blocking calls](https://github.com/reactor/reactor-core/blob/v3.8.3/docs/modules/ROOT/pages/faq.adoc)
