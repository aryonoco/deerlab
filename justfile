# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Install all tools and pre-commit hooks
setup:
    mise install --yes
    mise run install-python-tools
    ansible-galaxy collection install -r requirements.yml
    tflint --init --config=.tflint.hcl
    pre-commit install
    @echo "Setup complete"

# Extract TF_VAR_state_passphrase from SOPS (used by tofu recipes)
[private]
tofu-env:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "export TF_VAR_state_passphrase=$(sops -d --extract '["tofu_state_passphrase"]' inventory/group_vars/proxmox/secrets.sops.yaml)"

# Run tofu init
tofu-init:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just tofu-env)"
    cd tofu && tofu init

# Run tofu plan
tofu-plan:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just tofu-env)"
    cd tofu && tofu plan

# Run tofu apply
tofu-apply:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just tofu-env)"
    cd tofu && tofu apply -auto-approve

# Run ansible-playbook playbooks/site.yml
ansible-site:
    ansible-playbook playbooks/site.yml

# Run ansible-playbook on a specific playbook
ansible playbook:
    ansible-playbook "playbooks/{{ playbook }}.yml"

# Edit SOPS-encrypted Ansible secrets
secrets-edit:
    sops inventory/group_vars/proxmox/secrets.sops.yaml

# Edit SOPS-encrypted tofu variables
tfvars-edit:
    sops tofu/terraform.tfvars.sops.json

# Generate terraform-docs for tofu/ directory
docs:
    terraform-docs markdown table tofu

# Check REUSE/SPDX licensing compliance
reuse-lint:
    @echo "=== Checking REUSE compliance ==="
    reuse lint

# Run all CI checks locally
ci: reuse-lint fmt-check validate lint-all shellcheck ansible-lint markdownlint security-scan gitleaks check-version-sync check-trailing-whitespace check-eof-newline check-yaml check-json check-merge-conflicts
    @echo ""
    @echo "════════════════════════════════════════"
    @echo "  All CI checks passed"
    @echo "════════════════════════════════════════"

# Check formatting without modifying
fmt-check:
    @echo "=== Checking OpenTofu formatting ==="
    tofu fmt -check -recursive -diff tofu/

# Validate OpenTofu configuration
validate:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just tofu-env)"
    echo "Validating tofu/..."
    cd tofu
    tofu init
    tofu validate
    echo "All configurations valid"

# Validate OpenTofu configuration (CI-safe — no SOPS required)
validate-ci:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Validating OpenTofu configuration (CI mode) ==="
    cd tofu
    TF_VAR_state_passphrase="ci-placeholder-passphrase" tofu init -backend=false
    TF_VAR_state_passphrase="ci-placeholder-passphrase" tofu validate
    echo "All configurations valid"

# Run TFLint on the tofu/ directory
lint-all:
    #!/usr/bin/env bash
    set -e
    echo "=== Initializing TFLint plugins ==="
    tflint --init --config="$(pwd)/.tflint.hcl"
    echo "=== Running TFLint on tofu/ ==="
    tflint --config="$(pwd)/.tflint.hcl" --chdir="tofu"
    echo "TFLint passed"

# Run shellcheck on all shell scripts
shellcheck:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Running shellcheck ==="
    find . -name '*.sh' -not -path './collections/*' -not -path './.terraform/*' -not -path '*/.terraform/*' -not -path './.devcontainer/config/*' -print0 \
      | xargs -0 shellcheck
    echo "shellcheck passed"

# Lint all Ansible playbooks and roles
ansible-lint:
    @echo "=== Running ansible-lint ==="
    ansible-lint --profile=production

# Lint Ansible with auto-fix
ansible-lint-fix:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Running ansible-lint with fixes ==="
    rc=0
    ansible-lint --fix --profile=production || rc=$?
    # exit code 8 = files were modified (success)
    if [[ $rc -ne 0 && $rc -ne 8 ]]; then exit "$rc"; fi

# Lint all Markdown files
markdownlint:
    @echo "=== Running markdownlint ==="
    markdownlint-cli2 "**/*.md" "!collections/**"

# Lint Markdown with auto-fix
markdownlint-fix:
    @echo "=== Running markdownlint with fixes ==="
    markdownlint-cli2 --fix "**/*.md" "!collections/**"

# Run Trivy security scan
security-scan:
    @echo "=== Running Trivy security scan ==="
    trivy config . --severity HIGH,CRITICAL --exit-code 1 --skip-dirs collections

# Run gitleaks secret scan
gitleaks:
    @echo "=== Running gitleaks secret scan ==="
    gitleaks git --redact --verbose

# Check for trailing whitespace (excludes .md files)
check-trailing-whitespace:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Checking for trailing whitespace ==="
    if git --no-pager grep -n '[[:blank:]]$' -- ':!*.md' ':!*.lock' ':!collections/*'; then
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
    done < <(git ls-files -- ':!collections/*' ':!*.tfstate')
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

# Validate .opentofu-version matches mise.toml
check-version-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Checking version file sync ==="
    MISE_VERSION=$(grep '^opentofu' mise.toml | sed 's/.*= *"//;s/".*//')
    FILE_VERSION=$(cat .opentofu-version)
    if [ "$MISE_VERSION" != "$FILE_VERSION" ]; then
        echo "ERROR: .opentofu-version ($FILE_VERSION) does not match mise.toml ($MISE_VERSION)"
        exit 1
    fi
    echo "Version files in sync"

# Run pre-commit on all files
pre-commit:
    pre-commit run --all-files

# Format all code (OpenTofu + Markdown)
fmt:
    tofu fmt -recursive tofu/
    markdownlint-cli2 --fix "**/*.md" "!collections/**"
