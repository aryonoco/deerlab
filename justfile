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

# Run every check against a host now: pages nobody, records nothing
verify host:
    ansible-playbook playbooks/verify.yml --limit {{ host }} --extra-vars podman_service_verify_force=true --extra-vars podman_service_verify_notify=false --extra-vars podman_service_verify_mark=false

# Push the playbook to a host as the admin user (development and break-glass only)
# Positional, so each argument reaches ansible-playbook whole: a JSON
# --extra-vars value would otherwise be split on its spaces.
[positional-arguments]
apply host *ARGS:
    ansible-playbook playbooks/site.yml --limit "$1" "${@:2}"

# The timer stays off: a host being bootstrapped is not yet a recipient of the
# encrypted inventory, so its first unattended run could only fail to decrypt.
# The key typed at the prompt reaches the host only through the environment
# and a root-only file. The run connects to the host's public address
# directly: a fresh host is on no tailnet to jump through.
# First run against a freshly imaged host, as root; joins it to the tailnet
bootstrap host *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    read -rsp "One-off auth key for {{ host }} (tag:edge or tag:svc): " DEERLAB_TAILSCALE_AUTH_KEY; echo
    [[ -n $DEERLAB_TAILSCALE_AUTH_KEY ]] || { echo "an auth key is required" >&2; exit 1; }
    export DEERLAB_TAILSCALE_AUTH_KEY
    ansible-playbook playbooks/site.yml --limit {{ host }} --extra-vars ansible_user=root --extra-vars base_pull_enabled=false --extra-vars ansible_ssh_common_args= {{ ARGS }}

# Join a running host to the tailnet with a one-off tagged key (runbook: Tailscale)
enrol host:
    #!/usr/bin/env bash
    set -euo pipefail
    read -rsp "One-off auth key for {{ host }} (tag:edge or tag:svc): " DEERLAB_TAILSCALE_AUTH_KEY; echo
    [[ -n $DEERLAB_TAILSCALE_AUTH_KEY ]] || { echo "an auth key is required" >&2; exit 1; }
    export DEERLAB_TAILSCALE_AUTH_KEY
    ansible-playbook playbooks/enrol.yml --limit {{ host }} --extra-vars deerlab_ssh_route=public

# Open a shell on a host, or run ARGS there: the edge directly, every other host through it
[positional-arguments]
ssh host *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    host=$1; shift
    # ansible.cfg's timer callback prints after the JSON, so jq reads only up to
    # the object's closing brace.
    cmd=$(ANSIBLE_LOAD_CALLBACK_PLUGINS=1 ANSIBLE_STDOUT_CALLBACK=ansible.posix.json \
      ansible "$host" -m ansible.builtin.debug -a var=deerlab_ssh_command \
      | sed '/^}$/q' | jq -r --arg h "$host" '.plays[0].tasks[0].hosts[$h].deerlab_ssh_command')
    # eval splits the command's own quoting; ARGS reach ssh as given, unexpanded.
    eval "exec $cmd \"\$@\""

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

# Print the inventory file holding a service's restic password. sops encrypts
# values and not key names, so the key name is readable in the committed
# ciphertext and the group need not be guessed: guessing it is how a restore
# drill ends up pointed at an empty repository and passes without restoring
# anything. Exactly one match, or nothing.
[private]
restic-secrets-file service:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t matches < <(grep -l 'backup_{{ service }}_restic_password' inventory/group_vars/*/secrets.sops.yaml)
    if [[ ${#matches[@]} -ne 1 ]]; then
        echo "ERROR: expected exactly one inventory file to hold the restic password of {{ service }}, found ${#matches[@]}" >&2
        exit 1
    fi
    echo "${matches[0]}"

# Apply retention to a service's restic repository from the operator's full-access credentials
backup-prune service:
    #!/usr/bin/env bash
    set -euo pipefail
    secrets="$(just restic-secrets-file {{ service }})"
    export RESTIC_REPOSITORY="$(sops -d --extract '["backup_s3_bucket"]' inventory/group_vars/all/secrets.sops.yaml)/{{ service }}"
    export RESTIC_PASSWORD_COMMAND="sops -d --extract '[\"backup_{{ service }}_restic_password\"]' $secrets"
    sops exec-env secrets/backup-admin.sops.yaml 'restic forget --keep-within 30d --keep-within-weekly 3m --keep-within-monthly 1y --prune'

# Restore the latest snapshot of a service to a scratch directory and integrity-check it
restore-drill service:
    #!/usr/bin/env bash
    set -euo pipefail
    secrets="$(just restic-secrets-file {{ service }})"
    target="/tmp/deerlab-restore-{{ service }}"
    rm -rf "$target"
    export RESTIC_REPOSITORY="$(sops -d --extract '["backup_s3_bucket"]' inventory/group_vars/all/secrets.sops.yaml)/{{ service }}"
    export RESTIC_PASSWORD_COMMAND="sops -d --extract '[\"backup_{{ service }}_restic_password\"]' $secrets"
    sops exec-env secrets/backup-admin.sops.yaml "restic restore latest --target $target"
    # The drill exists to be able to fail, and `find -exec` cannot: it exits 0
    # whether it matched nothing or ran sqlite3 over a corrupt database, because
    # sqlite3 itself exits 0 on corruption. So count what came back and test the
    # answer, the same shape the backup unit uses.
    mapfile -t restored < <(find "$target" -type f)
    if [[ ${#restored[@]} -eq 0 ]]; then
        echo "ERROR: restored nothing to $target. Wrong repository, or an empty snapshot." >&2
        exit 1
    fi
    # Three extensions are in use: wallabag writes .sqlite, linkding writes
    # .sqlite3, Mealie writes .db. Enumerated rather than globbed as *.sqlite*
    # or *.db* on purpose - that would also match the -wal, -shm and -journal
    # sidecars, and handing those to integrity_check fails on a perfectly
    # good snapshot.
    mapfile -t dbs < <(find "$target" -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \))
    if [[ ${#dbs[@]} -eq 0 ]]; then
        echo "ERROR: ${#restored[@]} file(s) restored to $target, but no *.sqlite, *.sqlite3 or *.db to check." >&2
        echo "If {{ service }} keeps a database, the snapshot has lost it. If it keeps none, this drill can prove nothing about it: read the restored tree by hand." >&2
        exit 1
    fi
    for db in "${dbs[@]}"; do
        if ! answer="$(sqlite3 "$db" 'PRAGMA integrity_check' 2>&1)"; then
            answer="sqlite3 exited non-zero: $answer"
        fi
        if [[ "$answer" != ok ]]; then
            echo "ERROR: $db failed integrity_check: $answer" >&2
            exit 1
        fi
        echo "ok $db"
    done
    echo "Restored ${#restored[@]} file(s) to $target, ${#dbs[@]} database(s) checked"
