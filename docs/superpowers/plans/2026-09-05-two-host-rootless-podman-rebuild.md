<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me> -->

# Two-host rootless Podman rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Proxmox, LXC and OpenTofu stack with two Debian 13 VPSs, an edge running Caddy and a services host running Wallabag, both configured entirely by Ansible with rootless Podman Quadlets, kernel WireGuard between them, pull-based delivery, restic backups and ntfy alerts.

**Architecture:** Ansible is the only executor. Host-wide concerns are `base_*` roles, the container platform is `podman_host`, `podman_user` and `podman_service`, and the two thin roles `caddy` and `wallabag` only place service-specific files. Service definitions are inventory data; one generic role renders every Quadlet from that data into a root-owned per-user directory. Each host pulls a signed `release` branch on a timer.

**Tech Stack:** Debian 13, Ansible 14 (core 2.21), Podman 5.4.2 with pasta, systemd 257, systemd-networkd WireGuard, nftables, SOPS with age, restic, Renovate, mise, just, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-05-two-host-rootless-podman-design.md`

## Global Constraints

- Targets are stock Debian 13 with Podman **5.4.2**. Quadlet files use only keys that exist in 5.4.2: never `Memory=`, never `Wants=`/`After=` naming a `.container` unit, never `[Install] UpheldBy=`.
- No systemd sandboxing directives in a Quadlet `[Service]` section. Allowed there: `Restart=`, `RestartSec=`, `TimeoutStartSec=`, `MemoryMax=`, `CPUQuota=`, `TasksMax=`, `OnFailure=`.
- Every task touching Podman or a user manager sets `become: true`, `become_user: <service user>`, and both `XDG_RUNTIME_DIR: /run/user/<uid>` and `DBUS_SESSION_BUS_ADDRESS: unix:path=/run/user/<uid>/bus` in `environment`. Never `become_method: su`. Never Podman as root.
- Ansible **14.3.1** (core 2.21.3). Collections: `community.general >=13,<14`, `ansible.posix >=2.2,<3`, `community.sops >=2.4,<3`, `containers.podman >=1.20,<2`.
- ansible-lint production profile plus `role-argument-spec`. FQCN everywhere. Every `command`/`shell` has `changed_when` or `creates`. Every file task has `mode`. Every role variable is prefixed with the role name. Task names start with a capital letter. Secrets tasks set `no_log: true`.
- yamllint: 160-column lines, file modes quoted as strings like `"0644"`, truthy values only `true`/`false`.
- No bespoke check scripts. Validation uses ansible-lint, `validate:` on template tasks, `systemd-analyze verify`, `nft --check`.
- REUSE headers on every new file: tasks, handlers and templates are `CPAL-1.0` (`# SPDX-License-Identifier: CPAL-1.0` / `# Copyright (c) 2026 Aryan Ameri`; in Jinja templates wrap them as `{# ... #}`), defaults, meta, inventory and config are `0BSD`, docs are `CC-BY-4.0` in HTML comments.
- Commit messages read as if a human wrote them. No AI attribution lines. Run `just ci` before every commit. Never `--no-verify`.
- Inventory host names are `edge1` and `svc1`. Tunnel addresses: edge `<edge tunnel IPv4>` / `<edge tunnel IPv6>`, services `<services tunnel IPv4>` / `<services tunnel IPv6>`. WireGuard port `<WireGuard port>`. Service UIDs start at `2000`; subordinate ranges are `100000 + (uid - 2000) * 65536`, width `65536`.
- Deviations from the spec, agreed here: the repository is public, so hosts clone over anonymous HTTPS and no deploy key exists on any host, while signature verification of the `release` head still applies. There is no separate `bootstrap.yml`; the push path is `site.yml` run as root once, and the only extra bootstrap action is registering the host's age public key as a SOPS recipient. There are no thin `caddy` and `wallabag` roles: the service definition gained a `config_files` list that the generic role writes into the service user's home and restarts on, which covers the Caddyfile and leaves nothing service-specific for a role to do.

---

## File Structure

Created or rewritten by this plan. Everything under `tofu/`, `roles/proxmox_*`, `roles/lxc_*`, and the Proxmox playbooks is deleted in Task 2.

| Path | Responsibility |
| --- | --- |
| `mise.toml` | Every tool the repo needs, including Python tools via the pipx backend |
| `requirements.yml` | Collection pins |
| `host-requirements.txt` | Python pins for the Ansible virtual environment on the hosts |
| `ansible.cfg`, `.ansible-lint` | Unchanged paths, lint rule additions |
| `justfile` | Developer and CI entry points |
| `.github/workflows/ci.yml` | One lint job that runs `just ci` through mise, plus advisory spell check |
| `.github/workflows/promote.yml` | Fast-forwards `release` to `main` when CI on `main` succeeds |
| `renovate.json` | Dependency automation with digest pinning |
| `inventory/hosts.yml` | Groups `edge`, `services`, `podman_hosts`; hosts `edge1`, `svc1` |
| `inventory/group_vars/all/main.yml` | Non-secret shared data: admin keys, allowed signers, tunnel prefixes, port |
| `inventory/group_vars/all/secrets.sops.yaml` | Admin user name, domain, ntfy, dead-man URLs, root hash, WireGuard PSK, S3 |
| `inventory/group_vars/podman_hosts/main.yml` | Registry list shared by service users |
| `inventory/group_vars/edge/main.yml` | Firewall role, Caddy service definition, Caddyfile data |
| `inventory/group_vars/services/main.yml` | Firewall role, Wallabag service definition |
| `inventory/group_vars/services/secrets.sops.yaml` | Wallabag Symfony secret, restic passwords, per-service S3 keys |
| `inventory/host_vars/<host>/main.yml` | `ansible_host`, tunnel addresses, WireGuard public key, public endpoint |
| `inventory/host_vars/<host>/secrets.sops.yaml` | WireGuard private key |
| `playbooks/site.yml` | Imports `deps.yml`, `base.yml`, `edge.yml`, `services.yml` |
| `playbooks/deps.yml` | Installs collections into the checkout before any role runs |
| `playbooks/base.yml` | `base_os`, `base_ssh`, `base_wireguard`, `base_firewall`, `base_notify`, `base_pull` on all hosts |
| `playbooks/edge.yml` | `podman_host`, `podman_user`, `podman_service`, `backup` on `edge` |
| `playbooks/services.yml` | `podman_host`, `podman_user`, `podman_service`, `backup` on `services` |
| `roles/base_os` | Packages, admin user, root password, sysctl, kernel command line, journald, chrony, needrestart, unattended-upgrades, auditd, optional hidepid |
| `roles/base_ssh` | sshd drop-in with validation and rescue |
| `roles/base_wireguard` | networkd netdev and network units, key files, wait-online, hosts entries |
| `roles/base_firewall` | The single nftables ruleset template |
| `roles/base_notify` | ntfy notifier units in system and user scope, reboot-required timer |
| `roles/base_pull` | Ansible venv, sops and age, host age key, git verification config, pull timer |
| `roles/podman_host` | Podman packages, image policy, registry defaults, version assertions |
| `roles/podman_user` | Service accounts, subordinate IDs, linger, directories, slice and wait-network drop-ins, ntfy credential copy |
| `roles/podman_service` | Config files, secrets, image pre-pull, Quadlet volume and container units, reload, verify, start, smoke test |
| `roles/backup` | Per-service restic timer and unit, repository initialisation, credentials |
| `secrets/backup-admin.sops.yaml` | Operator-only S3 credentials for prune and restore, outside the inventory |
| `docs/runbook.md` | Bootstrap, rekey, merge, reboot, break-glass, restore drill, adding a service |
| `README.md`, `CLAUDE.md` | Rewritten for the new design |

---

## Phase 1: Repository surgery and tooling

### Task 1: Move the entire toolchain into mise

**Files:**

- Modify: `mise.toml`
- Modify: `.devcontainer/Dockerfile`
- Modify: `.devcontainer/devcontainer.json`
- Modify: `.devcontainer/scripts/post-create.sh`
- Modify: `.devcontainer/scripts/on-create.sh`
- Modify: `.devcontainer/config/zshrc`
- Modify: `.pre-commit-config.yaml`
- Modify: `justfile` (the `setup` recipe only; the rest is rewritten in Task 4)

**Interfaces:**

- Produces: `mise install` provides `ansible`, `ansible-playbook`, `ansible-galaxy`, `ansible-lint`, `yamllint`, `reuse`, `sops`, `age`, `age-keygen`, `restic`, `shellcheck`, `trivy`, `gitleaks`, `just`, `pre-commit`, `markdownlint-cli2`, `cspell`, `uv`, `node`. Every later task and CI assume these binaries come from mise.

- [ ] **Step 1: Confirm the current pins are broken**

Run: `mise install --yes 2>&1 | tail -5`
Expected: an error mentioning `trivy@0.69.1` and a 404, proving the refresh is needed.

- [ ] **Step 2: Replace `mise.toml`**

```toml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

# Single source of truth for every tool the repo needs. CI, the devcontainer
# and `just setup` all run `mise install` and nothing else.

[tools]
node = "lts"
uv = "0.12.9"
just = "1.58.0"
pre-commit = "4.6.2"
markdownlint-cli2 = "0.23.2"
shellcheck = "0.11.0"
trivy = "0.74.0"
gitleaks = "8.30.1"
sops = "3.13.3"
age = "1.3.2"
restic = "0.19.1"
"npm:cspell" = "10.2.1"
"pipx:ansible" = { version = "14.3.1", uvx_args = "--with-executables-from ansible-core --with paramiko --with passlib" }
"pipx:ansible-lint" = { version = "26.8.0", uvx_args = "--with passlib" }
"pipx:yamllint" = "1.38.0"
"pipx:reuse" = "6.2.0"

[env]
# Consumed by .pre-commit-config.yaml
PRECOMMIT_HOOKS_VERSION = "v6.0.0"
```

- [ ] **Step 3: Run mise install and verify every binary resolves**

Run:

```bash
mise install --yes
for t in ansible-playbook ansible-galaxy ansible-lint yamllint reuse sops age age-keygen shellcheck trivy gitleaks just pre-commit markdownlint-cli2 cspell; do
  printf '%-18s ' "$t"; mise x -- "$t" --version 2>&1 | head -1
done
mise x -- restic version
```

Expected: every line prints a version. `ansible-playbook` prints `[core 2.21.3]`.

- [ ] **Step 4: Simplify the devcontainer Dockerfile**

Replace `.devcontainer/Dockerfile` with:

```dockerfile
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

FROM mcr.microsoft.com/devcontainers/base:trixie

# System packages that are not tools mise manages: interactive helpers and
# the sqlite3 CLI used by the restore drill.
RUN apt-get update \
    && apt-get install -y --no-install-recommends fzf fd-find sqlite3 wireguard-tools \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Debian installs fd as "fdfind"; symlink to the standard name
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Docker named volumes inherit ownership from the mount-point at creation time.
RUN mkdir -p /home/vscode/.local/share/mise \
             /home/vscode/.local/share/mise/state \
             /home/vscode/.config/gh \
             /home/vscode/.config/sops/age \
    && chown -R vscode:vscode /home/vscode/.local /home/vscode/.config

# Antidote (zsh plugin manager) is cloned at build time so container startup
# does not depend on network access to GitHub.
RUN git clone --depth=1 https://github.com/mattmc3/antidote.git /home/vscode/.antidote \
    && chown -R vscode:vscode /home/vscode/.antidote

ENV PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:${PATH}"

WORKDIR /workspaces/deerlab
USER vscode
```

- [ ] **Step 5: Remove the OpenTofu volume from devcontainer.json**

Delete this object from the `mounts` array in `.devcontainer/devcontainer.json`:

```json
    {
      "source": "deerlab-tofu-cache-${devcontainerId}",
      "target": "/home/vscode/.opentofu.d/plugin-cache",
      "type": "volume"
    },
```

Then run `grep -n -i 'tofu\|terraform\|tflint' .devcontainer/devcontainer.json` and delete every remaining match, which are VS Code extension entries for HashiCorp and OpenTofu language support.

- [ ] **Step 6: Replace post-create.sh**

```bash
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
```

- [ ] **Step 7: Remove the OpenTofu path from on-create.sh**

In `.devcontainer/scripts/on-create.sh`, delete the line `/home/vscode/.opentofu.d/plugin-cache \` from the `chown` list.

- [ ] **Step 8: Remove OpenTofu helpers from the shell config**

Run: `grep -n -i 'tofu\|tflint\|terraform\|infoctx\|tfscan' .devcontainer/config/zshrc`

Delete every function or alias block the grep reveals. In the `infrahelp` function, replace the list of commands with the three lines printed at the end of `post-create.sh` above.

- [ ] **Step 9: Update pre-commit hooks**

Replace `.pre-commit-config.yaml` with:

```yaml
---
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

repos:
  - repo: local
    hooks:
      - id: gitleaks
        name: gitleaks
        entry: mise exec -- gitleaks protect --staged --redact
        language: system
        pass_filenames: false
        always_run: true

  - repo: local
    hooks:
      - id: shellcheck
        name: shellcheck
        entry: mise exec -- shellcheck
        language: system
        types: [shell]
        files: \.sh$
        exclude: ^(\.devcontainer/config/|collections/)

  - repo: local
    hooks:
      - id: ansible-lint
        name: ansible-lint
        entry: mise exec -- ansible-lint --offline
        language: system
        pass_filenames: false
        files: \.(ya?ml)$
        exclude: ^(collections/|\.github/)

  - repo: local
    hooks:
      - id: markdownlint-fix
        name: markdownlint --fix
        entry: mise exec -- markdownlint-cli2 --fix
        language: system
        types: [markdown]
        exclude: ^collections/

  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: trailing-whitespace
        exclude: (\.md$|^collections/)
      - id: end-of-file-fixer
        exclude: (^collections/|^LICENSE)
      - id: check-yaml
        exclude: ^collections/
      - id: check-json
        exclude: ^collections/
      - id: check-merge-conflict
        exclude: (^collections/|^LICENSE)

  - repo: local
    hooks:
      - id: reuse-lint
        name: REUSE compliance
        entry: mise exec -- reuse lint
        language: system
        pass_filenames: false
        always_run: true
```

- [ ] **Step 10: Update the `setup` recipe in the justfile**

Replace the `setup` recipe body with:

```just
# Install all tools and pre-commit hooks
setup:
    mise trust --yes mise.toml
    mise install --yes
    ansible-galaxy collection install -r requirements.yml
    pre-commit install
    @echo "Setup complete"
```

Leave every other recipe alone for now; Task 4 rewrites the file.

- [ ] **Step 11: Verify and commit**

Run: `mise x -- pre-commit run --all-files 2>&1 | tail -15`
Expected: hooks run; tofu and tflint hooks no longer appear. Failures at this point come only from the Proxmox and Tofu files that Task 2 deletes, so note them and continue.

```bash
git add mise.toml .devcontainer .pre-commit-config.yaml justfile
git commit -m "Manage the whole toolchain with mise

Refresh every pin, move the Python tools onto mise's pipx backend so
ansible-playbook and friends are exposed, and drop the separate uv tool
install step from the devcontainer. trivy 0.69.1 no longer exists
upstream, which had broken mise install."
```

### Task 2: Remove OpenTofu, Proxmox and LXC

**Files:**

- Delete: `tofu/`, `roles/proxmox_install`, `roles/proxmox_base`, `roles/proxmox_hardening`, `roles/proxmox_acme`, `roles/proxmox_totp`, `roles/proxmox_lxc_config`, `roles/lxc_base`, `roles/lxc_caddy`, `roles/lxc_preflight`, `roles/lxc_wallabag`, `playbooks/*.yml`, `inventory/`, `docs/networking-and-uid-mapping.md`, `docs/opentofu-integration-analysis.md`, `docs/TODO.md`, `.tflint.hcl`, `.opentofu-version`, `.github/dependabot.yml`, `.github/workflows/deploy.yml`, `scripts/upgrade-bookworm-to-trixie.sh`
- Modify: `.gitignore`, `.gitleaks.toml`, `REUSE.toml`, `.markdownlint-cli2.jsonc`, `cspell.json`

**Interfaces:**

- Produces: an empty `roles/`, `playbooks/` and `inventory/` tree ready for the new layout. The SSH, sysctl, unattended-upgrades and auditd content of `roles/proxmox_hardening/tasks/main.yml` is reused verbatim in Task 6 and Task 7; read it from git history with `git show HEAD~1:roles/proxmox_hardening/tasks/main.yml` when those tasks need it.

- [ ] **Step 1: Delete the old trees**

```bash
git rm -r -q tofu roles playbooks inventory scripts docs/networking-and-uid-mapping.md docs/opentofu-integration-analysis.md docs/TODO.md .tflint.hcl .opentofu-version .github/dependabot.yml .github/workflows/deploy.yml
mkdir -p roles playbooks inventory
```

- [ ] **Step 2: Remove OpenTofu entries from `.gitignore`**

Run: `grep -n -i 'tofu\|terraform\|tfstate\|\.tf$' .gitignore`

Delete every matching line and the two comment headers that introduce them. Keep `collections/`, `.ansible_fact_cache/`, `.venv/`, `.cache/`.

- [ ] **Step 3: Trim `.gitleaks.toml`**

Replace the `paths` list in `.gitleaks.toml` with:

```toml
paths = [
  # SOPS-encrypted files — values are ciphertext (ENC[AES256_GCM,...]), safe to commit
  '''.*\.sops\.yaml$''',
  # SOPS configuration — contains age public keys (not secrets)
  '''\.sops\.yaml$''',
  # Vendored Ansible collections (excluded everywhere in this repo)
  '''collections/''',
]
```

- [ ] **Step 4: Trim `REUSE.toml`**

Remove `"**/*.hcl"` from the first annotation's `path` list. Remove `".opentofu-version"` and `".tflint.hcl"` from the root dotfiles annotation. Replace the machine-generated annotation with:

```toml
# Machine-generated / encrypted (annotation-only, no inline headers possible)
[[annotations]]
path = ["**/*.sops.yaml"]
SPDX-FileCopyrightText = "2026 Aryan Ameri <info@ameri.me>"
SPDX-License-Identifier = "0BSD"
```

Run: `grep -n 'tofu\|\.tf\b\|terraform' REUSE.toml`
Expected: no output. If any annotation still names a Tofu path, delete it.

- [ ] **Step 5: Trim `.markdownlint-cli2.jsonc` and `cspell.json`**

In `.markdownlint-cli2.jsonc` remove the `"**/.terraform/**"` and `"**/.opentofu/**"` entries. In `cspell.json` remove `".terraform/**"`, `".opentofu/**"` and `"*.lock.hcl"` from `ignorePaths`.

- [ ] **Step 6: Verify nothing references the old stack**

Run: `git grep -n -i -E 'tofu|terraform|tflint|proxmox|pct |lxc' -- ':!docs/superpowers/**' ':!project-words.txt' ':!CLAUDE.md' ':!README.md' ':!justfile' ':!.github/**' ':!LICENSE*' ':!LICENSES/**'`
Expected: no output. `justfile` and the workflows are rewritten in Task 4, `CLAUDE.md` and `README.md` in Task 22.

Run: `mise x -- reuse lint | tail -3`
Expected: `Congratulations! Your project is compliant`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Remove the Proxmox, LXC and OpenTofu stack

The new design is two plain Debian hosts configured by Ansible alone.
Everything that only existed to hold the hypervisor together goes:
the Tofu tree and its encrypted state, the Proxmox and LXC roles and
playbooks, the SDN documentation, TFLint, Dependabot's Terraform job
and the push-based deploy workflow."
```

### Task 3: Ansible 14, collection pins and lint configuration

**Files:**

- Modify: `requirements.yml`
- Create: `host-requirements.txt`
- Modify: `.ansible-lint`
- Modify: `ansible.cfg`

**Interfaces:**

- Produces: `requirements.yml` floors that every role may rely on; `host-requirements.txt` consumed by `roles/base_pull` in Task 11.

- [ ] **Step 1: Write the collection pins**

Replace `requirements.yml` with:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

collections:
  - name: community.general
    version: ">=13.0.0,<14.0.0"
  - name: ansible.posix
    version: ">=2.2.0,<3.0.0"
  - name: community.sops
    version: ">=2.4.0,<3.0.0"
  - name: containers.podman
    version: ">=1.20.0,<2.0.0"
```

- [ ] **Step 2: Write the host Python pins**

Create `host-requirements.txt`:

```text
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri
# Installed into /opt/deerlab/venv on each host by roles/base_pull.
ansible==14.3.1
passlib==1.7.4
```

- [ ] **Step 3: Enable the argument-spec rule**

Replace the `enable_list` in `.ansible-lint` with:

```yaml
enable_list:
  - args
  - empty-string-compare
  - no-log-password
  - no-same-owner
  - no-prompting
  - role-argument-spec
```

Replace the `exclude_paths` block with:

```yaml
exclude_paths:
  - .cache/
  - .git/
  - .venv/
  - collections/
  - "*.sops.yaml"
  - secrets/
```

- [ ] **Step 4: Adjust `ansible.cfg`**

Add `interpreter_python = auto_silent` under `[defaults]`, directly after `inventory = inventory/hosts.yml`. Leave every other line as it is.

- [ ] **Step 5: Install collections and run the linter on the empty tree**

Run:

```bash
mise x -- ansible-galaxy collection install -r requirements.yml
mise x -- ansible-galaxy collection list 2>/dev/null | grep -E 'community.general|ansible.posix|community.sops|containers.podman'
mise x -- ansible-lint
```

