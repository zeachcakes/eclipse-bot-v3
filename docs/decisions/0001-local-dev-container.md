---
status: accepted
date: 2026-09-04
---

# Develop in a local dev container on Docker Desktop

## Context and Problem Statement

`eclipse-bot-v3` is starting fresh: the repo holds only a README, a licence, and
project notes, and no language, framework, or datastore has been chosen. The
development machine is equally bare — no language runtime, no version manager,
and no container CLI on `PATH`.

Something has to provision a development environment before any code can be
written, and that choice should not quietly settle the stack question along with
it. It should also not have to be redone if this project ever moves to a hosted
environment.

## Considered Options

### Approach

* **Dev container spec (`devcontainer.json`)** — one declarative config, consumed
  identically by local tooling and by GitHub Codespaces.
* **Host-native toolchain** — install a runtime and a version manager directly on
  the machine. Rejected: reproducible only by written instructions, and it puts
  project tooling into the user's global environment.
* **Nix / devenv / devbox / mise** — genuinely reproducible without containers.
  Rejected: steep ramp-up, and no path to a hosted environment. This rejection is
  about replacing the container, and still stands. `mise` is nevertheless used
  *inside* the image to manage project runtimes; that is a different role and not
  a reversal of this option.
* **Plain `docker compose` + `docker compose exec`** — containers without the
  spec. Rejected: gives up Features, lifecycle hooks, and editor integration, and
  is not what a hosted environment would consume.

### Runtime

* **Docker Desktop** — the most-trodden path for dev containers and Compose;
  already installed on the machine; free under its personal-use terms.
* **OrbStack** — meaningfully lighter (roughly 4.5× less idle RAM) and faster to
  start. Rejected only on familiarity and licence simplicity, not on merit.
* **Colima** — lightest of the three and fully open source. Rejected: CLI-only,
  and needs more manual wiring to work with the editor extension.
* **Podman Desktop** — rootless and fully open source. Rejected: Compose and
  user-namespace handling still have rough edges under the dev container tooling.

### Client

* **VS Code Dev Containers extension _and_ the `devcontainer` CLI** — the
  extension for "Reopen in Container", the CLI so the same config can be driven
  headlessly from a terminal or from CI.
* **Extension only** — rejected: no headless path.
* **CLI only** — rejected: loses "Reopen in Container" and port-forwarding UI.
* **DevPod** — would add a provider abstraction for running the same config on a
  remote machine. Rejected: upstream has been stalled since v0.6.15 (March 2025),
  and the abstraction solves a problem this project does not have.
* **Coder / Gitpod, self-hosted** — rejected: requires a server to operate; far
  past the scale of this project.

### Composition

* **Docker Compose (`dockerComposeFile`)** — the image is defined in
  `docker-compose.yaml` rather than in `devcontainer.json`.
* **Single container (`image` in `devcontainer.json`)** — simpler today, since
  there is exactly one service. Rejected: switching to Compose later changes
  `workspaceFolder` and mount semantics at the same time, and that is a more
  disruptive edit than starting with Compose and adding a service.

### Scope

* **Stack-agnostic** — the container provides a shell, `git`, `gh`, and Claude
  Code, and nothing that presumes a language or datastore.
* **Pin a runtime and a database** — rejected: fastest to a working environment,
  but a dev container that ships a specific runtime and database settles the
  stack question by default rather than on its merits.
* **Pin a runtime only** — rejected for the same reason, to a lesser degree.

## Decision Outcome

Develop inside a dev container defined by `.devcontainer/devcontainer.json` and
`.devcontainer/docker-compose.yaml`, running on Docker Desktop, opened either
through the VS Code Dev Containers extension or the `devcontainer` CLI.

The container is deliberately stack-agnostic. It is composed with Docker Compose
even though it currently has a single service, so that the stack decision — when
it is made — is additive.

### Consequences

* Good, because the environment is reproducible from the repo, and nothing about
  the toolchain depends on what happens to be installed on the host. This is the
  primary benefit and is deliberately absolute: the host runs no project runtime
  and no version manager. `mise` is installed in the image, not on the Mac, so
  `mise.toml` is inert on the host and no host/container config split is needed.
