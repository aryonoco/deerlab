<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me> -->

# deerlab: two-host rootless Podman design

Status: approved design, 2026-09-05. This document supersedes the Proxmox, LXC and
OpenTofu design described in `docs/networking-and-uid-mapping.md` and
`docs/opentofu-integration-analysis.md`, which are deleted by the refactor.

## 1. Goals and principles

### 1.1 Goals

- Run self-hosted services on two Debian 13 VPSs with everything except the base
  image defined as code and applied by Ansible.
- Terminate TLS on an edge host that runs only Caddy. Run every application on a
  services host that is reachable only from the edge over an encrypted tunnel.
- Run every service as a rootless Podman Quadlet under its own locked-down system
  user, hardened with the container runtime's own controls and native kernel and
  systemd facilities.
- Keep git as the single source of truth: what runs is what the release branch
  says, including container image digests.

### 1.2 Non-goals

- Virtual machines, clustering, live migration, or a hypervisor of any kind.
- A control plane for the tunnel. Two static peers need none.
- Metrics dashboards in the first version.
- Live playbook execution in CI. CI lints and validates statically.

### 1.3 Principles

- **Least privilege at real boundaries.** Isolation comes from user namespaces,
  separate subordinate ID ranges, the firewall and the tunnel, not from layers that
  only appear to add it.
- **Maintainability is a requirement, not a preference.** Fewest moving parts that
  achieve the goal. One generic role owns the service contract. Constraints are
  enforced by construction and by native validators, never by bespoke scripts.
- **Nothing unsupported upstream on the critical path.** Hardening that systemd or
  Podman upstream declares unsupported is optional and off by default.
- **Data in inventory, logic in roles.** Adding a service is an inventory change.

## 2. Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Baseline | Fresh reimage of both hosts to stock Debian 13 | No Proxmox residue, testable day-zero path |
| Hosts | One edge host, one services host, same provider, public IPs only | Kernel and network boundary between TLS termination and data |
| Tunnel | Kernel WireGuard via systemd-networkd, keys in SOPS | No daemon, no third-party control plane, config is two unit files |
| Operator SSH | Public on both hosts, key-only, no IP allowlist | User decision. Post-quantum key exchange and per-source penalties are on by default in OpenSSH 10 |
| Delivery | Each host pulls a protected release branch on a timer | No inbound access from CI, no root credentials in GitHub, drift self-heals |
| Image updates | Digest pins bumped by Renovate pull requests | Git equals what runs. `podman auto-update` is mutually exclusive with digest pins |
| First services | Caddy on the edge, Wallabag on the services host | Wallabag kept with documented exceptions |
| TLS | HTTP-01 with the stock Caddy image | No DNS API credential on the edge |
| Backups | restic per service to an S3-compatible bucket | Per-service credentials, append-only by policy |
| Alerts | Pushover via systemd on-failure hooks | No mail relay on the hosts; the account already exists and its delivery path shares no failure domain with the hosts or the monitor |
| CI | Lint and static validation only | User decision |
| Reboots | Notify, never reboot automatically | User wants to watch reboots |
| Podman version | Debian 13's 5.4.2 | No backports exist; the Quadlet feature set is sufficient |
| Quadlet management | Templated files, not the Ansible Podman module's quadlet mode | Full key coverage, root ownership, Renovate can read the image line |
| Ansible | Version 14, core 2.21 | Fixes SOPS deprecation warnings, current collections |

## 3. Topology and network

### 3.1 Hosts and exposure

| Host | Group | Public inbound | Runs |
| --- | --- | --- | --- |
| edge | `edge`, `podman_hosts` | tcp 22, 80, 443; udp 443, <WireGuard port> | sshd, Caddy, WireGuard responder |
| services | `services`, `podman_hosts` | tcp 22 | sshd, application services |

Both hosts are dual-stack on the public side. The services host has no public
WireGuard port: it initiates the tunnel and keeps it alive.

### 3.2 WireGuard

- One interface per host, `wg0`, defined by a templated `.netdev` and `.network`
  pair under `/etc/systemd/network/`. The provider's own NIC configuration is not
  touched. Ansible detects the renderer in use and marks the public NIC unmanaged
  for networkd.
