# eclipse-bot-v3

A utility bot for Reddit Eclipse, a Clash of Clans community, to assist with clan
activities using the [Clash of Clans API](https://developer.clashofclans.com).

The project is at an early stage. It holds the Java build and database
foundation, `catalog` (a small example service), and a Discord interaction
service with `/ping` and `/help`. Clash of Clans utilities and background jobs
will be added to the Java backend.

## Stack

- Java services on Spring Boot (WebFlux), built with Gradle.
- TypeScript and discord.js for Discord interactions, built with npm.
- PostgreSQL 18, with Flyway migrations and jOOQ.
- Java, Python and Node.js are the base runtimes ([ADR 0001](docs/decisions/0001-language-runtimes.md)). Java and Node.js are used so far.
- Tools and development commands are managed with [mise](mise.toml).

## Layout

| Path | Contents |
| --- | --- |
| [services/discord](services/discord) | Discord interaction service; [setup and commands](services/discord/README.md) |
| [services/catalog](services/catalog) | Example Java service with `schema` (migrations and generated jOOQ model) and `server` modules |
| [libraries](libraries) | Shared code |
| [tools/gradle](tools/gradle) | Gradle convention plugins |
| [docs/decisions](docs/decisions) | Architecture decision records |
| [.github](.github) | GitHub Actions workflows (CI, PR title, labels), Dependabot and labeler configuration |

## Getting started

Run commands from the repository root. Install the pinned tools and the Discord
service's locked npm dependencies with one setup task:

```sh
mise run setup
```

Optionally run `mise exec -- pre-commit install` to install the Git hooks.
Setup installs dependencies; it does not start services, register Discord
commands or prepare a database.

Create the single local configuration file once, only if root `.env` does not
already exist:

```sh
cp -n .env.example .env
```

Fill in only the settings needed for the service you want to run. Keep an
existing `.env` and add missing keys from [.env.example](.env.example) manually;
do not replace it with the template. The root file holds PostgreSQL, Discord,
and catalog migration/runtime settings. There is no service-local `.env`.

Mise loads root `.env` for its tasks and commands, including from subdirectories.
Its values replace existing process variables locally, even when blank. All
mise-launched subprocesses inherit these values. Keep real credentials out of
Git and logs. CI supplies its own settings and disables this loader.

To register and run `/ping` and `/help`, fill in `DISCORD_TOKEN`,
`DISCORD_APPLICATION_ID` and `DISCORD_GUILD_ID`, then follow the Discord
[setup guide](services/discord/README.md). It runs independently of Java and
PostgreSQL.

| Command | Purpose |
| --- | --- |
| `mise run setup` | Install pinned tools and locked npm dependencies |
| `mise run discord:install` | Reinstall the service's locked npm dependencies |
| `mise run discord:ci` | Install, type-check, test and build the Discord service |
| `mise run discord:register` | Replace this application's commands in the configured guild |
| `mise run discord:dev` | Run the Discord service in watch mode |
| `mise run db:up` | Start PostgreSQL and wait for readiness |
| `mise run db:down` | Stop PostgreSQL while retaining its data |
| `mise run catalog:prepare` | Explicitly migrate the catalog schema and generate jOOQ sources |
| `mise run java:build` | Build and test Java modules using prepared sources |
| `mise run java:conventions:check` | Check the Gradle convention plugins |
| `mise run catalog:dev` | Start the catalog service using its runtime settings |

For catalog development, fill in the PostgreSQL and catalog settings, start the
database, and create the catalog schema and its migration/application roles
outside Gradle. Then run `mise run catalog:prepare` before `mise run java:build`
or `mise run catalog:dev`. Generated jOOQ sources are not committed, so a fresh
checkout, a clean or a migration change needs this explicit preparation.
Builds and startup never run migrations. The preparation task includes
`--no-configuration-cache` because database tasks do not support that cache.

Catalog migration settings use `CATALOG_DB_URL`, `CATALOG_DB_USER` and
`CATALOG_DB_PASSWORD`. A supplied environment value takes precedence over a
legacy Gradle property, even when blank; properties are a fallback only when
the variable is absent. Runtime uses the JDBC URL plus `CATALOG_R2DBC_URL`,
`CATALOG_APP_DB_USER` and `CATALOG_APP_DB_PASSWORD`.

[ADR 0007](docs/decisions/0007-per-service-database-schemas.md) describes database
preparation. [ADR 0010](docs/decisions/0010-centralized-development-workflow.md)
records the shared development workflow and configuration precedence.
