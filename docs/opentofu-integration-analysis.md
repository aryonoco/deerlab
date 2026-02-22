<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me> -->

# OpenTofu Integration for deerlab

## Overview

deerlab uses Ansible + OpenTofu to manage a single-node Proxmox VE 9 hypervisor on Debian 13 Trixie. The cloud provider does not support IaC for the outer VM, but once PVE is installed, OpenTofu manages everything with a Proxmox API endpoint.

**Tofu owns "what exists" (resource lifecycle via the Proxmox API).
Ansible owns "how it's configured" (OS/service config via SSH).**

---

## What Tofu Manages

### LXC Containers — `tofu/containers.tf`

`proxmox_virtual_environment_container` resources keyed by hostname. Containers are defined in `terraform.tfvars.sops.json` and support cores, memory, disk, networking, tags, and privileged/unprivileged mode. Template references are ignored after initial creation (`ignore_changes`).

### LXC Templates — `tofu/templates.tf`

`proxmox_virtual_environment_download_file` resources keyed by template name (e.g., `debian-13`). Templates are defined in `terraform.tfvars.sops.json` with `url`, `checksum` (SHA-512), and `checksum_algorithm`. Downloads use HTTPS from a Proxmox CDN mirror with SHA-512 checksum verification for integrity (defense in depth). Containers reference templates by map key, creating an implicit dependency so downloads complete before container creation. Set `overwrite = false` to avoid unnecessary upstream checks on every plan.

### PVE Cluster Firewall — `tofu/firewall.tf`

`proxmox_virtual_environment_cluster_firewall` sets cluster-wide options (input=DROP, output=ACCEPT, log rate limiting). `proxmox_virtual_environment_firewall_rules` manages the rule list. Default rules allow SSH and PVE web UI (8006).

---

## What Ansible Manages

These have no Proxmox API equivalent — they require SSH into the host OS:

| Role | What | Why |
| --- | --- | --- |
| `proxmox_install` | PVE installation, kernel, initial bridge/NAT, postfix | Must exist before the Proxmox API does |
| `proxmox_base` | No-sub repo, timezone, sysctl, state passphrase + API token generation | Host-level config + bootstrap secrets for Tofu |
| `proxmox_hardening` | SSH, sysctl, nftables, fail2ban, auditd, unattended-upgrades, nag removal | Host-level security hardening via SSH |
| `proxmox_acme` | Let's Encrypt ACME certificates via DNS-01 (Porkbun) | Bootstrap prerequisite for secure Tofu connectivity |

---

## Provider: bpg/proxmox

- **Repository:** [github.com/bpg/terraform-provider-proxmox](https://github.com/bpg/terraform-provider-proxmox)
- **OpenTofu Registry:** [library.tf/providers/bpg/proxmox](https://library.tf/providers/bpg/proxmox/latest)
- **Requires:** OpenTofu >= 1.11, Proxmox VE 9.x
- **Auth:** API token (`root@pam!ansible`, created by `proxmox_base` Ansible role)
- **Pinned:** `~> 0.96.0` in `tofu/versions.tf`

---

## State Management

Encrypted local state committed to git. OpenTofu native encryption using PBKDF2 + AES-GCM (configured in `tofu/versions.tf`). The passphrase is injected via `TF_VAR_state_passphrase`.

### Single source of truth

All sensitive config (host IP, SSH user, API token, state passphrase) lives in the SOPS-encrypted `secrets.sops.yaml`. `inventory/hosts.yml` provides only the host name (not sensitive) — Tofu reads it via `yamldecode(file(...))` in `locals.tf` to derive the node name. Secrets and tfvars are read natively by `carlpett/sops` ephemeral resources in `locals.tf`. Only `TF_VAR_state_passphrase` is exported manually (the `encryption` block must decrypt state before any provider or ephemeral resource initializes).

---

## Execution Order

1. **Ansible** — `ansible-playbook playbooks/site.yml`
   - Installs PVE, configures host, hardens, provisions ACME certificate, creates API token
2. **Tofu** — `cd tofu && tofu plan && tofu apply`
   - Creates containers and firewall rules using the API token Ansible created
3. **Drift detection** — `tofu plan` at any time
   - Shows exact diff of any manual changes to Tofu-managed resources

---

## Directory Structure

```text
tofu/
  locals.tf                          # reads inventory/hosts.yml — derives node name
  versions.tf                        # required_version, required_providers, state encryption
  provider.tf                        # bpg/proxmox provider config (uses locals derived from ephemeral sops resources)
  variables.tf                       # input variables (state_passphrase only — everything else via ephemeral SOPS)
  containers.tf                      # LXC container resources (for_each over local.containers)
  templates.tf                       # LXC template downloads (for_each over local.templates)
  firewall.tf                        # cluster firewall options + rules
  outputs.tf                         # container IDs and IPs
  terraform.tfvars.sops.json         # SOPS-encrypted variable overrides (containers, etc.)
  terraform.tfvars.sops.json.example # plaintext example showing expected shape
```

---

## Known Limitations (bpg Provider)

- **SSH required for some operations:** File uploads, snippet management, and LXC `idmap` configuration require SSH in addition to the API token. The `ssh` block is configured in `provider.tf`.
- **Concurrent creation causes lock errors:** Creating multiple containers simultaneously causes Proxmox lock conflicts. Use `tofu apply -parallelism=1` or `depends_on` chains.
- **No cloud-init for LXC:** Proxmox does not support cloud-init for LXC containers. Use Ansible for post-creation configuration.
- **HA migration drift:** If HA migrates a container to another node, Tofu's state becomes stale. Manual `tofu state` adjustment is needed.
- **No cluster formation:** The provider cannot join or create Proxmox clusters. Use `pvecm` via Ansible if ever needed.

---

## Future Tofu Candidates

| Priority | What | Notes |
| --- | --- | --- |
| **3** | User/token/RBAC management | Deferred — bootstrap chicken-and-egg (Ansible creates the initial token Tofu needs). Resources: `proxmox_virtual_environment_user`, `_user_token`, `_role`, `_acl`. |
| **4** | Storage definitions | `proxmox_virtual_environment_storage_nfs`, `_zfspool`, `_lvm`/`_lvmthin`, `_pbs`, `_cifs`, `_directory`. Tofu manages the Proxmox storage definition, not the underlying pool creation (`zpool create`, `vgcreate`) — those stay in Ansible. |
| **5** | Additional bridges / SDN | The initial `vmbr0` + NAT stays in Ansible (chicken-and-egg). Additional networking: `proxmox_virtual_environment_network_linux_bridge`, `_linux_vlan`, `_sdn_zone_*`, `_sdn_vnet`, `_sdn_subnet`. |
| **6** | ACME certificates | Implemented via Ansible (`proxmox_acme` role) — bootstrap prerequisite for secure Tofu connectivity. Provider has `acme_account` and `acme_dns_plugin` resources but no `acme_certificate` resource for ordering certs, and there's a chicken-and-egg dependency (Tofu needs a valid cert to connect with `insecure=false`). |