- Private key and preshared key come from SOPS and are written as files owned by
  `root:systemd-network`, mode 0640, referenced by `PrivateKeyFile=` and
  `PresharedKeyFile=`. The preshared key is the post-quantum hedge.
- Tunnel addressing: an IPv4 /24 and a random ULA /64, one address per host.
  `AllowedIPs` on each peer is exactly the other host's /32 and /128. Never a
  wider prefix; the kernel binds a key to its allowed source addresses.
- The edge sets `ListenPort=<WireGuard port>` and no endpoint for the services peer. The
  services host sets `Endpoint=<edge public ip>:<WireGuard port>`, an explicit `ListenPort`,
  and `PersistentKeepalive=25`. This keeps a symmetric conntrack entry open, so the
  edge reaches the services host with no inbound rule, and the tunnel recovers on
  its own after an edge outage of any length.
- `MTUBytes=1420`, set explicitly.
- Tunnel hostnames are a templated `/etc/hosts`, not DNS.
- `systemd-networkd-wait-online@wg0.service` is enabled on both hosts.

### 3.3 Firewall

One templated nftables ruleset per host, in a table named `inet deerlab`, loaded
by `nftables.service` at sysinit. The service is only ever reloaded. Stopping it
flushes every rule on Debian and must not be done. The template task validates
with `nft --check` before writing.

Rules use `iifname` and `oifname`, so they load before the tunnel exists. The
whole ruleset is a single template driven by inventory: host role, service UIDs,
egress classes, resolver address.

Input, both hosts: default drop, established and related accepted first, invalid
dropped, loopback accepted, ICMP and ICMPv6 types needed for path MTU discovery
and neighbour discovery accepted, SSH rate-limited to new connections.

Input, edge: tcp 80 and 443, udp 443, udp <WireGuard port>.

Input, services: backend ports accepted only when `iifname "wg0"` and the source
is the edge's tunnel address. Nothing else.

Output, both hosts: policy accept for root and system daemons. Each service UID
gets its own chain, selected by `meta skuid`, which matches because pasta's
host-side sockets belong to the service user:

| Egress class | Rule |
| --- | --- |
| `any` | accept |
| `web` | tcp 80 and 443 to any address except RFC 1918, link-local, ULA and the tunnel prefix; DNS to the host resolver only; everything else dropped |
| `none` | drop |

Dropped output is logged with the UID at a low rate. Caddy is class `any`.
Wallabag is class `web`, which is its server-side request forgery control.

### 3.4 Ports 80, 443 and HTTP/3

Caddy's host-side ports are reached through an nftables redirect on the edge,
for IPv4 and IPv6: tcp 80 to 8080, tcp 443 to 8443, udp 443 to 8443. Caddy
publishes 8080 and 8443 and still listens on 80 and 443 inside its own network
namespace, so its redirects and ACME challenges work unchanged. The host's
`ip_unprivileged_port_start` stays at 1024.

HTTP/3 is enabled from the start. It runs through pasta's userspace UDP path and
is one of the first-boot experiments in section 9. The QUIC buffer sysctls
`net.core.rmem_max` and `net.core.wmem_max` are raised on the edge so Caddy does
not need `CAP_NET_ADMIN`.

pasta preserves client source addresses when no custom Podman network is used, so
Caddy logs real client IPs. No `trusted_proxies` is configured at the edge.

### 3.5 Backends and boot ordering

Backend units publish on the wildcard address, never on the tunnel address. A
unit that binds a tunnel address races the interface at boot and fails hard on
Podman 5.4.2. The firewall is what scopes backends to the tunnel.

Lingering user managers start before the tunnel exists, and on a plain server
nothing pulls `network-online.target` into boot at all. Both are fixed with one
drop-in per service user on the system side:

```ini
# /etc/systemd/system/user@<uid>.service.d/10-wait-network.conf
[Unit]
Wants=network-online.target systemd-networkd-wait-online@wg0.service
After=network-online.target systemd-networkd-wait-online@wg0.service
```

Every Quadlet still carries `Restart=always` as a backstop.

### 3.6 Proxy path

