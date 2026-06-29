# Modules Reference

Every reusable NixOS module lives under `modules/` and is exposed as one or
more options under the `jupiter.*` namespace (per the convention in
`CLAUDE.md`). This page documents each module: its options, defaults, what it
configures, and which hosts currently enable it.

Modules with no `jupiter.*` option are unconditional — every host that
imports them gets the config with no toggle.

## Core

### `modules/common.nix`
No option — the universal baseline. See [01-architecture.md §5](01-architecture.md#5-two-base-layers-commonnix-vs-common-statefulnix).

### `modules/common-stateful.nix`
No option — `common.nix` + bootloader + fallback root filesystem for hosts with local disks.

### `modules/core/impermanence.nix`
```
jupiter.core.impermanence.enable     (bool, default false)
jupiter.core.impermanence.persistPath (string, default "/persist")
```
Wraps `environment.persistence."${persistPath}"` (from the `impermanence`
flake input): persists `/var/log`, `/var/lib/nixos`, `/var/lib/systemd/coredump`,
`/var/lib/libvirt`, NetworkManager connections, `/var/lib/sops-nix`, the
machine-id, and the SSH host key — plus, for user `io`: `Downloads`, `Music`,
`Pictures`, `Documents`, `Videos`, `Projects`, `.config`, `.ssh`,
`.local/share/keyrings`, `.local/share/direnv`, `.gemini`, `.claude`, and
`.bash_history`.

**Enabled by:** `t460s` only.

### `modules/branding.nix`
```
jupiter.branding.enable   (bool, default false)
```
RobCo Industries / Fallout-themed boot experience: GRUB (with the
`fallout-grub-theme` fetched from GitHub), green-phosphor console palette,
verbose `preDeviceCommands` boot banner, RobCo-styled MOTD, and (when
`jupiter.desktop.enable` is also true) the `ly` TTY display manager in place
of `greetd`.

**Enabled by:** `lenovo`, `nas`, `t460s`. Off elsewhere (`dashboards` keeps a
fast plain `systemd-boot` menu; `elitedesk` is a bootloader-less netboot node).

## Desktop

### `modules/desktop/default.nix`
```
jupiter.desktop.enable      (bool, default false)
jupiter.desktop.compositor  (enum ["niri" "gnome" "none"], default "niri")
```
See [03-software-inventory.md §4](03-software-inventory.md#4-desktop-class-currently-t460s) for the full package list per compositor choice.

**Enabled by:** `t460s` (`compositor = "niri"`).

## Storage

### `modules/storage/zfs-impermanent.nix`
```
jupiter.storage.zfs.enable  (bool, default false)
jupiter.storage.zfs.disk    (string, default "/dev/nvme0n1")
```
Declares a disko ZFS layout (`rpool`: `local/root`, `local/nix`,
`safe/persist`) and an initrd-stage systemd service that runs
`zfs rollback -r rpool/local/root@blank` before `sysroot.mount` on every
boot — the "erase your darlings" pattern. Pairs with
`jupiter.core.impermanence` to decide what survives the rollback.

**Enabled by:** `t460s` (`disk = "/dev/nvme0n1"`).

### `modules/zfs-nas.nix`
No option — unconditional. Sets `boot.supportedFilesystems = [ "zfs" ]`,
imports the hand-created `tank`/`europa` pools via `boot.zfs.extraPools`,
enables `services.zfs.autoScrub`/`trim`, and declares the three Samba shares
(`media`, `personal`, `archive`) plus `samba-wsdd`.

**Imported by:** `nas` only.

### `modules/storage/sanoid.nix`
No option — unconditional. Snapshot templates `important`
(hourly 36 / daily 30 / monthly 6 / yearly 1) applied recursively to
`tank/personal`, `tank/backups`, `tank/vm`; template `bulk`
(daily 7 / monthly 1) applied to `tank/media`. No `syncoid` replication
target is configured (`europa` is a frozen archive, not a backup pool).

**Imported by:** `nas` only.

### `modules/storage/zfs-tuning.nix`
No option — unconditional. Caps ZFS ARC at ~11GiB
(`zfs_arc_max=11811160064`), sets `vm.swappiness=10`, bumps TCP socket
buffers for 1GbE throughput, and tunes Samba (`sendfile`, async I/O,
`TCP_NODELAY`, min protocol SMB2, multichannel off since the link is a single
bonded interface).

**Imported by:** `nas` only.

### `modules/storage/nas-nfs.nix`
No option — unconditional. `services.nfs.server`, exporting `/tank/media`
(read-only, LAN + headscale mesh) and `/srv/netboot` (read-only, LAN).
Firewall: TCP 2049.

**Imported by:** `nas` only.

### `modules/storage/iscsi.nix`
```
jupiter.nas.iscsi.enable      (bool, default false)
jupiter.nas.iscsi.targetIqn   (string, default "iqn.2026-06.au.jupiter:nas.target0")
jupiter.nas.iscsi.luns        (list of { name, dev, initiatorIqn })
```
Generates an LIO `services.target` config: one block backstore per LUN (WWN
derived from a SHA-256 hash of the LUN name), one ACL per LUN mapping it to
the consuming host's initiator IQN. Firewall: TCP 3260.

**Enabled by:** `nas`, with two LUNs — `db` (`/dev/zvol/rpool/db`) and `loki`
(`/dev/zvol/rpool/loki`), both ACL'd to `iqn.2026-06.au.jupiter:elitedesk`.

## Network

### `modules/network/nas-bond.nix`
```
jupiter.nas.bond.enable      (bool, default false)
jupiter.nas.bond.interfaces  (list of string, default ["enp2s0f0" "enp2s0f1"])
jupiter.nas.bond.mtu         (int, default 1500)
```
802.3ad (LACP) bonding across the NAS's two 1GbE ports
(`xmit_hash_policy = "layer3+4"`, `lacp_rate = "fast"`). The matching
UniFi-switch-side LACP config must exist first, or the NAS loses network
connectivity when this is enabled.

**Set by:** `nas`, currently `enable = false` (not yet turned on).

### `modules/services/dns.nix`
```
jupiter.dns.enable           (bool, default false)
jupiter.dns.domain           (string, default "home.jupiter.au")
jupiter.dns.allowedNetworks  (list of string, default ["127.0.0.0/8" "::1/128"])
jupiter.dns.records          (attrset of fqdn -> ipv4)
```
Two cooperating services:

- **unbound** — authoritative for the internal split-horizon zone
  (`local-zone`/`local-data` built from `jupiter.dns.records`), DNSSEC
  validation, aggressive caching/prefetch, and a hard requirement that it is
  a *pure forwarder* to `dnscrypt-proxy` for everything else (no direct
  recursion to the public internet — see [05-networking.md](05-networking.md)).
- **dnscrypt-proxy** — listens on `127.0.0.1:5353`, anonymized DNSCrypt
  routing (`anonymized_dns.routes`, `via = ["*"]`), DNSSEC/no-log/no-filter
  required upstreams only.

Firewall: TCP+UDP 53.

**Enabled by:** `lenovo`, with `home.jupiter.au` and `allowedNetworks`
covering the default LAN, IoT VLAN, Cameras VLAN, and the headscale mesh
range — see [02-hosts.md](02-hosts.md#lenovo) for the exact CIDR list.

### `modules/headscale.nix`
No option — unconditional `services.headscale`. Port 8080, `magic_dns`
enabled, base domain `jupiter.mesh`, mesh clients told to use `10.1.1.20` for
DNS, `ip_prefixes` `100.64.0.0/10` + `fd7a:115c:a1e0::/48`. Firewall: TCP 8080.

**Imported by:** `lenovo` only — the single mesh control plane, exposed
publicly via the Cloudflare Tunnel (`headscale.jupiter.au`).

### `modules/cloudflared.nix`
No option — unconditional. One named tunnel
(`aa1088b8-a0e1-4073-8567-6a9bf5fb4bd7`), credentials from sops secret
`cloudflare_cert`, ingress rules for `headscale.jupiter.au`, `n8n.jupiter.au`,
`ha.jupiter.au` (all `http_status:404` default catch-all).

**Imported by:** `lenovo` only.

### `modules/pxe-server.nix`
```
jupiter.pxe.enable    (bool, default false)
jupiter.pxe.kernel     (string, path/URL to bzImage)
jupiter.pxe.initrd     (string, path/URL to initrd)
jupiter.pxe.cmdLine    (string, default "loglevel=4")
```
Wraps `services.pixiecore` in `"boot"` mode (acts as DHCP proxy + serves the
kernel/initrd itself — no separate webroot needed).

**Enabled by:** `lenovo`, via the `pxeModule` defined in `flake.nix`, which
sources `kernel`/`initrd`/`cmdLine` directly from
`self.nixosConfigurations.elitedesk.config.system.build` — see
[01-architecture.md §3](01-architecture.md#3-the-mkhost-pattern-flakenix).

## Services

### `modules/services/syncthing.nix`
```
jupiter.services.syncthing.enable  (bool, default false)
```
`services.syncthing` for user `io`, GUI bound to `0.0.0.0:8384` (reachable
over LAN/headscale), device/folder management left to the WebUI
(`overrideDevices`/`overrideFolders = false`). Also drops a `.stignore`
template into `/home/io` on first activation that excludes most dotfiles/caches
but explicitly re-includes `.claude` and `.gemini`. Firewall: TCP 8384/22000,
UDP 22000/21027.

**Enabled by:** `nas`, `t460s`.

### `modules/services/tcxwave-power-tuning.nix`
No option — unconditional. See the full breakdown in
[03-software-inventory.md §3](03-software-inventory.md#dashboards-tcx-wave-kiosks-4)
and [02-hosts.md](02-hosts.md#dashboards-jupiter-dashboard).

**Imported by:** `dashboards` only.

### `modules/home-assistant-vm.nix`
No option — unconditional. `virtualisation.libvirtd` with
`qemu_kvm`/`runAsRoot`/`swtpm`; ships `virt-manager`, `libvirt`, `qemu_kvm`
CLI tools. Network bridging is left to the host (`hosts/lenovo` declares
`br0` itself) to avoid NIC-name mismatches.

**Imported by:** `lenovo` only.

### `modules/n8n.nix`
No option — unconditional `services.n8n`. `allowUnfree` is turned on (n8n's
license is "sustainable use", which Nixpkgs treats as unfree). Listens on
`127.0.0.1:5678` behind the Cloudflare Tunnel; `WEBHOOK_URL =
"https://n8n.jupiter.au"`.

**Imported by:** `lenovo` only.

### `modules/backups.nix`
```
jupiter.backups.paths        (list of string, default [])
jupiter.backups.repository   (string, default "s3:s3.us-west-004.backblazeb2.com/jupiter-os-backups")
```
`services.restic.backups.daily-cloud-backup`: nightly at 02:00
(±1h randomized delay), excludes `**/tmp`/`**/cache`, password + S3
credentials from sops secrets `restic_password`/`restic_env`, retention
`--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.

**Used by:** `lenovo` (`/var/lib/n8n`, `/var/lib/libvirt/images`) and `nas`
(`/tank/personal`, `/tank/backups/homeassistant`).

## How to add a new module

Per `CLAUDE.md`: put new cross-host functionality in `modules/` behind a
`jupiter.*` option, then have hosts opt in via the toggle rather than
inlining the underlying config. Keep flake-level module wiring (new
flake inputs that need injecting into every host) going through the
`mkHost` lexical closure in `flake.nix` rather than `specialArgs`.
