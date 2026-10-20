---
status: accepted
date: 2026-10-21
decision-makers: Kanishk Gupta
---

# TypeScript and discord.js for Discord interactions

## Context and Problem Statement

The repository has a Java build and database foundation, but no Discord
interaction service. Node.js is already an approved and pinned runtime
([ADR 0001](0001-language-runtimes.md)). The bot needs to accept commands in one
Discord server initially, with Clash of Clans polling and scheduled notifications
planned for later.

Java will handle persistence, Clash of Clans API calls, Kafka and backend jobs.
The user has chosen discord.js for Discord interactions and gRPC for internal
service communication. How do we establish that boundary and start the bot
without depending on unfinished backend features?

## Considered Options

- A TypeScript discord.js service with its own npm package and root mise tasks.
- A Java service that also owns Discord interactions.
- A Node.js service that owns Discord interactions, persistence and jobs together.
- Driving the Node.js package through Gradle immediately.

## Decision Outcome

Use a TypeScript discord.js service in `services/discord`, with npm owning its
dependencies, type checking, compilation and tests. Root mise tasks orchestrate
these npm commands. The package is independent of the Java Gradle build. Run
TypeScript directly with the pinned Node.js 24 runtime for development and command
registration; compile JavaScript to `dist` for production.

This records the chosen Node.js and Java responsibilities. Python's role remains
undecided; this decision does not add or remove a runtime.

### Service responsibilities

- Node.js owns the Discord gateway connection, interaction acknowledgements,
  command routing, Discord presentation and sending messages.
- Java owns persistence, Clash of Clans API calls, polling, scheduled jobs and
  Kafka integration. The interaction service does not access PostgreSQL or call
  the Clash of Clans API directly.
- Internal service communication will use gRPC. No concrete RPCs, generated
  clients or delivery contracts are introduced by this decision. Define them
  alongside the first backend feature, using shared protobuf definitions.
- Future jobs persist durable delivery work in Java and hand it to Node.js over
  gRPC for ordinary Discord messages. Delivery retries and deduplication belong
  in that design. Interaction tokens are unsuitable for scheduled notifications
  because they expire after 15 minutes.

### Initial Discord behavior

- Start with `/ping` and `/help` in one configured guild. A shared command
  registry provides both command definitions and handlers.
- Use only `GatewayIntentBits.Guilds`. No privileged gateway intents or message
  content access are needed for these commands.
- Load `DISCORD_TOKEN`, `DISCORD_APPLICATION_ID` and `DISCORD_GUILD_ID` from the
  process environment. Mise loads the single root `.env` for local development
  ([ADR 0010](0010-centralized-development-workflow.md)); the service has no
  dotenv file or loader of its own. All local mise subprocesses inherit the
  shared settings, while Discord-specific behavior stays in this service.
  Discord IDs remain strings to preserve their 64-bit values.
- Register commands to the configured guild through the `discord:register` mise
  task, which invokes the package's registration script.
  Registration bulk-replaces this application's command set in that guild, so
  it runs only when command definitions change, never automatically at startup.
  Guild installation uses the `bot` and `applications.commands` scopes.
- Reply or defer within Discord's three-second initial-response window. Commands
  that call a backend must defer before waiting on that work. Their eventual
  results are rendered and sent by Node.js.
- The starter can run without Java services, PostgreSQL, Kafka or a Clash of
  Clans API key. Backend-backed features are subsequent work.

### Build and installation

The npm scripts expose type checking, compilation, local tests, development,
production startup and guild command registration. They remain the source of
truth for package operations. Root tasks in `mise.toml` wrap those scripts as
`discord:check`, `discord:test`, `discord:build`, `discord:dev`, `discord:start`
and `discord:register`. Each sets its directory to `services/discord`; root mise
configuration supplies the same local environment from either directory. The
Node.js version is declared only in root `mise.toml`, with npm supplied by that
runtime. Keep usage in the [service README](../../services/discord/README.md).

`mise install` installs runtimes and development tools. Project dependencies
remain declared in the service's `package.json` and locked in
`package-lock.json`. `mise run setup` installs pinned tools and depends on
`discord:install`, which runs `npm ci --ignore-scripts`. The install task can also
be run explicitly. It uses the committed dependency tree without running install
lifecycle scripts. Do not install discord.js through mise's npm tool backend,
which is intended for command-line tools, or replace the npm lockfile with tool
declarations.

Use `mise exec -- npm install --prefix services/discord <package>@<version>`
from the repository root when adding or updating a dependency. Review and commit
the manifest and lockfile changes together. Check, test, build and runtime tasks
do not install dependencies implicitly; rerun the install task when dependencies
change. No experimental mise dependency provider or installation hook is needed.

`discord:ci` depends on the install task and then runs the npm check, test and
build scripts in sequence. A separate Node.js CI job installs Node.js and invokes
`mise run --skip-tools discord:ci`, avoiding installation of unrelated repository
tools. CI sets `MISE_NO_ENV=1` so local dotenv values cannot replace injected
settings. It does not need Discord credentials or connect to Discord. Existing
Gradle build checks do not validate this service.

### Consequences

- Good, because Discord interactions can be implemented and exercised before
  backend features exist.
- Good, because Discord-specific code stays in one service, while Java owns
  business operations and durable work.
- Good, because command registration and command execution use the same registry.
- Good, because the initial setup needs only the existing Node.js runtime and
  a Discord application installed in one guild.
- Good, because mise provides commands from the repository root while npm keeps
  the package's dependency and build configuration local to the service.
- Bad, because npm adds another dependency and build workflow to maintain.
- Bad, because future notifications need a durable handoff with retries and
  deduplication across service failures.
- Open, because protobuf APIs, backend service boundaries and job scheduling
  details will be decided with the first feature that needs them.

## More Information

- [discord.js command handling](https://discordjs.guide/legacy/app-creation/handling-commands)
  and [command registration](https://discordjs.guide/legacy/app-creation/deploying-commands).
- [Discord interactions](https://docs.discord.com/developers/interactions/receiving-and-responding)
  document the initial-response deadline and interaction-token lifetime.
- [Discord application commands](https://docs.discord.com/developers/docs/interactions/slash-commands)
  document guild registration and installation scopes.
- [Discord snowflakes](https://docs.discord.com/developers/reference#snowflakes)
  explain why IDs are serialized as strings.
- [gRPC introduction](https://grpc.io/docs/what-is-grpc/introduction/)
  describes shared protobuf service definitions and cross-language clients.
- [mise's Node.js cookbook](https://mise.jdx.dev/mise-cookbook/nodejs.html)
  shows task wrappers around project npm scripts.
- [mise task configuration](https://mise.jdx.dev/tasks/task-configuration.html)
  documents task working directories and dependencies; the
  [npm backend](https://mise.jdx.dev/dev-tools/backends/npm.html) distinguishes
  CLI tools from application dependencies.
