#!/usr/bin/env bash
#
# Runs once, after the container is created. This is the only lifecycle hook the
# project uses. Anything that can be installed is baked into the image as a
# Feature instead, so this is reserved for the two kinds of work an image layer
# genuinely cannot do: fixing up named volumes, which are not part of any image
# layer, and reading the workspace, which is not mounted during the build.
#
set -euo pipefail

echo "[post-create] start"

# Named volumes mount root-owned, and Docker creates their parent directories as
# root too — hence /home/vscode/.local rather than just the mise data directory.
# Without this the vscode user cannot write to either volume.
sudo chown -R vscode:vscode /home/vscode/.claude /home/vscode/.local

# Install the runtimes pinned in mise.toml. This has to run here rather than at
# build time: the workspace is not mounted while Features install, so mise.toml
# does not exist yet. A no-op while [tools] is empty, so it costs nothing until a
# stack is chosen. Tools land in the mise-data volume and survive rebuilds.
mise install

echo "[post-create] done"
