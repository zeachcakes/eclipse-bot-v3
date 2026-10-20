---
status: accepted
date: 2026-10-21
decision-makers: Kanishk Gupta
---

# Centralized development commands and local configuration

## Context and Problem Statement

The repository combines Java services, a TypeScript Discord service and local
PostgreSQL. Their build tools have different working directories, and separate
dotenv files would duplicate local configuration. Developers need one setup
entry point and one local environment file without duplicating dependency
versions or changing the explicit database-preparation policy.

This decision supersedes the local configuration and environment-precedence
parts of [ADR 0007](0007-per-service-database-schemas.md), adds helper tests to the
convention build described in [ADR 0006](0006-layered-convention-plugins.md), and
updates the command entry points used by
[ADR 0008](0008-continuous-integration-and-repository-automation.md).

## Considered Options

- Root mise tasks around the existing npm, Gradle and Compose commands, with one
  root `.env` loaded by mise.
- Separate setup commands and dotenv files for each service.
- Declare application libraries as mise npm tools instead of npm dependencies.
- Enable the experimental mise dependency provider or install dependencies from
  runtime installation hooks.

## Decision Outcome

Use root `mise.toml` as the entry point for development setup and commands. Mise
orchestrates the existing build tools; npm and Gradle retain their native
dependency and build configuration. No experimental dependency provider or
installation hook is needed.

### Sources of configuration

| File | Owns |
| --- | --- |
| `mise.toml` | Runtime/tool versions, development tasks and local dotenv loading |
| `mise.lock` | Resolved tool versions and download verification data |
| `services/discord/package.json` | Project library requirements and npm scripts |
| `services/discord/package-lock.json` | Resolved npm dependency tree |
| `.env` | Untracked local PostgreSQL, Discord and catalog settings |
| `.env.example` | Shared setting names and blank placeholders |

Node.js is pinned only in `mise.toml`; npm comes with that runtime. The Discord
package does not repeat the Node.js pin in `engines`. Application libraries and
TypeScript remain project-local npm dependencies. The mise npm backend is for
CLI tools, so it does not replace the application manifest or npm lockfile.

When adding or updating a package, run
`mise exec -- npm install --prefix services/discord <package>@<version>` from the
repository root, adding `--save-dev` for a development dependency. Review and
commit the manifest and lockfile changes together.

### Setup and tasks

Set `task.run_auto_install = true` explicitly. Before running tasks, mise installs
configured tools that are missing. `mise run setup` is a dependency-only task
that depends on `discord:install`, so it installs pinned tools and then runs
`npm ci --ignore-scripts` once for the Discord package. Plain `mise install`
installs tools but does not install project libraries.

Setup does not create credentials, register Discord commands, start services or
prepare a database. Installing Git hooks remains optional with
`mise exec -- pre-commit install`.

| Task | Underlying operation |
| --- | --- |
| `discord:install` | `npm ci --ignore-scripts` in the Discord package |
| `discord:check`, `discord:test`, `discord:build` | The package's check, test and build scripts |
| `discord:dev`, `discord:start`, `discord:register` | The package's development, production and registration scripts |
| `discord:ci` | Depend on install, then run check, test and build in sequence |
| `java:build` | `./gradlew build` |
| `java:conventions:check` | The included convention-plugin build's check task |
| `catalog:prepare` | Explicit catalog preparation with `--no-configuration-cache` |
| `catalog:dev` | The catalog server's `bootRun` task |
| `db:up`, `db:down` | Start PostgreSQL with a readiness wait, or stop it while retaining data |

Task directories are anchored to `config_root`, so invoking them from a service
directory behaves the same as invoking them from the repository root. npm
scripts remain the source of truth for package commands. Ordinary Discord
check, test, build and runtime tasks do not depend on installation; rerun
`discord:install` after dependency changes. `setup` and `discord:ci` explicitly
depend on installation.

