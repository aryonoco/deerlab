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

ver_trivy=$(get_version trivy --version)
ver_ghcli=$(get_version gh --version)
ver_node=$(get_version node --version)
ver_mdlint=$(get_version markdownlint-cli2 --version)
ver_sops=$(get_version sops --version)
ver_ansible=$(get_version ansible --version)

echo "Tools:"
echo "  Trivy:          ${ver_trivy}"
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
echo "  just ci        - run every CI check locally"
echo "  just plan HOST - check and diff a host without changing it"
echo "  just apply HOST - push the playbook to a host (bootstrap only)"
echo ""