Expected: the four collections list at versions within the pins (community.general 13.x, containers.podman 1.20.x, community.sops 2.4.x, ansible.posix 2.2.x). ansible-lint reports `Passed: 0 failure(s), 0 warning(s)`.

- [ ] **Step 6: Commit**

```bash
git add requirements.yml host-requirements.txt .ansible-lint ansible.cfg
git commit -m "Move to Ansible 14 and pin the collections it ships

Also enable the role-argument-spec rule, which CLAUDE.md has required
all along but was never switched on."
```

### Task 4: CI, promotion workflow, Renovate and the justfile

**Files:**

- Modify: `.github/workflows/ci.yml`
- Create: `.github/workflows/promote.yml`
- Create: `renovate.json`
- Modify: `justfile`

**Interfaces:**

- Produces: `just ci` as the single local and CI gate; `just plan HOST`, `just apply HOST`, `just bootstrap HOST`, `just merge BRANCH`, `just secrets-edit FILE`, `just secrets-rekey`, `just backup-prune SERVICE`, `just restore-drill SERVICE`, `just idempotency HOST`. Later tasks call these by name.

- [ ] **Step 1: Rewrite the justfile**

```just
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Install all tools and pre-commit hooks
setup:
    mise trust --yes mise.toml
    mise install --yes
    ansible-galaxy collection install -r requirements.yml
    pre-commit install
    @echo "Setup complete"

# Run all CI checks locally
ci: reuse-lint ansible-lint shellcheck markdownlint security-scan gitleaks check-trailing-whitespace check-eof-newline check-yaml check-json check-merge-conflicts
    @echo ""
    @echo "════════════════════════════════════════"
    @echo "  All CI checks passed"
    @echo "════════════════════════════════════════"

# Check REUSE/SPDX licensing compliance
reuse-lint:
    @echo "=== Checking REUSE compliance ==="
    reuse lint

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
    find . -name '*.sh' -not -path './collections/*' -not -path './.devcontainer/config/*' -print0 | xargs -0 shellcheck
    echo "shellcheck passed"

# Lint all Markdown files
markdownlint:
    @echo "=== Running markdownlint ==="
    markdownlint-cli2 "**/*.md" "!collections/**"

# Run Trivy configuration scan
security-scan:
    @echo "=== Running Trivy security scan ==="
    trivy config . --severity HIGH,CRITICAL --exit-code 1 --skip-dirs collections

# Run gitleaks secret scan
gitleaks:
    @echo "=== Running gitleaks secret scan ==="
    gitleaks git --redact --verbose

# Spell check (advisory in CI)
spellcheck:
    cspell --config cspell.json --no-progress "**/*.md" "**/*.yml" "**/*.yaml" "**/*.j2" "**/*.toml" "!collections/**"

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

# Run pre-commit on all files
pre-commit:
    pre-commit run --all-files

# Format Markdown and YAML
fmt:
    markdownlint-cli2 --fix "**/*.md" "!collections/**"
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

# Fast-forward main to a green branch and push, preserving your commit signatures
merge branch:
    gh pr checks {{ branch }} --required --watch
    git switch main
    git pull --ff-only origin main
    git merge --ff-only {{ branch }}
    git push origin main

# Edit a SOPS-encrypted file
secrets-edit file:
    sops {{ file }}

# Re-encrypt every SOPS file for the recipients currently listed in .sops.yaml
secrets-rekey:
    #!/usr/bin/env bash
    set -euo pipefail
    git ls-files '*.sops.yaml' | while IFS= read -r f; do
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
```

- [ ] **Step 2: Rewrite the CI workflow**

Replace `.github/workflows/ci.yml` with:

```yaml
# SPDX-License-Identifier: 0BSD
# SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me>

name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  checks:
    name: Lint and validate
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - name: Checkout
        uses: actions/checkout@v7.0.1
        with:
          fetch-depth: 0

      - name: Setup tools via mise
        uses: jdx/mise-action@v4.3.0
        with:
          install: true
          cache: true

      - name: Install Ansible collections
        run: ansible-galaxy collection install -r requirements.yml

      - name: Run every check
        run: just ci

  spell-check:
    name: Spell check (advisory)
    runs-on: ubuntu-latest
    timeout-minutes: 5
    continue-on-error: true
    steps:
      - name: Checkout
        uses: actions/checkout@v7.0.1

      - name: Setup tools via mise
        uses: jdx/mise-action@v4.3.0
        with:
          install: true
          cache: true

      - name: Run cspell
        run: just spellcheck
```

- [ ] **Step 3: Create the promotion workflow**

Create `.github/workflows/promote.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me>

# Fast-forwards the release branch to main once CI has passed on main.
# The hosts pull release, verify the head commit's signature, and apply.

name: Promote

on:
  workflow_run:
    workflows: [CI]
    branches: [main]
    types: [completed]

permissions:
  contents: write

jobs:
  promote:
    name: Fast-forward release
    if: github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Checkout main
        uses: actions/checkout@v7.0.1
        with:
          ref: main
          fetch-depth: 0

      - name: Push main to release
        run: git push origin HEAD:refs/heads/release
```

- [ ] **Step 4: Create the Renovate configuration**

Create `renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended", "docker:pinDigests"],
  "timezone": "Australia/Sydney",
  "schedule": ["before 6am on monday"],
  "enabledManagers": ["custom.regex", "ansible-galaxy", "mise", "github-actions", "pip_requirements", "pre-commit"],
  "customManagers": [
    {
      "customType": "regex",
      "description": "Container image references in inventory service definitions (image: registry/repo:tag@sha256:digest)",
      "managerFilePatterns": ["/^inventory/group_vars/.+\\.ya?ml$/"],
      "matchStrings": [
        "image:\\s*\"?(?<depName>[a-z0-9.-]+(?:/[a-z0-9._-]+)+):(?<currentValue>[A-Za-z0-9._-]+)@(?<currentDigest>sha256:[a-f0-9]{64})\"?"
      ],
      "datasourceTemplate": "docker",
      "versioningTemplate": "docker"
    }
  ],
  "packageRules": [
    {
      "matchManagers": ["custom.regex"],
      "groupName": "container images",
      "labels": ["dependencies", "images"]
    },
    {
      "matchManagers": ["mise", "pip_requirements"],
      "matchPackageNames": ["ansible", "pipx:ansible"],
      "groupName": "ansible"
    }
  ]
}
```

- [ ] **Step 5: Validate**

Run:

```bash
python3 -c "import json;json.load(open('renovate.json'))" && echo renovate.json ok
mise x -- yamllint .github/workflows/ci.yml .github/workflows/promote.yml
just --list
```

Expected: `renovate.json ok`, no yamllint output, and the recipe list shows `plan`, `apply`, `bootstrap`, `merge`, `secrets-rekey`, `backup-prune`, `restore-drill`, `idempotency`.

Run: `just ci`
Expected: passes. There are no roles yet, so ansible-lint has nothing to fail on.

- [ ] **Step 6: Commit**

```bash
git add justfile .github/workflows/ci.yml .github/workflows/promote.yml renovate.json
git commit -m "Rebuild CI around just ci and add the release promotion

One CI job installs the toolchain with mise and runs the same recipe a
developer runs locally. A second workflow fast-forwards release to main
after CI passes, which is the branch the hosts pull. Renovate replaces
Dependabot so collections, mise pins, pip pins, actions and container
image digests in inventory all get pull requests."
```

- [ ] **Step 7: One-time GitHub configuration**

In the repository settings on GitHub: create a ruleset on `main` requiring signed commits, linear history, and the `Lint and validate` status check. Create a ruleset on `release` blocking force pushes and requiring signed commits. Install the Renovate GitHub App on the repository. Create the `release` branch once from `main`:

```bash
git push origin main:refs/heads/release
```

### Task 5: Inventory and playbook skeleton

**Files:**

- Create: `inventory/hosts.yml`
- Create: `inventory/group_vars/all/main.yml`
- Create: `inventory/group_vars/all/secrets.sops.yaml`
- Create: `inventory/group_vars/podman_hosts/main.yml`
- Create: `inventory/group_vars/edge/main.yml`
- Create: `inventory/group_vars/services/main.yml`
- Create: `inventory/group_vars/services/secrets.sops.yaml`
- Create: `inventory/host_vars/edge1/main.yml`, `inventory/host_vars/edge1/secrets.sops.yaml`
- Create: `inventory/host_vars/svc1/main.yml`, `inventory/host_vars/svc1/secrets.sops.yaml`
- Create: `secrets/backup-admin.sops.yaml`
- Create: `playbooks/site.yml`, `playbooks/deps.yml`, `playbooks/base.yml`, `playbooks/edge.yml`, `playbooks/services.yml`
- Modify: `.sops.yaml`

**Interfaces:**

- Produces: the variable names every role reads. Roles reference these exact names: `deerlab_admin_ssh_keys`, `deerlab_wg_port`, `deerlab_wg_ipv4_prefix`, `deerlab_wg_ipv6_prefix`, `deerlab_domain`, `deerlab_ntfy_url`, `deerlab_ntfy_token`, `deerlab_deadman_urls`, `deerlab_root_password_hash`, `deerlab_allowed_signers`, `deerlab_repo_url`, `base_wireguard_preshared_key`, `base_wireguard_private_key`, `base_wireguard_public_key`, `base_wireguard_ipv4`, `base_wireguard_ipv6`, `base_wireguard_public_endpoint`, `base_firewall_role`, `podman_services`, `podman_user_registries`, `backup_s3_bucket`, `backup_s3_endpoint`, `backup_<service>_restic_password`, `backup_<service>_s3_access_key`, `backup_<service>_s3_secret_key`, `wallabag_symfony_secret`, `deerlab_acme_email`, `caddy_caddyfile`.

- [ ] **Step 1: Write the plain inventory files**

`inventory/hosts.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

all:
  children:
    podman_hosts:
      children:
        edge:
          hosts:
            edge1:
        services:
          hosts:
            svc1:
```

`inventory/group_vars/all/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

# Public data shared by every host. Secrets live in secrets.sops.yaml.

deerlab_timezone: Etc/UTC

# SSH public keys allowed to log in as the admin user.
deerlab_admin_ssh_keys:
  - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPUTYOURKEYHERE operator@laptop"

# Keys allowed to sign commits on the release branch, in allowed_signers format.
deerlab_allowed_signers:
  - "info@ameri.me ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPUTYOURKEYHERE"

deerlab_repo_url: https://github.com/aryonoco/deerlab.git

deerlab_wg_port: <WireGuard port>
deerlab_wg_ipv4_prefix: <tunnel IPv4 prefix>
deerlab_wg_ipv6_prefix: <tunnel IPv6 prefix>

# GitHub's SSH host key is not needed: hosts clone over HTTPS.
```

Replace the two `AAAAC3...PUTYOURKEYHERE` values with the operator's real public keys. They are inventory data, not secrets.

`inventory/group_vars/podman_hosts/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

# Registries every service user may pull from. Anything else is rejected
# by the per-user policy.json that roles/podman_user writes.
podman_user_registries:
  - docker.io
```

`inventory/group_vars/edge/main.yml` (the `podman_services` dictionary and `caddy_caddyfile` are filled in Task 16; create the file now with the firewall role only):

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_firewall_role: edge
podman_services: {}
```

`inventory/group_vars/services/main.yml` (the Wallabag definition is added in Task 14):

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_firewall_role: services
podman_services: {}
```

`inventory/host_vars/edge1/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

ansible_host: 203.0.113.10
base_wireguard_ipv4: <edge tunnel IPv4>
base_wireguard_ipv6: "<edge tunnel IPv6>"
base_wireguard_public_key: "REPLACED-IN-TASK-8"
# Public address and port the services host connects to. Literal IP, not a name.
base_wireguard_public_endpoint: "203.0.113.10:<WireGuard port>"
```

`inventory/host_vars/svc1/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

ansible_host: 203.0.113.20
base_wireguard_ipv4: <services tunnel IPv4>
base_wireguard_ipv6: "<services tunnel IPv6>"
base_wireguard_public_key: "REPLACED-IN-TASK-8"
```

Replace the two `203.0.113.x` addresses with the provider-assigned public IPv4 addresses when the VPSs exist. Task 8 replaces the WireGuard public keys.

- [ ] **Step 2: Create the encrypted files**

Each file is created with `sops` so it is encrypted from the first commit. Values marked `CHANGE-ME` are filled by the operator; the plan cannot know them.

```bash
mkdir -p inventory/group_vars/all inventory/group_vars/services inventory/host_vars/edge1 inventory/host_vars/svc1 secrets
cat > /tmp/all-secrets.yaml <<'EOF'
ansible_user: deerlab
deerlab_domain: <domain>
deerlab_acme_email: CHANGE-ME
deerlab_ntfy_url: https://ntfy.sh/CHANGE-ME-topic
deerlab_ntfy_token: CHANGE-ME
deerlab_root_password_hash: CHANGE-ME
deerlab_deadman_urls:
  pull:
    edge1: https://hc-ping.com/CHANGE-ME
    svc1: https://hc-ping.com/CHANGE-ME
  backup:
    caddy: https://hc-ping.com/CHANGE-ME
    wallabag: https://hc-ping.com/CHANGE-ME
base_wireguard_preshared_key: CHANGE-ME
backup_s3_bucket: s3:https://CHANGE-ME.example/deerlab-backups
backup_s3_endpoint: https://CHANGE-ME.example
EOF
mise x -- sops --encrypt --output inventory/group_vars/all/secrets.sops.yaml /tmp/all-secrets.yaml
cat > /tmp/services-secrets.yaml <<'EOF'
wallabag_symfony_secret: CHANGE-ME
backup_wallabag_restic_password: CHANGE-ME
backup_wallabag_s3_access_key: CHANGE-ME
backup_wallabag_s3_secret_key: CHANGE-ME
EOF
mise x -- sops --encrypt --output inventory/group_vars/services/secrets.sops.yaml /tmp/services-secrets.yaml
for h in edge1 svc1; do
  printf 'base_wireguard_private_key: CHANGE-ME\n' > /tmp/host-secrets.yaml
  mise x -- sops --encrypt --output "inventory/host_vars/$h/secrets.sops.yaml" /tmp/host-secrets.yaml
done
cat > /tmp/backup-admin.yaml <<'EOF'
AWS_ACCESS_KEY_ID: CHANGE-ME
AWS_SECRET_ACCESS_KEY: CHANGE-ME
EOF
mise x -- sops --encrypt --output secrets/backup-admin.sops.yaml /tmp/backup-admin.yaml
rm -f /tmp/all-secrets.yaml /tmp/services-secrets.yaml /tmp/host-secrets.yaml /tmp/backup-admin.yaml
```

Then fill the real values with `just secrets-edit <file>`. Generate the pieces you can generate now:

```bash
mise x -- age --version >/dev/null
wg genpsk                                  # base_wireguard_preshared_key
openssl passwd -6                          # deerlab_root_password_hash, for the provider console
openssl rand -base64 48 | tr -d '/+=' | cut -c1-48   # wallabag_symfony_secret
openssl rand -base64 48 | tr -d '/+=' | cut -c1-48   # backup_wallabag_restic_password
```

The ntfy topic and token come from ntfy.sh (a self-served access token with write permission on the topic), the dead-man URLs from a healthchecks.io project with four checks, and the S3 values from the bucket you create in Task 18.

- [ ] **Step 3: Register the secrets path in `.sops.yaml`**

Replace `.sops.yaml` with:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

# Recipients: the operator key, then one key per host added at bootstrap
# (Task 11). Run `just secrets-rekey` after editing this list.
creation_rules:
  - path_regex: '\.sops\.yaml$'
    age: "age10ef6lafmvtk8myhsl28a79zz3463f6xupf8vxx5uduyptmtxmunq4v8nvm"
```

- [ ] **Step 4: Write the playbooks**

Only `site.yml` and `deps.yml` exist after this task. `base.yml` is created in Task 7 and grows one role per task, `services.yml` in Task 16 and `edge.yml` in Task 18, so that every intermediate commit lints green with no missing roles.

`playbooks/site.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Install collections into the checkout
  ansible.builtin.import_playbook: deps.yml
```

`playbooks/deps.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

# Runs on the controller. In pull mode the controller is the host itself and
# the checkout is the working directory, so collections land in
# <checkout>/collections where ansible.cfg looks for them.
- name: Install collections into the checkout
  hosts: podman_hosts
  gather_facts: false
  become: false
  tasks:
    - name: Install the pinned collections
      ansible.builtin.command:
        cmd: "{{ ansible_playbook_python | dirname }}/ansible-galaxy collection install -r requirements.yml -p collections"
        chdir: "{{ playbook_dir }}/.."
      register: deps_galaxy
      changed_when: "'Installing' in deps_galaxy.stdout"
      delegate_to: localhost
      run_once: true
```

- [ ] **Step 5: Verify the inventory parses and secrets decrypt**

Run:

```bash
mise x -- ansible-inventory --graph
mise x -- ansible-inventory --host svc1 | python3 -c "import sys,json;d=json.load(sys.stdin);print(sorted(k for k in d if k.startswith('deerlab_') or k.startswith('base_')))"
```

Expected: the graph shows `podman_hosts` containing `edge` with `edge1` and `services` with `svc1`. The variable list includes `deerlab_domain`, `deerlab_ntfy_url`, `base_wireguard_private_key`, `base_wireguard_ipv4`, proving the SOPS vars plugin decrypts.

Run: `just ci`
Expected: passes.

- [ ] **Step 6: Commit**

```bash
git add inventory secrets .sops.yaml playbooks
git commit -m "Lay out the two-host inventory and playbooks

Two groups, edge and services, under podman_hosts. Public data in
plain group and host vars, secrets in SOPS files created encrypted
from the start."
```

---

## Phase 2: Base roles on the services host

### Task 6: Provision the services VPS

**Files:**

- Modify: `inventory/host_vars/svc1/main.yml`

**Interfaces:**

- Produces: a reachable `svc1` with root key access, which every host verification step in Phase 2 uses.

- [ ] **Step 1: Create the VPS**

At the provider, create a VPS from the stock Debian 13 image with your SSH public key installed for root. Choose the smallest size with at least 2 GB RAM and 20 GB disk. Do not enable any provider firewall yet; the host firewall is the control.

- [ ] **Step 2: Record its address**

Set `ansible_host` in `inventory/host_vars/svc1/main.yml` to the public IPv4 address the provider assigned.

- [ ] **Step 3: Trust the host key and verify reachability**

```bash
ssh-keyscan -H "$(mise x -- ansible-inventory --host svc1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ansible_host"])')" >> ~/.ssh/known_hosts
mise x -- ansible svc1 -m ansible.builtin.ping -e ansible_user=root
```

Expected: `svc1 | SUCCESS` with `"ping": "pong"`.

- [ ] **Step 4: Record the network renderer for later reference**

```bash
mise x -- ansible svc1 -e ansible_user=root -m ansible.builtin.shell -a 'dpkg -l ifupdown netplan.io 2>/dev/null | grep "^ii"; systemctl is-enabled systemd-networkd networking 2>/dev/null; cat /etc/os-release | grep VERSION='
```

Expected: `VERSION="13 (trixie)"`. Note whether `ifupdown` or `netplan.io` is installed; Task 9 leaves that configuration alone either way.

- [ ] **Step 5: Commit**

```bash
git add inventory/host_vars/svc1/main.yml
git commit -m "Point svc1 at the new services VPS"
```

### Task 7: base_os role

**Files:**

- Create: `roles/base_os/defaults/main.yml`
- Create: `roles/base_os/meta/main.yml`
- Create: `roles/base_os/meta/argument_specs.yml`
- Create: `roles/base_os/tasks/main.yml`
- Create: `roles/base_os/tasks/accounts.yml`
- Create: `roles/base_os/tasks/hidepid.yml`
- Create: `roles/base_os/handlers/main.yml`
- Create: `roles/base_os/templates/chrony.conf.j2`
- Create: `roles/base_os/templates/audit.rules.j2`
- Create: `playbooks/base.yml`
- Modify: `playbooks/site.yml`

**Interfaces:**

- Consumes: `ansible_user`, `deerlab_admin_ssh_keys`, `deerlab_root_password_hash`, `deerlab_timezone` from inventory.
- Produces: the admin user named by `ansible_user` with passwordless sudo and the operator's keys, so Task 8 can disable root login. The handler name `Flag reboot required` is reused by other roles through `notify`.

- [ ] **Step 1: Write the contract first**

`roles/base_os/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/base_os/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: Debian 13 host baseline
    description: >
      Packages, the admin account, the console root password, sysctl,
      kernel command line, journald, chrony with NTS, needrestart,
      unattended-upgrades without automatic reboot, auditd with a minimal
      ruleset, and optional /proc hiding.
    options:
      base_os_timezone:
        type: str
        default: Etc/UTC
        description: System timezone.
      base_os_admin_user:
        type: str
        required: true
        description: Login name of the administrative user with sudo.
      base_os_admin_ssh_keys:
        type: list
        elements: str
        required: true
        description: Public keys allowed for the admin user. Replaces the file.
      base_os_root_password_hash:
        type: str
        required: true
        description: Crypt hash for root, used only at the provider console.
      base_os_packages:
        type: list
        elements: str
        description: Packages installed on every host.
      base_os_packages_absent:
        type: list
        elements: str
        description: Packages purged from every host.
      base_os_sysctl:
        type: dict
        description: Kernel parameters applied on every host.
      base_os_sysctl_extra:
        type: dict
        default: {}
        description: Additional kernel parameters for a host or group.
      base_os_kernel_cmdline:
        type: str
        description: Extra parameters appended to GRUB_CMDLINE_LINUX_DEFAULT.
      base_os_journald_max_use:
        type: str
        default: 512M
        description: journald SystemMaxUse.
      base_os_journald_retention:
        type: str
        default: 90day
        description: journald MaxRetentionSec.
      base_os_chrony_nts_servers:
        type: list
        elements: str
        description: NTS-capable time servers.
      base_os_auditd_enabled:
        type: bool
        default: true
        description: Install auditd with the minimal ruleset.
      base_os_hidepid_enabled:
        type: bool
        default: false
        description: >
          Mount /proc with hidepid=invisible and a proc exemption group.
          Unsupported by systemd upstream; test a lingering user manager
          before enabling.