Caddy proxies to `http://<services tunnel ip>:<port>` in plain HTTP. WireGuard
already provides confidentiality, integrity and peer authentication; TLS with
verification disabled would add nothing, and Caddy's documentation says so. Each
upstream has an active health check and a short retry window so a backend restart
does not surface as an error. Health check traffic also keeps the tunnel warm.

## 4. Service model

### 4.1 Service accounts and subordinate IDs

- One system user per service. UID is explicit in inventory, allocated from 2000
  upward. Home is `/var/lib/<service>`, mode 0700. Shell is `nologin`, password
  locked. No shared supplementary groups, ever.
- `/etc/subuid` and `/etc/subgid` are whole templated files. Each service gets a
  65536-wide range starting at `100000 + index * 65536`. Ranges never overlap;
  overlap would let one service reach another's files through the mapping. The
  user module never allocates these for system accounts, and `usermod` appends
  duplicates on rerun, so templating is the only idempotent path. A change to
  either file notifies a per-user `podman system migrate` handler.
- Lingering is enabled with `loginctl enable-linger`, guarded by `creates:` on
  `/var/lib/systemd/linger/<username>`.
- Ansible installs `podman uidmap passt netavark aardvark-dns dbus-user-session
  catatonit acl systemd-container` explicitly, because Debian only recommends the
  rootless prerequisites. `fuse-overlayfs` is not installed; native rootless
  overlay works on kernel 6.12.

### 4.2 Quadlet placement and control

Quadlet files are templated as root into
`/etc/containers/systemd/users/<uid>/`, owner `root:root`, mode 0644. The service
user can read its unit and cannot rewrite it. The bare `users/` directory is never
used; it would run the unit under every lingering user.

Reload and start use `ansible.builtin.systemd_service` with `scope: user`,
`become_user` set to the service user, and both `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` in the task environment. Without the second variable
Podman silently falls back to the cgroupfs manager, which also disables
healthchecks. A smoke task asserts `podman info` reports the systemd cgroup
manager and the overlay storage driver.

Generated units are validated on the host with `systemd-analyze --user verify`
run as the service user, which exercises the real Quadlet generator.

### 4.3 Images and trust

- Every image reference is fully qualified with tag and digest, written literally
  in the `Image=` line so Renovate's Quadlet manager can bump it.
- Ansible pre-pulls each image as the service user with the Podman image module.
  Units set `Pull=never`. This avoids the 90-second start timeout and the
  boot-time resolver race that breaks `.image` units on headless Debian 13.
- Each service user gets a `policy.json` that rejects by default and accepts only
  the registries in use, and a `registries.conf` with an empty search list and
  enforcing short-name mode. Both are complete files; Podman does not merge them.
- Debian's Podman 5.4.2 carries unfixed CVEs that require a malicious image to
  exploit. Digest pinning and trusted sources are the mitigation.

### 4.4 Container baseline

Only keys that Podman 5.4.2 supports are used. `Memory=` and dependency keys that
name `.container` units arrived in 5.5 and are not available. The generic role
renders the unit from the service definition; there is no free-form passthrough
for the `[Service]` section, so systemd sandboxing directives cannot be added by
accident. In a user manager those directives implicitly enable private user
namespaces or no-new-privileges on the Podman process itself and break rootless
operation.

| Area | Keys |
| --- | --- |
| Capabilities | `DropCapability=all`, then `AddCapability=` from the service allowlist |
| Privilege | `NoNewPrivileges=true` |
| Filesystem | `ReadOnly=true` and `ReadOnlyTmpfs=true` when the image allows; `Tmpfs=/tmp:rw,nosuid,nodev,noexec,size=64m`; named `.volume` units for state |
| Kernel surface | `Mask=` for `/proc/acpi`, `/proc/kcore`, `/proc/keys`, `/proc/timer_list`, `/proc/sched_debug`, `/proc/latency_stats`, `/sys/firmware`; `SeccompProfile=/usr/share/containers/seccomp.json` stated explicitly |
| Limits | `PidsLimit=`, `ShmSize=` |
| Health | `HealthCmd=`, `HealthInterval=`, `HealthStartPeriod=`, `HealthOnFailure=kill`, `Notify=healthy` |
| Identity | `UserNS=` unset, so container root maps to the service user and volumes are owned by it. `keep-id` only where an image insists on a fixed non-root UID |
| Network | `PublishPort=` per service. The default pasta network, no custom `.network` |
| Service | `Restart=always`, `RestartSec=5`, `TimeoutStartSec=` per service, `MemoryMax=`, `CPUQuota=`, `TasksMax=`, `OnFailure=notify-failure@%n.service` |
| Install | `WantedBy=default.target` |

