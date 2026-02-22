<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me> -->

# Networking, UID/GID Mapping, and Container Connectivity

## Overview

deerlab uses Proxmox SDN Simple zones to isolate container network traffic into purpose-specific segments. Containers are unprivileged LXC with nested user namespaces for rootless Podman. Ansible connects to containers via `pct exec` through the Proxmox host using the `community.proxmox.proxmox_pct_remote` connection plugin. Containers have no SSH server installed.

---

## SDN Topology

### Zones

Two Simple zones carved from the existing `10.10.0.0/16` management space. Longest-prefix matching ensures `/24` subnets route correctly alongside the wider `/16`.

| Zone       | VNet       | Subnet           | Gateway      | SNAT | Purpose                                   |
|------------|------------|------------------|--------------|------|-------------------------------------------|
| `public`   | `vnetpub`  | `10.10.2.0/24`   | `10.10.2.1`  | Yes  | Internet-facing (outbound + DNAT inbound) |
| `services` | `vnetsvc`  | `10.10.3.0/24`   | `10.10.3.1`  | No   | Reverse-proxy backends (no internet)      |

**Simple zone** was chosen because this is a single-node setup — no tunneling overhead, no VXLAN complexity.

### Network diagram

```text
Internet
  |
  | (host public IP)
  v
+----------------------------------+
|  Proxmox Host (kartar)           |
|  vmbr0: 10.10.0.0/16 (mgmt)     |
|                                  |
|  nftables DNAT :80,:443 (iifname)|
|         --> 10.10.2.2            |
|                                  |
|  +--- public zone (SNAT) ----+  |
|  |  vnetpub: 10.10.2.0/24    |  |
|  |  gw: 10.10.2.1            |  |
|  |                            |  |
|  |  caddy eth0: 10.10.2.2    |  |
|  +----------------------------+  |
|                                  |
|  +--- services zone (no SNAT) -+ |
|  |  vnetsvc: 10.10.3.0/24      | |
|  |  gw: 10.10.3.1              | |
|  |                              | |
|  |  caddy eth1: 10.10.3.2      | |
|  |  (future):   10.10.3.3+     | |
|  +------------------------------+ |
+----------------------------------+
```

### Adding a new zone

Future purpose-specific zones (e.g., `media` for Sonarr/Sabnzbd) follow the same pattern:

1. Add zone, vnet, and subnet resources to `tofu/sdn.tf`
2. Add the new resources to the `applier` `depends_on` and `replace_triggered_by` lists
3. Assign the next `/24` subnet (e.g., `10.10.4.0/24`)
4. Set `snat = false` for internal-only zones, `snat = true` should be reserved for connecting to reverse proxy.

---

## UID/GID Mapping

### Three-level mapping

UIDs map through three levels: Host -> LXC -> Podman.

```text
Host UID space        LXC UID space         Podman UID space
--------------        -------------         ----------------
100000-265535   --->  0-165535        --->   (rootless containers)
  |                     |
  |  idmap: u 0 100000 165536            subuid: caddy:100000:65536
  |                     |
  |  host 100000 = LXC root (0)         LXC 100000 = Podman root (0)
  |  host 101000 = LXC caddy (1000)     host 200000-265535 = Podman
```

### Host subuid/subgid

The Proxmox host has a single wide range set once by the `proxmox_lxc_config` role:

```text
root:100000:1000000
```

This covers all current and future container idmaps without modification.

### Per-container idmap allocation