```

- [ ] **Step 2: Add the role to a new base playbook and run the linter**

`playbooks/base.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Configure every host
  hosts: podman_hosts
  roles:
    - role: base_os
```

Append to `playbooks/site.yml`:

```yaml

- name: Configure every host
  ansible.builtin.import_playbook: base.yml
```

Run: `mise x -- ansible-lint`
Expected: FAIL, `base_os` has no tasks file yet. This confirms the linter is checking the playbook.

- [ ] **Step 3: Write defaults**

`roles/base_os/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_os_timezone: "{{ deerlab_timezone | default('Etc/UTC') }}"
base_os_admin_user: "{{ ansible_user }}"
base_os_admin_ssh_keys: "{{ deerlab_admin_ssh_keys }}"
base_os_root_password_hash: "{{ deerlab_root_password_hash }}"

base_os_packages:
  - acl
  - auditd
  - ca-certificates
  - chrony
  - curl
  - git
  - needrestart
  - nftables
  - python3-venv
  - restic
  - sqlite3
  - unattended-upgrades
  - wireguard-tools

base_os_packages_absent:
  - fail2ban
  - systemd-timesyncd

base_os_kernel_cmdline: "lockdown=integrity systemd.ssh_auto=no"

base_os_sysctl:
  # Rootless Podman needs this. Assert it explicitly so nothing can flip it.
  kernel.unprivileged_userns_clone: 1
  # Kernel
  kernel.randomize_va_space: 2
  kernel.dmesg_restrict: 1
  kernel.kptr_restrict: 2
  kernel.sysrq: 0
  kernel.yama.ptrace_scope: 2
  kernel.kexec_load_disabled: 1
  kernel.unprivileged_bpf_disabled: 2
  kernel.perf_event_paranoid: 3
  net.core.bpf_jit_harden: 2
  # Filesystem
  fs.protected_hardlinks: 1
  fs.protected_symlinks: 1
  fs.protected_fifos: 2
  fs.protected_regular: 2
  fs.suid_dumpable: 0
  # Memory
  vm.mmap_min_addr: 65536
  vm.swappiness: 10
  # Network
  net.ipv4.ip_forward: 0
  net.ipv6.conf.all.forwarding: 0
  net.ipv4.tcp_syncookies: 1
  net.ipv4.tcp_rfc1337: 1
  net.ipv4.conf.all.rp_filter: 2
  net.ipv4.conf.default.rp_filter: 2
  net.ipv4.conf.all.accept_source_route: 0
  net.ipv4.conf.default.accept_source_route: 0
  net.ipv4.conf.all.send_redirects: 0
  net.ipv4.conf.default.send_redirects: 0
  net.ipv4.conf.all.accept_redirects: 0
  net.ipv4.conf.default.accept_redirects: 0
  net.ipv4.conf.all.secure_redirects: 0
  net.ipv4.conf.default.secure_redirects: 0
  net.ipv4.conf.all.log_martians: 1
  net.ipv4.conf.default.log_martians: 1
  net.ipv4.icmp_echo_ignore_broadcasts: 1
  net.ipv4.icmp_ignore_bogus_error_responses: 1
  net.ipv6.conf.all.accept_redirects: 0
  net.ipv6.conf.default.accept_redirects: 0
  net.ipv6.conf.all.accept_source_route: 0
  net.ipv6.conf.default.accept_source_route: 0

base_os_sysctl_extra: {}

base_os_journald_max_use: 512M
base_os_journald_retention: 90day

base_os_chrony_nts_servers:
  - time.cloudflare.com
  - nts.netnod.se

base_os_auditd_enabled: true
base_os_hidepid_enabled: false
```

- [ ] **Step 4: Write the tasks**

`roles/base_os/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - base_os_admin_user | length > 0
      - base_os_admin_ssh_keys | length > 0
      - base_os_root_password_hash | length > 0
      - base_os_root_password_hash != 'CHANGE-ME'
      - ansible_facts['distribution'] == 'Debian'
      - ansible_facts['distribution_major_version'] == '13'
    fail_msg: base_os needs an admin user, admin keys, a root password hash, and a Debian 13 target

# Phase 1 — Packages

- name: Install baseline packages
  ansible.builtin.apt:
    name: "{{ base_os_packages }}"
    state: present
    update_cache: true
    cache_valid_time: 3600
  environment:
    DEBIAN_FRONTEND: noninteractive

- name: Purge packages that conflict with the design
  ansible.builtin.apt:
    name: "{{ base_os_packages_absent }}"
    state: absent
    purge: true
  environment:
    DEBIAN_FRONTEND: noninteractive

# Phase 2 — Accounts

- name: Configure the admin and root accounts
  ansible.builtin.include_tasks: accounts.yml

# Phase 3 — Time

- name: Set the timezone
  community.general.timezone:
    name: "{{ base_os_timezone }}"

- name: Configure chrony for NTS-only time sources
  ansible.builtin.template:
    src: chrony.conf.j2
    dest: /etc/chrony/conf.d/deerlab.conf
    owner: root
    group: root
    mode: "0644"
  notify: Restart chrony

- name: Enable chrony
  ansible.builtin.systemd_service:
    name: chrony
    enabled: true
    state: started

# Phase 4 — Kernel

- name: Apply kernel parameters
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/90-deerlab.conf
    sysctl_set: true
    reload: true
  loop: "{{ (base_os_sysctl | combine(base_os_sysctl_extra)) | dict2items }}"
  loop_control:
    label: "{{ item.key }}"

- name: Check that GRUB is the boot loader
  ansible.builtin.stat:
    path: /etc/default/grub
  register: base_os_grub

- name: Add kernel command line parameters
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT {{ base_os_kernel_cmdline }}"
    dest: /etc/default/grub.d/90-deerlab.cfg
    owner: root
    group: root
    mode: "0644"
  when: base_os_grub.stat.exists
  notify:
    - Update grub
    - Flag reboot required

- name: Warn when GRUB is absent
  ansible.builtin.debug:
    msg: /etc/default/grub not found. Add "{{ base_os_kernel_cmdline }}" to the boot loader by hand.
  when: not base_os_grub.stat.exists

# Phase 5 — Logging

- name: Create the persistent journal directory
  ansible.builtin.file:
    path: /var/log/journal
    state: directory
    owner: root
    group: systemd-journal
    mode: "2755"

- name: Configure journald retention
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      [Journal]
      Storage=persistent
      Compress=yes
      SystemMaxUse={{ base_os_journald_max_use }}
      MaxRetentionSec={{ base_os_journald_retention }}
    dest: /etc/systemd/journald.conf.d/10-deerlab.conf
    owner: root
    group: root
    mode: "0644"
  notify: Restart journald

# Phase 6 — Updates

- name: Enable periodic unattended upgrades
  ansible.builtin.copy:
    content: |
      // {{ ansible_managed }}
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";
    dest: /etc/apt/apt.conf.d/20auto-upgrades
    owner: root
    group: root
    mode: "0644"

- name: Configure unattended upgrades without automatic reboot
  ansible.builtin.copy:
    content: |
      // {{ ansible_managed }}
      Unattended-Upgrade::Automatic-Reboot "false";
      Unattended-Upgrade::Remove-Unused-Dependencies "true";
      Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
    dest: /etc/apt/apt.conf.d/52unattended-upgrades-local
    owner: root
    group: root
    mode: "0644"

- name: Let needrestart restart services automatically
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      $nrconf{restart} = 'a';
    dest: /etc/needrestart/conf.d/50-deerlab.conf
    owner: root
    group: root
    mode: "0644"

# Phase 7 — Audit

- name: Configure auditd
  when: base_os_auditd_enabled
  block:
    - name: Set auditd log handling
      ansible.builtin.lineinfile:
        path: /etc/audit/auditd.conf
        regexp: "{{ item.regexp }}"
        line: "{{ item.line }}"
      loop:
        - { regexp: '^max_log_file\b', line: "max_log_file = 50" }
        - { regexp: '^num_logs\b', line: "num_logs = 10" }
        - { regexp: '^max_log_file_action\b', line: "max_log_file_action = rotate" }
        - { regexp: '^space_left_action\b', line: "space_left_action = syslog" }
        - { regexp: '^admin_space_left_action\b', line: "admin_space_left_action = syslog" }
      loop_control:
        label: "{{ item.line }}"
      notify: Restart auditd

    - name: Write the audit rules
      ansible.builtin.template:
        src: audit.rules.j2
        dest: /etc/audit/rules.d/99-deerlab.rules
        owner: root
        group: root
        mode: "0640"
      notify: Restart auditd

    - name: Enable auditd
      ansible.builtin.systemd_service:
        name: auditd
        enabled: true
        state: started

# Phase 8 — /proc hiding (optional)

- name: Hide other users' processes
  ansible.builtin.include_tasks: hidepid.yml
  when: base_os_hidepid_enabled
```

`roles/base_os/tasks/accounts.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Create the admin user
  ansible.builtin.user:
    name: "{{ base_os_admin_user }}"
    groups: sudo
    append: true
    shell: /bin/bash
    create_home: true

- name: Install the admin user's SSH keys
  ansible.posix.authorized_key:
    user: "{{ base_os_admin_user }}"
    key: "{{ base_os_admin_ssh_keys | join('\n') }}"
    exclusive: true

- name: Allow the admin user to sudo without a password
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      {{ base_os_admin_user }} ALL=(ALL) NOPASSWD: ALL
    dest: /etc/sudoers.d/90-deerlab-admin
    owner: root
    group: root
    mode: "0440"
    validate: /usr/sbin/visudo -cf %s

- name: Set the root password for the provider console
  ansible.builtin.user:
    name: root
    password: "{{ base_os_root_password_hash }}"
  no_log: true
```

`roles/base_os/tasks/hidepid.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Create the proc exemption group
  ansible.builtin.group:
    name: proc
    system: true

- name: Mount /proc with hidepid
  ansible.posix.mount:
    path: /proc
    src: proc
    fstype: proc
    opts: rw,nosuid,nodev,noexec,relatime,hidepid=invisible,gid=proc
    state: present
  notify: Flag reboot required

- name: Exempt logind and polkit from hidepid
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      [Service]
      SupplementaryGroups=proc
    dest: "/etc/systemd/system/{{ item }}.service.d/10-hidepid.conf"
    owner: root
    group: root
    mode: "0644"
  loop:
    - systemd-logind
    - polkit
  notify:
    - Reload systemd
    - Flag reboot required
```

- [ ] **Step 5: Write the handlers and templates**

`roles/base_os/handlers/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Restart chrony
  ansible.builtin.systemd_service:
    name: chrony
    state: restarted

- name: Update grub
  ansible.builtin.command:
    cmd: update-grub
  changed_when: true

- name: Flag reboot required
  ansible.builtin.copy:
    content: "deerlab: a change needs a reboot to take effect\n"
    dest: /run/reboot-required
    owner: root
    group: root
    mode: "0644"

- name: Restart journald
  ansible.builtin.systemd_service:
    name: systemd-journald
    state: restarted

- name: Restart auditd  # noqa: command-instead-of-module
  ansible.builtin.command:
    cmd: service auditd restart
  changed_when: true

- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

`roles/base_os/templates/chrony.conf.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
# Only authenticated sources may be selected. The Debian pool in
# chrony.conf stays as an unauthenticated fallback that is never chosen
# while an NTS source is reachable.
authselectmode require
{% for server in base_os_chrony_nts_servers %}
server {{ server }} iburst nts
{% endfor %}
```

`roles/base_os/templates/audit.rules.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
## {{ ansible_managed }}
-D
-b 8192
-f 1

# Identity and privilege
-w /etc/sudoers -p wa -k sudo
-w /etc/sudoers.d/ -p wa -k sudo
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/subuid -p wa -k identity
-w /etc/subgid -p wa -k identity
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k privilege_escalation

# Configuration this repository owns
-w /etc/ssh/ -p wa -k sshd
-w /etc/nftables.conf -p wa -k firewall
-w /etc/systemd/network/ -p wa -k network
-w /etc/containers/systemd/ -p wa -k quadlets
-w /var/lib/systemd/linger/ -p wa -k linger
-w /etc/deerlab/ -p wa -k deerlab

# Kernel modules
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules

-e 1
```

- [ ] **Step 6: Lint**

Run: `just ci`
Expected: passes.

- [ ] **Step 7: Apply to svc1 as root and verify**

```bash
just bootstrap svc1
mise x -- ansible svc1 -e ansible_user=root -m ansible.builtin.shell -a 'sysctl kernel.unprivileged_userns_clone kernel.kptr_restrict; chronyc -N authdata | head -5; timedatectl show -p Timezone; cat /run/reboot-required; id deerlab; sudo -l -U deerlab | tail -1'
```

Expected: `kernel.unprivileged_userns_clone = 1`, `kernel.kptr_restrict = 2`, the chrony sources show `NTS` in the Mode column with a non-zero `KeyID`, `Timezone=Etc/UTC`, the reboot flag text, the admin user exists and is allowed `(ALL) NOPASSWD: ALL`. Substitute the real admin name for `deerlab`.

Reboot the host now so the kernel command line takes effect, then confirm:

```bash
mise x -- ansible svc1 -e ansible_user=root -m ansible.builtin.reboot
mise x -- ansible svc1 -e ansible_user=root -m ansible.builtin.shell -a 'cat /sys/kernel/security/lockdown; cat /proc/cmdline'
```

Expected: `none [integrity] confidentiality` and a command line containing `lockdown=integrity systemd.ssh_auto=no`.

- [ ] **Step 8: Commit**

```bash
git add roles/base_os playbooks/base.yml playbooks/site.yml
git commit -m "Add the base_os role

Packages, admin account, console root password, sysctl set with
unprivileged user namespaces pinned on, lockdown=integrity and the
systemd SSH generator disabled on the kernel command line, persistent
journald, chrony with NTS only, needrestart in automatic mode,
unattended-upgrades without automatic reboot, auditd with a minimal
ruleset, and an optional hidepid mount that is off by default."
```

### Task 8: base_ssh role

**Files:**

- Create: `roles/base_ssh/defaults/main.yml`
- Create: `roles/base_ssh/meta/main.yml`
- Create: `roles/base_ssh/meta/argument_specs.yml`
- Create: `roles/base_ssh/tasks/main.yml`
- Create: `roles/base_ssh/handlers/main.yml`
- Create: `roles/base_ssh/templates/50-deerlab.conf.j2`
- Modify: `playbooks/base.yml`

**Interfaces:**

- Consumes: the admin user from Task 7, `deerlab_wg_ipv4_prefix` and `deerlab_wg_ipv6_prefix`.
- Produces: root login disabled. After this task runs on a host, use `just apply HOST`, never `just bootstrap HOST`.

- [ ] **Step 1: Write the contract and add the role**

`roles/base_ssh/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/base_ssh/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: OpenSSH server hardening
    description: >
      Key-only authentication for one admin user, root login disabled,
      post-quantum key exchange first, per-source penalties with the
      tunnel exempt, and a validated drop-in that is removed again if
      sshd rejects it.
    options:
      base_ssh_admin_user:
        type: str
        required: true
        description: The only login allowed.
      base_ssh_penalty_exempt:
        type: list
        elements: str
        description: Prefixes exempt from PerSourcePenalties.
      base_ssh_max_auth_tries:
        type: int
        default: 3
      base_ssh_login_grace_time:
        type: int
        default: 30
      base_ssh_kex_algorithms:
        type: list
        elements: str
      base_ssh_ciphers:
        type: list
        elements: str
      base_ssh_macs:
        type: list
        elements: str
      base_ssh_host_key_algorithms:
        type: list
        elements: str
```

Append `- role: base_ssh` to the `roles` list in `playbooks/base.yml`.

Run: `mise x -- ansible-lint`
Expected: FAIL, `base_ssh` has no tasks yet.

- [ ] **Step 2: Write defaults**

`roles/base_ssh/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_ssh_admin_user: "{{ ansible_user }}"
base_ssh_penalty_exempt:
  - "{{ deerlab_wg_ipv4_prefix }}"
  - "{{ deerlab_wg_ipv6_prefix }}"
base_ssh_max_auth_tries: 3
base_ssh_login_grace_time: 30

base_ssh_kex_algorithms:
  - mlkem768x25519-sha256
  - sntrup761x25519-sha512
  - sntrup761x25519-sha512@openssh.com
  - curve25519-sha256
  - curve25519-sha256@libssh.org

base_ssh_ciphers:
  - chacha20-poly1305@openssh.com
  - aes256-gcm@openssh.com
  - aes128-gcm@openssh.com
  - aes256-ctr

base_ssh_macs:
  - hmac-sha2-512-etm@openssh.com
  - hmac-sha2-256-etm@openssh.com

base_ssh_host_key_algorithms:
  - ssh-ed25519-cert-v01@openssh.com
  - ssh-ed25519
  - rsa-sha2-512-cert-v01@openssh.com
  - rsa-sha2-512
  - rsa-sha2-256
```

- [ ] **Step 3: Write the tasks, handler and template**

`roles/base_ssh/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - base_ssh_admin_user | length > 0
    fail_msg: base_ssh_admin_user is required

- name: Confirm the admin user exists before locking root out
  ansible.builtin.getent:
    database: passwd
    key: "{{ base_ssh_admin_user }}"

- name: Remove ECDSA and DSA host keys
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - /etc/ssh/ssh_host_ecdsa_key
    - /etc/ssh/ssh_host_ecdsa_key.pub
    - /etc/ssh/ssh_host_dsa_key
    - /etc/ssh/ssh_host_dsa_key.pub
  notify: Restart ssh

- name: Remove the cloud-init sshd override
  ansible.builtin.file:
    path: /etc/ssh/sshd_config.d/50-cloud-init.conf
    state: absent
  notify: Restart ssh

- name: Deploy the sshd drop-in with rollback on validation failure
  block:
    - name: Write the sshd drop-in
      ansible.builtin.template:
        src: 50-deerlab.conf.j2
        dest: /etc/ssh/sshd_config.d/50-deerlab.conf
        owner: root
        group: root
        mode: "0644"
      register: base_ssh_dropin

    - name: Validate the full sshd configuration  # noqa: no-handler
      ansible.builtin.command:
        cmd: sshd -t
      changed_when: false
      when: base_ssh_dropin.changed

  rescue:
    - name: Remove the rejected drop-in
      ansible.builtin.file:
        path: /etc/ssh/sshd_config.d/50-deerlab.conf
        state: absent

    - name: Fail after removing the rejected drop-in
      ansible.builtin.fail:
        msg: sshd -t rejected 50-deerlab.conf. The file was removed to prevent a lockout.

- name: Restart ssh when the drop-in changed  # noqa: no-handler
  ansible.builtin.systemd_service:
    name: ssh
    state: restarted
  when: base_ssh_dropin.changed
```

`roles/base_ssh/handlers/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Restart ssh
  ansible.builtin.systemd_service:
    name: ssh
    state: restarted
```

`roles/base_ssh/templates/50-deerlab.conf.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}

# Authentication
PermitRootLogin no
AllowUsers {{ base_ssh_admin_user }}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
RequiredRSASize 3072
StrictModes yes

# Brute-force protection
MaxAuthTries {{ base_ssh_max_auth_tries }}
LoginGraceTime {{ base_ssh_login_grace_time }}
PerSourcePenalties crash:90 authfail:5 noauth:1 grace-exceeded:20 refuseconnection:10 max:600 min:15
PerSourcePenaltyExemptList {{ base_ssh_penalty_exempt | join(',') }}

# Sessions
ClientAliveInterval 300
ClientAliveCountMax 3
MaxSessions 4

# Forwarding
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
PermitUserEnvironment no

# Logging
LogLevel VERBOSE

# Algorithms
KexAlgorithms {{ base_ssh_kex_algorithms | join(',') }}
Ciphers {{ base_ssh_ciphers | join(',') }}
MACs {{ base_ssh_macs | join(',') }}
HostKeyAlgorithms {{ base_ssh_host_key_algorithms | join(',') }}

# Host keys
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
```

- [ ] **Step 4: Lint**

Run: `just ci`
Expected: passes.

- [ ] **Step 5: Apply as root one last time, then verify as the admin**

```bash
just bootstrap svc1
mise x -- ansible svc1 -m ansible.builtin.shell -a 'sshd -T | grep -E "^(permitrootlogin|allowusers|kexalgorithms|persourcepenalties)"'
mise x -- ansible svc1 -e ansible_user=root -m ansible.builtin.ping
```

Expected: the first command connects as the admin user and prints `permitrootlogin no`, `allowusers <admin>`, a key exchange list beginning with `mlkem768x25519-sha256`, and the penalty settings. The final command fails with `Permission denied (publickey)`, proving root is locked out.

- [ ] **Step 6: Commit**

