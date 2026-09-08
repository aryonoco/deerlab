<!-- SPDX-License-Identifier: CC-BY-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <info@ameri.me> -->

# deerlab runbook

Operating procedures for the two-host estate: an edge host running only Caddy,
a services host running each application as a rootless Podman Quadlet, linked by
kernel WireGuard, configured entirely by Ansible and delivered by `ansible-pull`
against a signed `release` branch.

This document is written for someone who has only this repository, is under
time pressure, cannot experiment on a live estate and has nobody to ask. It
records what the build actually did, including the things that are silent when
they go wrong. Where something has never been tested, it says so — see
[What is not proven](#what-is-not-proven), and read it before you rely on
anything here in a real disaster.

Every address, hostname, domain, account name, bucket, endpoint and credential
belonging to this estate is encrypted in the inventory, because this repository
is public. Commands below use `<placeholders>` or `{{ inventory_variable }}`
references. Substitute from the decrypted inventory; never paste a real value
back into this file.

## Contents

- [Before you can do anything](#before-you-can-do-anything)
- [The shape of the estate](#the-shape-of-the-estate)
- [Where everything lives on a host](#where-everything-lives-on-a-host)
- [Day to day: getting a change onto the hosts](#day-to-day-getting-a-change-onto-the-hosts)
- [Reading state on a host](#reading-state-on-a-host)
- [Reboots and planned maintenance](#reboots-and-planned-maintenance)
- [Alerts, and the things that look like faults but are not](#alerts-and-the-things-that-look-like-faults-but-are-not)
- [Backups](#backups)
- [Restore](#restore)
- [Rebuilding a host from nothing](#rebuilding-a-host-from-nothing)
- [Bootstrapping a host](#bootstrapping-a-host)
- [Adding a service](#adding-a-service)
- [Rotating a secret](#rotating-a-secret)
- [SSH from a machine with several keys](#ssh-from-a-machine-with-several-keys)
- [Break-glass](#break-glass)
- [What is not proven](#what-is-not-proven)

## Before you can do anything

Two things this estate depends on are **not in this repository and cannot be
recovered from it**. A rebuild is impossible without the first and unsafe
without the second.

### The SOPS age identity

Every useful value in `inventory/` is encrypted to age recipients listed in
`.sops.yaml`: one operator key, plus one key per host that the `base_pull` role
generates on the host itself. The operator's private identity is **never written
to disk**. The login shell exports `SOPS_AGE_KEY_CMD`, which invokes the
password manager's CLI to print the identity on demand, and `sops` runs that
command each time it needs to decrypt.

Consequences to internalise:

- A process that does not inherit `SOPS_AGE_KEY_CMD` cannot decrypt anything.
  If a command fails to find a key, export the variable *inline in front of the
  command* rather than writing a key file.
- **On the operator's machine**, never set `SOPS_AGE_KEY_FILE` or create
  `~/.config/sops/age/keys.txt`. `sops` checks the file variable **before** the
  command variable, so a stray key file silently retires the vault route and
  puts the identity back on disk.
- **On the hosts it is the opposite, by design.** There is no vault and no
  interactive shell there, so `deerlab-pull.service` sets
  `Environment=SOPS_AGE_KEY_FILE=/etc/deerlab/age.key` — a root-only 0400 file
  generated on the host at bootstrap. Each host decrypts with its own key, which
  is why every host must be a recipient in `.sops.yaml` before its first
  unattended pull can succeed.
- If a `sops`, `ansible` or `just` command **hangs** instead of failing, the
  vault is locked. Unlock it and retry. A hang is not a decryption error.
- Losing the identity means losing the estate's configuration secrets
  permanently. There is no second copy on either host that can help: the host
  keys can decrypt the inventory but they are on the hosts you are trying to
  rebuild, and the operator-only credentials under `secrets/` are encrypted to
  the operator key alone.

### The object store's version-retention window

Per-service object-store credentials are scoped to that service's prefix, and
that scoping is real — each service's key is refused at the `Stat` of the other
service's repository config object. What it does not buy is a per-host blast
radius. Every `*.sops.yaml` under `inventory/` is encrypted to **both** host
keys, because a host that cannot decrypt the other's group vars cannot parse
the inventory at all: `base_wireguard` and `base_firewall` derive their peer
settings from `hostvars[<peer>]`, and reading those forces Ansible to compute
the peer's whole variable set. So every service's restic password and
object-store keys sit on both hosts, and the matching ciphertext is in a public
repository besides. **Assume a compromise of either host reaches every
service's repository.** What makes the resulting deletion recoverable is the
retention window below, not the prefix scoping.

But those credentials **can delete**. They have to: `restic backup` takes and
releases a lock under `locks/` on every run and cannot complete without delete
rights. So the only thing standing between a compromised host and the erasure of
that history is that **the object store retains prior versions of deleted
objects for a fixed window**.

That window is configured at the provider. It is not recorded in this
repository and cannot be, and nothing in the estate verifies it. It is a
required control, and it is a *detection deadline*, not immutability: it only
buys time for the dead-man checks to notice that backups have stopped. Look up
the configured window, and know it before you need it — if backup alerts have
been silent longer than that window, the history may already be gone.

The operator's own full-access object-store credential lives in
`secrets/backup-admin.sops.yaml`, encrypted to the operator key only,
deliberately not shared with either host. That is why a compromise of a host
cannot reach the credential that could erase everything.

## The shape of the estate

| | edge host (`edge1`) | services host (`svc1`) |
| --- | --- | --- |
| Group | `edge`, `podman_hosts` | `services`, `podman_hosts` |
| Public inbound | tcp 22, 80, 443, **8080, 8443**; udp 443, **8443**; udp WireGuard port | tcp 22; udp WireGuard port, **from the edge's public address only** |
| Runs | sshd, Caddy | sshd, application services |
| Service users | `caddy`, uid 2000 | `wallabag`, uid 2001 |

- Both hosts are stock Debian 13, dual-stack on the public side, configured by
  the `base_*` roles. Nothing else is installed by hand.
- **Ansible is the only executor.** There is no hypervisor, no OpenTofu, no
  container orchestrator, no control plane for the tunnel.
- The tunnel is kernel WireGuard driven by `systemd-networkd`: one `.netdev`
  and one `.network` per host under `/etc/systemd/network/`. **Both peers carry
  an `Endpoint=`**, an explicit `ListenPort` and `PersistentKeepalive=25`, so
  either host can initiate and neither depends on the other being up first.
- Caddy proxies to `http://<services tunnel IPv4>:<port>` in plain HTTP.
  WireGuard already provides confidentiality, integrity and peer
  authentication. Backends publish on the wildcard address, never on the tunnel
  address — a unit that binds the tunnel address races the interface at boot and
  fails hard on Podman 5.4.2. **The firewall, not the bind address, is what
  scopes a backend to the tunnel.**
- Host ports 80 and 443 reach Caddy through an nftables redirect to 8080 and
  8443. Caddy still listens on 80 and 443 inside its own namespace, so its own
  redirects and ACME challenges work unchanged.
- Each service runs under its own system user with its own 65536-wide
  subordinate ID range, its own firewall egress chain, its own slice limits and
  its own backup repository. One service definition in inventory derives all of
  them.
- **Subordinate ID ranges are arithmetic, not allocated**:
  `podman_user_subid_base + (uid - podman_user_uid_base) * podman_user_subid_count`,
  from
  `roles/podman_user/templates/subid.j2`. A rebuilt host derives the same
  mapping from the same inventory, which is what makes a restore portable. The
  corollary is a live hazard: **changing a service's `uid`, or
  `podman_user_uid_base` / `podman_user_subid_base` /
  `podman_user_subid_count`, silently invalidates
  the file ownership recorded in every existing snapshot for that service.**

## Where everything lives on a host

Assembling this under pressure is what costs the time. `<svc>` is the service
name, which is also its username; `<uid>` is its uid.

| Thing | Path |
| --- | --- |
| Pull unit and timer | `/etc/systemd/system/deerlab-pull.{service,timer}` |
| Pull checkout | `/var/lib/deerlab/checkout` |
| Pull's Ansible virtualenv | `/opt/deerlab/venv` |
| Host's age identity | `/etc/deerlab/age.key` (mode 0400) |
| Allowed signers for `--verify-commit` | `/etc/deerlab/allowed_signers` |
| Pushover credential, system scope | `/etc/deerlab/pushover.conf` |
| Pushover credential, per service user | `/etc/deerlab/pushover/<svc>.conf` |
| Quadlet units | `/etc/containers/systemd/users/<uid>/` |
| Service home | `/var/lib/<svc>` (mode 0700) |
| Service config files | `/var/lib/<svc>/config/` |
| Podman volumes | `/var/lib/<svc>/.local/share/containers/storage/volumes/<svc>-<volume>/_data` |
| Backup env, password, dead-man conf | `/etc/deerlab/backup/<svc>.env`, `.password`, `-deadman.conf` |
| Backup bootstrap marker | `/etc/deerlab/backup/<svc>.initialised` |
| Backup unit and timer | `/etc/systemd/user/deerlab-backup-<svc>.{service,timer}` |
| SQLite staging copy | `/var/lib/<svc>/backup/staging/` |
| User-manager ordering drop-in | `/etc/systemd/system/user@<uid>.service.d/10-wait-network.conf` |
| Per-service slice limits | `/etc/systemd/system/user-<uid>.slice.d/50-deerlab.conf` |
| Firewall ruleset | `/etc/nftables.conf` |
| WireGuard | `/etc/systemd/network/` |

Quadlet units are owned `root:root` mode 0644 — the service user can read its
unit and cannot rewrite it. The bare `/etc/containers/systemd/users/` directory
is never used; a unit placed there runs under *every* lingering user.

## Day to day: getting a change onto the hosts

Delivery is pull-based. Every host runs `deerlab-pull.timer` on
`OnCalendar=*:0/30` with `RandomizedDelaySec=300`, checks out `release`,
verifies the head commit's SSH signature against `/etc/deerlab/allowed_signers`,
and applies `playbooks/site.yml --limit <itself>`.

1. Branch, change, `just ci`, push, open a pull request.
2. When CI is green: `just merge <branch>`. This fast-forwards `main` **from
   your machine** so your signature stays on the head commit, then runs
   `git verify-commit HEAD` — the same check the hosts run. GitHub's own merge
   buttons rewrite or re-sign commits and the hosts would reject the result.
3. The `Promote` workflow fast-forwards `release` to `main` after CI passes on
   `main`. It is the only thing that pushes `release`.
4. Within 30 minutes both hosts apply it. To make it sooner:

       mise x -- ansible <host> -b -m ansible.builtin.shell \
         -a 'systemctl start deerlab-pull.service'

Commits created through the GitHub API — which is **every** Renovate commit —
carry GitHub's web-flow GPG signature rather than a key in
`deerlab_allowed_signers`, and the hosts refuse them. Rebase a bot branch under
your own key before merging: `git rebase --force-rebase -S main`.

The gate that matters is on the host, not on GitHub. There are no server-side
branch rules, deliberately: GitHub counts a commit as verified if *any*
registered key signed it, while `ansible-pull --verify-commit` demands a key
from the allowed-signers file. An unverifiable commit stops delivery no matter
what GitHub accepted.

### Seeing a change before you merge it

`just plan <host>` runs `site.yml` in check-and-diff mode against the real host.

Two things you must know to read its output:

- **A converged host reports exactly one change in check mode**: the
  `base_pull : Install Ansible into its virtual environment` task, because
  `ansible.builtin.pip` cannot determine whether requirements are satisfied
  without invoking pip, which check mode forbids. It is not drift. **Anything
  beyond that one change is real.**
- **`just plan` requires an already-bootstrapped host.** The `podman_service`
  role runs `podman info` as each service user, and that user does not exist
  until a real run has created it. Check mode against a fresh image fails; use
  `just bootstrap`.

`just apply <host>` pushes directly, bypassing the release branch. It is for
bootstrap and break-glass only. Anything it does will be reverted by the next
pull unless the same change is also promoted — which is the design working, not
a fault, but it will restart the affected units when it happens.

## Reading state on a host

Neither host permits root SSH. Connect as the admin user
(`{{ deerlab_admin_user }}`, encrypted in `inventory/group_vars/all/`) and
escalate with `sudo -i`. `ansible.cfg` sets `become = true` globally, so ad-hoc
Ansible already escalates without `-b`; the examples here pass it anyway, so they
still read correctly out of context.

    # Is a pull running? `systemctl is-active --quiet` LIES here - see below.
    systemctl show deerlab-pull.service -p ActiveState --value
    systemctl list-timers deerlab-pull.timer --no-pager

    # Service state, from the system side
    systemctl --user --machine=<svc>@ is-active <svc>.service
    systemctl --user --machine=<svc>@ show <svc>.service \
      -p ActiveState -p SubState -p Result -p NRestarts

    # Logs. `journalctl --machine=<svc>@` does NOT work: it attempts namespace
    # entry. Match on the unit and uid instead.
    journalctl _SYSTEMD_USER_UNIT=<svc>.service _UID=<uid> --since "-10 min" -o cat

    # Anything run directly as the service user needs a working directory that
    # user can reach. Run it from /, or runuser dies on `cannot chdir`.
    cd / && runuser -u <svc> -- podman volume ls

> **`systemctl is-active --quiet deerlab-pull.service` is wrong and will
> mislead you.** A `Type=oneshot` unit that is *running* is `activating`, not
> `active`, so `is-active` exits non-zero and you conclude nothing is running
> while a pull is in flight. This exact mistake caused a service to be restarted
> underneath an operator mid-drill. Always use
> `systemctl show deerlab-pull.service -p ActiveState --value`; `inactive` or
> `failed` means done.

A healthy pull takes roughly 90 seconds and is bounded by
`TimeoutStartSec=20m`. Because of the timer's 0–300s randomised delay, two
consecutive firings can land as little as 25 minutes apart, not a clean 30.
**The pull is a live hazard during any manual intervention**, and there is no
safe way to suppress it: stopping the timer is self-trapping, because only a
pull re-enables it. The mitigation is procedural — check `ActiveState`, confirm
the timer has headroom, and work in the window immediately after a pull
completes.

## Reboots and planned maintenance

Automatic reboots are off. A daily timer sends a Pushover message reading
`Reboot required on <host>` for as long as `/run/reboot-required` exists.

Reboot the services host first, then the edge:

    mise x -- ansible svc1 -b -m ansible.builtin.reboot
    mise x -- ansible svc1 -b -m ansible.builtin.shell \
      -a 'systemctl --user --machine=wallabag@ is-active wallabag.service'
    mise x -- ansible edge1 -b -m ansible.builtin.reboot

What to expect, so a regression is visible:

- **Services host.** The host takes about a minute to come back. The service
  unit is `activating` immediately afterwards and reaches `active` some 30–60
  seconds later while the application finishes starting; `NRestarts` stays at
  `0` throughout. A non-zero `NRestarts` means the wait-network ordering
  drop-in has been lost and the unit is racing the tunnel at boot.
- **Edge host.** The host is down for roughly 15 seconds. The tunnel
  re-establishes **within about a second** of the interface coming up, because
  both peers hold an `Endpoint=`.

That last number is the one to watch. An earlier design gave the edge no
`Endpoint=`: it learned svc1's address at runtime and lost it on every reboot,
so it could not initiate, and recovery waited for the services host's session to
expire at WireGuard's `REJECT_AFTER_TIME`. Measured across two reboots, the
backend was unreachable for 30 seconds and for 183 seconds — a 0–180s window in
which Caddy was fully up and every real request received
`503 no upstreams available`.

**So: minutes of `503 no upstreams available` after an edge reboot means the
peer `Endpoint=` or the source-scoped inbound WireGuard rule on the services
host has been lost.** It is not a transient. Check
`base_wireguard_public_endpoint` on both hosts and the services host's inbound
rule before looking anywhere else.

## Alerts, and the things that look like faults but are not

Two independent channels, deliberately sharing no failure domain:

- **Pushover, direct from each host**, attached with `OnFailure=` to every
  Quadlet, every backup unit, the pull unit, and the host units listed in
  `base_notify_onfailure_units` — `nftables.service` and
  `systemd-networkd.service`. The reboot-required timer posts the same way. A failing
  unit reports itself. Notifications leave the host directly and depend on
  neither the edge nor the external monitor — an outage of the thing that
  watches must not also silence the thing that reports.
- **Dead-man push monitors on an external uptime monitor**, hosted away from
  both hosts. Each successful pull and each successful backup pings a push URL;
  the monitor alerts when a ping does not arrive in time. A host that stops
  running anything reports nothing, and silence is indistinguishable from
  health — this is what closes that gap. Push URLs are bearer secrets and live
  in SOPS (`deerlab_deadman_urls`): anyone holding one can mark a check healthy
  and mask a real outage.

Nothing watches the external monitor itself.

### Expected, not incidents

- **Stopping any service always leaves it `failed` and always pages you.** The
  Quadlets carry `Restart=always` and `Notify=healthy`; Podman exits non-zero on
  `SIGTERM`, so an explicit `systemctl --user stop` ends in `ActiveState=failed`
  and trips `OnFailure=notify-failure@…`. Expect exactly one Pushover alert per
  stop during any planned restore or maintenance. Do not chase it. (`Restart=always`
  does not resurrect a unit after an explicit stop, so the stop does hold.)
- **A red backup dead-man may mean "snapshot fine, repository unverifiable".**
  The backup unit runs `restic check` *after* the snapshot is committed, and a
  check failure fails the unit — so `ExecStartPost`, the dead-man ping, is
  skipped. Both alarms fire. The Pushover message names the unit; read the
  journal before concluding the snapshot did not happen.
- **`just plan` reporting one change on a converged host** is the pip task, not
  drift. See [Day to day](#day-to-day-getting-a-change-onto-the-hosts).
- **A host briefly ahead of `release`** after a `just apply` will be reverted by
  the next pull, restarting the affected unit once. Expected; it resolves when
  the commit is promoted.

### The health check does not prove the data is good

This is the most important line in this document after the restore ordering.

The container health check and `systemctl is-active` are both blind to a
destroyed database, and were measured to be:

| state | `ActiveState` | health check | `/login` |
| --- | --- | --- | --- |
| database overwritten with random bytes, service left **running** | `active` | 200 | 200 |
| database overwritten with random bytes, service **restarted** onto it | `active` | 200 | 500 |
| restored | `active` | 200 | 200 |

A running instance keeps serving 200 over a destroyed file because SQLite has
the pages cached and the inode never changed. **Corruption can therefore sit
invisible until the next restart**, which with `Restart=always` may be days
later and unattended.

The acceptance test after any restore is therefore **`GET /login` returning 200
after a restart**, and nothing weaker.

Even that only proves the database is *readable*. It cannot tell you the data is
**yours** — see [Rebuilding a host from nothing](#rebuilding-a-host-from-nothing).
Only a human looking at content can.

## Backups

One `backup` role, driven by the same `podman_services` record as everything
else. Per service it installs a user-scope oneshot unit and timer in that
service's own systemd manager, running at `03:00` UTC with
`RandomizedDelaySec=1800` — so between 03:00 and 03:30, bounded by
`TimeoutStartSec=1h`.

The unit's steps, in order:

1. `ExecStartPre`: `podman unshare test -s <live database>`. This guard exists
   because `sqlite3` opens its source with `OPEN_CREATE` — a path that is merely
   *wrong* does not fail, it creates an empty 4096-byte database, copies that
   over the last good staging copy, passes the integrity check, uploads it and
   pings the dead-man. Nothing downstream can tell that apart from a healthy
   backup. `-s`, not `-f`, because a zero-length file is exactly the case to
   refuse.
2. An online SQLite `.backup` into `/var/lib/<svc>/backup/staging/`, inside
   `podman unshare` so subordinate-owned files are readable.
3. `PRAGMA integrity_check` on that copy, **tested** rather than merely run:
   `sqlite3` exits 0 on a corrupt database.
4. `podman unshare restic backup` of the staging directory plus each named
   volume's `_data`.
5. `restic check` — structural, no `--read-data`.
6. `ExecStartPost`: the dead-man ping.

On the edge, Caddy's data volume is backed up the same way, so a rebuild does
not burn ACME rate limits re-issuing certificates.

### Hazards specific to this role

- **`restic check` takes an exclusive repository lock** and runs after every
  snapshot. A manual `just backup-prune` fired inside the backup window will
  contend with it. Run retention outside 03:00–03:30 UTC.
- **restic invoked by the role runs under the service user's systemd manager,
  not your SSH session.** It therefore **outlives an interrupted command**:
  `Ctrl-C` does not stop it, and it may still be holding a repository lock after
  your terminal has returned. Check with `restic list locks` before concluding a
  lock is stale.
- **A stale lock is cleared with `restic unlock`. Never by deleting objects from
  the repository.**
- **`/etc/deerlab/backup/<svc>.initialised` is a safety marker, not clutter.**
  It records that the repository has been bootstrapped, so the unattended pull
  stops probing the object store forever. It also stops a repository that has
  been *deleted at the provider* from being silently recreated: without the
  marker the next pull would initialise a fresh empty repository, the backup
  would succeed against it, and the dead-man would go green over no history at
  all. With the marker, `restic backup` fails against the missing repository and
  pages you, which is the alarm you want. **Deleting this file is not a
  troubleshooting step.** Delete it only to deliberately re-bootstrap a
  repository you have decided is genuinely gone, and understand that doing so
  starts your history again from zero.
- **Renaming a database path in inventory leaves the old file in staging.** It
  is never cleaned up and keeps being archived alongside the new one, where a
  careless restore could pick it. Remove it from
  `/var/lib/<svc>/backup/staging/` by hand after any such rename.
- **Before removing a volume, check nothing else references it** — another
  service definition, another mount, another backup path.
- The `restic` on the hosts is not necessarily the version pinned in
  `mise.toml`, which is the operator machine's. Do not assume parity of flags.

### Retention

Retention runs **from the operator's machine only**, using the full-access
credential in `secrets/backup-admin.sops.yaml`:

    just backup-prune <service>

The policy is `forget --keep-within 30d --keep-within-weekly 3m
--keep-within-monthly 1y --prune`, as restic recommends for append-only
repositories.

`just backup-prune` and `just restore-drill` take **one** argument, the service
name. The inventory file holding that service's restic password is located by
the key name it contains, and the recipe fails loudly on zero or more than one
match — guessing the group is how a restore drill ends up pointed at an empty
repository and passes without restoring anything.

## Restore

Read the [ordering requirement](#rebuilding-a-host-from-nothing) before
restoring onto a host that has just been rebuilt.

### Pre-flight, every time

Check (a) every time: it bit during the drill that produced this procedure, and
a pull started the service back up underneath the operator mid-restore. Checks
(b) and (c) have never yet caught anything — no repository lock has ever been
encountered — but they cost seconds and they guard failures this design predicts.

    # (a) No pull mid-flight, and enough headroom before the next one.
    systemctl show deerlab-pull.service -p ActiveState --value   # need inactive|failed
    systemctl list-timers deerlab-pull.timer --no-pager          # need >5 min

    # (b) No backup running, and no repository lock.
    systemctl --user --machine=<svc>@ show deerlab-backup-<svc>.service \
      -p ActiveState --value
    systemd-run --machine=<svc>@ --user --quiet --pipe --wait --collect \
      --property=EnvironmentFile=/etc/deerlab/backup/<svc>.env \
      --setenv=RESTIC_PASSWORD_FILE=/etc/deerlab/backup/<svc>.password \
      /usr/bin/restic list locks
    # No output means no lock. Clear a stale one with `restic unlock`, NEVER by
    # deleting repository objects.

    # (c) Choose the snapshot. `latest` is right for "undo the last hour" and
    #     wrong for almost everything else - see the ordering requirement.
    systemd-run --machine=<svc>@ --user --quiet --pipe --wait --collect \
      --property=EnvironmentFile=/etc/deerlab/backup/<svc>.env \
      --setenv=RESTIC_PASSWORD_FILE=/etc/deerlab/backup/<svc>.password \
      /usr/bin/restic snapshots --compact

`systemd-run --machine=<svc>@ --user … --pipe --wait --collect` is the form used
throughout, and it propagates exit status faithfully — verified. It exists so
that repository credentials reach restic through the same `EnvironmentFile`
systemd already parses, and never as a `KEY=value` prefix on a command line:
`/proc/<pid>/cmdline` is mode 0444 and readable by any local account, including
one service user reading another's. Only `/proc/<pid>/environ` is protected, at
0400. Do not "simplify" these commands by exporting credentials in your shell.

### Drill: restore to a scratch directory

Quarterly, from the operator's machine, using the operator credential:

    just restore-drill <service>

This restores the latest snapshot to `/tmp/deerlab-restore-<service>`, runs
`PRAGMA integrity_check` on every `*.sqlite` it finds, and prints the target. It
touches nothing on the hosts.

### A. Restore a database into a live service

The proved sequence. Run **as root on the services host**. Prefer pasting it
into a root shell on the host over pushing it through Ansible: the command
otherwise passes through three shells (yours, Ansible's `/bin/sh -c`, and the
inner `sh -c`), and `$d` eaten by the outer shell makes the copy target
`/<db file>` at the filesystem root, where it silently succeeds. If you must
push it, keep the script in a file and use `-a "$(cat step.sh)"`.

    # 1. Stop the service. It will end `failed` and page you. Expected.
    systemctl --user --machine=<svc>@ stop <svc>.service
    systemctl --user --machine=<svc>@ show <svc>.service -p ActiveState --value

    # 2. Restore, verify, then swap atomically.
    systemd-run --machine=<svc>@ --user --quiet --pipe --wait --collect \
      --property=EnvironmentFile=/etc/deerlab/backup/<svc>.env \
      --setenv=RESTIC_PASSWORD_FILE=/etc/deerlab/backup/<svc>.password \
      /usr/bin/podman unshare /bin/sh -c '
    set -e
    d=/var/lib/<svc>/.local/share/containers/storage/volumes/<svc>-<volume>/_data/<db dir>
    s=/var/lib/<svc>/backup/restore
    r=$s/var/lib/<svc>/backup/staging/<db file>
    rm -rf "$s"
    /usr/bin/restic restore latest --target "$s" --include /var/lib/<svc>/backup/staging/<db file>
    test -s "$r"
    test "$(/usr/bin/sqlite3 "$r" "PRAGMA integrity_check")" = ok
    # Take ownership and mode from the file being replaced. The fallback is
    # this application's container uid, not a universal one - see below.
    own=$(stat -c '%u:%g' "$d/<db file>" 2>/dev/null || echo 65534:65534)
    mode=$(stat -c '%a' "$d/<db file>" 2>/dev/null || echo 644)
    cp "$r" "$d/<db file>.restored"
    chown "$own" "$d/<db file>.restored"
    chmod "$mode" "$d/<db file>.restored"
    rm -f "$d/<db file>-wal" "$d/<db file>-shm" "$d/<db file>-journal"
    mv -f "$d/<db file>.restored" "$d/<db file>"
    rm -rf "$s"
    '
    echo "restore rc=$?"   # must be 0

    # 3. Start, then verify with a real request. is-active and the health check
    #    both return green over a destroyed database - see above.
    systemctl --user --machine=<svc>@ start <svc>.service
    curl -s -o /dev/null -w "login=%{http_code}\n" http://127.0.0.1:<port>/login

Why each of those lines is the way it is:

- **Integrity-check the restored file before it overwrites the live one.** Copy
  first and find out afterwards, and a bad restore has already landed.
- **Swap atomically, within the same directory.** `cp` onto the live path
  truncates and rewrites the live inode; anything that reads it mid-copy — an
  `ansible-pull`-triggered start, for instance — sees a torn file. A rename
  within one filesystem is atomic.
- **Set owner and mode explicitly, read off the file being replaced.** `cp`
  onto an *existing* file keeps that file's mode, but in the disaster this
  procedure is for the file may be gone, and owner and mode would then come from
  the transient unit's umask. Reading them with `stat` first means the procedure
  carries no service-specific constant whenever the live file is present.
- **Remove `-journal` as well as `-wal` and `-shm`.** This database is not in
  WAL mode, so no `-wal`/`-shm` exist at all; `-journal`, the rollback journal,
  is the file that can actually re-corrupt a freshly restored database. Removing
  all three costs nothing.
- **`65534:65534 644` is only the fallback, and it is not universal.** It is
  *this* application's container uid: inside `podman unshare` the service user is
  uid 0 and this image's web server user maps to namespace uid 65534. `ls`
  renders it as `nobody nogroup` from the host's `/etc/passwd`; it is a real
  mapped id, not an unmapped one. **Another image will map a different uid**, so
  check the live tree with `stat` before trusting the fallback, and never copy
  this number into a procedure for a different service.
- `restic restore --include` still creates the whole parent directory chain, so
  the file lands at a nested absolute path under `--target` and the summary
  reads something like `Restored 6 / 1 files/dirs`. That is normal.

### B. Rebuild a service's volumes from a snapshot

For when the volumes themselves are gone, not just a file inside one. Proved
end to end: both volumes were removed outright, recreated empty by their Quadlet
units, restored, and the service reached `active`/`healthy` 37 seconds after
start with a database byte-identical to the pre-drill file.

Run as root on the services host, from `/`.

    V=/var/lib/<svc>/.local/share/containers/storage/volumes
    export XDG_RUNTIME_DIR=/run/user/<uid>
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus

    # 1. Stop the service. Ends `failed`, pages you. Expected.
    systemctl --user --machine=<svc>@ stop <svc>.service

    # 2. Remove the volumes. Quadlet runs the container with --rm, so stopping
    #    already removed it and nothing holds a reference.
    cd / && runuser -u <svc> -- podman volume rm <svc>-<volume> ...

    # 3. Let the Quadlet .volume units recreate them empty. `restart`, not
    #    `start`: they are Type=oneshot RemainAfterExit=yes and are still
    #    "active" from the last boot, so `start` is a no-op.
    systemctl --user --machine=<svc>@ restart <svc>-<volume>-volume.service ...

    # 4. Restore each volume tree, inside the same user namespace the backup
    #    used. NOTE THE TARGET - see the trap below.
    systemd-run --machine=<svc>@ --user --quiet --pipe --wait --collect \
      --property=EnvironmentFile=/etc/deerlab/backup/<svc>.env \
      --setenv=RESTIC_PASSWORD_FILE=/etc/deerlab/backup/<svc>.password \
      /usr/bin/podman unshare /usr/bin/restic restore \
      "<snapshot>:$V/<svc>-<volume>" --target "$V/<svc>-<volume>"

    # 5. Start it, then verify with a real request.
    systemctl --user --machine=<svc>@ start <svc>.service

> ### The trap: restore to the volume directory, never to its `_data` child
>
> restic does **not** apply stored metadata to its own `--target` directory. So
> restoring `<snap>:…/<svc>-<volume>/_data` into `…/<svc>-<volume>/_data` leaves
> the *contents* correctly owned while `_data` itself keeps whatever Podman gave
> it on creation — the service user, not the container user. Measured against
> the exact post-recreate state:
>
> | restore target | resulting `_data` ownership |
> | --- | --- |
> | `<snap>:…/<svc>-<volume>/_data` → `…/<svc>-<volume>/_data` | service user (**wrong**) |
> | `<snap>:…/<svc>-<volume>` → `…/<svc>-<volume>` | container user (**right**) |
>
> **Contents right, directory wrong.** On a volume whose application writes into
> a restored *subdirectory* this goes completely unnoticed, possibly for months.
> On a volume whose container writes straight into `_data` — an uploads or
> images volume — it breaks immediately, and the error will not mention
> ownership. Restoring one level up is the whole difference, and nothing about
> the obvious command tells you so.

Two more things about the namespace, both load-bearing:

- **Both ends must run inside `podman unshare`.** The backup was taken there, so
  restic recorded the container's files as namespace uid 65534 rather than the
  five-or-six-digit subordinate uid they actually are on disk. Restore outside
  the namespace and you write a literal 65534, a uid that belongs to nothing.
  Restore inside it and the kernel translates through the *restoring* host's
  `/etc/subuid` — which is why a rebuilt host with a correctly derived
  subordinate range gets the right answer.
- **Never restore this repository with `--target /`.** Inside `podman unshare`,
  files owned by real root also read as 65534, because real root is unmapped and
  65534 is the overflow uid. In a snapshot, `/var` and `/var/lib` are therefore
  indistinguishable from genuinely container-owned files, and restic would try
  to apply container ownership to system directories. Restore the named subtrees
  and the question never arises.

## Rebuilding a host from nothing

**Read this section before you need it.** It contains the one finding most
likely to cost real data, and it is invisible at the moment it matters.

### A botched rebuild does not look broken. It looks successful.

A fresh host's application entrypoint checks whether its database exists and is
non-empty. If it does not, **it installs a brand-new database with a
brand-new admin account** — and then everything downstream reports health:

- the unit reaches `active`;
- the container health check passes;
- `/login` returns **200**;
- the edge's upstream health check goes `host is up` and traffic is routed;
- the next scheduled backup **snapshots that empty database** and pings the
  dead-man green.

So the failure mode is not an outage. It is a host that is up, green, fast and
empty, holding an admin account nobody knows, quietly overwriting your history
one nightly snapshot at a time. No automated check in this estate distinguishes
that state from a correct one, because every check asks whether the database is
*readable*, and it is.

### Therefore

1. **Restore before the first backup runs.** This is an ordering requirement,
   not advice. The backup timer fires at 03:00–03:30 UTC, so plan the rebuild to
   finish inside that budget.

   Note that you **cannot durably suppress the timer** to buy time. The `backup`
   role ends every run with `enabled: true, state: started` on it, so a
   `systemctl --user stop` is undone by the next pull within 30 minutes — the
   same self-trapping property the pull timer has. Masking it would instead make
   that task fail the pull. Treat the 03:00 UTC window as a real deadline, and
   if you cannot meet it, fall back on point 2 rather than on fighting systemd.
2. **Reaching past the newest snapshot is normal in this scenario.** Retention
   keeps prior snapshots for the configured window, so recovery is a matter of
   reading `restic snapshots` and choosing by *time*, not taking `latest`. The
   newest snapshot may be the empty one, and it will look perfectly fine. This
   is the reason the retention window is a required control and not a nicety.
3. **Only a human can confirm the restore.** Log in and look at real content —
   an entry you recognise, a user count, a row you put there. `GET /login`
   returning 200 proves the database is readable. It does not prove it is yours.

### The sequence

> **This sequence has never been run end to end.** Every restore drill so far
> was onto a host that already had its service user, subordinate ranges, Quadlet
> units, pulled image, Podman secrets, backup credentials, user manager, tunnel
> and firewall. Steps 2 and 3 below are drilled; step 1 is inference from the
> fact that these hosts were themselves built this way. Expect to debug, budget
> accordingly, and read
> [What is not proven](#what-is-not-proven) before you start.

The realistic order on a genuinely new host is *not* "restore, then start". It
is:

1. Provision the host and bootstrap it — see
   [Bootstrapping a host](#bootstrapping-a-host). Ansible creates the service
   user, the subordinate ranges, the Quadlets, the secrets, the network and the
   backup credentials, pulls the image, and starts the service **over an empty
   volume**. Everything from here on depends on that having happened: on a new
   host, none of it exists until `ansible-pull` has run once.

   A rebuilt host has no `/etc/deerlab/backup/<svc>.initialised` marker, so the
   `backup` role probes the object store once with `restic cat config`. Against
   an existing repository that probe succeeds, no `restic init` runs, and the
   marker is written. **Bootstrapping a replacement host does not erase or
   reinitialise the existing repository.** If the probe fails, that means the
   credentials are wrong or the repository really is gone — stop and find out
   which before letting anything write.
2. **Do not celebrate the green service.** Go straight to
   [Restore B](#b-rebuild-a-services-volumes-from-a-snapshot): stop the service,
   restore the volumes, start it.
3. Verify by restart-and-look, per point 3 above.
4. Only then let the backup timer run.

A rebuild is not finished when the service is green. It is finished when the
data is verified.

## Bootstrapping a host

1. Create the VPS from the stock Debian 13 image with your SSH key on root.
2. Fill in that host's encrypted vars in
   `inventory/host_vars/<host>/secrets.sops.yaml`: `ansible_host`,
   `base_wireguard_ipv4`, `base_wireguard_ipv6`, `base_wireguard_private_key`.
   Generate the keypair with `wg genkey` and `wg pubkey`; write the private half
   with `mise x -- sops set` so no plaintext key touches the disk, and put the
   public half in `inventory/host_vars/<host>/main.yml` as
   `base_wireguard_public_key`. It is deliberately plaintext: it is derived from
   the private key, it is handed to the peer by design, and keeping it clear
   stops each host having to decrypt the other's host vars.
   **`base_wireguard_public_endpoint` is not uniform across the two hosts, and
   getting it wrong degrades the tunnel silently.** Its role default is the
   empty string. The services host derives its own in
   `inventory/host_vars/svc1/main.yml` from `ansible_host` and the WireGuard
   port; the edge carries an explicit value in its own
   `inventory/host_vars/edge1/secrets.sops.yaml` and defines none in
   `main.yml`. Each host builds its peer list from the **other** host's value,
   and `roles/base_wireguard/templates/wg.netdev.j2` emits **neither
   `Endpoint=` nor `PersistentKeepalive=`** when that value is empty.

   So a replacement host must be given an endpoint one way or the other —
   explicitly in its `secrets.sops.yaml`, or derived in its `main.yml` as the
   services host does. Miss it and the *other* host has nothing to send to and
   no keepalive to hold the path open, so it cannot initiate. That is the
   asymmetry described under
   [Reboots and planned maintenance](#reboots-and-planned-maintenance), only
   mirrored — and it will not fail outright, because the host that still has an
   endpoint keeps initiating. It stays hidden until the host that still has one
   is the host that reboots. **A rebuilt edge is the dangerous case**, because
   the edge is the one whose value is explicit rather than derived, so it is the
   one that is easy to leave empty.

   After bootstrapping either host, confirm from the **peer** that it has an
   endpoint for the new host before you consider the tunnel done:

       mise x -- ansible <peer> -m ansible.builtin.shell -a 'wg show wg0 endpoints'
3. `ssh-keyscan -H <ip> >> ~/.ssh/known_hosts`, then `just bootstrap <host>`.
   That run connects as root with `base_pull_enabled=false`, because a host
   being bootstrapped is not yet a SOPS recipient and its first unattended pull
   could only fail to decrypt. Root login is closed by the end of the run.
4. The run prints `base_pull age public key for <host>: age1…`. Add it to the
   inventory rule in `.sops.yaml`, run `just secrets-rekey`, commit, `just merge
   <branch>`, and wait for `Promote`.
5. Start the first pull by hand and confirm the dead-man goes green:

       mise x -- ansible <host> -b -m ansible.builtin.shell \
         -a 'systemctl start deerlab-pull.service'

Note that `secrets/` is matched by its own creation rule, listed **first** so it
wins, and is encrypted to the operator key alone. Nothing on a host reads that
directory: the credential it holds can erase a repository's history, so giving a
host key access to it would mean a compromise of either host also destroys the
path back.

## Adding a service

1. Add an entry to `podman_services` — in
   `inventory/group_vars/services/main.yml` for the services host, or
   `inventory/group_vars/edge/main.yml` for the edge. Give it the next UID from
   2000 upward, a fully qualified digest-pinned image written as a literal
   `image:` value, published ports, volumes, tmpfs, a health command, limits, an
   egress class and a `backup:` block. Renovate's custom manager matches
   `image:` lines under `inventory/group_vars/` — not the Quadlet's `Image=`
   line, which the role renders — so an image assembled from variables is one
   Renovate will never bump. Secrets go in
   the matching `secrets.sops.yaml` and are referenced from the definition with
   `{{ }}`.

   The record itself stays in plaintext, deliberately: the service key, the
   image, ports, UID, capabilities, health command, limits and egress class are
   what review is *for*, and they identify nothing on their own. Every field
   that resolves to or authenticates against something outside the repository —
   a domain, an address, an email, a bucket, a credential — is a `{{ }}`
   reference to an encrypted variable.

2. **Start from nothing and add back.** Drop all capabilities, set
   `read_only: true` and `no_new_privileges: true`, then add back only what the
   image proves it needs, one at a time, recording in a comment beside the
   definition what failed and how. That is how the current service's list was
   arrived at, and why one capability that "looked required" is not in it.

3. Add a site block to `caddy_caddyfile` in
   `inventory/group_vars/edge/main.yml` pointing at
   `http://{{ hostvars['svc1']['base_wireguard_ipv4'] }}:<port>`, with an active
   health check whose URI actually reads the database, and create the DNS
   records.

4. Create a push monitor for the backup on the external uptime monitor and add
   its URL to `deerlab_deadman_urls.backup`, with a heartbeat interval covering
   the schedule *plus its jitter* — the backup timer carries
   `RandomizedDelaySec=1800`. Create object-store credentials scoped to the
   service's own prefix, and add the restic password and the two keys to the
   matching `secrets.sops.yaml` as `backup_<service>_restic_password`,
   `backup_<service>_s3_access_key` and `backup_<service>_s3_secret_key`.

5. `just plan svc1`, then merge. The service user, subordinate range, slice
   drop-in, firewall chain, Quadlet, secrets, backup unit and timer all derive
   from that one record.

When proving a *new edge*, point `caddy_acme_ca` at the CA's staging directory
URL first. Staging's failure limits are far higher, so a wrong DNS record or an
unreachable port 80 costs nothing. Empty selects the production CA.

## Rotating a secret

Edit with `just secrets-edit <file>`, commit, merge, promote. The next pull
recreates the Podman secret and restarts the unit that consumes it.

- WireGuard keys are rotated the same way, and **both hosts must be updated in
  the same commit** — a half-rotated tunnel is a broken tunnel, and the services
  host has no other route in.
- After changing the recipient list in `.sops.yaml`, run `just secrets-rekey`.
  It re-encrypts every tracked `*.sops.yaml` for the recipients currently
  listed. Note that sops matches creation rules against the **absolute** path,
  which is why the `secrets/` rule is anchored `(^|/)secrets/…` and not
  `^secrets/…`; an anchor that matches nothing makes `updatekeys` report
  "already up to date" and leaves the credential shared, with a green result.
- Rotating a secret is not a substitute for treating an exposure as an
  exposure. Ciphertext in this repository is world-readable and permanently
  archived by third parties, so an age key leak would be retroactive and total.

## SSH from a machine with several keys

`ssh` offers agent keys in agent order until one is accepted, and each offer
counts against the server's `MaxAuthTries`. If you carry many keys, pin the one
that belongs to these hosts so only it is offered:

    Host <edge public IPv4> <services public IPv4>
        IdentitiesOnly yes
        IdentityFile ~/.ssh/deerlab.pub

Pointing `IdentityFile` at the *public* key selects that identity from the
agent. This is a convenience, not a requirement — the server's limit is set high
enough that an unpinned client still authenticates.

## Break-glass

If SSH is unreachable, use the provider's console. The root password is the one
whose hash is held in the inventory as `deerlab_root_password_hash`; decrypt
`inventory/group_vars/all/secrets.sops.yaml` to find the plaintext you set, or
set a new one and re-apply. (`base_os` sets it precisely so the console is a
usable route when the network path is not.)

**Never `systemctl stop nftables` on a Debian host.** It flushes every rule and
leaves the host wide open with no ruleset at all. Use `systemctl reload
nftables`, or `nft -f /etc/nftables.conf` after editing. The template task
validates with `nft --check` before writing, so a rendered ruleset that reaches
disk has at least parsed.

Break-glass changes made with `just apply` are reverted by the next pull. If the
fix must stick, promote it.

## What is not proven

A runbook that overstates its coverage is worse than one that admits gaps,
because it stops the reader being careful exactly where care is needed. As of
the last drill:

- **The full rebuild path has never been run end to end.** Every restore so far
  was onto a host that kept its service user, subordinate ranges, Quadlet units,
  pulled image, Podman secrets, backup credentials, user manager, tunnel and
  firewall. What is evidenced is the *last* link: data back into a host that was
  already built. The links before it are inference from the fact that these
  hosts were themselves built that way. The honest test is a third VPS,
  bootstrapped from this repository with nothing but an address and a DNS
  change, then restored.
- **Restoring onto a host with a different subordinate base has not been
  demonstrated.** The argument that `podman unshare` makes it portable follows
  from where the kernel applies the mapping and is sound, but both ends of every
  drill so far were the same host with the same `/etc/subuid`.
- **The raw volume copy of a database inside a snapshot is a hot copy.** Every
  snapshot contains the database twice: the staging copy, written by SQLite's
  online `.backup` and integrity-checked by the unit, which is consistent by
  construction; and the plain file read of the live database inside the volume
  tree, which is consistent only by luck. A volume-level restore (Restore B)
  takes the second one. On a busy instance it can carry a torn page set, and
  nothing in the pipeline would notice — `restic check` verifies the repository,
  not the database inside it. **A torn copy has never been produced, restored or
  detected.** If you have the choice, restore the volumes and then overwrite the
  database with the snapshot's staging copy per Restore A.
- **The alerting path has never fired for a backup failure.** That
  `OnFailure=notify-failure@…` resolves in user scope is verified by
  `systemd-analyze --user verify`; delivery is inherited from a path proved
  elsewhere. A real backup failure has never been deliberately induced.
- **Retention has never actually deleted a snapshot.** Every repository is well
  inside `--keep-within 30d`, so `forget --prune` has only ever been a no-op
  beyond index maintenance. That the operator credential *can* delete is
  untested; that the per-service credentials can delete their own locks is
  tested.
- **Scale is unproven.** The repositories are hundreds of kilobytes. Nothing
  here says anything about restore duration, timeout headroom or hot-copy risk
  at gigabytes.
