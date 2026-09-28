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
apply host *ARGS:
    ansible-playbook playbooks/site.yml --limit {{ host }} {{ ARGS }}

# First run against a freshly imaged host, connecting as root. The timer stays
# off: a host being bootstrapped is not yet a recipient of the encrypted
# inventory, so its first unattended run could only fail to decrypt.
bootstrap host *ARGS:
    ansible-playbook playbooks/site.yml --limit {{ host }} --extra-vars ansible_user=root --extra-vars base_pull_enabled=false {{ ARGS }}

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
    gh pr checks {{ quote(branch) }} --watch
    git switch main
    # Full ref names: git prefers a tag to a branch of the same name, so a tag
    # called main on origin, or origin/<branch> here, would otherwise be
    # merged in the branch's place, and a local tag called main would make
    # the push ambiguous.
    git pull --ff-only origin refs/heads/main
    # Land the pull request's head as origin has it, not the local branch: a
    # resign whose push you declined leaves re-signed commits there that the
    # pull request never held and its checks never ran on.
    git fetch origin
    # The same check ansible-pull --verify-commit runs against the release head,
    # made before the merge, so a head that fails it is never merged into main.
    # A bot's commits carry GitHub's web-flow signature rather than a key in
    # allowed_signers: run just resign on the branch first.
    git verify-commit {{ quote("refs/remotes/origin/" + branch) }}
    git merge --ff-only {{ quote("refs/remotes/origin/" + branch) }}
    # Again on the head about to be pushed.
    git verify-commit HEAD
    git push origin refs/heads/main:refs/heads/main