```bash
git add roles/base_ssh playbooks/base.yml
git commit -m "Add the base_ssh role

Key-only login for the admin user, root disabled, post-quantum key
exchange first, per-source penalties instead of fail2ban, and a
validated drop-in that removes itself if sshd rejects it."
```

### Task 9: base_wireguard role

**Files:**

- Create: `roles/base_wireguard/defaults/main.yml`
- Create: `roles/base_wireguard/meta/main.yml`
- Create: `roles/base_wireguard/meta/argument_specs.yml`
- Create: `roles/base_wireguard/tasks/main.yml`
- Create: `roles/base_wireguard/handlers/main.yml`
- Create: `roles/base_wireguard/templates/wg.netdev.j2`
- Create: `roles/base_wireguard/templates/wg.network.j2`
- Create: `roles/base_wireguard/templates/unmanaged.network.j2`
- Modify: `inventory/host_vars/edge1/main.yml`, `inventory/host_vars/svc1/main.yml`
- Modify: `inventory/host_vars/edge1/secrets.sops.yaml`, `inventory/host_vars/svc1/secrets.sops.yaml`
- Modify: `playbooks/base.yml`

**Interfaces:**

- Consumes: `base_wireguard_private_key`, `base_wireguard_public_key`, `base_wireguard_ipv4`, `base_wireguard_ipv6`, `base_wireguard_public_endpoint` (edge only), `base_wireguard_preshared_key`, `deerlab_wg_port`, `deerlab_wg_ipv4_prefix`, `deerlab_wg_ipv6_prefix`, and the same host vars of every other host in `podman_hosts` through `hostvars`.
- Produces: interface `wg0` with the tunnel addresses, and `/etc/hosts` entries `<host>.wg` for every peer. Task 10 and Task 16 use `hostvars[groups['edge'][0]].base_wireguard_ipv4` for the edge's tunnel address.

- [ ] **Step 1: Generate the key pairs and store them**

```bash
for h in edge1 svc1; do
  wg genkey > "/tmp/$h.key"
  echo "$h public: $(wg pubkey < /tmp/$h.key)"
done
```

Put each printed public key into `base_wireguard_public_key` in `inventory/host_vars/<host>/main.yml`. Put each private key into `base_wireguard_private_key` with `just secrets-edit inventory/host_vars/<host>/secrets.sops.yaml`. Then `rm -f /tmp/edge1.key /tmp/svc1.key`. The preshared key was generated in Task 5.

- [ ] **Step 2: Write the contract and add the role**

`roles/base_wireguard/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/base_wireguard/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: Kernel WireGuard tunnel via systemd-networkd
    description: >
      One wg0 interface per host peered with every other host in the
      podman_hosts group. Keys come from SOPS and are written as files
      readable by systemd-network. A host with a public endpoint is the
      responder; the others initiate with a persistent keepalive.
    options:
      base_wireguard_interface:
        type: str
        default: wg0
      base_wireguard_port:
        type: int
        required: true
      base_wireguard_private_key:
        type: str
        required: true
        description: This host's private key, from SOPS.
      base_wireguard_public_key:
        type: str
        required: true
      base_wireguard_preshared_key:
        type: str
        required: true
        description: Shared by all peers, from SOPS.
      base_wireguard_ipv4:
        type: str
        required: true
        description: This host's tunnel IPv4 address without prefix length.
      base_wireguard_ipv6:
        type: str
        required: true
      base_wireguard_ipv4_prefix:
        type: str
        required: true
        description: Tunnel IPv4 network in CIDR form.
      base_wireguard_ipv6_prefix:
        type: str
        required: true
      base_wireguard_public_endpoint:
        type: str
        default: ""
        description: host:port other peers connect to. Set only on the edge.
      base_wireguard_mtu:
        type: int
        default: 1420
      base_wireguard_keepalive:
        type: int
        default: 25
      base_wireguard_unmanaged_match:
        type: str
        default: "en* eth*"
        description: Interface names networkd must leave to the provider's configuration.
```

Append `- role: base_wireguard` to the `roles` list in `playbooks/base.yml`.

Run: `mise x -- ansible-lint`
Expected: FAIL, `base_wireguard` has no tasks yet.

- [ ] **Step 3: Write defaults, tasks, handlers and templates**

`roles/base_wireguard/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_wireguard_interface: wg0
base_wireguard_port: "{{ deerlab_wg_port }}"
base_wireguard_ipv4_prefix: "{{ deerlab_wg_ipv4_prefix }}"
base_wireguard_ipv6_prefix: "{{ deerlab_wg_ipv6_prefix }}"
base_wireguard_public_endpoint: ""
base_wireguard_mtu: 1420
base_wireguard_keepalive: 25
base_wireguard_unmanaged_match: "en* eth*"
```

`roles/base_wireguard/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - base_wireguard_private_key | length > 0
      - base_wireguard_private_key != 'CHANGE-ME'
      - base_wireguard_preshared_key | length > 0
      - base_wireguard_preshared_key != 'CHANGE-ME'
      - base_wireguard_public_key | length > 0
      - base_wireguard_ipv4 | length > 0
      - base_wireguard_ipv6 | length > 0
    fail_msg: base_wireguard needs this host's keys and tunnel addresses
    quiet: true

- name: Build the peer list from the other hosts
  ansible.builtin.set_fact:
    base_wireguard_peers: >-
      {{ base_wireguard_peers | default([]) + [{
           'name': item,
           'public_key': hostvars[item]['base_wireguard_public_key'],
           'ipv4': hostvars[item]['base_wireguard_ipv4'],
           'ipv6': hostvars[item]['base_wireguard_ipv6'],
           'endpoint': hostvars[item]['base_wireguard_public_endpoint'] | default('')
         }] }}
  loop: "{{ groups['podman_hosts'] | difference([inventory_hostname]) }}"

- name: Write the private key
  ansible.builtin.copy:
    content: "{{ base_wireguard_private_key }}\n"
    dest: "/etc/systemd/network/{{ base_wireguard_interface }}.key"
    owner: root
    group: systemd-network
    mode: "0640"
  no_log: true
  notify: Reconfigure wg

- name: Write the preshared key
  ansible.builtin.copy:
    content: "{{ base_wireguard_preshared_key }}\n"
    dest: "/etc/systemd/network/{{ base_wireguard_interface }}.psk"
    owner: root
    group: systemd-network
    mode: "0640"
  no_log: true
  notify: Reconfigure wg

- name: Leave the provider's interfaces to their own configuration
  ansible.builtin.template:
    src: unmanaged.network.j2
    dest: /etc/systemd/network/05-unmanaged.network
    owner: root
    group: root
    mode: "0644"
  notify: Reload networkd

- name: Define the WireGuard netdev
  ansible.builtin.template:
    src: wg.netdev.j2
    dest: "/etc/systemd/network/50-{{ base_wireguard_interface }}.netdev"
    owner: root
    group: systemd-network
    mode: "0640"
  notify: Reconfigure wg

- name: Define the WireGuard network
  ansible.builtin.template:
    src: wg.network.j2
    dest: "/etc/systemd/network/50-{{ base_wireguard_interface }}.network"
    owner: root
    group: root
    mode: "0644"
  notify: Reconfigure wg

- name: Enable systemd-networkd
  ansible.builtin.systemd_service:
    name: systemd-networkd
    enabled: true
    state: started

- name: Wait for the tunnel interface at boot
  ansible.builtin.systemd_service:
    name: "systemd-networkd-wait-online@{{ base_wireguard_interface }}.service"
    enabled: true

- name: Name the peers in /etc/hosts
  ansible.builtin.lineinfile:
    path: /etc/hosts
    regexp: '\s{{ item.name }}\.wg(\s|$)'
    line: "{{ item.ipv4 }} {{ item.name }}.wg"
  loop: "{{ base_wireguard_peers }}"
  loop_control:
    label: "{{ item.name }}"

- name: Flush handlers so the tunnel is up before the firewall runs
  ansible.builtin.meta: flush_handlers
```

`roles/base_wireguard/handlers/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Reload networkd
  ansible.builtin.command:
    cmd: networkctl reload
  changed_when: true

- name: Reconfigure wg
  ansible.builtin.command:
    cmd: "networkctl reload"
  changed_when: true
  notify: Reconfigure wg interface

- name: Reconfigure wg interface
  ansible.builtin.command:
    cmd: "networkctl reconfigure {{ base_wireguard_interface }}"
  changed_when: true
  failed_when: false
```

`roles/base_wireguard/templates/wg.netdev.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
[NetDev]
Name={{ base_wireguard_interface }}
Kind=wireguard
Description=deerlab tunnel

[WireGuard]
PrivateKeyFile=/etc/systemd/network/{{ base_wireguard_interface }}.key
ListenPort={{ base_wireguard_port }}
{% for peer in base_wireguard_peers %}

[WireGuardPeer]
# {{ peer.name }}
PublicKey={{ peer.public_key }}
PresharedKeyFile=/etc/systemd/network/{{ base_wireguard_interface }}.psk
AllowedIPs={{ peer.ipv4 }}/32
AllowedIPs={{ peer.ipv6 }}/128
{% if peer.endpoint | length > 0 %}
Endpoint={{ peer.endpoint }}
PersistentKeepalive={{ base_wireguard_keepalive }}
{% endif %}
{% endfor %}
```

`roles/base_wireguard/templates/wg.network.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
[Match]
Name={{ base_wireguard_interface }}

[Network]
Address={{ base_wireguard_ipv4 }}/{{ base_wireguard_ipv4_prefix.split('/')[1] }}
Address={{ base_wireguard_ipv6 }}/{{ base_wireguard_ipv6_prefix.split('/')[1] }}

[Link]
MTUBytes={{ base_wireguard_mtu }}
RequiredForOnline=routable
```

`roles/base_wireguard/templates/unmanaged.network.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
# The provider configures the public NIC. networkd must not touch it.
[Match]
Name={{ base_wireguard_unmanaged_match }}

[Link]
Unmanaged=yes
```

- [ ] **Step 4: Lint**

Run: `just ci`
Expected: passes.

- [ ] **Step 5: Apply and verify on svc1**

```bash
just apply svc1
mise x -- ansible svc1 -m ansible.builtin.shell -a 'networkctl status wg0 | head -12; wg show wg0 | sed "s/private key.*/private key: hidden/"; getent hosts edge1.wg; ls -l /etc/systemd/network/'
```

Expected: `wg0` is `configured` with `<services tunnel IPv4>/24` and the ULA address, `wg show` lists one peer with `endpoint: <edge ip>:<WireGuard port>` and `persistent keepalive: every 25 seconds`, `getent hosts edge1.wg` prints `<edge tunnel IPv4>`, and the key files are `-rw-r----- root systemd-network`. No handshake yet; the edge does not exist until Task 18. The public interface must still show the provider's address in `networkctl status` as `unmanaged`.

- [ ] **Step 6: Commit**

```bash
git add roles/base_wireguard inventory/host_vars playbooks/base.yml
git commit -m "Add the base_wireguard role

One kernel WireGuard interface per host managed by systemd-networkd.
Peers are derived from the other hosts in the group, keys come from
SOPS, allowed addresses are pinned to single hosts, and the services
side initiates with a keepalive so it needs no public port."
```

### Task 10: base_firewall role

**Files:**

- Create: `roles/base_firewall/defaults/main.yml`
- Create: `roles/base_firewall/meta/main.yml`
- Create: `roles/base_firewall/meta/argument_specs.yml`
- Create: `roles/base_firewall/tasks/main.yml`
- Create: `roles/base_firewall/handlers/main.yml`
- Create: `roles/base_firewall/templates/nftables.conf.j2`
- Modify: `playbooks/base.yml`

**Interfaces:**

- Consumes: `base_firewall_role` (`edge` or `services`), `podman_services` (a dictionary; each value has `uid`, `egress`, and `publish` as a list of `host:container` port strings), `deerlab_wg_port`, the edge's `base_wireguard_ipv4` and `base_wireguard_ipv6` via `hostvars`, and `ansible_facts['dns']['nameservers']`.
- Produces: `/etc/nftables.conf` with table `inet deerlab`. Task 14 and Task 16 rely on the per-UID chains and the backend accept rule; Task 18 relies on the edge redirects.

- [ ] **Step 1: Write the contract and add the role**

`roles/base_firewall/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/base_firewall/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: nftables ruleset for an edge or services host
    description: >
      One templated ruleset. Default-drop input with SSH, ICMP for path
      MTU discovery, and either the edge's public ports and redirects
      or the services host's backend ports scoped to the tunnel. Output
      is permissive for root and gets a per-UID chain for every service
      user according to its egress class.
    options:
      base_firewall_role:
        type: str
        required: true
        choices: [edge, services]
      base_firewall_services:
        type: dict
        required: true
        description: The podman_services dictionary for this host.
      base_firewall_ssh_port:
        type: int
        default: 22
      base_firewall_wg_port:
        type: int
        required: true
      base_firewall_peer_ipv4:
        type: str
        default: ""
        description: Tunnel IPv4 address of the edge, required on a services host.
      base_firewall_peer_ipv6:
        type: str
        default: ""
      base_firewall_edge_tcp_redirects:
        type: dict
        description: Public port to Caddy's published port, TCP.
      base_firewall_edge_udp_redirects:
        type: dict
        description: Public port to Caddy's published port, UDP.
      base_firewall_private_v4:
        type: list
        elements: str
      base_firewall_private_v6:
        type: list
        elements: str
      base_firewall_resolvers:
        type: list
        elements: str
        description: Resolver addresses web-class services may reach on port 53.
```

Append `- role: base_firewall` to the `roles` list in `playbooks/base.yml`.

Run: `mise x -- ansible-lint`
Expected: FAIL, `base_firewall` has no tasks yet.

- [ ] **Step 2: Write defaults**

`roles/base_firewall/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_firewall_services: "{{ podman_services }}"
base_firewall_ssh_port: 22
base_firewall_wg_port: "{{ deerlab_wg_port }}"
base_firewall_peer_ipv4: "{{ hostvars[groups['edge'][0]]['base_wireguard_ipv4'] | default('') }}"
base_firewall_peer_ipv6: "{{ hostvars[groups['edge'][0]]['base_wireguard_ipv6'] | default('') }}"

base_firewall_edge_tcp_redirects:
  80: 8080
  443: 8443
base_firewall_edge_udp_redirects:
  443: 8443

base_firewall_private_v4:
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 192.168.0.0/16
  - 169.254.0.0/16
  - 100.64.0.0/10
  - 127.0.0.0/8
base_firewall_private_v6:
  - fc00::/7
  - fe80::/10
  - ::1/128

base_firewall_resolvers: "{{ ansible_facts['dns']['nameservers'] }}"
```

- [ ] **Step 3: Write the tasks, handler and template**

`roles/base_firewall/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - base_firewall_role in ['edge', 'services']
      - base_firewall_services is mapping
      - base_firewall_role == 'edge' or base_firewall_peer_ipv4 | length > 0
    fail_msg: base_firewall_role must be edge or services, and a services host needs the edge's tunnel address

- name: Collect the backend ports published on this host
  ansible.builtin.set_fact:
    base_firewall_backend_ports: >-
      {{ base_firewall_services.values()
         | map(attribute='publish')
         | flatten
         | map('regex_replace', '^([0-9]+):.*$', '\1')
         | map('int')
         | unique
         | sort }}

- name: Write the ruleset
  ansible.builtin.template:
    src: nftables.conf.j2
    dest: /etc/nftables.conf
    owner: root
    group: root
    mode: "0644"
    validate: /usr/sbin/nft --check --file %s
  notify: Reload nftables

- name: Enable nftables
  ansible.builtin.systemd_service:
    name: nftables
    enabled: true
    state: started

- name: Flush handlers so the ruleset applies before later roles test connectivity
  ansible.builtin.meta: flush_handlers
```

`roles/base_firewall/handlers/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Reload nftables
  ansible.builtin.systemd_service:
    name: nftables
    state: reloaded
```

`roles/base_firewall/templates/nftables.conf.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
#!/usr/sbin/nft -f
# {{ ansible_managed }}
# Never `systemctl stop nftables`: Debian's unit flushes every rule on stop.
flush ruleset

table inet deerlab {
{% for name, svc in base_firewall_services.items() %}
  chain svc_{{ name }} {
{% if svc.egress == 'any' %}
    accept
{% elif svc.egress == 'web' %}
    ip daddr { {{ base_firewall_private_v4 | join(', ') }} } counter drop
    ip6 daddr { {{ base_firewall_private_v6 | join(', ') }} } counter drop
{% for resolver in base_firewall_resolvers %}
    {{ 'ip6' if ':' in resolver else 'ip' }} daddr {{ resolver }} udp dport 53 accept
    {{ 'ip6' if ':' in resolver else 'ip' }} daddr {{ resolver }} tcp dport 53 accept
{% endfor %}
    tcp dport { 80, 443 } accept
    limit rate 10/minute log prefix "nft-out-{{ name }} " level info
    counter drop
{% else %}
    limit rate 10/minute log prefix "nft-out-{{ name }} " level info
    counter drop
{% endif %}
  }

{% endfor %}
  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iifname "lo" accept
    meta l4proto icmp icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } accept
    meta l4proto icmpv6 icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert, nd-router-solicit, mld-listener-query } accept
    tcp dport {{ base_firewall_ssh_port }} ct state new limit rate 10/minute burst 10 packets accept
{% if base_firewall_role == 'edge' %}
    tcp dport { {{ base_firewall_edge_tcp_redirects.values() | join(', ') }} } accept
    udp dport { {{ base_firewall_edge_udp_redirects.values() | join(', ') }} } accept
    udp dport {{ base_firewall_wg_port }} accept
{% elif base_firewall_backend_ports | length > 0 %}
    iifname "wg0" ip saddr {{ base_firewall_peer_ipv4 }} tcp dport { {{ base_firewall_backend_ports | join(', ') }} } ct state new accept
{% if base_firewall_peer_ipv6 | length > 0 %}
    iifname "wg0" ip6 saddr {{ base_firewall_peer_ipv6 }} tcp dport { {{ base_firewall_backend_ports | join(', ') }} } ct state new accept
{% endif %}
{% endif %}
    limit rate 5/minute log prefix "nft-in-drop " level info
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
    ct state established,related accept
    ct state invalid drop
    oifname "lo" accept
    meta skuid 0 accept
{% for name, svc in base_firewall_services.items() %}
    meta skuid {{ svc.uid }} jump svc_{{ name }}
{% endfor %}
  }
{% if base_firewall_role == 'edge' %}

  chain prerouting_nat {
    type nat hook prerouting priority dstnat; policy accept;
{% for from, to in base_firewall_edge_tcp_redirects.items() %}
    iifname != "lo" tcp dport {{ from }} redirect to :{{ to }}
{% endfor %}
{% for from, to in base_firewall_edge_udp_redirects.items() %}
    iifname != "lo" udp dport {{ from }} redirect to :{{ to }}
{% endfor %}
  }
{% endif %}
}
```

- [ ] **Step 4: Lint**

Run: `just ci`
Expected: passes.

- [ ] **Step 5: Apply and verify on svc1**

```bash
just apply svc1
mise x -- ansible svc1 -m ansible.builtin.shell -a 'nft list ruleset | head -40; curl -sI https://deb.debian.org | head -1; systemctl is-enabled nftables'
```

Expected: the ruleset shows `table inet deerlab` with `chain input` `policy drop`, no `svc_` chains yet because `podman_services` is empty, outbound HTTPS from root succeeds with `HTTP/2 200`, and `nftables` is `enabled`. Your SSH session survived the reload.

- [ ] **Step 6: Commit**

```bash
git add roles/base_firewall playbooks/base.yml
git commit -m "Add the base_firewall role

A single nftables template for both hosts: default-drop input,
per-service-UID output chains driven by the egress class in the
service definition, tunnel-scoped backend access on the services
host, and the 80/443 redirects to Caddy on the edge."
```

### Task 11: base_notify role

**Files:**

- Create: `roles/base_notify/defaults/main.yml`
- Create: `roles/base_notify/meta/main.yml`
- Create: `roles/base_notify/meta/argument_specs.yml`
- Create: `roles/base_notify/tasks/main.yml`
- Create: `roles/base_notify/handlers/main.yml`
- Create: `roles/base_notify/templates/ntfy.conf.j2`
- Create: `roles/base_notify/templates/notify-failure@.service.j2`
- Modify: `playbooks/base.yml`

**Interfaces:**

- Consumes: `deerlab_ntfy_url`, `deerlab_ntfy_token`.
- Produces: `notify-failure@.service` in system scope reading `/etc/deerlab/ntfy.conf`, and in user scope reading `/etc/deerlab/ntfy/%u.conf`. Task 14 writes the per-user copies. Any unit may set `OnFailure=notify-failure@%n.service`. The template `ntfy.conf.j2` is reused by Task 14 through `template: src: ../../base_notify/templates/ntfy.conf.j2`, which is why its variables are the global `deerlab_ntfy_*` names.

- [ ] **Step 1: Write the contract and add the role**

`roles/base_notify/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/base_notify/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: ntfy failure notifications
    description: >
      A templated systemd unit in system and user scope that posts to an
      ntfy topic with curl, a daily reboot-required reminder, and
      OnFailure drop-ins for the host units that matter.
    options:
      base_notify_url:
        type: str
        required: true
        description: Full ntfy topic URL.
      base_notify_token:
        type: str
        required: true
        description: Write-only access token for the topic.
      base_notify_onfailure_units:
        type: list
        elements: str
        description: System units that get an OnFailure drop-in.
```

