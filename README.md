# eclipse-bot-v3

A utility bot for Reddit Eclipse, a Clash of Clans community, to assist with clan
activities using the [Clash of Clans API](https://developer.clashofclans.com).

The project is at an early stage. So far it holds the build and database
foundation and `catalog`, a small example service. The bot's own features are not
built yet.

## Stack

- Java services on Spring Boot (WebFlux), built with Gradle.
- PostgreSQL 18, with Flyway migrations and jOOQ.
- Java, Python and Node.js are the base runtimes ([ADR 0001](docs/decisions/0001-language-runtimes.md)). Only Java is used so far.
- Tools are pinned with [mise](mise.toml).

## Layout

| Path | Contents |
| --- | --- |
| [services](services) | Bot services. `catalog` has a `schema` module (migrations and generated jOOQ model) and a `server` module |
| [libraries](libraries) | Shared code |
| [tools/gradle](tools/gradle) | Gradle convention plugins |
| [docs/decisions](docs/decisions) | Architecture decision records |
| [.github](.github) | GitHub Actions workflows, pull request labeler rules and label definitions |

## Getting started

```sh
mise install                 # install pinned tools
pre-commit install           # install git hooks
cp .env.example .env         # then fill in the local database credentials
docker compose up -d --wait  # start local PostgreSQL
```

Generated jOOQ sources are not committed, so a fresh checkout needs
`./gradlew :services:catalog:schema:prepareSchema --no-configuration-cache` before
`./gradlew build`. Database tasks don't support the configuration cache.
It migrates a database where the `catalog` schema and a migration role already
exist. Pass that role's settings as the Gradle properties `catalog.db.url`,
`catalog.db.user` and `catalog.db.password`, or as the environment variables
`CATALOG_DB_URL`, `CATALOG_DB_USER` and `CATALOG_DB_PASSWORD`.

[ADR 0007](docs/decisions/0007-per-service-database-schemas.md) has the commands and the full workflow.