`Restart=` must be written explicitly; the Quadlet generator does not set it for
containers. Memory, CPU and task controls work in user units because Debian 13's
systemd delegates those controllers. IO limits are not available without a
host-wide change and are not used.

### 4.5 Per-user slice

A drop-in on `user-<uid>.slice`, a system unit controlled by PID 1, sets memory,
task and CPU ceilings the service user cannot raise. `IPAddressDeny=any` with a
loopback and tunnel allowance is applied there only for services of egress class
`none`; for named internet destinations the firewall's UID chains are the control.

### 4.6 Secrets

SOPS values become Podman secrets created as the service user through the
`podman_secret` module, which compares content and is idempotent, with `no_log`.
Units consume them with `Secret=name` as a mounted file under `/run/secrets/` by
default, and as `type=env` only where the application cannot read a file.
Podman's file driver stores secrets base64-encoded, not encrypted, protected by
the 0700 home directory. Rotating a secret requires a unit restart, which the
role handles with a handler.

Encrypted systemd credentials do not work in user units on systemd 257. Where a
non-container process in a user unit needs a secret, such as the backup job, it is
a root-written file owned `root:<service group>`, mode 0640, loaded with
`LoadCredential=name:/absolute/path`, which does work in user units.

### 4.7 Caddy

- Image `docker.io/library/caddy` at a pinned digest.
- `DropCapability=all` plus `AddCapability=CAP_NET_BIND_SERVICE`. The official
  binary carries a file capability and refuses to exec with everything dropped.
  The capability is confined to Caddy's own network namespace.
- `ReadOnly=true`, `NoNewPrivileges=true`, a named volume for `/data` which holds
  the ACME account and certificates, a tmpfs for `/config`, the Caddyfile mounted
  as a read-only directory.
- Admin API disabled. Reloads are unit restarts.
- Health check against an internal listener that only answers a static path.
- Publishes `8080:80`, `8443:443`, `8443:443/udp`.
- Caddyfile is inventory data rendered into the role.

### 4.8 Wallabag

The official image is not designed for hardening. Each exception is stated in its
service definition and in this table.

| Item | Setting | Reason |
| --- | --- | --- |
| Identity | Runs as root inside the container, default user namespace mapping | The entrypoint switches users itself and chowns the data directory |
| Capabilities | `CAP_CHOWN CAP_SETUID CAP_SETGID CAP_NET_BIND_SERVICE CAP_DAC_OVERRIDE CAP_FOWNER`, to be trimmed empirically | Derived from reading the entrypoint; see section 9 |
| No new privileges | On, verified at first boot | Every privilege change is a drop from root, so expected to work |
| Filesystem | Not read-only. Volume for `data`, tmpfs for `/tmp` and `/run` | The entrypoint runs `composer install` into the application tree on every start |
| Secret | `SYMFONY__ENV__SECRET` from SOPS as an environment secret | The image default is a publicly known constant |
| Settings | `SYMFONY__ENV__DOMAIN_NAME`, `SYMFONY__ENV__SERVER_NAME`, registration disabled, `PHP_MEMORY_LIMIT=256M`, `TZ=Etc/UTC` | Correct absolute URLs and headroom for article fetching |
| Database | SQLite in the data volume | One file, one consistent backup path |
| Health | `/api/info`, unauthenticated | Shipped by the image |
| Start timeout | 900 seconds | First start is slow |
| Egress | Class `web` | Fetches arbitrary URLs by design |
| Client IP | Sees the edge's tunnel address | The application ignores forwarded headers; accepted |
| Backups | Helper image with `sqlite3` for online backup | The image ships no `sqlite3` binary |

### 4.9 Patterns for future services

- An application with its own database runs both containers in one `.pod` under
  one service user and talks over the pod's loopback. The security unit is the
  service, not the container.