Append `- role: base_notify` to the `roles` list in `playbooks/base.yml`.

Run: `mise x -- ansible-lint`
Expected: FAIL, `base_notify` has no tasks yet.

- [ ] **Step 2: Write defaults, tasks, handlers and templates**

`roles/base_notify/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_notify_url: "{{ deerlab_ntfy_url }}"
base_notify_token: "{{ deerlab_ntfy_token }}"
base_notify_onfailure_units:
  - nftables.service
  - systemd-networkd.service
```

`roles/base_notify/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - base_notify_url | length > 0
      - base_notify_token | length > 0
      - base_notify_token != 'CHANGE-ME'
    fail_msg: base_notify needs the ntfy URL and token
    quiet: true

- name: Create the configuration directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop:
    - /etc/deerlab
    - /etc/deerlab/ntfy

- name: Write the curl configuration for the system notifier
  ansible.builtin.template:
    src: ntfy.conf.j2
    dest: /etc/deerlab/ntfy.conf
    owner: root
    group: root
    mode: "0600"
  no_log: true

- name: Install the system-scope notifier
  ansible.builtin.template:
    src: notify-failure@.service.j2
    dest: /etc/systemd/system/notify-failure@.service
    owner: root
    group: root
    mode: "0644"
  vars:
    base_notify_credential_path: /etc/deerlab/ntfy.conf
  notify: Reload systemd

- name: Install the user-scope notifier
  ansible.builtin.template:
    src: notify-failure@.service.j2
    dest: /etc/systemd/user/notify-failure@.service
    owner: root
    group: root
    mode: "0644"
  vars:
    base_notify_credential_path: /etc/deerlab/ntfy/%u.conf
  notify: Reload systemd

- name: Install the reboot-required reminder
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      [Unit]
      Description=Notify that a reboot is required
      ConditionPathExists=/run/reboot-required

      [Service]
      Type=oneshot
      LoadCredential=ntfy.conf:/etc/deerlab/ntfy.conf
      ExecStart=/usr/bin/curl --silent --show-error --fail --max-time 15 --config %d/ntfy.conf --data "Reboot required on %H"
    dest: /etc/systemd/system/deerlab-reboot-required.service
    owner: root
    group: root
    mode: "0644"
  notify: Reload systemd

- name: Schedule the reboot-required reminder daily
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      [Timer]
      OnCalendar=daily
      RandomizedDelaySec=1h
      Persistent=true

      [Install]
      WantedBy=timers.target
    dest: /etc/systemd/system/deerlab-reboot-required.timer
    owner: root
    group: root
    mode: "0644"
  notify: Reload systemd

- name: Attach the notifier to host units
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      [Unit]
      OnFailure=notify-failure@%n.service
    dest: "/etc/systemd/system/{{ item }}.d/10-deerlab-notify.conf"
    owner: root
    group: root
    mode: "0644"
  loop: "{{ base_notify_onfailure_units }}"
  notify: Reload systemd

- name: Flush handlers before enabling the timer
  ansible.builtin.meta: flush_handlers

- name: Enable the reboot-required timer
  ansible.builtin.systemd_service:
    name: deerlab-reboot-required.timer
    enabled: true
    state: started
```

`roles/base_notify/handlers/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

`roles/base_notify/templates/ntfy.conf.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
url = "{{ deerlab_ntfy_url }}"
header = "Authorization: Bearer {{ deerlab_ntfy_token }}"
header = "Title: deerlab {{ inventory_hostname }}"
header = "Priority: high"
header = "Tags: warning"
```

`roles/base_notify/templates/notify-failure@.service.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
[Unit]
Description=Notify ntfy that %i failed

[Service]
Type=oneshot
LoadCredential=ntfy.conf:{{ base_notify_credential_path }}
ExecStart=/usr/bin/curl --silent --show-error --fail --max-time 15 --config %d/ntfy.conf --data "%i failed on %H"
```

- [ ] **Step 3: Lint**

Run: `just ci`
Expected: passes.

- [ ] **Step 4: Apply and verify on svc1**

```bash
just apply svc1
mise x -- ansible svc1 -m ansible.builtin.shell -a 'systemctl start notify-failure@manual-test.service; systemctl is-active deerlab-reboot-required.timer; systemctl cat nftables.service | grep OnFailure'
```

Expected: a notification titled `deerlab svc1` with the text `manual-test failed on svc1` arrives on the ntfy topic, the timer is `active`, and the nftables unit shows `OnFailure=notify-failure@%n.service`. Because Task 7 flagged a reboot, also run `systemctl start deerlab-reboot-required.service` and expect a `Reboot required on svc1` notification, then `rm /run/reboot-required` if the host was already rebooted in Task 7.

- [ ] **Step 5: Commit**

```bash
git add roles/base_notify playbooks/base.yml
git commit -m "Add the base_notify role

One templated notifier unit in system and user scope that posts to
ntfy with curl and a credential file, a daily reboot-required
reminder, and OnFailure drop-ins for the firewall and networkd."
```

### Task 12: base_pull role and host bootstrap completion

**Files:**

- Create: `roles/base_pull/defaults/main.yml`
- Create: `roles/base_pull/meta/main.yml`
- Create: `roles/base_pull/meta/argument_specs.yml`
- Create: `roles/base_pull/tasks/main.yml`
- Create: `roles/base_pull/handlers/main.yml`
- Create: `roles/base_pull/templates/deerlab-pull.service.j2`
- Create: `roles/base_pull/templates/deerlab-pull.timer.j2`
- Modify: `playbooks/base.yml`, `.sops.yaml`

**Interfaces:**

- Consumes: `deerlab_repo_url`, `deerlab_allowed_signers`, `deerlab_deadman_urls`, `host-requirements.txt` from the repo root.
- Produces: `/opt/deerlab/venv`, `/etc/deerlab/age.key`, `deerlab-pull.timer`. The debug output `base_pull age public key` is what the operator adds to `.sops.yaml`.

- [ ] **Step 1: Write the contract and add the role**

`roles/base_pull/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/base_pull/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: Pull-based delivery with ansible-pull
    description: >
      A pinned Ansible virtual environment, sops and age, a host age key
      generated on first run, git configured to verify SSH-signed commits
      against an allowed-signers file, and a timer that pulls the release
      branch and applies this host's plays.
    options:
      base_pull_repo_url:
        type: str
        required: true
        description: HTTPS clone URL of this repository.
      base_pull_branch:
        type: str
        default: release
      base_pull_dir:
        type: path
        default: /var/lib/deerlab
      base_pull_venv:
        type: path
        default: /opt/deerlab/venv
      base_pull_interval:
        type: str
        default: "*:0/30"
        description: systemd OnCalendar expression.
      base_pull_allowed_signers:
        type: list
        elements: str
        required: true
        description: Lines in ssh allowed_signers format.
      base_pull_deadman_url:
        type: str
        required: true
        description: URL pinged after a successful run.
      base_pull_sops_version:
        type: str
        default: "3.13.3"
      base_pull_age_key_file:
        type: path
        default: /etc/deerlab/age.key
      base_pull_enabled:
        type: bool
        default: true
        description: Whether the timer is enabled and started.
```

Append `- role: base_pull` to the `roles` list in `playbooks/base.yml`.

Run: `mise x -- ansible-lint`
Expected: FAIL, `base_pull` has no tasks yet.

- [ ] **Step 2: Write defaults, tasks, handlers and templates**

`roles/base_pull/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_pull_repo_url: "{{ deerlab_repo_url }}"
base_pull_branch: release
base_pull_dir: /var/lib/deerlab
base_pull_venv: /opt/deerlab/venv
base_pull_interval: "*:0/30"
base_pull_allowed_signers: "{{ deerlab_allowed_signers }}"
base_pull_deadman_url: "{{ deerlab_deadman_urls['pull'][inventory_hostname] }}"
base_pull_sops_version: "3.13.3"
base_pull_age_key_file: /etc/deerlab/age.key
base_pull_enabled: true
```

`roles/base_pull/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - base_pull_repo_url | length > 0
      - base_pull_allowed_signers | length > 0
      - base_pull_deadman_url | length > 0
      - base_pull_deadman_url != 'https://hc-ping.com/CHANGE-ME'
    fail_msg: base_pull needs the repository URL, allowed signers, and a dead-man URL
    quiet: true

- name: Install age and the Python tooling
  ansible.builtin.apt:
    name:
      - age
      - git
      - python3-venv
    state: present
  environment:
    DEBIAN_FRONTEND: noninteractive

- name: Install sops
  ansible.builtin.include_role:
    name: community.sops.install
  vars:
    sops_version: "{{ base_pull_sops_version }}"
    sops_source: github

- name: Create the deerlab directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0700"
  loop:
    - "{{ base_pull_dir }}"
    - /etc/deerlab

- name: Copy the pinned Python requirements
  ansible.builtin.copy:
    src: "{{ playbook_dir }}/../host-requirements.txt"
    dest: /etc/deerlab/host-requirements.txt
    owner: root
    group: root
    mode: "0644"

- name: Install Ansible into its virtual environment
  ansible.builtin.pip:
    requirements: /etc/deerlab/host-requirements.txt
    virtualenv: "{{ base_pull_venv }}"
    virtualenv_command: python3 -m venv

- name: Generate the host's age key
  ansible.builtin.command:
    cmd: "age-keygen -o {{ base_pull_age_key_file }}"
    creates: "{{ base_pull_age_key_file }}"

- name: Restrict the age key
  ansible.builtin.file:
    path: "{{ base_pull_age_key_file }}"
    owner: root
    group: root
    mode: "0400"

- name: Read the host's age public key
  ansible.builtin.command:
    cmd: "age-keygen -y {{ base_pull_age_key_file }}"
  register: base_pull_age_public
  changed_when: false

- name: Show the age public key to register in .sops.yaml
  ansible.builtin.debug:
    msg: "base_pull age public key for {{ inventory_hostname }}: {{ base_pull_age_public.stdout }}"

- name: Write the allowed signers
  ansible.builtin.copy:
    content: "{{ base_pull_allowed_signers | join('\n') }}\n"
    dest: /etc/deerlab/allowed_signers
    owner: root
    group: root
    mode: "0644"

- name: Configure git to verify SSH signatures
  community.general.git_config:
    name: "{{ item.name }}"
    value: "{{ item.value }}"
    scope: global
  loop:
    - { name: gpg.format, value: ssh }
    - { name: gpg.ssh.allowedSignersFile, value: /etc/deerlab/allowed_signers }
    - { name: safe.directory, value: "{{ base_pull_dir }}/checkout" }
  loop_control:
    label: "{{ item.name }}"

- name: Write the dead-man curl configuration
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      url = "{{ base_pull_deadman_url }}"
    dest: /etc/deerlab/deadman-pull.conf
    owner: root
    group: root
    mode: "0600"
  no_log: true

- name: Install the pull service
  ansible.builtin.template:
    src: deerlab-pull.service.j2
    dest: /etc/systemd/system/deerlab-pull.service
    owner: root
    group: root
    mode: "0644"
  notify: Reload systemd

- name: Install the pull timer
  ansible.builtin.template:
    src: deerlab-pull.timer.j2
    dest: /etc/systemd/system/deerlab-pull.timer
    owner: root
    group: root
    mode: "0644"
  notify: Reload systemd

- name: Flush handlers before enabling the timer
  ansible.builtin.meta: flush_handlers

- name: Enable the pull timer
  ansible.builtin.systemd_service:
    name: deerlab-pull.timer
    enabled: "{{ base_pull_enabled }}"
    state: "{{ base_pull_enabled | ternary('started', 'stopped') }}"
```

`roles/base_pull/handlers/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

`roles/base_pull/templates/deerlab-pull.service.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
[Unit]
Description=deerlab configuration pull
Wants=network-online.target
After=network-online.target
OnFailure=notify-failure@%n.service

[Service]
Type=oneshot
Environment=SOPS_AGE_KEY_FILE={{ base_pull_age_key_file }}
Environment=ANSIBLE_NOCOLOR=1
WorkingDirectory={{ base_pull_dir }}
LoadCredential=deadman.conf:/etc/deerlab/deadman-pull.conf
ExecStart={{ base_pull_venv }}/bin/ansible-pull --url {{ base_pull_repo_url }} --checkout {{ base_pull_branch }} --directory {{ base_pull_dir }}/checkout --verify-commit --clean --connection local --inventory inventory/hosts.yml --limit {{ inventory_hostname }} playbooks/site.yml
ExecStartPost=/usr/bin/curl --silent --show-error --fail --max-time 15 --config %d/deadman.conf --data "pull ok"
```

`roles/base_pull/templates/deerlab-pull.timer.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
[Timer]
OnCalendar={{ base_pull_interval }}
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Lint**

Run: `just ci`
Expected: passes.

- [ ] **Step 4: Apply, register the host key, and prove the pull works**

```bash
just apply svc1
```

Copy the age public key from the `base_pull age public key for svc1` debug line into `.sops.yaml`, so the `age:` value becomes a comma-separated list with no spaces:

```yaml
    age: "age10ef6lafmvtk8myhsl28a79zz3463f6xupf8vxx5uduyptmtxmunq4v8nvm,age1<svc1 public key>"
```

Then re-encrypt, sign, push and promote:

```bash
just secrets-rekey
git add .sops.yaml inventory secrets
git commit -m "Add svc1 as a SOPS recipient"
git push origin main
```

Wait for the `Promote` workflow to fast-forward `release`, then trigger a pull immediately instead of waiting for the timer:

```bash
mise x -- ansible svc1 -m ansible.builtin.shell -a 'systemctl start deerlab-pull.service; journalctl -u deerlab-pull.service -n 40 --no-pager | grep -E "PLAY RECAP|ok=|verify|error" '
```

Expected: `PLAY RECAP` with `svc1 : ok=... failed=0`, and no `error`. The healthchecks.io check for `pull/svc1` shows a fresh ping. A `Priority: high` notification did not arrive. If the log shows `Signature verification failed`, the commit on `release` is not signed by a key in `deerlab_allowed_signers`; sign your commits (`git config commit.gpgsign true`, `gpg.format ssh`, `user.signingkey <pubkey path>`) and push again.

- [ ] **Step 5: Commit**

```bash
git add roles/base_pull playbooks/base.yml
git commit -m "Add the base_pull role

Each host installs a pinned Ansible into a virtual environment,
generates its own age key, verifies the release branch head against
an allowed-signers file, and applies its own plays every thirty
minutes. A dead-man ping marks each successful run."
```

---

## Phase 3: Container platform and Wallabag on the services host

### Task 13: podman_host role

**Files:**

- Create: `roles/podman_host/defaults/main.yml`
- Create: `roles/podman_host/meta/main.yml`
- Create: `roles/podman_host/meta/argument_specs.yml`
- Create: `roles/podman_host/tasks/main.yml`
- Create: `roles/podman_host/templates/policy.json.j2`
- Create: `playbooks/services.yml`
- Modify: `playbooks/site.yml`

**Interfaces:**

- Consumes: `podman_user_registries` from `inventory/group_vars/podman_hosts/main.yml`.
- Produces: Podman 5.4.2 with every rootless prerequisite installed, a system-wide image policy that rejects unlisted registries, and short names disabled. Task 15's image pull depends on the policy allowing `docker.io`.

- [ ] **Step 1: Write the contract and create the services playbook**

`roles/podman_host/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/podman_host/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: Rootless Podman host prerequisites
    description: >
      Installs Podman and everything Debian only recommends for rootless
      operation, removes the legacy network and storage helpers, writes a
      default-reject image policy that allows only listed registries, and
      asserts the versions the design was written against.
    options:
      podman_host_packages:
        type: list
        elements: str
      podman_host_packages_absent:
        type: list
        elements: str
      podman_host_registries:
        type: list
        elements: str
        required: true
        description: Registries images may be pulled from.
      podman_host_min_passt_version:
        type: str
        description: Debian version string of passt with the AppArmor fix.
```

`playbooks/services.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Configure the services host
  hosts: services
  roles:
    - role: podman_host
```

Append to `playbooks/site.yml`:

```yaml

- name: Configure the services host
  ansible.builtin.import_playbook: services.yml
```

Run: `mise x -- ansible-lint`
Expected: FAIL, `podman_host` has no tasks yet.

- [ ] **Step 2: Write defaults, tasks and the policy template**

`roles/podman_host/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

podman_host_packages:
  - podman
  - uidmap
  - passt
  - netavark
  - aardvark-dns
  - dbus-user-session
  - catatonit
  - containers-storage
  - systemd-container

podman_host_packages_absent:
  - fuse-overlayfs
  - slirp4netns

podman_host_registries: "{{ podman_user_registries }}"
podman_host_min_passt_version: "0.0~git20250503.587980c-2+deb13u1"
```

`roles/podman_host/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - podman_host_registries | length > 0
    fail_msg: podman_host_registries must list at least one registry
    quiet: true

- name: Install Podman and the rootless prerequisites Debian only recommends
  ansible.builtin.apt:
    name: "{{ podman_host_packages }}"
    state: present
    update_cache: true
    cache_valid_time: 3600
  environment:
    DEBIAN_FRONTEND: noninteractive

- name: Remove the legacy helpers so nothing falls back to them
  ansible.builtin.apt:
    name: "{{ podman_host_packages_absent }}"
    state: absent
    purge: true
  environment:
    DEBIAN_FRONTEND: noninteractive

- name: Gather package facts
  ansible.builtin.package_facts:
    manager: apt

- name: Assert the Podman release the design targets
  ansible.builtin.assert:
    that:
      - ansible_facts['packages']['podman'][0]['version'] is match('^5\.4\.')
    fail_msg: "podman is {{ ansible_facts['packages']['podman'][0]['version'] }}, the Quadlet keys in this repo assume 5.4.x"

- name: Check the passt version carries the AppArmor fix
  ansible.builtin.command:
    argv:
      - dpkg
      - --compare-versions
      - "{{ ansible_facts['packages']['passt'][0]['version'] }}"
      - ge
      - "{{ podman_host_min_passt_version }}"
  changed_when: false

- name: Reject unlisted registries system-wide
  ansible.builtin.template:
    src: policy.json.j2
    dest: /etc/containers/policy.json
    owner: root
    group: root
    mode: "0644"
    backup: true

- name: Disable short image names
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      unqualified-search-registries = []
      short-name-mode = "enforcing"
    dest: /etc/containers/registries.conf.d/10-deerlab.conf
    owner: root
    group: root
    mode: "0644"
```

`roles/podman_host/templates/policy.json.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
{% for registry in podman_host_registries %}
      "{{ registry }}": [{"type": "insecureAcceptAnything"}]{{ "," if not loop.last }}
{% endfor %}
    },
    "containers-storage": {"": [{"type": "insecureAcceptAnything"}]},
    "docker-archive": {"": [{"type": "insecureAcceptAnything"}]},
    "oci-archive": {"": [{"type": "insecureAcceptAnything"}]},
    "dir": {"": [{"type": "insecureAcceptAnything"}]}
  }
}
```

- [ ] **Step 3: Lint, apply and verify**

Run: `just ci`
Expected: passes.

```bash
just apply svc1
mise x -- ansible svc1 -m ansible.builtin.shell -a 'dpkg -l podman passt uidmap dbus-user-session catatonit | grep "^ii" | awk "{print \$2, \$3}"; dpkg -l fuse-overlayfs slirp4netns 2>&1 | grep -c "^ii" ; ls /usr/lib/systemd/user-generators/podman-user-generator; python3 -m json.tool /etc/containers/policy.json | head -4'
```

Expected: `podman 5.4.2...`, `passt 0.0~git20250503...+deb13u1` or newer, the count of installed legacy helpers is `0`, the user generator exists, and the policy starts with `"default": [{"type": "reject"}]`.

- [ ] **Step 4: Commit**

```bash
git add roles/podman_host playbooks/services.yml playbooks/site.yml
git commit -m "Add the podman_host role

Debian only recommends the packages rootless Podman needs, so install
them explicitly, remove fuse-overlayfs and slirp4netns, reject images
from unlisted registries, and assert the Podman and passt versions the
Quadlet templates were written against."
```

### Task 14: podman_user role

**Files:**

- Create: `roles/podman_user/defaults/main.yml`
- Create: `roles/podman_user/meta/main.yml`
- Create: `roles/podman_user/meta/argument_specs.yml`
- Create: `roles/podman_user/tasks/main.yml`
- Create: `roles/podman_user/tasks/user.yml`
- Create: `roles/podman_user/handlers/main.yml`
- Create: `roles/podman_user/templates/subid.j2`
- Modify: `playbooks/services.yml`

**Interfaces:**

- Consumes: `podman_services` (dictionary keyed by service name; each value has `uid`, `egress`, `limits` with `memory`, `cpu`, `tasks`), `deerlab_ntfy_url`, `deerlab_ntfy_token`, `deerlab_wg_ipv4_prefix`, `deerlab_wg_ipv6_prefix`, and the template `roles/base_notify/templates/ntfy.conf.j2`.
- Produces: for every service, a system user with home `/var/lib/<name>` (mode 0700) and a `config` subdirectory, a subordinate range, linger, a running user manager with `/run/user/<uid>/bus`, `/etc/deerlab/ntfy/<name>.conf`, a slice drop-in and a wait-network drop-in. Task 15 relies on all of these existing before it runs.

- [ ] **Step 1: Write the contract and add the role**

`roles/podman_user/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/podman_user/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: One locked-down system user per service
    description: >
      Creates the service accounts with explicit UIDs, allocates
      non-overlapping subordinate ID ranges as whole templated files,
      enables lingering, orders each user manager after the tunnel,
      applies resource ceilings on the per-user slice, and gives each
      user its own copy of the ntfy credential.
    options:
      podman_user_services:
        type: dict
        required: true
        description: >
          The podman_services dictionary. Keys are service names. Each
          value needs uid (int, 2000 or higher), egress (any, web or
          none) and limits with memory, cpu and tasks.
      podman_user_uid_base:
        type: int
        default: 2000
        description: Lowest permitted service UID; the subordinate range index is uid minus this.
      podman_user_subid_base:
        type: int
        default: 100000
      podman_user_subid_count:
        type: int
        default: 65536
      podman_user_wg_interface:
        type: str
        default: wg0
      podman_user_wg_prefixes:
        type: list
        elements: str
        description: Tunnel prefixes allowed for egress-class none services.