* Good, because the stack is undecided and a container makes that cheap to change:
  trying a runtime and abandoning it costs a rebuild rather than accumulated cruft
  on the host.
* Good, because development happens on the same Linux the bot will deploy to.
  macOS is case-insensitive by default, so an entire class of "works locally,
  breaks in production" bug is ruled out up front.
* Good, because it bounds what an autonomous agent with shell access can reach.
  Claude Code runs against this repo, and inside the container it cannot see the
  host's SSH keys, documents, or browser profiles.
* Revisit if the bot turns out to be stateless, or to need no more than SQLite. The
  datastore argument is doing real work in this decision; without it, host-native
  `mise` alone would be the lighter option.
* The same config is what GitHub Codespaces consumes, so it stays compatible at
  no cost. This is a property, **not a design driver**: hosted development is not
  planned, and the config should not be shaped around it. Prebuilds in particular
  are declined — they consume Actions minutes *and* storage on top of the GitHub
  Free allowance (120 core-hours / 15 GB-month), and buy nothing locally, where
  `devcontainer up` runs every lifecycle hook back-to-back and `devcontainer build`
  has no lifecycle options at all. The project therefore uses a single
  `postCreateCommand` and leaves `onCreateCommand` / `updateContentCommand` unused.
* Reinforcing the above: Clash of Clans API keys from `developer.clashofclans.com`
  are bound to an IP address, so a cloud development environment would break the
  key outright. Worth confirming when the key is first registered.
* Good, because adding a database is a new service in an existing Compose file
  rather than a restructuring of the dev container.
* **Node.js is present in the image as a dependency of the Claude Code feature,
  not as a stack decision.** Nothing about this ADR chooses a language for the
  project. It is pinned to `lts` only because the feature otherwise installs
  Node 18, which is past end-of-life.
* Bad, because Docker Desktop has the heaviest idle footprint of the runtimes
  considered. Switching is cheap if that becomes annoying — `docker context` and
  the `dev.containers.dockerPath` setting make every alternative drop-in — so
  this is reversible without touching the committed config.
* Docker Desktop's licence is free for personal use only. If this project ever
  stops being personal, the runtime choice has to be revisited.
* A named volume is not part of any image layer, and is not captured in a
  Codespaces prebuild snapshot either. The `chown` of the `claude-config` and
  `mise-data` volumes therefore has to stay in `postCreateCommand`: baking it into
  the image or moving it to `onCreateCommand` for a prebuild saving would leave a
  fresh, root-owned volume and no remaining hook to fix it. This is the same
  "works locally, fails hosted" shape as the `ports:` trap below.
* Runtimes pinned in `mise.toml` are installed at container creation rather than
  at image build, because **the workspace is not mounted while Features install** —
  nothing during the build can read `mise.toml`. Baking them in would mean a
  Dockerfile that `COPY`s the file and a move from `image:` to `build:` in
  `docker-compose.yaml`; installing at creation and caching the result in the
  `mise-data` volume gets the same practical effect without that restructuring.
  Two supporting details are easy to miss: a bind-mounted config is untrusted, so
  `mise install` needs `MISE_TRUSTED_CONFIG_PATHS` to avoid a prompt it cannot
  answer; and the mise Feature adds no shell activation, so the shims directory is
  put on `PATH` explicitly via `remoteEnv`.
* Two traps apply when a database service is eventually added, both of which
  cost real debugging time if hit:
  * the service needs a `pg_isready` (or equivalent) healthcheck and a
    `depends_on: { condition: service_healthy }` from `app`, or the application
    container will race the database on startup;
  * a `ports:` entry in `docker-compose.yaml` **does not forward from a
    Codespace**. Port forwarding belongs in `forwardPorts` in
    `devcontainer.json`. Getting this wrong works locally and fails only in a
    hosted environment — precisely the parity this decision exists to protect.
* The repo name is spelled out in both `docker-compose.yaml` and
  `devcontainer.json`, because `${localWorkspaceFolderBasename}` is a
  `devcontainer.json` variable and Compose does not interpolate it. Renaming the
  repository means editing both files.