- Two distinct services on the services host that must talk use a unix socket in
  a directory owned by the listener with a 0710 mode granting the caller's group,
  where the listener can bind one. Otherwise the listener publishes on
  `127.0.0.1` and the firewall's UID chains restrict who may connect. Neither is
  built in v1.
- Cross-user Podman networks do not exist; do not design around them.

## 5. Host baseline

Applied to both hosts by the `base_*` roles.

- **Packages**: as listed in 4.1, plus `nftables chrony needrestart
  unattended-upgrades auditd wireguard-tools`. Not installed: `fail2ban`, which
  no longer matches Debian 13's sshd log format and defaults to an iptables action.
- **SSH**: key-only, root login disabled, one admin user in a sudo group. Key
  exchange list keeps `mlkem768x25519-sha256` first, as OpenSSH 10 does by default.
  `PerSourcePenalties` tuned, the tunnel prefix exempt, verbose logging. Kernel
  command line carries `systemd.ssh_auto=no` so the systemd SSH generator creates
  no vsock or unix listeners outside the firewall's view.
- **Kernel**: sysctl set merged from the existing role and the well-curated
  dev-sec list. `kernel.unprivileged_userns_clone=1` is asserted explicitly so no
  future change can disable rootless containers. `kernel.unprivileged_bpf_disabled`
  stays at Debian's default of 2, which is recoverable. `lockdown=integrity` on
  the kernel command line.
- **Updates**: unattended-upgrades with automatic reboot off. A daily timer
  notifies through Pushover while `/run/reboot-required` exists. needrestart restarts
  patched services automatically.
- **Logging and time**: persistent journald with `SystemMaxUse=512M` and a
  retention cap. chrony with NTS, `systemd-timesyncd` masked, egress allowed on
  udp 123 and tcp 4460.
- **Audit**: auditd with a minimal ruleset covering configuration changes, login
  UID, privileged commands and module loads. No syscall-tracing rules, which fire
  on every container operation.
- **`/proc` hiding**: available as a role toggle, off by default. systemd upstream
  does not support global `hidepid` and polkit exemption bugs remain open. When
  enabled it uses `hidepid=invisible,gid=proc` in fstab with supplementary group
  drop-ins for logind and polkit, and no service user is ever in that group.
- **Break-glass**: the provider console with a root password held in SOPS. The
  recovery procedure is written before the default-drop ruleset is applied.
- **Not adopted**: the `devsec.hardening` collection. Its Debian defaults disable
  unprivileged user namespaces and mount `/proc` with `hidepid=2`, either of which
  stops every rootless container, and its SSH role removes the post-quantum key
  exchange.

## 6. Repository layout and Ansible execution

### 6.1 Removed and kept

Removed: the `tofu/` tree and its state, the `proxmox_*`, `lxc_*` roles and
playbooks, the SDN and Tofu documents, the Tofu CI jobs, `deploy.yml`, Dependabot
configuration, and Tofu tooling from the devcontainer and `mise.toml`.

Kept: repository history, REUSE licensing, the devcontainer, the justfile,
pre-commit, the lint stack, the SOPS layout, and the SSH, sysctl, nftables and
unattended-upgrades work from `proxmox_hardening`, split into `base_*` roles.

### 6.1.1 Operator machine

The operator works on macOS, directly on the host, not in a container. The
devcontainer stays in the repository but is not the execution environment: the
age identity is no longer a file on disk, so `sops` cannot decrypt inside it.
The identity is fetched from Bitwarden at runtime through `SOPS_AGE_KEY_CMD`,
which the login shell exports; a process that does not inherit that variable
cannot decrypt. `mise.toml` supplies the toolchain, with `wireguard-tools` and
an HTTP/3-capable `curl` installed from Homebrew alongside it.

### 6.2 Versions

Ansible 14 with core 2.21. Collection pins move to `community.general 13`,
`community.sops 2.4`, `containers.podman 1.20`, `ansible.posix 2.2`. Debian 13
targets run Python 3.13, within the supported range.

### 6.3 Layout