```

Append `- role: podman_user` to the `roles` list in `playbooks/services.yml`.

Run: `mise x -- ansible-lint`
Expected: FAIL, `podman_user` has no tasks yet.

- [ ] **Step 2: Write defaults, tasks, handlers and template**

`roles/podman_user/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

podman_user_services: "{{ podman_services }}"
podman_user_uid_base: 2000
podman_user_subid_base: 100000
podman_user_subid_count: 65536
podman_user_wg_interface: wg0
podman_user_wg_prefixes:
  - "{{ deerlab_wg_ipv4_prefix }}"
  - "{{ deerlab_wg_ipv6_prefix }}"
```

`roles/podman_user/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate the service definitions
  ansible.builtin.assert:
    that:
      - item.value.uid is defined
      - item.value.uid | int >= podman_user_uid_base
      - item.value.egress in ['any', 'web', 'none']
      - item.value.limits.memory is defined
      - item.value.limits.cpu is defined
      - item.value.limits.tasks is defined
    fail_msg: "service {{ item.key }} needs uid >= {{ podman_user_uid_base }}, an egress class, and memory, cpu and tasks limits"
    quiet: true
  loop: "{{ podman_user_services | dict2items }}"
  loop_control:
    label: "{{ item.key }}"

- name: Reject duplicate UIDs
  ansible.builtin.assert:
    that:
      - podman_user_services.values() | map(attribute='uid') | list | unique | length == podman_user_services | length
    fail_msg: two services share a UID
    quiet: true

- name: Write the subordinate UID ranges
  ansible.builtin.template:
    src: subid.j2
    dest: /etc/subuid
    owner: root
    group: root
    mode: "0644"
  notify: Migrate podman storage

- name: Write the subordinate GID ranges
  ansible.builtin.template:
    src: subid.j2
    dest: /etc/subgid
    owner: root
    group: root
    mode: "0644"
  notify: Migrate podman storage

- name: Configure each service user
  ansible.builtin.include_tasks: user.yml
  loop: "{{ podman_user_services | dict2items }}"
  loop_control:
    loop_var: podman_user_item
    label: "{{ podman_user_item.key }}"

- name: Reload systemd for the drop-ins
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: Start each user manager
  ansible.builtin.systemd_service:
    name: "user@{{ item.value.uid }}.service"
    state: started
  loop: "{{ podman_user_services | dict2items }}"
  loop_control:
    label: "{{ item.key }}"

- name: Wait for each user's D-Bus socket
  ansible.builtin.wait_for:
    path: "/run/user/{{ item.value.uid }}/bus"
    timeout: 30
  loop: "{{ podman_user_services | dict2items }}"
  loop_control:
    label: "{{ item.key }}"

- name: Flush handlers so a storage migration never runs after services have started
  ansible.builtin.meta: flush_handlers
```

`roles/podman_user/tasks/user.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Create the service account for {{ podman_user_item.key }}
  ansible.builtin.user:
    name: "{{ podman_user_item.key }}"
    uid: "{{ podman_user_item.value.uid }}"
    system: true
    create_home: true
    home: "/var/lib/{{ podman_user_item.key }}"
    shell: /usr/sbin/nologin
    password: "!"
    password_lock: true

- name: Restrict the home directory of {{ podman_user_item.key }}
  ansible.builtin.file:
    path: "/var/lib/{{ podman_user_item.key }}"
    state: directory
    owner: "{{ podman_user_item.key }}"
    group: "{{ podman_user_item.key }}"
    mode: "0700"

- name: Create the config directory of {{ podman_user_item.key }}
  ansible.builtin.file:
    path: "/var/lib/{{ podman_user_item.key }}/config"
    state: directory
    owner: "{{ podman_user_item.key }}"
    group: "{{ podman_user_item.key }}"
    mode: "0750"

- name: Enable lingering for {{ podman_user_item.key }}
  ansible.builtin.command:
    cmd: "loginctl enable-linger {{ podman_user_item.key }}"
    creates: "/var/lib/systemd/linger/{{ podman_user_item.key }}"

- name: Give a private ntfy credential to {{ podman_user_item.key }}
  ansible.builtin.template:
    src: ../../base_notify/templates/ntfy.conf.j2
    dest: "/etc/deerlab/ntfy/{{ podman_user_item.key }}.conf"
    owner: root
    group: "{{ podman_user_item.key }}"
    mode: "0640"
  no_log: true

- name: Order the user manager after the tunnel for {{ podman_user_item.key }}
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      [Unit]
      Wants=network-online.target systemd-networkd-wait-online@{{ podman_user_wg_interface }}.service
      After=network-online.target systemd-networkd-wait-online@{{ podman_user_wg_interface }}.service
    dest: "/etc/systemd/system/user@{{ podman_user_item.value.uid }}.service.d/10-wait-network.conf"
    owner: root
    group: root
    mode: "0644"

- name: Cap the slice resources of {{ podman_user_item.key }}
  ansible.builtin.copy:
    content: |
      # {{ ansible_managed }}
      [Slice]
      MemoryMax={{ podman_user_item.value.limits.memory }}
      CPUQuota={{ podman_user_item.value.limits.cpu }}
      TasksMax={{ podman_user_item.value.limits.tasks }}
      {% if podman_user_item.value.egress == 'none' %}
      IPAddressDeny=any
      IPAddressAllow=localhost
      {% for prefix in podman_user_wg_prefixes %}
      IPAddressAllow={{ prefix }}
      {% endfor %}
      {% endif %}
    dest: "/etc/systemd/system/user-{{ podman_user_item.value.uid }}.slice.d/50-deerlab.conf"
    owner: root
    group: root
    mode: "0644"
```

`roles/podman_user/handlers/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Migrate podman storage
  ansible.builtin.command:
    cmd: podman system migrate
  become: true
  become_user: "{{ item.key }}"
  environment:
    XDG_RUNTIME_DIR: "/run/user/{{ item.value.uid }}"
    DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/{{ item.value.uid }}/bus"
  changed_when: true
  failed_when: false
  loop: "{{ podman_user_services | dict2items }}"
  loop_control:
    label: "{{ item.key }}"
```

`roles/podman_user/templates/subid.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
{% for name, svc in podman_user_services | dictsort %}
{{ name }}:{{ podman_user_subid_base + (svc.uid | int - podman_user_uid_base) * podman_user_subid_count }}:{{ podman_user_subid_count }}
{% endfor %}
```

- [ ] **Step 3: Lint**

Run: `just ci`
Expected: passes. The role runs against an empty `podman_services` until Task 16 adds Wallabag, so the host verification of this role happens in Task 16.

- [ ] **Step 4: Commit**

```bash
git add roles/podman_user playbooks/services.yml
git commit -m "Add the podman_user role

One system user per service with an explicit UID, a home under
/var/lib, no shell and a locked password. Subordinate ranges are
whole templated files because the user module never allocates them
for system accounts. Linger, a slice with ceilings the user cannot
raise, a drop-in ordering the user manager after the tunnel, and a
private copy of the ntfy credential complete the account."
```

### Task 15: podman_service role

**Files:**

- Create: `roles/podman_service/defaults/main.yml`
- Create: `roles/podman_service/meta/main.yml`
- Create: `roles/podman_service/meta/argument_specs.yml`
- Create: `roles/podman_service/tasks/main.yml`
- Create: `roles/podman_service/tasks/service.yml`
- Create: `roles/podman_service/templates/container.j2`
- Create: `roles/podman_service/templates/volume.j2`
- Modify: `playbooks/services.yml`

**Interfaces:**

- Consumes: everything Task 14 produced, and the full service definition documented in the argument spec below.
- Produces: `/etc/containers/systemd/users/<uid>/<name>.container` and `<name>-<volume>.volume`, Podman secrets named `<name>-<secret>`, named volumes `<name>-<volume>`, a running unit `<name>.service` in the service user's manager. Task 20 relies on the volume naming `<name>-<volume>` to find `/var/lib/<name>/.local/share/containers/storage/volumes/<name>-<volume>/_data`.

- [ ] **Step 1: Write the contract and add the role**

`roles/podman_service/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/podman_service/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: Rootless Podman Quadlet per service
    description: >
      For each service in podman_services: writes config files into the
      service user's home, creates Podman secrets, pre-pulls the pinned
      image, renders root-owned Quadlet volume and container units into
      /etc/containers/systemd/users/<uid>, reloads and verifies the user
      manager, restarts on change, and asserts the systemd cgroup manager.
    options:
      podman_service_services:
        type: dict
        required: true
        description: >
          The podman_services dictionary. Each value supports the keys
          uid (int), image (fully qualified, tag and digest), publish
          (list of host:container[/udp]), volumes (list of {name, mount}),
          mounts (list of {src, dst, ro}), tmpfs (list of strings),
          env (dict), secrets (list of {name, value, type, target}),
          config_files (list of {path, content, mode}), capabilities
          (list), read_only (bool), no_new_privileges (bool), userns
          (str), network (str), health ({cmd, interval, start_period}),
          limits ({memory, cpu, tasks, pids}), start_timeout (int),
          egress (any|web|none), backup ({sqlite: {volume, path}, volumes}).
      podman_service_unit_root:
        type: path
        default: /etc/containers/systemd/users
```

Append `- role: podman_service` to the `roles` list in `playbooks/services.yml`.

Run: `mise x -- ansible-lint`
Expected: FAIL, `podman_service` has no tasks yet.

- [ ] **Step 2: Write defaults and tasks**

`roles/podman_service/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

podman_service_services: "{{ podman_services }}"
podman_service_unit_root: /etc/containers/systemd/users
```

`roles/podman_service/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate the service definitions
  ansible.builtin.assert:
    that:
      - item.value.image is match('^[a-z0-9.-]+(/[a-z0-9._-]+)+:[A-Za-z0-9._-]+@sha256:[a-f0-9]{64}$')
      - item.value.publish is defined
      - item.value.health.cmd is defined
      - item.value.limits.pids is defined
      - (item.value.secrets | default([])) | map(attribute='value') | select('equalto', 'CHANGE-ME') | list | length == 0
    fail_msg: "service {{ item.key }} needs a fully qualified digest-pinned image, publish, health.cmd, limits.pids, and no CHANGE-ME secrets"
    quiet: true
  loop: "{{ podman_service_services | dict2items }}"
  loop_control:
    label: "{{ item.key }}"

- name: Deploy each service
  ansible.builtin.include_tasks: service.yml
  loop: "{{ podman_service_services | dict2items }}"
  loop_control:
    loop_var: podman_service_item
    label: "{{ podman_service_item.key }}"
```

`roles/podman_service/tasks/service.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Set the facts for {{ podman_service_item.key }}
  ansible.builtin.set_fact:
    podman_service_name: "{{ podman_service_item.key }}"
    podman_service_spec: "{{ podman_service_item.value }}"
    podman_service_uid: "{{ podman_service_item.value.uid }}"
    podman_service_home: "/var/lib/{{ podman_service_item.key }}"
    podman_service_unit_dir: "{{ podman_service_unit_root }}/{{ podman_service_item.value.uid }}"
    podman_service_env:
      XDG_RUNTIME_DIR: "/run/user/{{ podman_service_item.value.uid }}"
      DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/{{ podman_service_item.value.uid }}/bus"

- name: Write the config files of {{ podman_service_name }}
  ansible.builtin.copy:
    content: "{{ item.content }}"
    dest: "{{ podman_service_home }}/{{ item.path }}"
    owner: "{{ podman_service_name }}"
    group: "{{ podman_service_name }}"
    mode: "{{ item.mode | default('0640') }}"
  loop: "{{ podman_service_spec.config_files | default([]) }}"
  loop_control:
    label: "{{ item.path }}"
  register: podman_service_config_files

- name: Create the secrets of {{ podman_service_name }}
  containers.podman.podman_secret:
    name: "{{ podman_service_name }}-{{ item.name }}"
    data: "{{ item.value }}"
    state: present
  become: true
  become_user: "{{ podman_service_name }}"
  environment: "{{ podman_service_env }}"
  loop: "{{ podman_service_spec.secrets | default([]) }}"
  loop_control:
    label: "{{ item.name }}"
  no_log: true
  register: podman_service_secrets

- name: Check for the image of {{ podman_service_name }}
  ansible.builtin.command:
    cmd: "podman image exists {{ podman_service_spec.image }}"
  become: true
  become_user: "{{ podman_service_name }}"
  environment: "{{ podman_service_env }}"
  register: podman_service_image_exists
  changed_when: false
  failed_when: podman_service_image_exists.rc not in [0, 1]

- name: Pull the image of {{ podman_service_name }}
  ansible.builtin.command:
    cmd: "podman pull --quiet {{ podman_service_spec.image }}"
  become: true
  become_user: "{{ podman_service_name }}"
  environment: "{{ podman_service_env }}"
  when: podman_service_image_exists.rc == 1
  changed_when: true

- name: Create the unit directory of {{ podman_service_name }}
  ansible.builtin.file:
    path: "{{ podman_service_unit_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Write the volume units of {{ podman_service_name }}
  ansible.builtin.template:
    src: volume.j2
    dest: "{{ podman_service_unit_dir }}/{{ podman_service_name }}-{{ item.name }}.volume"
    owner: root
    group: root
    mode: "0644"
  loop: "{{ podman_service_spec.volumes | default([]) }}"
  loop_control:
    label: "{{ item.name }}"
  register: podman_service_volume_units

- name: Write the container unit of {{ podman_service_name }}
  ansible.builtin.template:
    src: container.j2
    dest: "{{ podman_service_unit_dir }}/{{ podman_service_name }}.container"
    owner: root
    group: root
    mode: "0644"
  register: podman_service_container_unit

- name: Decide on a restart of {{ podman_service_name }}
  ansible.builtin.set_fact:
    podman_service_restart: >-
      {{ podman_service_container_unit.changed
         or (podman_service_volume_units.changed | default(false))
         or (podman_service_config_files.changed | default(false))
         or (podman_service_secrets.changed | default(false)) }}

- name: Reload the user manager of {{ podman_service_name }}  # noqa: no-handler
  ansible.builtin.systemd_service:
    daemon_reload: true
    scope: user
  become: true
  become_user: "{{ podman_service_name }}"
  environment: "{{ podman_service_env }}"
  when: podman_service_restart | bool

- name: Verify the generated unit of {{ podman_service_name }}
  ansible.builtin.command:
    cmd: "systemd-analyze --user --generators=true verify {{ podman_service_name }}.service"
  become: true
  become_user: "{{ podman_service_name }}"
  environment: "{{ podman_service_env }}"
  changed_when: false

- name: Restart after a change to {{ podman_service_name }}  # noqa: no-handler
  ansible.builtin.systemd_service:
    name: "{{ podman_service_name }}.service"
    state: restarted
    scope: user
  become: true
  become_user: "{{ podman_service_name }}"
  environment: "{{ podman_service_env }}"
  when: podman_service_restart | bool

- name: Ensure the running state of {{ podman_service_name }}
  ansible.builtin.systemd_service:
    name: "{{ podman_service_name }}.service"
    state: started
    scope: user
  become: true
  become_user: "{{ podman_service_name }}"
  environment: "{{ podman_service_env }}"

- name: Read the Podman runtime facts of {{ podman_service_name }}
  ansible.builtin.command:
    cmd: podman info --format json
  become: true
  become_user: "{{ podman_service_name }}"
  environment: "{{ podman_service_env }}"
  register: podman_service_info
  changed_when: false

- name: Assert the systemd cgroup manager and native overlay for {{ podman_service_name }}
  ansible.builtin.assert:
    that:
      - (podman_service_info.stdout | from_json).host.cgroupManager == 'systemd'
      - (podman_service_info.stdout | from_json).store.graphDriverName == 'overlay'
    fail_msg: "{{ podman_service_name }} fell back to cgroupfs or a non-overlay driver; check DBUS_SESSION_BUS_ADDRESS and dbus-user-session"
    quiet: true
```

- [ ] **Step 3: Write the templates**

`roles/podman_service/templates/container.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
# Podman 5.4.2 Quadlet. Only keys that exist in 5.4.2 belong here.
[Unit]
Description={{ podman_service_name }}
OnFailure=notify-failure@%n.service

[Container]
ContainerName={{ podman_service_name }}
Image={{ podman_service_spec.image }}
Pull=never
{% for port in podman_service_spec.publish %}
PublishPort={{ port }}
{% endfor %}
{% if podman_service_spec.network is defined %}
Network={{ podman_service_spec.network }}
{% endif %}
{% for volume in podman_service_spec.volumes | default([]) %}
Volume={{ podman_service_name }}-{{ volume.name }}.volume:{{ volume.mount }}
{% endfor %}
{% for mount in podman_service_spec.mounts | default([]) %}
Volume={{ mount.src }}:{{ mount.dst }}{{ ':ro' if mount.ro | default(true) else '' }}
{% endfor %}
{% for tmpfs in podman_service_spec.tmpfs | default([]) %}
Tmpfs={{ tmpfs }}
{% endfor %}
{% for key, value in (podman_service_spec.env | default({})).items() %}
Environment={{ key }}={{ value }}
{% endfor %}
{% for secret in podman_service_spec.secrets | default([]) %}
{% if secret.type | default('mount') == 'env' %}
Secret={{ podman_service_name }}-{{ secret.name }},type=env,target={{ secret.target }}
{% else %}
Secret={{ podman_service_name }}-{{ secret.name }},type=mount,target={{ secret.target | default('/run/secrets/' ~ secret.name) }},mode=0400
{% endif %}
{% endfor %}
DropCapability=all
{% if podman_service_spec.capabilities | default([]) | length > 0 %}
AddCapability={{ podman_service_spec.capabilities | join(' ') }}
{% endif %}
NoNewPrivileges={{ 'true' if podman_service_spec.no_new_privileges | default(true) else 'false' }}
ReadOnly={{ 'true' if podman_service_spec.read_only | default(true) else 'false' }}
ReadOnlyTmpfs=true
SeccompProfile=/usr/share/containers/seccomp.json
Mask=/proc/acpi:/proc/kcore:/proc/keys:/proc/timer_list:/proc/sched_debug:/proc/latency_stats:/sys/firmware
PidsLimit={{ podman_service_spec.limits.pids }}
{% if podman_service_spec.userns is defined %}
UserNS={{ podman_service_spec.userns }}
{% endif %}
HealthCmd={{ podman_service_spec.health.cmd }}
HealthInterval={{ podman_service_spec.health.interval | default('30s') }}
HealthStartPeriod={{ podman_service_spec.health.start_period | default('60s') }}
HealthRetries=3
HealthOnFailure=kill
Notify=healthy
StopTimeout=30

[Service]
Restart=always
RestartSec=5
TimeoutStartSec={{ podman_service_spec.start_timeout | default(300) }}
MemoryMax={{ podman_service_spec.limits.memory }}
CPUQuota={{ podman_service_spec.limits.cpu }}
TasksMax={{ podman_service_spec.limits.tasks }}

[Install]
WantedBy=default.target
```

`roles/podman_service/templates/volume.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
[Volume]
VolumeName={{ podman_service_name }}-{{ item.name }}
```

- [ ] **Step 4: Lint**

Run: `just ci`
Expected: passes. Host verification comes with the first service in Task 16.

- [ ] **Step 5: Commit**

```bash
git add roles/podman_service playbooks/services.yml
git commit -m "Add the podman_service role

Renders every service from its inventory definition into a root-owned
Quadlet under /etc/containers/systemd/users, creates its secrets and
config files, pre-pulls the pinned image so units never pull, verifies
the generated unit with systemd-analyze, restarts on any change, and
asserts the systemd cgroup manager."
```

### Task 16: Wallabag on the services host

**Files:**

- Modify: `inventory/group_vars/services/main.yml`

**Interfaces:**

- Consumes: `wallabag_symfony_secret`, `deerlab_domain`.
- Produces: the `wallabag` service on `svc1`, listening on host port 8080 for the edge. Task 18's Caddyfile targets `http://<services tunnel IPv4>:8080`.

- [ ] **Step 1: Define the service**

Replace `inventory/group_vars/services/main.yml` with:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_firewall_role: services

