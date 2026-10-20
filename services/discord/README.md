# Discord interaction service

This TypeScript service uses discord.js for Discord interactions and message
presentation. It starts independently of the Java services and PostgreSQL. Its
first commands are `/ping` and `/help`, registered to one configured server
(called a guild in Discord's API).

Java owns persistence, Clash of Clans API calls, polling, scheduled jobs and
Kafka. Internal service communication will use gRPC. Those integrations are
future work; this service does not yet call a backend or run jobs. See
[ADR 0009](../../docs/decisions/0009-discord-interaction-service.md).

## Prerequisites

- Install [mise](https://mise.jdx.dev/getting-started.html) and confirm
  `mise --version` works. Use a version that meets `min_version` in the root
  [mise.toml](../../mise.toml); mise installs the project's pinned runtimes.
- Use a Discord account that can install an application into your development
  server.

The starter bot runs without a running Java backend, PostgreSQL, Kafka or a
Clash of Clans API key.

## Run locally

### 1. Install dependencies and create the root environment file

Run commands from the repository root. Mise owns the Node.js version and provides
the development commands. Its setup task installs the pinned runtimes and tools,
including Node.js 24 and its bundled npm, then this service's locked dependencies:

```sh
mise run setup
```

`setup` depends on `discord:install`, which runs `npm ci --ignore-scripts` in
`services/discord` using the committed `package-lock.json`. It needs registry
access on a fresh checkout and replaces the service's existing `node_modules`.
Plain `mise install` installs tools, not project libraries. Dependencies remain
local to this npm package, and the Java Gradle build does not build it.

Create root `.env` once, only if it does not already exist:

```sh
cp -n .env.example .env
```

Keep existing values and add missing keys from the root template manually. There
is no separate Discord `.env`. Setup does not populate credentials, register
commands, start the bot or prepare a database.

### 2. Create the Discord application and fill in root `.env`

Fill in these three settings. PostgreSQL and catalog settings may remain empty
when running only the Discord service:

| Setting | Value |
| --- | --- |
| `DISCORD_TOKEN` | The bot token from the application's Bot page |
| `DISCORD_APPLICATION_ID` | The Application ID from General Information |
| `DISCORD_GUILD_ID` | The ID of the server used for development |

Mise loads that root file for its tasks and commands, including when invoked from
the service directory. Its values override existing process variables locally,
including blank values. All mise-launched subprocesses inherit the shared local
environment, though only this service uses the Discord settings. Keep the token
private and out of Git, screenshots and logs. Application and guild IDs remain
strings throughout the service. [ADR 0010](../../docs/decisions/0010-centralized-development-workflow.md)
records the shared configuration and CI behavior.

1. Create an application in the [Discord Developer Portal](https://discord.com/developers/applications).
2. Open **General Information** and copy the Application ID. Open **Bot** and
    generate or reset its token, then put it directly in root `.env`.
3. Under **Installation**, enable **Guild Install**. Use the `bot` and
    `applications.commands` scopes for the guild installation link, and install
    the application into your development server with an account allowed to
    manage that server.
4. Keep bot permissions minimal. The starter does not need Administrator or
    privileged gateway intents. It uses only the `Guilds` intent and does not read
    message content. Future channel notifications will need **View Channel** and
    **Send Messages** in their target channels.
5. Enable Developer Mode in Discord's settings, right-click your server and
    select **Copy Server ID** for `DISCORD_GUILD_ID`.

### 3. Register commands and start the bot

Once the application is installed in your server and root `.env` is filled in,
run these commands from the repository root:

```sh
mise run discord:register
mise run discord:dev
```

Development runs TypeScript directly and does not require a build. Wait for the
ready message in the terminal:

```text
Discord bot ready as <bot-tag>; guild <guild-id>.
```

In the configured Discord server, run `/ping` and expect
`Pong! The bot is responding.` Run `/help` to list available commands. Both
responses are visible only to the person who ran the command.

Press **Ctrl+C** to stop the bot. Watch mode restarts it after source changes.
After changing root `.env`, stop it and rerun `mise run discord:dev` so mise
loads the updated settings. On later sessions, start with just
`mise run discord:dev` unless dependencies or command definitions changed.

`discord:register` uses Discord's REST API to replace this application's entire
command set in the configured guild with the shared command registry. It can
remove commands previously registered to that guild by this same application.
Run it intentionally when adding, removing or changing command definitions; it
does not run at startup. Changes to handler code alone do not need registration.
Guild command changes are available immediately.

The registry supplies both the published command definitions and the interaction
handlers. Commands are limited to the configured guild.

## Checks and command reference

To install the locked dependencies, type-check, test and build without connecting
to Discord, run:

```sh
mise run discord:ci
```

| Root command | Package command | Purpose |
| --- | --- | --- |
| `mise run discord:install` | `npm ci --ignore-scripts` | Install the locked project dependencies |
| `mise run discord:check` | `npm run check` | Type-check the service without emitting JavaScript |
| `mise run discord:test` | `npm test` | Run the service's local tests |
| `mise run discord:build` | `npm run build` | Compile TypeScript into `dist` |
| `mise run discord:register` | `npm run register:commands` | Register the command set in the configured guild |
| `mise run discord:dev` | `npm run dev` | Run TypeScript directly on Node.js 24 |
| `mise run discord:start` | `npm start` | Run compiled JavaScript after a successful build |
| `mise run discord:ci` | Install, then check, test and build | Run all service checks without connecting to Discord |

The tasks wrap the npm scripts in `package.json` and set the working directory to
`services/discord`. They work when invoked from the root or from the service
directory; root mise configuration supplies the shared environment. The check,
test, build and runtime tasks do not install npm dependencies automatically.
`setup` and `discord:ci` depend on `discord:install`. Rerun the install task after
checking out changes to the dependency manifest or lockfile. Build before running
`discord:start`.

`discord:ci` first depends on `discord:install`, then runs type checking, tests
and compilation in sequence. The Node.js CI job installs the pinned Node.js
runtime and invokes `mise run --skip-tools discord:ci`; skipping tool installation
there avoids installing unrelated repository tools. It does not connect to
Discord or register commands. CI sets `MISE_NO_ENV=1` to use its supplied process
settings rather than loading local `.env` values.

## Run compiled JavaScript

For a local run of the compiled service, use the same root `.env` and run:

```sh
mise run discord:build
mise run discord:start
```

Rebuild after source changes before starting again. Press **Ctrl+C** to stop.
For deployment, supply the three Discord settings through the process environment
and set `MISE_NO_ENV=1` if starting through mise, so local dotenv values are not
loaded.

Development and registration use Node's native TypeScript support; no separate
TypeScript runtime loader is needed. npm scripts do not load dotenv files. When
running them directly, supply settings through the process environment or use
mise.

## Dependency updates

When adding or updating a dependency, run
`mise exec -- npm install --prefix services/discord <package>@<version>` from the
repository root, replacing the package and version placeholders. Add
`--save-dev` for development dependencies. Commit the resulting `package.json`
and `package-lock.json` changes together. Keep TypeScript and other package build
tools in `devDependencies`, so the service uses their locked project versions.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Mise reports an untrusted configuration | Review root `mise.toml`, then run `mise trust` from the repository root and retry. |
| `Missing required setting: DISCORD_...` | Fill in that setting in root `.env`, then stop and restart the mise command. |
| `Invalid setting: DISCORD_...` | Copy the numeric Application ID or Server ID, rather than an application name, server name or invite link. |
| Discord rejects the token | Use the bot token from the application's Bot page, rather than an OAuth client secret; update root `.env` and restart. |
| `/ping` or `/help` is missing | Check the application is installed in the server, the application and guild IDs match that installation, and rerun `mise run discord:register`. |
| A module or `tsc` cannot be found | Run `mise run discord:install` to restore the locked dependencies. |
| `dist/main.js` cannot be found | Run `mise run discord:build` before `mise run discord:start`. |

## Adding interactions

Add new command definitions and handlers to the shared registry, then rerun
`discord:register` if their published definitions changed. The gateway listener
handles chat-input commands through `Events.InteractionCreate`; client readiness
uses `Events.ClientReady`.

Discord requires an initial reply or deferral within three seconds. For a command
that will call Java or another slow dependency, defer as early as possible and
then edit the response. Set `MessageFlags.Ephemeral` on the initial reply or
deferral when the response should only be visible to the command's user; its
visibility cannot be changed later. Keep Discord formatting and response sending
in this service, with business operations behind the future gRPC boundary.

Interaction tokens last only 15 minutes. Java's future polling and scheduled
jobs must persist delivery work with destination IDs and pass it to this service
over gRPC for ordinary bot messages. They must not use saved interaction tokens
for later notifications. The delivery contract, retries and deduplication will
be designed with the first job feature.

## Useful links

- [discord.js command handling](https://discordjs.guide/legacy/app-creation/handling-commands)
- [discord.js guild command registration](https://discordjs.guide/legacy/app-creation/deploying-commands)
- [discord.js response methods](https://discordjs.guide/legacy/slash-commands/response-methods)
- [Discord interaction deadlines and token lifetime](https://docs.discord.com/developers/interactions/receiving-and-responding)
- [Discord application commands and installation scopes](https://docs.discord.com/developers/docs/interactions/slash-commands)
- [Discord snowflake IDs](https://docs.discord.com/developers/reference#snowflakes)
- [mise tasks for npm scripts](https://mise.jdx.dev/mise-cookbook/nodejs.html)
- [mise task configuration](https://mise.jdx.dev/tasks/task-configuration.html)
