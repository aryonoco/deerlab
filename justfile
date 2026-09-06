# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Install all tools
setup:
    mise trust --yes mise.toml
    mise install --yes
    ansible-galaxy collection install -r requirements.yml
    @echo "Setup complete"

# Run all CI checks locally
ci: ansible-lint shellcheck security-scan gitleaks check-trailing-whitespace check-eof-newline check-yaml check-json check-merge-conflicts
    @echo ""
    @echo "════════════════════════════════════════"
    @echo "  All CI checks passed"
    @echo "════════════════════════════════════════"

# Lint all Ansible playbooks and roles
ansible-lint:
    @echo "=== Running ansible-lint ==="
    ansible-lint

# Lint Ansible with auto-fix
ansible-lint-fix:
    #!/usr/bin/env bash
    set -euo pipefail
    rc=0
    ansible-lint --fix || rc=$?
    if [[ $rc -ne 0 && $rc -ne 8 ]]; then exit "$rc"; fi

# Run shellcheck on all shell scripts
shellcheck:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Running shellcheck ==="
    # -r so an empty result is a pass, not shellcheck's "No files specified" (exit 123)
    find . -name '*.sh' -not -path './collections/*' -not -path './.ansible/*' -print0 | xargs -0 -r shellcheck
    echo "shellcheck passed"

# Run Trivy configuration scan
security-scan:
    @echo "=== Running Trivy security scan ==="
    trivy config . --severity HIGH,CRITICAL --exit-code 1 --skip-dirs collections --skip-dirs .ansible

# Run gitleaks secret scan
gitleaks:
    @echo "=== Running gitleaks secret scan ==="
    gitleaks git --redact --verbose

# Check for trailing whitespace (excludes .md files)
check-trailing-whitespace:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Checking for trailing whitespace ==="
    if git --no-pager grep -n '[[:blank:]]$' -- ':!*.md' ':!collections/*'; then
        echo "ERROR: Trailing whitespace found"
        exit 1
    fi
    echo "No trailing whitespace found"

# Check that tracked files end with a newline
check-eof-newline:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Checking end-of-file newlines ==="
    failed=0
    while IFS= read -r f; do
        if [ ! -s "$f" ] || ! LC_ALL=C grep -Iq . "$f"; then continue; fi
        if [ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]; then
            echo "ERROR: Missing final newline: $f"
            failed=1
        fi
    done < <(git ls-files -- ':!collections/*')
    if [ "$failed" -ne 0 ]; then exit 1; fi
    echo "All files end with newline"

# Validate YAML syntax
check-yaml:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Validating YAML syntax ==="
    yamllint -d "{rules: {}}" $(git ls-files '*.yml' '*.yaml' -- ':!collections/*')
    echo "All YAML files valid"

# Validate JSON syntax
check-json:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Validating JSON syntax ==="
    failed=0
    while IFS= read -r f; do
        if ! python3 -c "import sys,json;json.load(open(sys.argv[1]))" "$f" 2>&1; then
            echo "ERROR: Invalid JSON: $f"
            failed=1
        fi
    done < <(git ls-files '*.json' -- ':!collections/*')
    if [ "$failed" -ne 0 ]; then exit 1; fi
    echo "All JSON files valid"

# Check for merge conflict markers
check-merge-conflicts:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Checking for merge conflict markers ==="
    if git --no-pager grep -n -E '^(<{7}|={7}|>{7})' -- ':!collections/*' ':!LICENSE*' ':!LICENSES/*'; then
        echo "ERROR: Merge conflict markers found"
        exit 1
    fi
    echo "No merge conflict markers found"

# Format YAML
fmt:
    just ansible-lint-fix

# Check and diff a host without changing it
plan host:
    ansible-playbook playbooks/site.yml --limit {{ host }} --check --diff

# Push the playbook to a host as the admin user (development and break-glass only)
apply host:
    ansible-playbook playbooks/site.yml --limit {{ host }}

# First run against a freshly imaged host, connecting as root
bootstrap host:
    ansible-playbook playbooks/site.yml --limit {{ host }} --extra-vars ansible_user=root

# Run the playbook twice and fail if the second run changed anything
idempotency host:
    #!/usr/bin/env bash
    set -euo pipefail
    ansible-playbook playbooks/site.yml --limit {{ host }}
    ansible-playbook playbooks/site.yml --limit {{ host }} | tee /tmp/deerlab-idempotency.log
    if grep -E 'changed=[1-9]' /tmp/deerlab-idempotency.log; then
        echo "ERROR: second run was not idempotent"
        exit 1
    fi
    echo "Idempotent"

# Fast-forward main to a green branch and push, refusing a head the hosts would reject
merge branch:
    gh pr checks {{ branch }} --required --watch
    git switch main
    git pull --ff-only origin main
    git merge --ff-only {{ branch }}
    # The same check ansible-pull --verify-commit runs against the release head.
    # Commits created through the GitHub API, which is every Renovate commit,
    # carry GitHub's GPG web-flow signature rather than a key in allowed_signers.
    # Recreate them under your own key first: git rebase --force-rebase -S main
    git verify-commit HEAD
    git push origin main

# Edit a SOPS-encrypted file
secrets-edit file:
    sops {{ file }}

# Re-encrypt every SOPS file for the recipients currently listed in .sops.yaml
secrets-rekey:
    #!/usr/bin/env bash
    set -euo pipefail
    git ls-files '*.sops.yaml' ':!/.sops.yaml' | while IFS= read -r f; do
        echo "updatekeys $f"
        sops updatekeys --yes "$f"
    done

# Apply retention to a service's restic repository from the operator's full-access credentials
backup-prune service:
    #!/usr/bin/env bash
    set -euo pipefail
    export RESTIC_REPOSITORY="$(sops -d --extract '["backup_s3_bucket"]' inventory/group_vars/all/secrets.sops.yaml)/{{ service }}"
    export RESTIC_PASSWORD_COMMAND="sops -d --extract '[\"backup_{{ service }}_restic_password\"]' inventory/group_vars/services/secrets.sops.yaml"
    sops exec-env secrets/backup-admin.sops.yaml 'restic forget --keep-within 30d --keep-within-weekly 3m --keep-within-monthly 1y --prune'

# Restore the latest snapshot of a service to a scratch directory and integrity-check it
restore-drill service:
    #!/usr/bin/env bash
    set -euo pipefail
    target="/tmp/deerlab-restore-{{ service }}"
    rm -rf "$target"
    export RESTIC_REPOSITORY="$(sops -d --extract '["backup_s3_bucket"]' inventory/group_vars/all/secrets.sops.yaml)/{{ service }}"
    export RESTIC_PASSWORD_COMMAND="sops -d --extract '[\"backup_{{ service }}_restic_password\"]' inventory/group_vars/services/secrets.sops.yaml"
    sops exec-env secrets/backup-admin.sops.yaml "restic restore latest --target $target"
    find "$target" -name '*.sqlite' -print -exec sqlite3 {} 'PRAGMA integrity_check' \;
    echo "Restored to $target"