podman_services:
  wallabag:
    uid: 2001
    # The image runs as root inside and rewrites its application tree on
    # every start, so it cannot be read-only and needs the capabilities
    # below. Each is an accepted exception recorded in the spec.
    image: docker.io/wallabag/wallabag:2.6.14@sha256:4a527e027e0d59e87c14225ef11e005af3d4890374202ad319ce5e63dfc66709
    publish:
      - "8080:80"
    volumes:
      - { name: data, mount: /var/www/wallabag/data }
      - { name: images, mount: /var/www/wallabag/web/assets/images }
    tmpfs:
      - "/tmp:rw,nosuid,nodev,noexec,size=64m"
      - "/run:rw,nosuid,nodev,size=16m"
    env:
      SYMFONY__ENV__DOMAIN_NAME: "https://wallabag.{{ deerlab_domain }}"
      SYMFONY__ENV__SERVER_NAME: wallabag
      SYMFONY__ENV__FOSUSER_REGISTRATION: "false"
      SYMFONY__ENV__DATABASE_DRIVER: pdo_sqlite
      POPULATE_DATABASE: "True"
      PHP_MEMORY_LIMIT: 256M
      TZ: Etc/UTC
    secrets:
      - { name: symfony-secret, value: "{{ wallabag_symfony_secret }}", type: env, target: SYMFONY__ENV__SECRET }
    capabilities:
      - CAP_CHOWN
      - CAP_SETUID
      - CAP_SETGID
      - CAP_NET_BIND_SERVICE
      - CAP_DAC_OVERRIDE
      - CAP_FOWNER
    read_only: false
    no_new_privileges: true
    health:
      cmd: curl --fail --silent http://localhost/api/info
      interval: 30s
      start_period: 180s
    limits:
      memory: 768M
      cpu: "100%"
      tasks: 512
      pids: 256
    start_timeout: 900
    egress: web
    backup:
      sqlite: { volume: data, path: db/wallabag.sqlite }
      volumes: [data, images]
```

- [ ] **Step 2: Lint and apply**

Run: `just ci`
Expected: passes.

Run: `just apply svc1`
Expected: the play ends with `failed=0`. The first run pulls the image and waits for the health check, which can take a few minutes because the entrypoint installs its dependencies.

- [ ] **Step 3: Verify the service, the firewall chain and the boot ordering**

```bash
mise x -- ansible svc1 -m ansible.builtin.shell -a 'systemctl --user --machine=wallabag@ is-active wallabag.service; curl -s http://127.0.0.1:8080/api/info; echo; nft list chain inet deerlab svc_wallabag | head -8; grep -c wallabag /etc/subuid; systemctl cat user@2001.service | grep After=network-online; ls -l /etc/containers/systemd/users/2001/'
```

Expected: `active`, a JSON body containing `"appname":"wallabag"`, the chain with private-range drops and the `tcp dport { 80, 443 } accept` rule, `1`, the wait-network drop-in line, and three root-owned files: `wallabag.container`, `wallabag-data.volume`, `wallabag-images.volume`.

- [ ] **Step 4: Run the UID-matching experiment**

```bash
mise x -- ansible svc1 -m ansible.builtin.shell -a '
nft add table inet probe
nft add chain inet probe out "{ type filter hook output priority filter; policy accept; }"
nft add rule inet probe out meta skuid 2001 counter
systemd-run --machine=wallabag@ --user --quiet --pipe --wait --collect podman exec wallabag curl -s -o /dev/null -w "%{http_code}\n" https://example.com/
nft list table inet probe | grep counter
nft delete table inet probe'
```

Expected: `200` from the container, then a `counter packets N bytes M` line with N greater than zero. That proves pasta's host-side sockets carry the service UID and the egress chain applies to the container.

- [ ] **Step 5: Verify the no-new-privileges and process identities**

```bash
mise x -- ansible svc1 -m ansible.builtin.shell -a 'systemd-run --machine=wallabag@ --user --quiet --pipe --wait --collect podman inspect wallabag | grep -E "no-new-privileges|CAP_[A-Z_]+" | sort -u; systemd-run --machine=wallabag@ --user --quiet --pipe --wait --collect podman exec wallabag ps -o user,comm | sort -u'
```

Expected: a `no-new-privileges` line and the six capabilities, and processes running as `root` (s6), `nginx` and `nobody` (php-fpm). The unit stayed `active` with no-new-privileges on, which settles that experiment.

- [ ] **Step 6: Commit**

```bash
git add inventory/group_vars/services/main.yml
git commit -m "Deploy Wallabag on the services host

Root inside, six capabilities, writable application tree, SQLite in a
named volume, images in a second volume, web-only egress, and the
Symfony secret from SOPS instead of the image's public default."
```

### Task 17: Trim Wallabag's capabilities empirically

**Files:**

- Modify: `inventory/group_vars/services/main.yml`

**Interfaces:**

- Produces: the minimum capability list, committed as inventory data.

- [ ] **Step 1: Remove one capability at a time**

For each capability in the order `CAP_FOWNER`, `CAP_DAC_OVERRIDE`, `CAP_NET_BIND_SERVICE`, `CAP_SETGID`, `CAP_SETUID`, `CAP_CHOWN`:

1. Delete the line from `capabilities` in `inventory/group_vars/services/main.yml`.
2. Run `just apply svc1`. The role restarts the unit and waits for the health check.
3. If the play fails at `Ensure wallabag is running` or the health check never passes, put the line back and note the capability as required. Read `journalctl --user --machine=wallabag@ -u wallabag -n 30` for the exact failure so the reason is recorded in the inventory comment.
4. If the play passes, run the checks from Task 16 Step 3 and confirm you can log in to Wallabag through the tunnel address with `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/login` returning `200`, then keep the removal.

- [ ] **Step 2: Record the result**

Update the comment above `capabilities` to state which were tested and why each remaining one is needed, using the journal messages you saw. Run `just ci`.

- [ ] **Step 3: Commit**

```bash
git add inventory/group_vars/services/main.yml
git commit -m "Trim Wallabag to the capabilities it proved to need"
```

---

## Phase 4: The edge host

### Task 18: Provision the edge, define Caddy, bootstrap

**Files:**

- Modify: `inventory/host_vars/edge1/main.yml`
- Modify: `inventory/group_vars/edge/main.yml`
- Create: `playbooks/edge.yml`
- Modify: `playbooks/site.yml`, `.sops.yaml`

**Interfaces:**

- Consumes: `deerlab_acme_email`, `deerlab_domain`, `hostvars['svc1']['base_wireguard_ipv4']`, the Wallabag backend on port 8080 from Task 16.
- Produces: the `caddy` service on `edge1`, public HTTPS for `wallabag.<domain>`, and a working tunnel in both directions.

- [ ] **Step 1: Create the VPS and point DNS at it**

Create the edge VPS exactly as in Task 6 Step 1. Set `ansible_host` and `base_wireguard_public_endpoint` in `inventory/host_vars/edge1/main.yml` to the assigned IPv4 address (endpoint form `<ip>:<WireGuard port>`). At your DNS provider create `A` and `AAAA` records for `wallabag.<domain>` pointing at the edge's public addresses; Caddy needs them for the HTTP-01 challenge on first start.

```bash
ssh-keyscan -H "$(mise x -- ansible-inventory --host edge1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ansible_host"])')" >> ~/.ssh/known_hosts
mise x -- ansible edge1 -m ansible.builtin.ping -e ansible_user=root
```

Expected: `pong`.

- [ ] **Step 2: Define the Caddy service and its Caddyfile**

Replace `inventory/group_vars/edge/main.yml` with:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

base_firewall_role: edge

# QUIC wants larger UDP buffers than Debian's default; raising them here
# means Caddy does not need CAP_NET_ADMIN to do it itself.
base_os_sysctl_extra:
  net.core.rmem_max: 7500000
  net.core.wmem_max: 7500000

caddy_caddyfile: |
  {
      admin off
      email {{ deerlab_acme_email }}
      servers {
          protocols h1 h2 h3
      }
  }

  # Internal health listener, never published.
  :8081 {
      respond /healthz 200
  }

  wallabag.{{ deerlab_domain }} {
      log {
          output stdout
          format json
      }
      reverse_proxy http://{{ hostvars['svc1']['base_wireguard_ipv4'] }}:8080 {
          health_uri /api/info
          health_interval 15s
          health_timeout 5s
          health_status 200
          lb_try_duration 5s
      }
  }

podman_services:
  caddy:
    uid: 2000
    image: docker.io/library/caddy:2.11.4@sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d
    # Host ports 80 and 443 are redirected to these by the firewall.
    publish:
      - "8080:80"
      - "8443:443"
      - "8443:443/udp"
    volumes:
      - { name: data, mount: /data }
    mounts:
      - { src: /var/lib/caddy/config, dst: /etc/caddy, ro: true }
    tmpfs:
      - "/tmp:rw,nosuid,nodev,noexec,size=64m"
      - "/config:rw,nosuid,nodev,noexec,size=16m"
    env:
      TZ: Etc/UTC
    config_files:
      - { path: config/Caddyfile, content: "{{ caddy_caddyfile }}", mode: "0640" }
    # The official binary carries a file capability and will not exec with
    # everything dropped. NET_BIND_SERVICE is confined to Caddy's namespace.
    capabilities:
      - CAP_NET_BIND_SERVICE
    read_only: true
    no_new_privileges: true
    health:
      cmd: wget -q -O /dev/null http://127.0.0.1:8081/healthz
      interval: 30s
      start_period: 30s
    limits:
      memory: 512M
      cpu: "100%"
      tasks: 256
      pids: 128
    start_timeout: 120
    egress: any
    backup:
      volumes: [data]
```

- [ ] **Step 3: Create the edge playbook**

`playbooks/edge.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Configure the edge host
  hosts: edge
  roles:
    - role: podman_host
    - role: podman_user
    - role: podman_service
```

Insert into `playbooks/site.yml` after the `base.yml` import and before the `services.yml` import:

```yaml

- name: Configure the edge host
  ansible.builtin.import_playbook: edge.yml
```

Run: `just ci`
Expected: passes.

- [ ] **Step 4: Bootstrap the edge and register its age key**

```bash
just bootstrap edge1
```

Expected: `failed=0`. Copy the `base_pull age public key for edge1` value into `.sops.yaml` as a third recipient, then:

```bash
just secrets-rekey
git add .sops.yaml inventory secrets playbooks
git commit -m "Add the edge host with Caddy and register it as a SOPS recipient"
git push origin main
```

Wait for `Promote` to succeed.

- [ ] **Step 5: Verify the tunnel, Caddy and the certificate**

```bash
mise x -- ansible podman_hosts -m ansible.builtin.shell -a 'wg show wg0 latest-handshakes'
mise x -- ansible edge1 -m ansible.builtin.shell -a 'systemctl --user --machine=caddy@ is-active caddy.service; nft list chain inet deerlab prerouting_nat'
curl -sI "https://wallabag.$(mise x -- sops -d --extract '["deerlab_domain"]' inventory/group_vars/all/secrets.sops.yaml)/login" | head -3
```

Expected: both hosts show a handshake timestamp within the last two minutes, Caddy is `active`, the NAT chain shows the three redirects, and the public URL answers `HTTP/2 200` with a valid certificate. Also start the pull on the edge once and confirm its dead-man ping: `mise x -- ansible edge1 -m ansible.builtin.shell -a 'systemctl start deerlab-pull.service'`.

- [ ] **Step 6: Verify the real client address reaches Caddy**

```bash
curl -s "https://wallabag.$(mise x -- sops -d --extract '["deerlab_domain"]' inventory/group_vars/all/secrets.sops.yaml)/api/info" >/dev/null
mise x -- ansible edge1 -m ansible.builtin.shell -a 'journalctl --user --machine=caddy@ -u caddy.service -n 5 --no-pager | grep -o "\"client_ip\":\"[^\"]*\"" | tail -1'
```

Expected: `"client_ip":"<your public address>"`, not the tunnel or loopback address.

- [ ] **Step 7: Commit**

```bash
git add inventory playbooks
git commit -m "Serve Wallabag through Caddy on the edge

Read-only Caddy with one capability, HTTP/3 enabled, ACME by HTTP-01,
JSON access logs, an internal health listener, and a plain-HTTP
upstream over the tunnel with active health checks."
```

### Task 19: First-boot experiments on the two-host system

**Files:**

- None. Results are recorded in `docs/runbook.md` in Task 22.

- [ ] **Step 1: Tunnel recovery after an edge reboot**

```bash
mise x -- ansible edge1 -m ansible.builtin.reboot
sleep 30
mise x -- ansible svc1 -m ansible.builtin.shell -a 'wg show wg0 latest-handshakes; date +%s'
```

Expected: the handshake timestamp is within 30 seconds of the printed time, with no action taken on the services host. Record the observed gap.

- [ ] **Step 2: Boot ordering on the services host**

```bash
mise x -- ansible svc1 -m ansible.builtin.reboot
mise x -- ansible svc1 -m ansible.builtin.shell -a 'systemctl --user --machine=wallabag@ is-active wallabag.service; systemctl --user --machine=wallabag@ show wallabag.service -p NRestarts; systemctl is-active network-online.target; systemctl --user --machine=wallabag@ is-active podman-user-wait-network-online.service'
```

Expected: `active`, `NRestarts=0`, `active`, `active`. If `NRestarts` is above zero, the wait-network drop-in did not order the user manager after the tunnel; check `systemctl cat user@2001.service`.

- [ ] **Step 3: HTTP/3**

