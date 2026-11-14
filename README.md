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
| [services/discord](services/discord) | Discord interaction service |
| [services/catalog](services/catalog) | Example Java service with `schema` (migrations and generated jOOQ model) and `server` modules |
| [services/guild/schema](services/guild/schema) | Guild persistence: CoC and Discord star-schema SQL migrations, configuration, and SQL regression checks; [design](docs/design/guild-star-schema.md) and [ER diagrams](docs/design/guild-er-diagram.md) |
| [libraries](libraries) | Shared code |
| [tools/gradle](tools/gradle) | Gradle convention plugins |
| [docs/development.md](docs/development.md) | Shared development guide |
| [docs/decisions](docs/decisions) | Architecture decision records |
| [docs/feature-specs](docs/feature-specs/README.md) | Agreed feature requirements for future GitHub issues |
| [.github](.github) | GitHub Actions workflows (CI, PR title, labels), Dependabot and labeler configuration |

## Repository instructions

[AGENTS.md](AGENTS.md) contains the shared GitHub commit strategy for Codex and
Claude. [CLAUDE.md](CLAUDE.md) imports those instructions for Claude.
