# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

FROM mcr.microsoft.com/devcontainers/base:trixie

# Stable system packages — rarely change, forming a cached layer
RUN apt-get update \
    && apt-get install -y --no-install-recommends shellcheck fzf fd-find age \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Debian installs fd as "fdfind"; symlink to the standard name
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# SOPS is not packaged in Debian; install from GitHub releases
ARG SOPS_VERSION=3.9.4
RUN curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
        -o /usr/local/bin/sops \
    && chmod +x /usr/local/bin/sops

# Docker named volumes inherit ownership from the mount-point at creation time.
# Pre-creating these directories ensures the vscode user owns them from the start,
# preventing permission errors on first container launch.
RUN mkdir -p /home/vscode/.local/share/mise \
             /home/vscode/.local/share/mise/state \
             /home/vscode/.opentofu.d/plugin-cache \
             /home/vscode/.config/gh \
             /home/vscode/.config/sops/age \
    && chown -R vscode:vscode /home/vscode/.local \
                               /home/vscode/.opentofu.d \
                               /home/vscode/.config

# Antidote (zsh plugin manager) is cloned at build time so container startup
# does not depend on network access to GitHub.
RUN git clone --depth=1 https://github.com/mattmc3/antidote.git /home/vscode/.antidote \
    && chown -R vscode:vscode /home/vscode/.antidote

# Declared here rather than in .zshrc so that mise shims and locally installed
# binaries are available in non-interactive shells (e.g. VS Code tasks, cron).
ENV PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:${PATH}"

WORKDIR /workspaces/deerlab
USER vscode