Run from any machine whose curl reports `HTTP3` in `curl -V` (the devcontainer's Debian curl does):

```bash
curl -sI --http3-only "https://wallabag.$(mise x -- sops -d --extract '["deerlab_domain"]' inventory/group_vars/all/secrets.sops.yaml)/login" | head -1
```

Expected: `HTTP/3 200`. If the connection fails or stalls, remove `h3` from the `protocols` line in `caddy_caddyfile`, drop the UDP publish and redirect, and record the failure in the runbook.

- [ ] **Step 4: Pull timers on both hosts**

```bash
mise x -- ansible podman_hosts -m ansible.builtin.shell -a 'systemctl list-timers deerlab-pull.timer --no-pager | tail -2; journalctl -u deerlab-pull.service --since "-2h" --no-pager | grep -c "PLAY RECAP"'
```

Expected: the timer is scheduled on both hosts and at least one recap has been logged since the last promotion. Both healthchecks.io pull checks are green.

## Phase 5: Backups

### Task 20: backup role

**Files:**

- Create: `roles/backup/defaults/main.yml`
- Create: `roles/backup/meta/main.yml`
- Create: `roles/backup/meta/argument_specs.yml`
- Create: `roles/backup/tasks/main.yml`
- Create: `roles/backup/tasks/service.yml`
- Create: `roles/backup/templates/backup.service.j2`
- Create: `roles/backup/templates/backup.timer.j2`
- Create: `inventory/group_vars/edge/secrets.sops.yaml`
- Modify: `playbooks/edge.yml`, `playbooks/services.yml`, `justfile`

**Interfaces:**

- Consumes: `podman_services` entries with a `backup` key, `backup_s3_bucket`, `deerlab_deadman_urls['backup']`, and per service `backup_<name>_restic_password`, `backup_<name>_s3_access_key`, `backup_<name>_s3_secret_key`.
- Produces: `deerlab-backup-<name>.timer` in each service user's manager, one restic repository per service at `<bucket>/<name>`.

- [ ] **Step 1: Create the bucket and credentials**

At the S3 provider: one bucket, and for each service a key pair scoped to the prefix `<name>/` with list, get and put but no delete permission, plus one operator key pair with full access. Put the per-service pairs and restic passwords into `inventory/group_vars/services/secrets.sops.yaml` (Wallabag) and a new `inventory/group_vars/edge/secrets.sops.yaml` (Caddy), and the operator pair into `secrets/backup-admin.sops.yaml`:

```bash
cat > /tmp/edge-secrets.yaml <<'EOF'
backup_caddy_restic_password: CHANGE-ME
backup_caddy_s3_access_key: CHANGE-ME
backup_caddy_s3_secret_key: CHANGE-ME
EOF
mise x -- sops --encrypt --output inventory/group_vars/edge/secrets.sops.yaml /tmp/edge-secrets.yaml
rm -f /tmp/edge-secrets.yaml
just secrets-edit inventory/group_vars/edge/secrets.sops.yaml
just secrets-edit inventory/group_vars/services/secrets.sops.yaml
just secrets-edit secrets/backup-admin.sops.yaml
just secrets-edit inventory/group_vars/all/secrets.sops.yaml   # backup_s3_bucket, backup_s3_endpoint
```

- [ ] **Step 2: Write the contract and add the role**

`roles/backup/meta/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

dependencies: []
```

`roles/backup/meta/argument_specs.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

argument_specs:
  main:
    short_description: Per-service restic backups
    description: >
      For each service whose definition has a backup key: a user-scope
      timer and unit that dumps SQLite with the online backup API inside
      the user namespace, integrity-checks the copy, runs restic over the
      staging directory and the listed volumes, and pings a dead-man URL.
      One repository per service with credentials that cannot delete.
    options:
      backup_services:
        type: dict
        required: true
        description: The podman_services dictionary.
      backup_s3_bucket:
        type: str
        required: true
        description: restic repository prefix, for example s3:https://host/bucket.
      backup_schedule:
        type: str
        default: "*-*-* 03:00:00"
      backup_deadman_urls:
        type: dict
        required: true
        description: Service name to dead-man URL.
```

Append `- role: backup` to the `roles` list in both `playbooks/edge.yml` and `playbooks/services.yml`.

Run: `mise x -- ansible-lint`
Expected: FAIL, `backup` has no tasks yet.

- [ ] **Step 3: Write defaults, tasks and templates**

`roles/backup/defaults/main.yml`:

```yaml
# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Aryan Ameri

backup_services: "{{ podman_services }}"
backup_schedule: "*-*-* 03:00:00"
backup_deadman_urls: "{{ deerlab_deadman_urls['backup'] }}"
```

`roles/backup/tasks/main.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - backup_s3_bucket | length > 0
      - backup_s3_bucket is match('^s3:https://')
    fail_msg: backup_s3_bucket must be an s3:https:// restic repository prefix
    quiet: true

- name: Create the backup configuration directory
  ansible.builtin.file:
    path: /etc/deerlab/backup
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Configure backups for each service that asks for them
  ansible.builtin.include_tasks: service.yml
  loop: "{{ backup_services | dict2items | selectattr('value.backup', 'defined') | list }}"
  loop_control:
    loop_var: backup_item
    label: "{{ backup_item.key }}"
```

`roles/backup/tasks/service.yml`:

```yaml
# SPDX-License-Identifier: CPAL-1.0
# Copyright (c) 2026 Aryan Ameri

- name: Set the facts for {{ backup_item.key }}
  ansible.builtin.set_fact:
    backup_name: "{{ backup_item.key }}"
    backup_uid: "{{ backup_item.value.uid }}"
    backup_spec: "{{ backup_item.value.backup }}"
    backup_home: "/var/lib/{{ backup_item.key }}"
    backup_volume_root: "/var/lib/{{ backup_item.key }}/.local/share/containers/storage/volumes"
    backup_restic_password: "{{ lookup('ansible.builtin.vars', 'backup_' ~ backup_item.key ~ '_restic_password') }}"
    backup_s3_access_key: "{{ lookup('ansible.builtin.vars', 'backup_' ~ backup_item.key ~ '_s3_access_key') }}"
    backup_s3_secret_key: "{{ lookup('ansible.builtin.vars', 'backup_' ~ backup_item.key ~ '_s3_secret_key') }}"
    backup_env:
      XDG_RUNTIME_DIR: "/run/user/{{ backup_item.value.uid }}"
      DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/{{ backup_item.value.uid }}/bus"
      RESTIC_REPOSITORY: "{{ backup_s3_bucket }}/{{ backup_item.key }}"
      RESTIC_PASSWORD: "{{ lookup('ansible.builtin.vars', 'backup_' ~ backup_item.key ~ '_restic_password') }}"
      AWS_ACCESS_KEY_ID: "{{ lookup('ansible.builtin.vars', 'backup_' ~ backup_item.key ~ '_s3_access_key') }}"
      AWS_SECRET_ACCESS_KEY: "{{ lookup('ansible.builtin.vars', 'backup_' ~ backup_item.key ~ '_s3_secret_key') }}"
  no_log: true

- name: Refuse placeholder credentials for {{ backup_name }}
  ansible.builtin.assert:
    that:
      - backup_restic_password != 'CHANGE-ME'
      - backup_s3_access_key != 'CHANGE-ME'
      - backup_deadman_urls[backup_name] is defined
    fail_msg: "backup credentials or dead-man URL for {{ backup_name }} are not set"
    quiet: true

- name: Write the restic environment of {{ backup_name }}
  ansible.builtin.copy:
    content: |
      RESTIC_REPOSITORY={{ backup_s3_bucket }}/{{ backup_name }}
      RESTIC_CACHE_DIR={{ backup_home }}/.cache/restic
      AWS_ACCESS_KEY_ID={{ backup_s3_access_key }}
      AWS_SECRET_ACCESS_KEY={{ backup_s3_secret_key }}
    dest: "/etc/deerlab/backup/{{ backup_name }}.env"
    owner: root
    group: "{{ backup_name }}"
    mode: "0640"
  no_log: true

- name: Write the repository password of {{ backup_name }}
  ansible.builtin.copy:
    content: "{{ backup_restic_password }}\n"
    dest: "/etc/deerlab/backup/{{ backup_name }}.password"
    owner: root
    group: "{{ backup_name }}"
    mode: "0640"
  no_log: true

- name: Write the dead-man configuration of {{ backup_name }}
  ansible.builtin.copy:
    content: |
      url = "{{ backup_deadman_urls[backup_name] }}"
    dest: "/etc/deerlab/backup/{{ backup_name }}-deadman.conf"
    owner: root
    group: "{{ backup_name }}"
    mode: "0640"
  no_log: true

- name: Create the staging directory of {{ backup_name }}
  ansible.builtin.file:
    path: "{{ backup_home }}/backup/staging"
    state: directory
    owner: "{{ backup_name }}"
    group: "{{ backup_name }}"
    mode: "0700"

- name: Install the backup unit of {{ backup_name }}
  ansible.builtin.template:
    src: backup.service.j2
    dest: "/etc/systemd/user/deerlab-backup-{{ backup_name }}.service"
    owner: root
    group: root
    mode: "0644"
  register: backup_unit

- name: Install the backup timer of {{ backup_name }}
  ansible.builtin.template:
    src: backup.timer.j2
    dest: "/etc/systemd/user/deerlab-backup-{{ backup_name }}.timer"
    owner: root
    group: root
    mode: "0644"
  register: backup_timer

- name: Check for the repository of {{ backup_name }}
  ansible.builtin.command:
    cmd: restic cat config
  become: true
  become_user: "{{ backup_name }}"
  environment: "{{ backup_env }}"
  register: backup_repo_check
  changed_when: false
  failed_when: false
  no_log: true

- name: Initialise the repository of {{ backup_name }}
  ansible.builtin.command:
    cmd: restic init
  become: true
  become_user: "{{ backup_name }}"
  environment: "{{ backup_env }}"
  when: backup_repo_check.rc != 0
  changed_when: true
  no_log: true

- name: Reload the user manager of {{ backup_name }}  # noqa: no-handler
  ansible.builtin.systemd_service:
    daemon_reload: true
    scope: user
  become: true
  become_user: "{{ backup_name }}"
  environment:
    XDG_RUNTIME_DIR: "/run/user/{{ backup_uid }}"
    DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/{{ backup_uid }}/bus"
  when: backup_unit.changed or backup_timer.changed

- name: Enable the backup timer of {{ backup_name }}
  ansible.builtin.systemd_service:
    name: "deerlab-backup-{{ backup_name }}.timer"
    enabled: true
    state: started
    scope: user
  become: true
  become_user: "{{ backup_name }}"
  environment:
    XDG_RUNTIME_DIR: "/run/user/{{ backup_uid }}"
    DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/{{ backup_uid }}/bus"
```

`roles/backup/templates/backup.service.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
[Unit]
Description=Back up {{ backup_name }} with restic
OnFailure=notify-failure@%n.service

[Service]
Type=oneshot
EnvironmentFile=/etc/deerlab/backup/{{ backup_name }}.env
Environment=RESTIC_PASSWORD_FILE=%d/restic.password
LoadCredential=restic.password:/etc/deerlab/backup/{{ backup_name }}.password
LoadCredential=deadman.conf:/etc/deerlab/backup/{{ backup_name }}-deadman.conf
{% if backup_spec.sqlite is defined %}
# Online SQLite backup inside the user namespace so subordinate-owned files are readable.
ExecStart=/usr/bin/podman unshare /usr/bin/sqlite3 {{ backup_volume_root }}/{{ backup_name }}-{{ backup_spec.sqlite.volume }}/_data/{{ backup_spec.sqlite.path }} ".backup %h/backup/staging/{{ backup_spec.sqlite.path | basename }}"
ExecStart=/usr/bin/sh -c 'test "$(/usr/bin/sqlite3 %h/backup/staging/{{ backup_spec.sqlite.path | basename }} "PRAGMA integrity_check")" = ok'
{% endif %}
ExecStart=/usr/bin/podman unshare /usr/bin/restic backup --quiet --exclude-caches %h/backup/staging{% for volume in backup_spec.volumes | default([]) %} {{ backup_volume_root }}/{{ backup_name }}-{{ volume }}/_data{% endfor %}

ExecStartPost=/usr/bin/curl --silent --show-error --fail --max-time 15 --config %d/deadman.conf --data "backup ok"
```

`roles/backup/templates/backup.timer.j2`:

```jinja
{# SPDX-License-Identifier: CPAL-1.0 #}
{# Copyright (c) 2026 Aryan Ameri #}
# {{ ansible_managed }}
[Timer]
OnCalendar={{ backup_schedule }}
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 4: Teach the justfile which group holds a service's secrets**

Replace the `backup-prune` and `restore-drill` recipes in `justfile` with versions that take the group:

```just
# Apply retention to a service's restic repository from the operator's full-access credentials
backup-prune service group:
    #!/usr/bin/env bash
    set -euo pipefail
    export RESTIC_REPOSITORY="$(sops -d --extract '["backup_s3_bucket"]' inventory/group_vars/all/secrets.sops.yaml)/{{ service }}"
    export RESTIC_PASSWORD_COMMAND="sops -d --extract '[\"backup_{{ service }}_restic_password\"]' inventory/group_vars/{{ group }}/secrets.sops.yaml"
    sops exec-env secrets/backup-admin.sops.yaml 'restic forget --keep-within 30d --keep-within-weekly 3m --keep-within-monthly 1y --prune'

# Restore the latest snapshot of a service to a scratch directory and integrity-check it
restore-drill service group:
    #!/usr/bin/env bash
    set -euo pipefail
    target="/tmp/deerlab-restore-{{ service }}"
    rm -rf "$target"
    export RESTIC_REPOSITORY="$(sops -d --extract '["backup_s3_bucket"]' inventory/group_vars/all/secrets.sops.yaml)/{{ service }}"
    export RESTIC_PASSWORD_COMMAND="sops -d --extract '[\"backup_{{ service }}_restic_password\"]' inventory/group_vars/{{ group }}/secrets.sops.yaml"
    sops exec-env secrets/backup-admin.sops.yaml "restic restore latest --target $target"
    find "$target" -name '*.sqlite' -print -exec sqlite3 {} 'PRAGMA integrity_check' \;
    echo "Restored to $target"
```

- [ ] **Step 5: Lint, apply and run a backup by hand**

Run: `just ci`
Expected: passes.

```bash
just apply svc1
just apply edge1
mise x -- ansible svc1 -m ansible.builtin.shell -a 'systemctl --user --machine=wallabag@ start deerlab-backup-wallabag.service; journalctl --user --machine=wallabag@ -u deerlab-backup-wallabag.service -n 20 --no-pager'
mise x -- ansible edge1 -m ansible.builtin.shell -a 'systemctl --user --machine=caddy@ start deerlab-backup-caddy.service; systemctl --user --machine=caddy@ list-timers deerlab-backup-caddy.timer --no-pager | tail -2'
```

Expected: the Wallabag journal shows the unit finishing with `Deactivated successfully` and no `Failed` line, the two backup checks on healthchecks.io are green, and the Caddy timer is scheduled. Then from the devcontainer:

```bash
just restore-drill wallabag services
```

Expected: the path of the restored `wallabag.sqlite` followed by `ok`, and `Restored to /tmp/deerlab-restore-wallabag`.

- [ ] **Step 6: Commit**

```bash
git add roles/backup inventory playbooks justfile
git commit -m "Add per-service restic backups

Each service user runs its own timer: an online SQLite copy made
inside the user namespace and integrity-checked, restic over the
staging directory and the named volumes, and a dead-man ping. One
repository per service with keys that cannot delete; retention runs
from the operator's machine with keep-within."
```

### Task 21: Restore into the live volume once, to prove the runbook

**Files:**

- None.

- [ ] **Step 1: Restore a snapshot over the running Wallabag**

Do this once, on the fresh deployment, before real data exists.

```bash
mise x -- ansible svc1 -m ansible.builtin.shell -a '
systemctl --user --machine=wallabag@ stop wallabag.service
systemd-run --machine=wallabag@ --user --quiet --pipe --wait --collect podman unshare sh -c "set -e; d=/var/lib/wallabag/.local/share/containers/storage/volumes/wallabag-data/_data/db; restic restore latest --target /var/lib/wallabag/backup/restore --include /var/lib/wallabag/backup/staging/wallabag.sqlite; rm -f \$d/wallabag.sqlite-wal \$d/wallabag.sqlite-shm; cp /var/lib/wallabag/backup/restore/var/lib/wallabag/backup/staging/wallabag.sqlite \$d/wallabag.sqlite; chown 65534:65534 \$d/wallabag.sqlite; rm -rf /var/lib/wallabag/backup/restore"
systemctl --user --machine=wallabag@ start wallabag.service
systemctl --user --machine=wallabag@ is-active wallabag.service
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/login'
```

The `restic` invocation needs the repository environment. The environment file is plain `KEY=value` lines, so add `set -a; . /etc/deerlab/backup/wallabag.env; set +a; export RESTIC_PASSWORD_FILE=/etc/deerlab/backup/wallabag.password;` at the start of the `sh -c` string when you run it; it is shown without that prefix to keep the line readable.

Expected: `active` and `200`. The stale write-ahead log is deleted before the copy, which is the step that prevents a restored database from being re-corrupted.

- [ ] **Step 2: Note what you learned**

Keep the exact working command line; Task 22 puts it in the runbook.

## Phase 6: Documentation and finish

### Task 22: Runbook, README, CLAUDE.md and the idempotency check

**Files:**

- Create: `docs/runbook.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write the runbook**

Create `docs/runbook.md`:

```markdown
<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me> -->

# deerlab runbook

Operating procedures for the two-host design. The design itself is in
`docs/superpowers/specs/2026-09-05-two-host-rootless-podman-design.md`.

## Day to day

Changes reach the hosts by pull. Every host runs `deerlab-pull.timer` every
30 minutes, checks out `release`, verifies the head commit's SSH signature
against the keys in `deerlab_allowed_signers`, and applies its own plays.

1. Branch, change, run `just ci`, push, open a pull request.
2. When CI is green: `just merge <branch>`. This fast-forwards `main` from
   the devcontainer so your signature stays on the head commit. GitHub's
   merge buttons would rewrite it.
3. The `Promote` workflow fast-forwards `release`. Within 30 minutes both
   hosts apply it. Start it sooner with
   `mise x -- ansible <host> -m ansible.builtin.shell -a 'systemctl start deerlab-pull.service'`.

`just plan <host>` shows what a run would change on the real host before
you merge. `just apply <host>` pushes directly and is for bootstrap and
break-glass only.

## Bootstrapping a host

1. Create the VPS from the stock Debian 13 image with your key on root.
2. Set `ansible_host` (and `base_wireguard_public_endpoint` on the edge)
   in `inventory/host_vars/<host>/main.yml`. Generate WireGuard keys with
   `wg genkey` and `wg pubkey`; the public key goes in the same file, the
   private key in `inventory/host_vars/<host>/secrets.sops.yaml`.
3. `ssh-keyscan -H <ip> >> ~/.ssh/known_hosts`, then `just bootstrap <host>`.
   Root login is closed at the end of that run.
4. Copy the `base_pull age public key` from the output into `.sops.yaml`,
   run `just secrets-rekey`, commit, `just merge`, wait for `Promote`.
5. `mise x -- ansible <host> -m ansible.builtin.shell -a 'systemctl start deerlab-pull.service'`
   and confirm the dead-man check goes green.

## Adding a service

1. Add an entry to `podman_services` in `inventory/group_vars/services/main.yml`
   with the next UID, a digest-pinned image, published port, volumes,
   health command, limits, egress class and backup paths. Secrets go in
   `inventory/group_vars/services/secrets.sops.yaml`; reference them from
   the definition with `{{ }}`.
2. Add a site block to `caddy_caddyfile` in `inventory/group_vars/edge/main.yml`
   pointing at `http://<services tunnel IPv4>:<port>` and create the DNS records.
3. Create a healthchecks.io check for the backup and add its URL to
   `deerlab_deadman_urls.backup`. Create S3 credentials scoped to the
   service's prefix without delete permission.
4. `just plan svc1`, then merge. The firewall chain, subordinate range,
   slice, timer and Quadlet all derive from the one definition.

## Reboots

Automatic reboots are off. A daily ntfy message says `Reboot required on
<host>` while `/run/reboot-required` exists. Reboot the services host first
with `mise x -- ansible svc1 -m ansible.builtin.reboot`, confirm
`systemctl --user --machine=wallabag@ is-active wallabag.service`, then the
edge. The tunnel re-establishes itself within 30 seconds of the edge
returning.

## Rotating a secret

Edit the SOPS file with `just secrets-edit <file>`, commit, merge. The next
pull recreates the Podman secret and restarts the unit that uses it.
WireGuard keys are rotated the same way; both hosts must be updated in the
same commit.

## Break-glass

If SSH is unreachable, use the provider's console with the root password
whose hash is `deerlab_root_password_hash`. Never `systemctl stop nftables`
on a Debian host; it flushes every rule. Use `systemctl reload nftables`
or `nft -f /etc/nftables.conf`.

## Restore

Quarterly drill from the devcontainer: `just restore-drill wallabag services`
restores the latest snapshot to `/tmp/deerlab-restore-wallabag` and prints
the integrity check.

Real restore into the live volume, as root on the services host:

    systemctl --user --machine=wallabag@ stop wallabag.service
    systemd-run --machine=wallabag@ --user --quiet --pipe --wait --collect \
      podman unshare sh -c 'set -e
        set -a; . /etc/deerlab/backup/wallabag.env; set +a
        export RESTIC_PASSWORD_FILE=/etc/deerlab/backup/wallabag.password
        d=/var/lib/wallabag/.local/share/containers/storage/volumes/wallabag-data/_data/db
        restic restore latest --target /var/lib/wallabag/backup/restore \
          --include /var/lib/wallabag/backup/staging/wallabag.sqlite
        rm -f $d/wallabag.sqlite-wal $d/wallabag.sqlite-shm
        cp /var/lib/wallabag/backup/restore/var/lib/wallabag/backup/staging/wallabag.sqlite $d/wallabag.sqlite
        chown 65534:65534 $d/wallabag.sqlite
        rm -rf /var/lib/wallabag/backup/restore'
    systemctl --user --machine=wallabag@ start wallabag.service

Deleting the write-ahead log before copying is what stops a restored
database from being overwritten by stale journal pages.

Retention: `just backup-prune wallabag services` from the devcontainer,
never from a host. The hosts' keys cannot delete.

## First-boot experiment results

Record here the outcomes of Task 19 of the implementation plan: tunnel
recovery time after an edge reboot, whether Wallabag came up without a
restart after a services reboot, and whether HTTP/3 negotiated.
```

- [ ] **Step 2: Rewrite the README**

Replace `README.md` with:

````markdown
<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me> -->

# deerlab

Two Debian 13 VPSs configured entirely by Ansible. An edge host runs
Caddy and nothing else. A services host runs every application as a
rootless Podman Quadlet under its own locked-down system user. The hosts
are linked by kernel WireGuard; the services host has no public port
except SSH. Each host pulls a signed `release` branch and applies its own
configuration every 30 minutes.

## What lives where

```text
inventory/   hosts, service definitions, SOPS-encrypted secrets
playbooks/   site.yml and the plays it imports
roles/       base_* for the host, podman_* for the platform, backup
docs/        the design spec, the implementation plan, the runbook
secrets/     operator-only credentials outside the inventory
```

A service is one entry in `podman_services`. The firewall chain, the
subordinate ID range, the resource slice, the Quadlet, the secrets and the
backup timer all derive from that entry.

## Getting started

```bash
just setup          # mise installs every tool, collections, pre-commit
just ci             # the same checks CI runs
just plan svc1      # check and diff against the real host
```

Everything else is in `docs/runbook.md`.

## Design

`docs/superpowers/specs/2026-09-05-two-host-rootless-podman-design.md`
records the decisions and the constraints that shaped them, including why
systemd sandboxing cannot be applied to rootless Quadlet units, why images
are digest-pinned rather than auto-updated, and what Wallabag's image
cannot be hardened against.

## Secrets

SOPS with age. Recipients are the operator key and one key per host,
listed in `.sops.yaml`. `just secrets-edit <file>` edits, `just
secrets-rekey` re-encrypts after changing recipients.

## AI/LLM Disclosure

This project was developed with significant LLM involvement. I'm a
systems architect by trade, not a programmer. I designed the
architecture, made technical decisions and directed development, but
AI/LLM tools generated most of the code. All code was reviewed, tested,
and iterated on by me.

## Licensing

This project is [REUSE](https://reuse.software/) compliant.

- **Code** (playbooks, roles, templates): [CPAL-1.0](LICENSE)
- **Configuration**: [0BSD](LICENSE-CONFIG)
- **Documentation**: [CC-BY-4.0](LICENSE-DOCS)
````

- [ ] **Step 3: Rewrite CLAUDE.md**

Replace `CLAUDE.md` with:

````markdown
# deerlab

Two Debian 13 VPSs, Ansible only. Edge host runs Caddy; services host runs
rootless Podman Quadlets, one system user per service. Design:
`docs/superpowers/specs/2026-09-05-two-host-rootless-podman-design.md`.
Operations: `docs/runbook.md`.

## Commits

- Never add "Co-Authored-By", "Generated by", or any AI attribution to commits, messages, or code
- Write commit messages as if a human wrote them
- Sign commits. Hosts verify the release branch head against `deerlab_allowed_signers`

## CRITICAL

- Tool versions are managed by mise. `mise.toml` is the single source of truth, including Python tools
- Run `just ci` before committing. Never bypass pre-commit hooks with `--no-verify`
- Never hardcode credentials. All secrets use SOPS + age; recipients are listed in `.sops.yaml`
- Targets run Podman 5.4.2. Quadlet files may only use keys that exist in 5.4.2: never `Memory=`, never `Wants=`/`After=` naming a `.container`
- Never put systemd sandboxing directives in a Quadlet `[Service]` section; in a user manager they break rootless Podman
- Never run Podman as root. Every Podman or `systemctl --user` task becomes the service user and sets both `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`
- No bespoke check scripts. Validate with ansible-lint, `validate:` on templates, `systemd-analyze verify`, `nft --check`
- Never `systemctl stop nftables` on a host; it flushes every rule

## Key Commands

- `just ci` — run the whole CI pipeline locally
- `just plan HOST` — check and diff against a real host
- `just apply HOST` — push to a host; bootstrap and break-glass only, delivery is pull-based
- `just bootstrap HOST` — first run against a fresh image as root
- `just merge BRANCH` — fast-forward main from the devcontainer so signatures survive
- `just secrets-edit FILE`, `just secrets-rekey`
- `just backup-prune SERVICE GROUP`, `just restore-drill SERVICE GROUP`
- `just idempotency HOST`

## Code Quality

- All linter rules are enforced as errors. Fix them, don't suppress them
- ansible-lint production profile plus role-argument-spec, ShellCheck, markdownlint, yamllint, cspell, Trivy, gitleaks, REUSE
- A second playbook run must produce zero changes

## Ansible

- Always use FQCN for modules
- Prefix all role variables with the role name
- Define defaults in `defaults/main.yml`. Document variables in `meta/argument_specs.yml`
- Use `changed_when` (or `creates`) and `failed_when` on every `command`/`shell` task
- Use `no_log: true` on tasks that handle secrets
- Validate required inputs with `ansible.builtin.assert` at the top of roles
- Prefer native modules over `command`/`shell`
- Playbooks are thin: a list of roles with `hosts:`, no inline tasks
- Data belongs in inventory (`group_vars/`, `host_vars/`), logic belongs in roles. A new service is an inventory change

## Services

- One entry in `podman_services` per service. Explicit UID from 2000, digest-pinned fully qualified image, published ports, volumes, health command, limits, egress class, backup paths
- Everything derives from that entry: user, subordinate range, slice, firewall chain, Quadlet, secrets, backup timer
- Least privilege: drop all capabilities and add back only what the image proves it needs, one at a time. Read-only root and no-new-privileges unless the image cannot run that way; record every exception in the definition's comments

## Structure

```text
inventory/   what to manage (hosts, service definitions, secrets)
playbooks/   when to run (site.yml imports deps, base, edge, services)
roles/       how to configure (base_*, podman_*, backup)
docs/        spec, plan, runbook
secrets/     operator-only credentials outside the inventory
```
````

- [ ] **Step 4: Lint and run the idempotency check on both hosts**

```bash
just ci
just idempotency svc1
just idempotency edge1
```

Expected: `just ci` passes and both idempotency runs print `Idempotent`. If a task reports `changed` on the second run, fix the task; common causes are `command` tasks without `creates`, and templates whose content depends on facts that change per run.

- [ ] **Step 5: Commit**

```bash
git add docs/runbook.md README.md CLAUDE.md
git commit -m "Document the two-host design for operators and agents

A runbook for pulls, bootstrap, adding a service, reboots, rotation,
break-glass and restore; a README that says what lives where; and a
CLAUDE.md that carries the constraints the rebuild established."
```

### Task 23: Decommission the old host

**Files:**

- None in the repository.

- [ ] **Step 1: Confirm nothing depends on the old host**

Run: `git grep -n -i kartar`
Expected: no output. If any reference remains, remove it and commit.

- [ ] **Step 2: Remove the DNS record and the VPS**

Delete the `kartar` DNS record at the DNS provider. Destroy the old VPS at the hosting provider. Remove its host key from `~/.ssh/known_hosts` with `ssh-keygen -R <old host FQDN>`.

- [ ] **Step 3: Close out**

Confirm both healthchecks.io pull checks and both backup checks have been green for at least a day, then mark the spec's status line as implemented and commit:

```bash
sed -i 's/^Status: approved design, 2026-09-05\./Status: implemented; see docs\/runbook.md for operations./' docs/superpowers/specs/2026-09-05-two-host-rootless-podman-design.md
git add docs/superpowers/specs/2026-09-05-two-host-rootless-podman-design.md
git commit -m "Mark the two-host design as implemented"
```
