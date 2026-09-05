# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

FROM mcr.microsoft.com/devcontainers/base:trixie

# System packages that are not tools mise manages: interactive helpers and
# the sqlite3 CLI used by the restore drill.
RUN apt-get update \
    && apt-get install -y --no-install-recommends fzf fd-find sqlite3 wireguard-tools \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Debian installs fd as "fdfind"; symlink to the standard name
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Docker named volumes inherit ownership from the mount-point at creation time.
RUN mkdir -p /home/vscode/.local/share/mise \
             /home/vscode/.local/share/mise/state \
             /home/vscode/.config/gh \
             /home/vscode/.config/sops/age \
    && chown -R vscode:vscode /home/vscode/.local /home/vscode/.config

# Antidote (zsh plugin manager) is cloned at build time so container startup
# does not depend on network access to GitHub.
RUN git clone --depth=1 https://github.com/mattmc3/antidote.git /home/vscode/.antidote \
    && chown -R vscode:vscode /home/vscode/.antidote

ENV PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:${PATH}"

WORKDIR /workspaces/deerlab
USER vscode
