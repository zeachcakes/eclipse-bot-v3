---
status: accepted
date: 2026-09-23
decision-makers: Kanishk Gupta
---

# PostgreSQL as the datastore, run locally with Docker Compose

## Context and Problem Statement

[ADR 0001](0001-language-runtimes.md) and [ADR 0002](0002-gradle-build-tool.md) leave the datastore open. The bot needs one to store clan and player data that it fetches from the Clash of Clans API. Which database do we use, and how does a developer run it locally without installing it on the host?

## Decision Outcome

Use PostgreSQL 18. For local development, run the official `postgres` image with Docker Compose:

* `compose.yaml` at the repository root defines one `postgres` service.
* The image is `postgres:18.6-trixie`, pinned by tag and by the digest of its multi-arch index, so every developer pulls the same bytes. Update the tag and the digest together.
* Credentials, database name and host port come from `.env`, which git ignores. `.env.example` holds the development defaults.
* The port binds to `127.0.0.1` only.
* Data lives in the named volume `postgres-data`, mounted at `/var/lib/postgresql`. PostgreSQL 18 images keep data in a version-specific directory under that path, which lets a later major upgrade use `pg_upgrade --link`.
* Docker is a host prerequisite, like mise. It is not pinned in `mise.toml`, because it is not a language runtime or a CLI tool that mise manages.

### Consequences

* Good, because no developer installs PostgreSQL on the host, and everyone runs the same version.
* Good, because `docker compose down -v` gives a clean database in one command.
* Good, because the Debian (`trixie`) image uses glibc collations, the same as most production hosts and managed PostgreSQL services.
* Bad, because local development needs a running Docker daemon.
* Open: this ADR does not choose a migration tool, a database access library, how tests get a database (for example Testcontainers), or where production PostgreSQL runs. Record those in later ADRs.
