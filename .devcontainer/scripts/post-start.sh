#!/usr/bin/env bash
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri
set -e
shopt -s inherit_errexit

# Uses parameter expansion rather than head/sed to avoid SC2312 subshell warnings
get_version() {
    local output
    output=$("${@}" 2>/dev/null) || { echo "N/A"; return; }
    echo "${output%%$'\n'*}"
}

echo ""
echo "=== deerlab Environment ==="
echo ""

ver_opentofu=$(get_version tofu version)
ver_opentofu="${ver_opentofu#OpenTofu }"
ver_tflint=$(get_version tflint --version)
ver_trivy=$(get_version trivy --version)
ver_tfdocs=$(get_version terraform-docs --version)
ver_ghcli=$(get_version gh --version)
ver_node=$(get_version node --version)
ver_mdlint=$(get_version markdownlint-cli2 --version)
ver_sops=$(get_version sops --version)
ver_ansible=$(get_version ansible --version)

echo "Tools:"
echo "  OpenTofu:       ${ver_opentofu}"
echo "  TFLint:         ${ver_tflint}"
echo "  Trivy:          ${ver_trivy}"
echo "  terraform-docs: ${ver_tfdocs}"
echo "  GitHub CLI:     ${ver_ghcli}"
echo "  Node.js:        ${ver_node}"
echo "  markdownlint:   ${ver_mdlint}"
echo "  SOPS:           ${ver_sops}"
echo "  Ansible:        ${ver_ansible}"
echo ""

echo "=== Authentication Status ==="
echo ""
if [[ -f "${SOPS_AGE_KEY_FILE:-/home/vscode/.config/sops/age/keys.txt}" ]]; then
    echo "SOPS age key: Present"
else
    echo "SOPS age key: NOT FOUND (bind mount ~/.config/sops/age from host)"
fi

echo ""
if gh auth status &>/dev/null 2>&1; then
    echo "GitHub CLI: Authenticated"
else
    echo "GitHub CLI: Not authenticated (run 'gh auth login')"
fi

echo ""
echo "=== Quick Commands ==="
echo "  infrahelp  - Show quick reference for all commands"
echo "  infoctx    - Show current Tofu/Git context"
echo "  tofucheck  - Format, validate, lint, and security scan"
echo "  tofuready  - Run init, validate, and plan (with SOPS passphrase)"
echo "  tfscan     - Run Trivy security scan"
echo "  tofudocs   - Generate OpenTofu documentation"
echo ""