# Re-sign a Renovate or Dependabot branch under your own key and, once you
# answer y, push it back to its pull request, so that just merge can land it.
# A bot's commits carry GitHub's web-flow signature, which the hosts refuse.
# Read the diff this prints before you answer: it is exactly the content your
# signature goes on, and the only review between the bot's content and that
# signature. Nothing is pushed until you answer y. The range-diff proves the
# rebase itself changed nothing the bot wrote. When it exits, it switches you
# back to the branch you started on.
resign branch:
    #!/usr/bin/env bash
    set -euo pipefail
    branch={{ quote(branch) }}
    # A strict pattern, not just the prefix: the name is copied from a pull
    # request and ends up in git commands.
    if [[ ! $branch =~ ^(renovate|dependabot)/[A-Za-z0-9._/-]+$ ]]; then
        echo "ERROR: '$branch' is not a renovate/ or dependabot/ branch" >&2
        exit 1
    fi
    if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
        echo "ERROR: the working tree has uncommitted changes" >&2
        exit 1
    fi
    # A rebase or git am of yours in progress: git refuses to switch during
    # one, and the exit trap below, which aborts any rebase it finds, would
    # throw yours away.
    if [[ -d $(git rev-parse --git-path rebase-merge) || -d $(git rev-parse --git-path rebase-apply) ]]; then
        echo "ERROR: a rebase or git am is in progress; finish or abort it first" >&2
        exit 1
    fi
    # Full ref names throughout: git resolves refs/tags/<name> before
    # refs/remotes/<name>, and fetch follows any tag that points into the
    # history it fetches, so a tag called origin/main would otherwise become
    # the base, and the commits up to it would drop out of the diff and the
    # signature check below.
    git fetch origin
    # Stop before anything changes if the bot's commits touch a path that is
    # ignored here and exists. Replaying a commit that adds it overwrites your
    # file, even when a later commit deletes it again, and the checkout's
    # --no-overwrite-ignore below cannot see that. .agents/ and .superpowers/
    # are ignored, and exist only on your machine.
    mapfile -d '' -t touched < <(git log -z --no-renames --format= --name-only \
        refs/remotes/origin/main.."refs/remotes/origin/$branch" | LC_ALL=C sort -zu)
    wait $!
    ignored=()
    if [[ ${#touched[@]} -gt 0 ]]; then
        # check-ignore reads each path as a pathspec, so ./ keeps a name such
        # as :foo literal. It exits 1 when none of the paths is ignored.
        mapfile -d '' -t ignored < <(printf './%s\0' "${touched[@]}" | git check-ignore -z --stdin)
        wait $! || [[ $? -eq 1 ]]
    fi
    clobbered=()
    for path in "${ignored[@]}"; do
        if [[ -e $path || -L $path ]]; then
            clobbered+=("${path#./}")
        fi
    done
    if [[ ${#clobbered[@]} -gt 0 ]]; then
        echo "ERROR: $branch's commits touch these paths, where you have ignored files:" >&2
        printf '    %s\n' "${clobbered[@]}" >&2
        echo "Nothing was checked out, and your files are unchanged." >&2
        exit 1
    fi
    # Switch back to where you started on exit. Left checked out, the bot's
    # content would sit in your tree, where mise evaluates its mise.toml at
    # your next prompt and just merge would read its justfile. An interrupt,
    # such as Ctrl-C while the agent waits to sign, can leave a rebase in
    # progress, and git refuses to switch until it is aborted.
    if start=$(git symbolic-ref --quiet HEAD); then
        start=${start#refs/heads/}
        detach=()
    else
        start=$(git rev-parse HEAD)
        detach=(--detach)
    fi
    switch_back() {
        if [[ -d $(git rev-parse --git-path rebase-merge) || -d $(git rev-parse --git-path rebase-apply) ]]; then
            git rebase --abort
        fi
        git switch "${detach[@]}" "$start"
    }
    trap switch_back EXIT
    # Checking the branch out would otherwise silently overwrite an ignored
    # file of yours at any path it tracks, and the switch back would then
    # delete it.
    if ! git switch --no-overwrite-ignore -C "$branch" "refs/remotes/origin/$branch"; then
        echo "ERROR: could not check out $branch. Any files git names above are" >&2
        echo "yours, untracked or ignored, and the branch would overwrite them" >&2
        exit 1
    fi
    if [[ $branch == dependabot/* ]]; then
        # Dependabot cannot write the two trailers every commit body must end
        # with. doNothing leaves a trailer that is already there alone.
        if ! git rebase --force-rebase -S \
            --exec 'git -c trailer.ifexists=doNothing commit --amend --no-edit -S --trailer "Developed-by: Aryan Ameri <info@ameri.me>" --trailer "Assisted-by: <Dependabot>"' \
            refs/remotes/origin/main; then
            git rebase --abort
            echo "ERROR: rebase failed and was aborted; if it conflicted," >&2
            echo "let the bot rebase its branch" >&2
            exit 1
        fi
    else
        if ! git rebase --force-rebase -S refs/remotes/origin/main; then
            git rebase --abort
            echo "ERROR: rebase failed and was aborted; if it conflicted," >&2
            echo "let the bot rebase its branch" >&2
            exit 1
        fi
    fi
    # Proves the rebase changed none of the bot's content.
    git range-diff refs/remotes/origin/main "refs/remotes/origin/$branch" HEAD
    # The actual content about to be signed and pushed. --text and no
    # external diff or textconv, so the bot's own .gitattributes cannot
    # reduce the full diff to "Binary files differ".
    git diff --stat --text --no-ext-diff --no-textconv refs/remotes/origin/main HEAD
    git diff --text --no-ext-diff --no-textconv refs/remotes/origin/main HEAD
    git log --format='%h %G? %an / %cn %s' refs/remotes/origin/main..HEAD
    # grep must read all its input: with -q it exits at the first match,
    # git's write then dies of SIGPIPE, and pipefail reads that as a pass.
    if git log --format='%G?' refs/remotes/origin/main..HEAD | grep -v '^G$' >/dev/null; then
        echo "ERROR: a commit is not signed by a key in your allowed signers" >&2
        exit 1
    fi
    # Only an answer of exactly y pushes; anything else, or no answer at all,
    # stops here. A pushed commit under your signature stays reachable on
    # origin even if it is never merged.
    printf 'Push the re-signed branch to its PR? [y/N] ' >&2
    answer=
    if ! read -r answer || [[ $answer != y ]]; then
        echo "Not confirmed: nothing was pushed" >&2
        exit 1
    fi
    git push --force-with-lease origin "HEAD:refs/heads/$branch"

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
    # Both extensions are in use: wallabag writes .sqlite, linkding writes
    # .sqlite3. Enumerated rather than globbed as *.sqlite* on purpose - that
    # would also match the -wal and -shm sidecars, and handing those to
    # integrity_check fails on a perfectly good snapshot.
    mapfile -t dbs < <(find "$target" -type f \( -name '*.sqlite' -o -name '*.sqlite3' \))
    if [[ ${#dbs[@]} -eq 0 ]]; then
        echo "ERROR: ${#restored[@]} file(s) restored to $target, but no *.sqlite or *.sqlite3 to check." >&2
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
