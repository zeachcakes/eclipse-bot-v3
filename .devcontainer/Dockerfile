# Rationale: docs/decisions/0002-mise-toolchain-in-dev-container.md
FROM mcr.microsoft.com/devcontainers/base:debian-12

# Keep the tag in sync with min_version in mise.toml.
COPY --from=ghcr.io/jdx/mise:2026.9.12@sha256:868b004119abb2e7c146618da63371ec65da40bfb0f38a0ec4128ca9e96c057a \
	/usr/local/bin/mise /usr/local/bin/mise

# ENV rather than remoteEnv, so shims are on PATH for every process, including
# `docker exec` and scripts that never source a shell profile.
ENV MISE_DATA_DIR=/mnt/mise-data
ENV PATH=/mnt/mise-data/shims:$PATH