```text
inventory/
  hosts.yml                       # edge, services, podman_hosts
  group_vars/all/                 # shared settings, secrets.sops.yaml
  group_vars/podman_hosts/        # service definitions
  group_vars/edge/  group_vars/services/
  host_vars/<host>/               # tunnel keys and per-host secrets, encrypted
playbooks/
  site.yml                        # base.yml, edge.yml, services.yml
  bootstrap.yml                   # the only push-mode playbook
roles/
  base_os  base_ssh  base_firewall  base_wireguard  base_notify  base_pull
  podman_host  podman_service
  caddy  wallabag  backup
docs/
```

Flat repository in collection shape, so ansible-lint's file-type heuristics work
without a `galaxy.yml`.

### 6.4 Service definition contract

`podman_services` is a dictionary in group vars. The `podman_service` role
validates it with `meta/argument_specs.yml`. Fields:

```yaml
podman_services:
  wallabag:
    uid: 2001
    image: docker.io/wallabag/wallabag:2.6.14@sha256:<digest>
    publish: ["8080:80"]
    volumes:
      - { name: data, mount: /var/www/wallabag/data }
    tmpfs: ["/tmp:rw,nosuid,nodev,noexec,size=64m", "/run:rw,nosuid,nodev,size=16m"]
    env: { SYMFONY__ENV__DOMAIN_NAME: "https://wallabag.example" }
    secrets:
      - { name: symfony_secret, value: "{{ wallabag_symfony_secret }}", type: env, target: SYMFONY__ENV__SECRET }
    capabilities: [CAP_CHOWN, CAP_SETUID, CAP_SETGID, CAP_NET_BIND_SERVICE, CAP_DAC_OVERRIDE, CAP_FOWNER]
    read_only: false
    no_new_privileges: true
    health: { cmd: "curl --fail --silent http://localhost/api/info", interval: 30s, start_period: 120s }
    limits: { memory: 768M, cpu: "100%", tasks: 512, pids: 256 }
    start_timeout: 900
    egress: web
    backup:
      sqlite: /var/www/wallabag/data/db/wallabag.sqlite
      paths: [data]
```

The subordinate ID range, the slice drop-in, the firewall chain and the backup
unit are all derived from this one record.

### 6.5 Execution contract

For every task that touches Podman or a user manager: `become: true`,
`become_user` set to the service user, `XDG_RUNTIME_DIR` and
`DBUS_SESSION_BUS_ADDRESS` in `environment`. Never `become_method: su`. Never
Podman as root. The `podman_service` role is the only place this appears; service
roles call it rather than reimplement it.

### 6.6 Lint and validation

- ansible-lint production profile with `role-argument-spec` added to the enabled
  rules. ansible-lint runs the syntax check internally.
- Templates that write firewall rules use `validate: nft --check --file %s`.
- Generated Quadlet units are verified on the host with `systemd-analyze --user
  verify` as the service user.
- No bespoke check scripts. Constraints that cannot be validated natively are
  enforced by the data contract in 6.4.

## 7. Delivery

### 7.1 Bootstrap

Run once per host from the operator's machine against the provider's fresh image:
`just bootstrap <host>`. The `bootstrap.yml` playbook creates the admin user,
places the age private key and a read-only deploy key as root-only files,
creates a Python virtual environment with the pinned Ansible version from a
requirements file in the repo, installs the pull timer, and runs `site.yml`
once. After bootstrap, root SSH is closed by the hardening and nothing pushes to
the host again except break-glass.

### 7.2 Pull

A system timer on each host, every 15 minutes with randomised delay, runs
`ansible-pull` with: checkout of the `release` branch, commit signature
verification against an allowed-signers file holding the operator's SSH signing
key, only-if-changed, clean of local drift, and a `--limit` to the host itself.
The unit has an on-failure hook to the notifier and pings a dead-man URL on
success. Git on the host is configured with `gpg.format ssh` and the allowed
signers file by `base_pull`.

### 7.3 Promotion

The repository has one operator, so promotion rests on local discipline rather
than server-side branch rules: GitHub enforces nothing about `main` or
`release`. Rules there would obstruct the only person they could protect, and
they would enforce the wrong thing anyway — GitHub counts a commit as verified
if any registered key signed it, while the host demands a key from the
allowed-signers list. The gate that matters is therefore on the host:
`ansible-pull --verify-commit` refuses a `release` head whose signature is not
from a key in that file, so an unverifiable commit stops delivery no matter what
GitHub accepted.