Ansible manages idmap entries in the container config file (the bpg provider's native `idmap` block is not yet released). Each container gets a dedicated range within the host's wide allocation.

| Container    | VMID | Host idmap start | Count  | Notes                     |
|--------------|------|------------------|--------|---------------------------|
| caddy        | 100  | 100000           | 165536 | Nesting (rootless Podman) |
| *(future)*   | 101  | 300000           | 165536 | Nesting                   |
| *(future)*   | 102  | 500000           | 65536  | Standard (no nesting)     |
| *(future)*   | 103  | 600000           | 65536  | Standard                  |

Gaps between ranges leave room for expansion.

### Calculating ranges for new containers

**With nesting (rootless Podman):** The container needs `65536 + subuid_count` UIDs. For a service user at UID 1000 with `subuid 100000:65536`, the total is `100000 + 65536 = 165536`.

**Without nesting:** Standard containers need only `65536` UIDs (the default LXC allocation).

### Inside the caddy LXC

The `caddy` user (UID 1000, maps to host UID 101000) gets subuid `100000:65536`:

```text
Container UID   Host UID     Purpose
0               100000       LXC root
1000            101000       caddy user
100000-165535   200000-265535  Podman rootless namespace
```

---

## DNAT (Inbound Port Forwarding)

### Design

A separate nftables table (`container_dnat`) handles inbound port forwarding. This is the only custom nftables table — host input filtering is handled by the PVE firewall (nftables backend), and NAT/SNAT is handled by Proxmox SDN.

### How it works

1. `proxmox_hardening` creates an empty bootstrap file at `/etc/nftables-container-dnat.conf` and includes it from `/etc/nftables.conf`
2. `proxmox_lxc_config` populates the file with actual DNAT rules using the `nftables-container-dnat.conf.j2` template
3. The file uses `destroy table` for idempotency
4. Rules use `iifname` to restrict DNAT to inbound traffic on the host's public interface, preventing outbound container traffic from being DNAT'd back to itself

### Current rules

```nft
table ip container_dnat {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "eth0" tcp dport 80 dnat to 10.10.2.2:80
    iifname "eth0" tcp dport 443 dnat to 10.10.2.2:443
  }
}
```

### Adding DNAT rules for new containers

Add entries to `inventory/group_vars/proxmox/lxc_config.yml`:

```yaml
proxmox_lxc_config_containers:
  - vmid: 100
    dnat:
      - { port: 80, dest: "10.10.2.2:80" }
      - { port: 443, dest: "10.10.2.2:443" }
  - vmid: 101
    dnat:
      - { port: 8080, dest: "10.10.2.3:8080" }
```

---

## Ansible Connection to Containers

### pct exec via proxmox_pct_remote

Ansible reaches containers via the `community.proxmox.proxmox_pct_remote`
connection plugin. This SSHes to the Proxmox host and runs
`pct exec <vmid> -- <command>` to execute inside the container.

```text
devcontainer --> SSH --> kartar (Proxmox host)
                          |
                          +--> pct exec 100 --> caddy container
```

Configuration in `inventory/group_vars/containers/main.yml`:

```yaml
ansible_connection: community.proxmox.proxmox_pct_remote
ansible_become: false
ansible_become_method: su
```

Per-container host_vars (encrypted):

```yaml
ansible_host: kartar.ameri.me    # Proxmox host, not container IP
proxmox_vmid: 100                # container VMID for pct exec
```

### Why pct exec over SSH

- No SSH attack surface inside containers
- No TCP forwarding configuration needed on the host
- No SSH key management inside containers
- `pct exec` is native to Proxmox — no extra infrastructure
- Supports `become_user` for rootless Podman tasks (via `su`)

### No SSH inside containers

Containers do not have openssh-server installed. The `lxc_base` role
explicitly removes it and purges leftover config. All management is
through `pct exec`.

---

## Execution Flow

```text
1. just tofu-apply            --> SDN zones/vnets/subnets + Caddy LXC (stopped)
2. just ansible lxc-prepare   --> Host: wide subuid range, DNAT rules, start container
3. just ansible caddy         --> Container: base setup, Podman, Caddy Quadlets
```

OpenTofu creates the container with `started=false`. The `proxmox_lxc_config` role starts it after host-level preparation (subuid, DNAT) is complete. `started` is in `ignore_changes` to prevent drift on subsequent `tofu plan` runs.
