---
status: accepted
date: 2026-09-23
---

# Manage project tools with mise inside the dev container

## Context and Problem Statement

ADR 0001 puts development inside a stack-agnostic dev container so that nothing
about the toolchain depends on the host. Something still has to install and pin
the tools the project uses — dev CLIs now, language runtimes once the stack is
chosen — and keep them in step with the repo.

The requirement is that tools are (re)installed whenever any of these change:

* `devcontainer.json`, the Dockerfile, or `docker-compose.yaml`;
* the version of the tool manager itself;
* `mise.toml`, whether a version is bumped or a tool is added or removed.

The config was first modelled on a GitHub Codespaces template, which is broader
than this project needs. Hosted development is not planned, so Codespaces-only
machinery should not shape the design.

## Considered Options

### Where mise runs

* **Inside the container only** — `mise.toml` is inert on the host, so there is
  no host/container config split.
* **On the host as well** — rejected: it puts a version manager on the Mac, which
  is exactly what ADR 0001 exists to avoid.

### How mise gets into the image

* **Official image, `COPY --from=ghcr.io/jdx/mise:<tag>@sha256:<digest>`** in a
  small Dockerfile — first-party, pinned by digest, and the same Dockerfile can
  create the volume mount points with the right owner.
* **`ghcr.io/devcontainers-extra/features/mise`** — what `mise generate
  devcontainer` emits, with the version pinnable in `devcontainer.json`.
  Rejected: community-maintained, installs through `nanolayer` and a second
  `gh-release` Feature, and still needs a `sudo chown` hook for the volume.
* **`ghcr.io/jsburckhardt/devcontainer-features/mise`** — used in an earlier
  attempt. Rejected: it downloads the binary with no checksum verification.

### When tools are installed

* **`postStartCommand: mise install`** — runs on every start, including the first
  start after any rebuild.
* **Bake tools into the image** (`COPY mise.toml` + `RUN mise install`) —
  rejected: an edit to `mise.toml` would then need a full image rebuild, and
  VS Code does not prompt for one because it does not watch `mise.toml`.
* **Prebuild hooks (`onCreateCommand`, `updateContentCommand`)** — rejected. They
  exist for Codespaces prebuilds, which consume Actions minutes *and* storage on
  top of the GitHub Free allowance and buy nothing locally, where every
  lifecycle hook runs back-to-back anyway.
* **A hash or stamp file that gates `mise install`** — rejected: `mise install`
  already compares `mise.toml` with what is installed and does nothing when they
  match, so a stamp adds code and gains nothing.

### Edits to `mise.toml` while the container is running

* **Shim auto-install plus the `hverlin.mise-vscode` extension** — a version bump
  of an installed tool installs on first use through its shim
  (`not_found_auto_install`, on by default). A newly added tool has no shim yet,
  so the extension's "missing tools" notice offers an Install button.
* **A background file watcher that runs `mise install` on save** — rejected: a
  long-running process started from a lifecycle hook, which can die without
  anyone noticing, to save one click.
* **Start and rebuild only** — rejected as the whole answer, since new tools
  would stay invisible until someone remembers to run `mise install`.

## Decision Outcome

mise runs inside the container only. The Dockerfile copies the binary from the
official `ghcr.io/jdx/mise` image, pinned by tag and digest, and sets
`MISE_DATA_DIR=/mnt/mise-data`, which is a named volume. `postStartCommand` runs
`mise install` and is the only lifecycle hook. `mise.toml` enables the lockfile,
so `mise.lock` records exact versions and checksums.

Each trigger reaches `mise install` like this:

| Change | Path to install |
|---|---|
| `devcontainer.json`, Dockerfile, `docker-compose.yaml` | VS Code prompts to rebuild (CLI: `devcontainer up --remove-existing-container`); the new container's start runs `mise install`. |
| mise version | Same as above: the tag lives in the Dockerfile. |
| `mise.toml` / `mise.lock` while stopped (branch switch, pull) | The next start runs `mise install`. |
| Version bump while running | The shim installs the new version on first use. |
| New tool while running | The mise extension shows a notice with an Install button. |

Features hold only what the container itself needs: Claude Code and the Node.js
it depends on. Project tools, including dev CLIs such as `gh`, are pinned in
`mise.toml`.

### Consequences

* Good, because one hook covers every trigger, and the hook needs no logic of its
  own.
* Good, because installed tools survive rebuilds in the `mise-data` volume, so a
  rebuild after a Dockerfile or `devcontainer.json` change does not re-download
  them.
* Good, because the image creates `/mnt/mise-data` and `/home/vscode/.claude`
  owned by `vscode`. A new, empty named volume takes the ownership of its mount
  point from the image, so no `sudo chown` hook is needed. This only applies to
  volumes created after this change; a volume that already exists keeps its
  current ownership.
* Good, because the shims directory is on `PATH` through `ENV` in the Dockerfile,
  so every process sees the tools, including `docker exec` and scripts that do
  not source a shell profile.
* A bind-mounted `mise.toml` is untrusted by default, and `mise install` would
  stop at a prompt it cannot answer. `MISE_TRUSTED_CONFIG_PATHS` in
  `containerEnv` pre-trusts the workspace.
* Adding a language runtime to `mise.toml` is still the stack decision and needs
  its own ADR. Node.js must not be pinned there while the Claude Code Feature
  brings its own: two nodes on `PATH` resolve in an order that depends on how the
  shell was started.
* Bad, because the container now has a Dockerfile to build rather than a plain
  image reference. The Dockerfile copies nothing from the repo, so its build
  context stays small.
* Reinforcing the rejection of hosted environments: Clash of Clans API keys from
  `developer.clashofclans.com` are bound to an IP address, so a cloud development
  environment would break the key outright. Worth confirming when the key is
  first registered.