Merges are fast-forwards performed from the operator's machine with
`just merge <branch>` once CI is green; GitHub's own merge buttons rewrite or
re-sign commits. Commits created through the GitHub API by an app — Renovate
included — carry GitHub's GPG web-flow signature instead of the operator's SSH
key, and the host rejects those. A bot branch is rebased onto `main` before it is
merged so its commits are recreated under the operator's signature. A workflow
then fast-forwards `release` to `main`. Only that workflow pushes `release`.

### 7.4 Plan visibility

`just plan <host>` runs `site.yml` in check and diff mode from the operator's machine
against the real host over SSH, for when the effect of a change should be seen
before merging. The pull logs its own diff to the journal.

### 7.5 Dependency updates

Renovate replaces Dependabot, with the Quadlet, Ansible Galaxy, mise and GitHub
Actions managers and digest pinning enabled. Renovate 44.9.1 or later is required
for digest pinning in Quadlet files. Automerge is off in v1. `AutoUpdate=` is
never set on a unit.

### 7.6 CI

Every existing lint job is kept. The Tofu jobs, the `.opentofu-version` sync
check and the deploy workflow are removed. No live playbook execution.

## 8. Backups, notifications, observability

### 8.1 Backups

One `backup` role, driven by the service definition, installs per service:

- A user-scope timer and a oneshot unit whose sequential `ExecStart=` lines, with
  no wrapper script, run: an online SQLite backup through a pinned helper image
  into a staging directory, an integrity check of the copy, `podman unshare
  restic backup` of the staging directory and the listed volumes, and a
  dead-man ping. `podman unshare` is required because volume files written by
  in-container users are owned by subordinate UIDs.
- A restic repository per service under a bucket prefix, S3 credentials per
  service scoped to that prefix, and a repository password from SOPS delivered as
  a credential file per 4.6. The credentials do carry delete, because `restic
  backup` takes and releases a lock under `locks/` on every run and cannot
  complete without it. Backblaze B2 application keys scope by bucket and name
  prefix but not by operation, so the protection against a compromised host
  erasing its own history comes from B2 keeping prior versions for 14 days rather
  than from withholding delete. That is a detection deadline, not immutability:
  the dead-man checks in 8.3 are what make it meaningful.
- On the edge, Caddy's data volume is backed up the same way so a rebuild does
  not exhaust certificate rate limits.

Retention runs from the operator's machine with `just backup-prune`, using
`forget --keep-within`, as restic recommends for append-only repositories. Hosts
never hold delete rights. `just restore-drill <service>` restores the latest
snapshot to a scratch path, integrity-checks it and reports. The runbook schedules
it quarterly. Repository passwords and the age key are kept off both hosts as
well, otherwise a lost host cannot be restored.

### 8.2 Notifications

`base_notify` installs a templated `notify-failure@.service` in both system and
user scope. Its `ExecStart` is `curl` with a config file loaded as a credential
that carries the Pushover endpoint, the application token and the user key from
SOPS, and a body naming the unit and host. Pushover takes a form POST, and curl
merges repeated `data` entries in a config file with `&`, so this stays one curl
invocation and no script. It is attached with `OnFailure=` to every Quadlet, every
backup timer, the pull unit and the firewall unit. The reboot-required timer posts
through the same path.

Notifications leave each host directly. They depend on neither the edge nor the
monitoring host, which is the property that makes them worth having: an outage of
the thing that watches must not also silence the thing that reports. That rules
out running the notification service beside the monitor.

### 8.3 Observability

Persistent journald with a size cap. Logs are read as root with
`journalctl _UID=<uid>`; service users are not added to the `systemd-journal`
group, which would expose every other service's logs. No metrics stack in v1.

Absence is monitored separately from failure. A failing unit reports itself; a
host that stops running anything reports nothing, and silence is indistinguishable
from health. An Uptime Kuma instance hosted away from both hosts closes that gap:
each successful pull and each successful backup pings a push monitor, and Kuma
alerts through Pushover when a ping does not arrive in time. Kuma's push monitors
have no separate grace period, so each interval is set to the expected period plus
enough slack to absorb a late run. The same instance runs an HTTP monitor against
the public URL, which is the external uptime check. Push URLs are bearer secrets
and live in SOPS: anyone holding one can mark a check healthy and mask a real
outage. Nothing watches Kuma itself; the host provider's own pod-failure alert is
the backstop.

