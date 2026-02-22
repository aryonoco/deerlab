#!/usr/bin/env bash
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri
set -euo pipefail

# Docker named volumes default to root ownership regardless of Dockerfile COPY/RUN
# directives. Correcting ownership here avoids permission-denied failures for
# tooling that writes to these paths (gh, mise, tofu).
sudo chown -R vscode:vscode \
    /home/vscode/.config/gh \
    /home/vscode/.opentofu.d/plugin-cache \
    /home/vscode/.local/share/mise \
    2>/dev/null || true

# A freshly created named volume is empty; mise expects its state directory
# to exist before it will write tool metadata.
mkdir -p /home/vscode/.local/share/mise/state

# These directories hold authentication tokens and keys; restricting to
# owner-only prevents other container users from reading credentials.
chmod 700 /home/vscode/.ssh 2>/dev/null || true
chmod 700 /home/vscode/.config/gh 2>/dev/null || true
chmod 700 /home/vscode/.config/sops/age 2>/dev/null || true
