<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me> -->

# TODO

## Migrate idmap blocks from Ansible back to Tofu

The plan called for native `idmap` blocks in `tofu/containers.tf`. The `idmap`
block was merged to the provider's main branch on Feb 21, 2026 — three days
after v0.96.0 was released. It doesn't exist in any tagged release yet.

**Current workaround:** The `proxmox_lxc_config` Ansible role manages idmaps by
writing `lxc.idmap` entries directly to `/etc/pve/lxc/<vmid>.conf` (which is
exactly what the provider's own implementation does internally). The idmap data
moved from tfvars to `inventory/group_vars/proxmox/lxc_config.yml`.

**Action:** Once bpg/proxmox v0.97+ ships, migrate idmap configuration back to
Tofu using native `idmap` blocks in `tofu/containers.tf` and remove the
shell-based idmap task from `roles/proxmox_lxc_config/tasks/main.yml`.