## 9. Verification and first-boot experiments

Idempotency: a second pull run reports zero changes. `just idempotency <host>`
runs the playbook twice and fails if the second run changed anything.

Each experiment below is run on the first build and has a pass criterion. A
failure changes the design detail it guards, not the goal.

| Experiment | Pass criterion |
| --- | --- |
| UID matching on pasta traffic | An nftables counter on `meta skuid <wallabag uid>` increments when the container fetches a URL |
| Cgroup manager | `podman info` as each service user reports `systemd`, not `cgroupfs` |
| Tunnel recovery | After rebooting the edge, the services host re-establishes the tunnel within 30 seconds with no action |
| Boot ordering | After rebooting the services host, backend units are active and the health check passes without a restart |
| HTTP/3 | A client negotiates h3 to the edge and page loads succeed; if it fails, disable in Caddy and record it |
| Wallabag capabilities | Remove one capability at a time from the allowlist until the entrypoint fails; the final list goes in inventory |
| Wallabag no-new-privileges | The unit starts and stays healthy with it on |
| Backup and restore | The drill restores a snapshot whose integrity check passes and Wallabag starts on it |
| `hidepid`, only if enabled | A lingering user manager starts cleanly and `pkexec true` succeeds |

## 10. Build order

1. Repository surgery: remove Tofu, Proxmox and LXC, bump Ansible, restructure
   roles, update CI, lint green.
2. Base roles on a scratch host or the services host: OS, SSH, firewall,
   WireGuard, notify, pull. Bootstrap the services host.
3. `podman_host` and `podman_service`, then Wallabag on the services host.
   Verify from the host that the backend answers on the tunnel address.
4. Bootstrap the edge: base roles, WireGuard, Caddy. Move DNS. Verify TLS,
   HTTP/3 and the proxy path.
5. Backups and restore drill. Notifications end to end.
6. Run the section 9 experiments and settle the inventory values they inform.
7. Decommission the old host.

## 11. Accepted risks and limitations

- The services host has one public listener, SSH, by user decision. Key-only
  authentication and OpenSSH's per-source penalties are the controls.
- Rootless containers are not confined by AppArmor; Podman does not apply
  profiles to rootless containers. Isolation rests on user namespaces, seccomp,
  dropped capabilities, the firewall and the tunnel.
- Podman secrets are not encrypted at rest on the host.
- A compromised edge can read and modify every request and response it proxies,
  and holds the TLS keys. The split limits the blast radius to what the firewall
  admits from the edge's tunnel address.
- Wallabag runs as root inside its container with six capabilities and a
  writable application tree.
- Debian 13's Podman 5.4.2 has unfixed CVEs that need a malicious image; image
  sources are pinned and trusted.
- Append-only backups protect history, not confidentiality: a compromised host
  can read its own repository.

## 12. Deferred to v2

- Socket-activated Caddy with native performance, once a Caddy release ships the
  CertMagic fix for HTTP-01 under socket activation.
- A derived Caddy image with the file capability stripped, allowing all
  capabilities dropped, built by a `.build` unit if plugins are ever needed.
- `hidepid` on by default, after the boot test has passed on a real host.
- Cosign key-pair verification for images built by this project.
- Metrics.

## 13. References

- podman-systemd.unit(5) for Podman 5.4.2, including the rootless search path and
  the user-scope network-online behaviour.
- pasta(1): port binding, `--freebind`, `--map-host-loopback`, low-port binding.
- systemd.exec(5), systemd.resource-control(5) and systemd.special(7) for
  systemd 257, and the systemd source for user-unit sandboxing behaviour.
- Debian bugs 1103560 (cgroup manager fallback), 1107134 (image units at boot),
  1133420 (IPv6 loopback publish).
- Podman issue 26035 (binding an unconfigured address), issue 21190 (auto-update
  with tag and digest), caddy-docker issue 396 (capability drop), Caddy issue 7525
  (socket activation and ACME).
- restic documentation on append-only repositories and `forget --keep-within`.
