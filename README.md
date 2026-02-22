<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me> -->

# deerlab

Ansible + OpenTofu GitOps for Proxmox VE 9 (LXC-only, single node).

**Ansible** owns host configuration (install, bootstrap, hardening via SSH).
**OpenTofu** owns resource lifecycle (containers, PVE firewall via the Proxmox API).

## Prerequisites

- **Ansible** >= 2.16 on your local machine
- **OpenTofu** >= 1.11 on your local machine
- **SOPS** + **age** for secrets encryption
- **SSH key-based root access** to a fresh Debian 13 (Trixie) VPS
- **DNS A record** — `<hostname>.<domain>` must resolve to the server IP
- **Porkbun API keys** — obtain from <https://porkbun.com/account/api>, enable API access for the domain

## Deploy from a Clone

All secrets are SOPS-encrypted and committed. On a new machine you only need:

1. Your age private key at `~/.config/sops/age/keys.txt` (from backup)
2. VPS host in known_hosts: `ssh-keyscan <vps-host> >> ~/.ssh/known_hosts`

```bash
ansible-galaxy collection install -r requirements.yml

# --- Stage 1: Ansible (install PVE, bootstrap, harden, ACME cert) ---
ansible-playbook playbooks/site.yml

# After ACME cert is issued, switch Tofu to verified TLS:
#   sops tofu/terraform.tfvars.sops.json   # set proxmox_insecure to false

# --- Stage 2: OpenTofu (containers, PVE firewall) ---
cd tofu
export TF_VAR_state_passphrase=$(sops -d --extract '["tofu_state_passphrase"]' \
  ../inventory/group_vars/proxmox/secrets.sops.yaml)
tofu init
tofu plan
tofu apply
```

## First-Time Setup

Starting from scratch (no encrypted files yet):

```bash
# install sops and age
# Debian: sudo apt install age
# sops: https://github.com/getsops/sops/releases

# generate an age keypair (one-time — back up this file)
age-keygen -o ~/.config/sops/age/keys.txt
# put the public key in .sops.yaml

ssh-keyscan <vps-host> >> ~/.ssh/known_hosts

# create and encrypt secrets
cp inventory/group_vars/proxmox/secrets.sops.yaml.example \
   inventory/group_vars/proxmox/secrets.sops.yaml
$EDITOR inventory/group_vars/proxmox/secrets.sops.yaml
sops --encrypt --in-place inventory/group_vars/proxmox/secrets.sops.yaml

# create and encrypt tofu variables
cd tofu
cp terraform.tfvars.sops.json.example terraform.tfvars.sops.json
sops --encrypt --in-place terraform.tfvars.sops.json
sops terraform.tfvars.sops.json   # fill in all values
```

Then follow the deploy steps above.

## What It Does

### Stage 1 — Ansible (host configuration via SSH)

1. **Install** (`proxmox_install`) — Takes a fresh Debian 13 Trixie VPS and installs
   Proxmox VE 9.x: GPG key, repo, kernel swap with reboot, postfix satellite relay,
   cleanup of stock kernel/os-prober, and NAT bridge (`vmbr0`) for containers.
2. **Bootstrap** (`proxmox_base`) — Post-install config: no-subscription repo, timezone,
   sysctl, state passphrase + API token generation (auto-encrypted to SOPS).
3. **Hardening** (`proxmox_hardening`) — SSH hardening (pubkey-only, post-quantum crypto),
   kernel/sysctl parameters, nftables firewall, fail2ban, unattended-upgrades, auditd,
   and PVE subscription nag removal. Each phase can be toggled independently.
4. **ACME Certificates** (`proxmox_acme`) — Automated Let's Encrypt TLS certificates
   using Proxmox's built-in ACME client with DNS-01 challenge validation (Porkbun by
   default, provider-agnostic). Registers an ACME account, configures the DNS plugin,
   and orders a certificate. Proxmox auto-renews via `pve-daily-update.timer`. Must
   complete before OpenTofu runs with `insecure=false`.

On re-runs, completed stages are skipped (idempotent). Target a single stage
with tags: `--tags install`, `--tags bootstrap`, `--tags hardening`, `--tags acme`.

### Stage 2 — OpenTofu (resource lifecycle via Proxmox API)

1. **Containers** — LXC container provisioning with state tracking, plan previews,
   and drift detection.
1. **PVE Firewall** — Cluster-level firewall rules managed declaratively with
   drift detection on security-critical config.

Run `tofu plan` at any time to detect drift from the declared state.

## Secrets

All secrets use [SOPS](https://github.com/getsops/sops) with
[age](https://github.com/FiloSottile/age) encryption.

- **Public key**: `.sops.yaml` at repo root (committed)
- **Private key**: `~/.config/sops/age/keys.txt` (back up this file)
- **Encrypted files**: any `*.sops.yaml` or `*.sops.json` in the repo (committed, values encrypted, keys readable)
- **Example**: `inventory/group_vars/proxmox/secrets.sops.yaml.example` documents all expected keys

To edit an already-encrypted secrets file, `sops` decrypts it in `$EDITOR` and re-encrypts on save:

```bash
sops inventory/group_vars/proxmox/secrets.sops.yaml
```

OpenTofu state is encrypted at rest and committed to the repo.

## Structure

```text
inventory/          # what to manage (hosts, vars, secrets)
playbooks/          # when to run (Ansible orchestration order)
roles/              # how to configure (Ansible roles — SSH into host)
tofu/               # what to provision (OpenTofu — Proxmox API)
docs/               # design documents and analysis
```

## Expanding This Repo

- **Add an LXC container**: define it in `tofu/terraform.tfvars.sops.json` under `containers`.
  Run `tofu plan` then `tofu apply`.
- **Configure software inside a container**: create an Ansible role and playbook.
  Tofu provisions the container; Ansible configures it via `pct exec`.
- **Add a new Ansible role**: `roles/proxmox_<thing>/{tasks,defaults,handlers}/main.yml`,
  a playbook in `playbooks/`, and add it to `playbooks/site.yml`.
- **Add Proxmox API resources** (storage, SDN): add `.tf` files to `tofu/`.
  See `docs/opentofu-integration-analysis.md` for the full migration roadmap.

## AI/LLM Disclosure

This project was developed with significant LLM involvement. I'm a systems architect by trade, not a programmer. I designed the architecture, made technical decisions and directed development, but AI/LLM tools generated most of the code.

All code was reviewed, tested, and iterated on by me. The design choices (Ansible/OpenTofu split, SOPS+age for secrets, idempotent staged deployment, etc.) are mine. The HCL and YAML syntax is not.
I'm publishing this because it works for me, not because of how it was written.

## Licensing

This project is [REUSE](https://reuse.software/) compliant.

- **Code** (scripts, playbooks, roles, OpenTofu): [CPAL-1.0](LICENSE)
- **Configuration**: [0BSD](LICENSE-CONFIG)
- **Documentation**: [CC-BY-4.0](LICENSE-DOCS)

See [REUSE.toml](REUSE.toml) for the complete file-to-license mapping.
