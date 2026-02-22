#!/usr/bin/env bash
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri
set -euo pipefail

echo "=========================================="
echo "  deerlab DevContainer Setup"
echo "=========================================="
echo ""

echo "Configuring shell..."
DEVCONTAINER_DIR="/workspaces/deerlab/.devcontainer"

cp "${DEVCONTAINER_DIR}/config/zshrc" /home/vscode/.zshrc
cp "${DEVCONTAINER_DIR}/config/zsh_plugins.txt" /home/vscode/.zsh_plugins.txt
cp "${DEVCONTAINER_DIR}/config/p10k.zsh" /home/vscode/.p10k.zsh

echo "  Done"

echo ""
echo "Installing tools via mise..."
WORKSPACE_DIR="/workspaces/deerlab"

if [[ -f "${WORKSPACE_DIR}/mise.toml" ]]; then
    cd "${WORKSPACE_DIR}"
    mise install --yes
    mise reshim
    export PATH="/home/vscode/.local/share/mise/shims:${PATH}"
    echo "  Tools installed from mise.toml"

    # Version pins live in mise.toml [env] to guarantee parity between local and CI environments
    echo "Installing Python CLI tools via uv..."
    mise_env=$(mise env)
    # Pre-declare variables so shellcheck does not flag SC2154 after eval
    ANSIBLE_VERSION="" ANSIBLE_LINT_VERSION="" YAMLLINT_VERSION=""
    eval "${mise_env}"
    uv tool install "ansible==${ANSIBLE_VERSION}" --with-executables-from ansible-core --with paramiko
    uv tool install "ansible-lint==${ANSIBLE_LINT_VERSION}" --with passlib
    uv tool install "yamllint==${YAMLLINT_VERSION}"
    uv tool install reuse
    export PATH="/home/vscode/.local/bin:${PATH}"
    echo "  Python CLI tools installed"
else
    echo "  No mise.toml found, skipping mise install"
fi

echo ""
echo "Installing Ansible collections..."
if [[ -f "${WORKSPACE_DIR}/requirements.yml" ]]; then
    cd "${WORKSPACE_DIR}"
    ansible-galaxy collection install -r requirements.yml
    echo "  Ansible collections installed"
fi

echo ""
echo "Initializing TFLint plugins..."
if [[ -f "${WORKSPACE_DIR}/.tflint.hcl" ]]; then
    tflint --init --config="${WORKSPACE_DIR}/.tflint.hcl" || echo "  TFLint init skipped (may need network)"
fi

echo ""
echo "Installing pre-commit hooks..."
if [[ -f "${WORKSPACE_DIR}/.pre-commit-config.yaml" ]]; then
    cd "${WORKSPACE_DIR}"
    pre-commit install
    echo "  Pre-commit hooks installed"
fi

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
    echo "  Added mise-path.sh sourcing to ~/.profile"
fi
echo "  Done"

echo ""
echo "Setting up environment files..."

if [[ ! -f "${WORKSPACE_DIR}/.env" ]] && [[ -f "${WORKSPACE_DIR}/.devcontainer/.env.example" ]]; then
    cp "${WORKSPACE_DIR}/.devcontainer/.env.example" "${WORKSPACE_DIR}/.env"
    echo "  Created .env from .env.example"
fi

if [[ -f "${WORKSPACE_DIR}/.gitignore" ]] && ! grep -qx '.env' "${WORKSPACE_DIR}/.gitignore"; then
    echo '.env' >> "${WORKSPACE_DIR}/.gitignore"
    echo "  Added .env to .gitignore"
elif [[ ! -f "${WORKSPACE_DIR}/.gitignore" ]]; then
    echo '.env' > "${WORKSPACE_DIR}/.gitignore"
    echo "  Created .gitignore with .env entry"
fi

echo "  Done"

echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "Tools installed via mise (from mise.toml):"
echo "  - OpenTofu, TFLint, Trivy, Just, terraform-docs, uv, markdownlint-cli2, pre-commit"
echo "Python CLI tools installed via uv (versions from mise.toml):"
echo "  - ansible, ansible-lint, yamllint"
echo ""
echo "Available commands:"
echo "  infrahelp  - Show quick reference for all commands"
echo "  infoctx    - Show current Tofu/Git context"
echo "  tofucheck  - Run format, validate, lint, and security scan"
echo "  tofuready  - Run init, validate, and plan (with SOPS passphrase)"
echo "  tfscan     - Run Trivy security scan"
echo "  tofudocs   - Generate OpenTofu documentation"
echo "  just ci    - Run CI checks locally"
echo ""
