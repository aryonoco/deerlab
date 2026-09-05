#!/usr/bin/env bash
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri
set -euo pipefail

echo "=========================================="
echo "  deerlab DevContainer Setup"
echo "=========================================="
echo ""

DEVCONTAINER_DIR="/workspaces/deerlab/.devcontainer"
WORKSPACE_DIR="/workspaces/deerlab"

echo "Configuring shell..."
cp "${DEVCONTAINER_DIR}/config/zshrc" /home/vscode/.zshrc
cp "${DEVCONTAINER_DIR}/config/zsh_plugins.txt" /home/vscode/.zsh_plugins.txt
cp "${DEVCONTAINER_DIR}/config/p10k.zsh" /home/vscode/.p10k.zsh
echo "  Done"

echo ""
echo "Installing tools via mise..."
cd "${WORKSPACE_DIR}"
mise trust --yes mise.toml
mise install --yes
mise reshim
export PATH="/home/vscode/.local/share/mise/shims:${PATH}"
echo "  Done"

echo ""
echo "Installing Ansible collections..."
ansible-galaxy collection install -r requirements.yml
echo "  Done"

echo ""
echo "Installing pre-commit hooks..."
pre-commit install
echo "  Done"

# Non-interactive shells (SSH, VS Code tasks) skip .zshrc, so mise shims
# must be injected into PATH via a profile.d script
echo ""
echo "Configuring mise PATH for non-interactive shells..."
MISE_PROFILE_DIR="/home/vscode/.local/share/mise/profile.d"
mkdir -p "${MISE_PROFILE_DIR}"
cat > "${MISE_PROFILE_DIR}/mise-path.sh" << 'MISE_EOF'
# Sourced by ~/.profile to expose mise shims in non-interactive shells
export PATH="/home/vscode/.local/share/mise/shims:${PATH}"
MISE_EOF
if ! grep -q 'mise/profile.d/mise-path.sh' /home/vscode/.profile 2>/dev/null; then
    echo '[ -f /home/vscode/.local/share/mise/profile.d/mise-path.sh ] && . /home/vscode/.local/share/mise/profile.d/mise-path.sh' >> /home/vscode/.profile
fi
echo "  Done"

echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "All tools come from mise.toml. Useful commands:"
echo "  just ci        - run every CI check locally"
echo "  just plan HOST - check and diff a host without changing it"
echo "  just apply HOST - push the playbook to a host (bootstrap only)"
echo ""