Java builds and catalog startup never depend on `catalog:prepare`. Schema and
role creation still happen outside Gradle. A fresh checkout, clean or migration
change requires deliberate preparation before a consumer can compile, preserving
ADR 0007's separation between database changes and ordinary builds.

### One local environment file

Keep one untracked root `.env` and one root `.env.example`. Initialize `.env`
only if it does not exist, for example with `cp -n .env.example .env`. Existing
files are preserved; add missing setting names manually. Do not copy a template
over existing credentials or create service-local dotenv files.

The root configuration loads it with:

```toml
[env]
_.file = { path = "{% if env.MISE_NO_ENV | default(value='0') != '1' %}.env{% endif %}", redact = true }
```

Locally the directive resolves to `.env`. Mise anchors that path to the root
config and skips a missing file. When `MISE_NO_ENV=1`, the directive resolves to
an empty path and loads no file. The guard is deliberate: the pinned mise
2026.9.12 honors `no_env` for `exec` but does not reliably honor it while building
a task's environment. Keep the explicit guard so CI task execution also skips
dotenv loading.

Node.js scripts no longer load dotenv files themselves. Applications read their process
environment, and Compose continues to use the same root `.env`. Local
mise-launched commands and activated shells receive the shared values; this is
not per-service secret isolation. Do not print or commit those values.

Mise dotenv values replace existing process variables, including blank values.
For Java migration settings, an environment variable that is present takes
precedence over the matching legacy Gradle property. A blank environment value
is validated as supplied and cannot fall back to a property. The property is a
compatibility fallback only when that environment variable is absent.

The convention-plugin build now has Jupiter unit tests for database-setting
resolution, covering precedence, missing and blank values, and credential-safe
errors. They exercise the helper without connecting to a database. Consumer
builds still exercise the convention-plugin wiring.

The root template includes PostgreSQL container settings, Discord application
settings, catalog migration credentials and separate catalog runtime
credentials. Commands validate only the settings they consume; a Discord-only
developer need not configure a database to run the bot.

### CI and production

CI sets `MISE_NO_ENV=1`; the guarded directive above disables local dotenv
loading and preserves the settings it injects. Each job installs only its needed
tools with `jdx/mise-action`, then invokes shared tasks with `--skip-tools` so the
task runner does not install unrelated root tools.

The Java job still creates an isolated PostgreSQL database and migration role,
then runs `catalog:prepare`, `java:build` and `java:conventions:check`. Its
temporary Compose configuration is generated for that job. The Node.js job runs
`discord:ci` without Discord credentials or live command registration.

Production supplies configuration in the process environment and runs compiled
artifacts. A local `.env` is not a deployment credential source.

### Consequences

- Good, because one setup command installs the toolchain and npm dependencies.
- Good, because root tasks behave consistently across working directories and
  CI while each build tool retains its own dependency records.
- Good, because local configuration has one file and database preparation stays
  an explicit operation.
- Bad, because all local mise subprocesses inherit the shared environment.
- Bad, because a present but blank local variable can override an exported value
  or a legacy Gradle property, so precedence must be explicit.
- Bad, because task wrappers must stay aligned with the package scripts and
  underlying build commands.

## More Information

- [Mise's Node.js cookbook](https://mise.jdx.dev/mise-cookbook/nodejs.html)
  demonstrates wrapping project npm scripts in tasks.
- [Task configuration](https://mise.jdx.dev/tasks/task-configuration.html)
  documents working directories and task dependencies.
- [Mise environments](https://mise.jdx.dev/environments/)
  documents root-relative dotenv loading and environment precedence.
- [The `no_env` setting](https://mise.jdx.dev/configuration/settings.html#no_env)
  describes disabling config environment loading; the explicit directive guard
  above handles the pinned version's task behavior.
- [The npm backend](https://mise.jdx.dev/dev-tools/backends/npm.html)
  distinguishes CLI tool installation from application dependencies.
