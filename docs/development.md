# Development

This is the shared guide for setting up the repository, configuring local
services, and running checks. The [Discord service README](../services/discord/README.md)
covers Discord application setup and interaction development. Architecture and
design rationale live in [the decisions directory](decisions).

## Prerequisites

- Git and a checkout of this repository.
- [Mise](https://mise.jdx.dev/getting-started.html), meeting `min_version` in
  [mise.toml](../mise.toml). It installs the pinned runtimes and development tools;
  separate Java or Node.js installations are unnecessary.
- Docker with Docker Compose for catalog and guild-schema development. The
  Discord service runs independently of PostgreSQL and the Java backend.
- For Discord development, an account allowed to install an application into a
  development server. See the [service guide](../services/discord/README.md).

## Getting started

Run commands from the repository root. Review the checked-out `mise.toml` and,
if mise reports it as untrusted, run `mise trust`. Install the pinned tools and
locked project dependencies:

```sh
mise run setup
```

Setup installs the runtimes and tools, then runs `discord:install`
(`npm ci --ignore-scripts` in `services/discord`). This requires registry access
on a fresh checkout and replaces that package's existing `node_modules`.
Plain `mise install` installs tools, not project libraries. Setup does not start
services, register Discord commands, prepare a database, or populate credentials.

Create the root configuration file only if it does not already exist:

```sh
cp -n .env.example .env
```

Preserve an existing `.env` and add missing keys from [.env.example](../.env.example)
manually. Fill in only the settings for the services you use. Do not create
service-local environment files or commit credentials.

Optionally install the local Git hooks:

```sh
mise exec -- pre-commit install
```

Continue with [catalog](#catalog-service), the [guild schema](#guild-schema)
or [Discord](#discord-service).

## Local configuration

Mise loads the single root `.env` for its tasks and commands, including commands
invoked from service directories. Task working directories are anchored to the
repository root. All mise-launched subprocesses inherit this local environment.

Local `.env` values override existing process variables, including when blank.
For database preparation, a present per-service environment variable also wins
over its matching legacy Gradle property. A blank supplied variable fails
validation; it does not fall back to the property. Properties are used only
when the corresponding environment variable is absent. Keep passwords and
connection values out of logs.

After changing `.env`, stop and restart the affected development process to
load the updated settings. npm scripts do not load dotenv files themselves;
when invoking them directly, provide the process environment or run through mise.

CI sets `MISE_NO_ENV=1` to disable the local dotenv loader and use injected
settings. Jobs install their required tools and invoke shared tasks with
`--skip-tools` to avoid installing unrelated tooling. Production runs compiled
artifacts with configuration supplied through the process environment.

## Catalog service

### Configure and start PostgreSQL

Fill in these root `.env` settings using local development credentials:

| Settings | Purpose |
| --- | --- |
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | Compose database administrator and database |
| `POSTGRES_PORT` | Local port; use `5432` unless another local database occupies it |
| `CATALOG_DB_URL` | PostgreSQL JDBC URL, for example `jdbc:postgresql://localhost:5432/eclipse_bot` |
| `CATALOG_DB_USER`, `CATALOG_DB_PASSWORD` | Migration role and its password |
| `CATALOG_R2DBC_URL` | Runtime reactive URL, for example `r2dbc:postgresql://localhost:5432/eclipse_bot` |
| `CATALOG_APP_DB_USER`, `CATALOG_APP_DB_PASSWORD` | Application role and its password |

Use your chosen database name and port in both URLs. Keep migration and
application credentials separate. The JDBC URL must not contain credentials.
Write out the R2DBC URL explicitly rather than deriving it from the JDBC URL.

```sh
mise run db:up
```

Compose starts PostgreSQL and waits for readiness. Its volume preserves data
between runs. On an existing volume, changing `POSTGRES_*` in `.env` does not
rename the initialized database or change existing database passwords.

### Provision the catalog schema once

Gradle and Flyway do not create database roles or the service schema. For a new
local database, open an administrator session:

```sh
docker compose exec postgres sh -c 'exec psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1'
```

The following example uses `catalog_migration` and `catalog_application` as the
role names. Set the matching `CATALOG_DB_USER` and `CATALOG_APP_DB_USER` values in
`.env`. At each `\password` prompt, enter the password from the corresponding
`.env` setting. Run this only when these roles and the schema do not yet exist;
preserve an existing provisioned schema and its data.

```sql
CREATE ROLE catalog_migration LOGIN;
\password catalog_migration
CREATE ROLE catalog_application LOGIN;
\password catalog_application
CREATE SCHEMA catalog AUTHORIZATION catalog_migration;
GRANT USAGE ON SCHEMA catalog TO catalog_application;
ALTER DEFAULT PRIVILEGES FOR ROLE catalog_migration IN SCHEMA catalog
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO catalog_application;
ALTER DEFAULT PRIVILEGES FOR ROLE catalog_migration IN SCHEMA catalog
  GRANT USAGE, SELECT ON SEQUENCES TO catalog_application;
\q
```

These default privileges apply to tables and sequences subsequently created by
the migration role. If catalog tables already exist, have their owner provision
the application role's grants on those existing objects as well.

### Start the service

```sh
mise run catalog:dev
```

The Gradle launcher validates the migration settings and applies pending Flyway
migrations, checks required tables, generates jOOQ sources, compiles, and starts
Spring Boot. Existing tables and data are preserved. Applied migrations are not
replayed. Inconsistent history or a missing table from an applied migration
causes startup to fail rather than recreate the table. Press **Ctrl+C** to stop.

The task includes `--no-configuration-cache`, which database preparation
requires. If calling Gradle directly, use:

```sh
./gradlew :services:catalog:server:bootRun --no-configuration-cache
```

Direct IDE main-class launches and packaged JARs do not invoke these Gradle
tasks. They require an already-prepared database and compiled generated model.
Configure the IDE to use the Gradle launcher for automatic preparation.

To inspect and validate migration history without changing tables:

```sh
mise exec -- ./gradlew :services:catalog:schema:flywayInfo :services:catalog:schema:flywayValidate --no-configuration-cache
```

To stop PostgreSQL while retaining its data:

```sh
mise run db:down
```

### Build and test Java

Ordinary Java builds and tests do not connect to or migrate a database.
Generated jOOQ sources are untracked, so a fresh checkout, a clean, or a migration
change needs explicit preparation before a build. The full-root build needs
both schemas prepared; each schema module verifies its own generated sources:

```sh
mise run catalog:prepare
mise run guild:prepare
mise run java:build
mise run java:conventions:check
```

After preparation, builds need neither a running database nor migration
credentials. Do not bypass generated-source verification when it reports
missing or stale output.

## Guild schema

The guild schema has no server module yet. Its migrations, SQL checks and
generated jOOQ model live in `services/guild/schema`. The
[guild schema guide](../services/guild/schema/README.md) describes the
migrations, the setup commands and the remaining policy decisions.

Set `GUILD_DB_URL`, `GUILD_DB_USER`, `GUILD_DB_PASSWORD`, `GUILD_APP_DB_USER`
and `GUILD_APP_DB_PASSWORD` in the existing root `.env`. Use different
migration and application roles. As the database administrator, create the
schema and its roles with
[bootstrap-guild.sql](../tools/postgres/bootstrap-guild.sql); the guild schema
guide has the command. Then prepare the schema:

```sh
mise run guild:prepare
```

Run the SQL checks only against an empty, disposable migrated database:

```sh
mise run guild:test
```

The SQL fixtures roll back. Ordinary builds never migrate or test a database.

## Discord service

After [shared setup](#getting-started), follow the
[Discord service README](../services/discord/README.md#run-locally) to create an
application, fill in its three settings, install it into a guild, register
commands, and start it. PostgreSQL and catalog settings can remain empty for
Discord-only development. No Clash of Clans API key or Kafka instance is needed.

The service guide owns the Discord-specific instructions, including permissions,
command registration behavior, watch mode, and troubleshooting. To run its
checks without a Discord connection or credentials, use `mise run discord:ci`.
That task installs dependencies, type-checks, tests, and builds; it does not
register commands or connect to Discord.

## Command reference

| Command | Purpose |
| --- | --- |
| `mise run setup` | Install pinned tools and locked project dependencies |
| `mise run db:up` | Start PostgreSQL and wait for readiness |
| `mise run db:down` | Stop PostgreSQL while retaining its data |
| `mise run catalog:prepare` | Explicitly migrate, check required tables, and generate jOOQ sources |
| `mise run catalog:dev` | Prepare the catalog schema, compile, and start the service |
| `mise run guild:prepare` | Explicitly migrate, check required tables, and generate jOOQ sources for the guild schema |
| `mise run guild:test` | Run transactional SQL assertions against the prepared guild schema |
| `mise run java:build` | Build and test Java modules using prepared sources |
| `mise run java:conventions:check` | Check Gradle convention plugins |
| `mise run discord:install` | Install locked npm dependencies with `npm ci --ignore-scripts` |
| `mise run discord:check` | Type-check the Discord service |
| `mise run discord:test` | Run Discord service tests |
| `mise run discord:build` | Compile Discord TypeScript into `dist` |
| `mise run discord:register` | Replace this application's commands in the configured guild |
| `mise run discord:dev` | Run Discord TypeScript in watch mode |
| `mise run discord:start` | Run compiled Discord JavaScript after building |
| `mise run discord:ci` | Install dependencies, type-check, test, and build |

Mise wraps the native Gradle and npm commands. npm scripts in
[package.json](../services/discord/package.json) remain the source of truth for
Discord package commands, and the Java build does not build the Discord package.
Ordinary Discord check, test, build, and runtime tasks do not install npm
dependencies automatically; rerun `discord:install` after dependency changes.

## Dependency updates

Application libraries belong to their build tool, not mise's tool list. For a
Discord npm dependency, run this from the repository root, substituting the
package and version:

```sh
mise exec -- npm install --prefix services/discord <package>@<version>
```

Add `--save-dev` for a development dependency. Commit `package.json` and
`package-lock.json` together. Java dependency versions are centralized in
[gradle/libs.versions.toml](../gradle/libs.versions.toml).

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Mise reports untrusted configuration | Review `mise.toml`, then run `mise trust` and retry |
| A Discord module or `tsc` cannot be found | Run `mise run discord:install` |
| Generated jOOQ sources are missing or stale | Configure the database and run `mise run catalog:prepare` or `mise run guild:prepare` |
| Database preparation rejects the configuration cache | Use the mise task or add `--no-configuration-cache` to the Gradle invocation |
| A blank setting overrides an exported value | Fill in or remove the blank root `.env` entry; restart the process |
| The catalog schema or migration role does not exist | Provision them before running preparation |
| Required tables are missing after migration | Inspect the selected database and Flyway history; restore or correct the schema deliberately instead of replaying applied migrations |
| Runtime database access is denied | Check the separate application credentials, schema usage, and table/sequence grants |
| Flyway reports no PostgreSQL database plugin | Keep `flyway-database-postgresql` on the convention-plugin classpath, as described in ADR 0006 |
| Listing Gradle tasks asks for database credentials | Treat this as a regression: settings should be resolved only when a database task executes |
| An ordinary build starts migrations or code generation | Treat this as a regression: preparation should be selected only explicitly or through service startup |
| No JDBC `DataSource` or jOOQ `DSLContext` exists at runtime | Retain the explicit JDBC configuration; R2DBC causes Spring Boot's JDBC auto-configuration to back off |

For Discord token, command, and installation issues, see the
[service troubleshooting guide](../services/discord/README.md#troubleshooting).
The database design and startup guarantees are recorded in
[ADR 0007](decisions/0007-per-service-database-schemas.md),
[ADR 0010](decisions/0010-centralized-development-workflow.md), and
[ADR 0011](decisions/0011-schema-preparation-before-development-startup.md).
