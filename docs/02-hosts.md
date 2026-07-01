# Hosts

Each section below covers one `nixosConfigurations.<host>` entry: its role,
network identity, storage, boot path, and the modules it imports. For the
package/service inventory see [03-software-inventory.md](03-software-inventory.md).
For module option details see [04-modules-reference.md](04-modules-reference.md).

Hosts are named after Jupiter's moons.

---

## `ganymede`

**Role:** always-on bare-metal compute node — the fleet's "core services" box.

- **Config:** `hosts/ganymede/configuration.nix`
- **Base layer:** `modules/common-stateful.nix`
- **`networking.hostId`:** `1e110000`
- **Network identity:** static `10.1.1.20/24` on bridge `br0` (`enp1s0` member), gateway `10.1.1.1`, `networking.useDHCP = false`. Points its own resolver at itself (`127.0.0.1`), overriding the fleet default.
- **Boot:** GRUB (Fallout theme) — `jupiter.branding.enable = true` on this host.
- **Storage:** `jupiter.storage.profile = "stateful"` — single OS ZFS pool (`rpool`) with `root`, `nix`, and `var` datasets (`var` holds n8n state + libvirt VM images); persistent root, no rollback. ⚠️ `jupiter.storage.disk` is a placeholder (`REPLACE-ME-ganymede-os-disk`) — must be set to the real by-id path before install.
- **Modules imported:** `common-stateful`, `home-assistant-vm`, `n8n`, `cloudflared`, `headscale`, `backups`, `pxe-server`, `services/dns`.
- **Distinguishing responsibilities:**
  - Runs the fleet's only DNS resolver (`jupiter.dns`, domain `home.jupiter.au`), serving the LAN, IoT/Camera VLANs, and the headscale mesh.
  - Hosts the Home Assistant OS VM under libvirt/KVM.
  - Runs n8n (workflow automation, backed by PostgreSQL on `callisto` over the LAN) and exposes it, Home Assistant, and headscale to the internet via a single Cloudflare Tunnel.
  - Runs the PXE/Pixiecore netboot server that boots `callisto` — wired directly to `callisto`'s build output in `flake.nix` (see [01-architecture.md](01-architecture.md#3-the-mkhost-pattern-flakenix)).
  - restic backs up `/var/lib/n8n` and `/var/lib/libvirt/images` offsite.

---

## `europa`

**Role:** ZFS storage array; the fleet's backup and replication target (the "NAS").

- **Config:** `hosts/europa/configuration.nix`, `hosts/europa/disko.nix`
- **Base layer:** `modules/common-stateful.nix`
- **`networking.hostId`:** `deadbeef`
- **Network identity:** static `10.1.1.2/24` on `enp2s0f0`, gateway `10.1.1.1`, DHCP off. Optional 802.3ad LACP bonding across both 1GbE ports is wired in (`jupiter.nas.bond`) but currently **disabled** pending matching switch-side config.
- **Boot:** GRUB (Fallout theme).
- **Hardware notes** (from `modules/storage/zfs-tuning.nix` comments): HPE MicroServer Gen10, Opteron X3216 (2c/1.6GHz), 16GB ECC, dual BCM5720 1GbE, all-4Kn SATA disks. The serving ceiling is the 1GbE link and ARC size, not disk speed — tuning is built around that.
- **Storage:** see [06-storage-and-backups.md](06-storage-and-backups.md) for the full pool/dataset breakdown. Three pools:
  - `rpool` — OS SSD (Crucial MX500 500GB), disko-managed: `root`, `nix`, `var`, plus two zvols (`db`, `loki`) exported over iSCSI, and `netboot`/`scratch` filesystems.
  - `tank` — 18TB mirror, hand-created (not disko-managed), imported via `boot.zfs.extraPools`. New primary data pool.
  - `europa` — 10TB mirror, hand-created, frozen read-only legacy archive. (Coincidentally shares its name with the host — this pool predates the host-naming convention and is not renamed further.)
- **Modules imported:** `common-stateful`, `zfs-nas`, `storage/sanoid`, `storage/zfs-tuning`, `storage/nas-nfs`, `storage/iscsi`, `storage/smart-monitoring`, `network/nas-bond`, `backups`.
- **Distinguishing responsibilities:**
  - Samba (SMB) shares: `media`, `personal`, read-only `archive`; discoverable via `samba-wsdd`.
  - NFS exports: `/tank/media` (read-only), `/srv/netboot` (read-only).
  - iSCSI target (LIO) exporting the `db` and `loki` zvols to `callisto`'s initiator.
  - sanoid snapshot policy on `tank/personal`, `tank/backups`, `tank/vm` (frequent) and `tank/media` (light).
  - restic backs up `/tank/personal` and `/tank/backups/homeassistant` offsite.
  - smartd (`jupiter.storage.smartMonitoring`) SMART self-tests + health checks across every attached disk.
  - Runs Syncthing for user `io`.

---

## Dashboard kiosks: `metis`, `adrastea`, `amalthea`, `thebe`

**Role:** 4x Toshiba TCx Wave touchscreen kiosk terminals, one per room, each its own host.

Identical hardware running the same Cage/Chromium kiosk session, but each
points at a different room's Home Assistant dashboard and so can't share a
`hostName`/`hostId` — they were split out of a single shared host into four
independent ones for exactly that reason.

| Host | Room | `networking.hostId` | `jupiter.dashboardKiosk.url` |
|---|---|---|---|
| `metis` | kitchen | `5e0dc488` | `https://ha.jupiter.au/kitchen` |
| `adrastea` | office | `73c2a70f` | `https://ha.jupiter.au/office` |
| `amalthea` | jupiter-bedroom | `0515cf00` | `https://ha.jupiter.au/jupiter-bedroom` |
| `thebe` | robbie-room | `af54f5c3` | `https://ha.jupiter.au/robbie-room` |

- **Config:** `hosts/{metis,adrastea,amalthea,thebe}/configuration.nix`
- **Base layer:** `modules/common-stateful.nix`
- **Boot:** branding left off (`jupiter.branding` is opt-in and not enabled here) — uses the plain `systemd-boot` menu for fastest boot, since these are wall-mounted appliances nobody watches POST.
- **Hardware:** Intel Core i5-6300U (Skylake-U, 2c/4t, 15W TDP) + integrated HD Graphics 520 (Gen9), built-in 15" touchscreen panel.
- **Storage:** `jupiter.storage.profile = "impermanent"` — single OS ZFS pool, root rolled back to `@blank` every boot. Only the minimal system set plus the `kiosk` Chromium profile persists (`/persist`). ⚠️ `jupiter.storage.disk` is a placeholder (`REPLACE-ME-<host>-os-disk`) per unit.
- **Modules imported:** `common-stateful`, `services/tcxwave-power-tuning` (shared hardware tuning), `desktop/dashboard-kiosk` (shared Cage/Chromium session, parameterized by `jupiter.dashboardKiosk.url`), `desktop/dashboard-gaming` (optional, off by default).
- **Display/UI:** Wayland-only kiosk via `services.cage` running Chromium in `--kiosk` mode, loading that unit's `jupiter.dashboardKiosk.url`. `services.xserver` is explicitly disabled. VA-API hardware video decode is enabled for the HD 520 iGPU. A dedicated `kiosk` user (in `video`+`render` groups) runs the session.
- **Power/boot tuning** (`services/tcxwave-power-tuning.nix`): latest kernel for newest `i915`/`intel_pstate` support, i915 RC6/FBC/PSR/fastboot, no `mitigations=off` (renders arbitrary remote content), zero-timeout bootloader, systemd-stage-1 initrd with a trimmed module set, zram swap, TLP for runtime PM, thermald, and volatile (RAM-only) journald logging.

---

## `callisto` (HP EliteDesk 800 G4)

**Role:** diskless compute node, netboots from `ganymede`'s PXE server.

- **Config:** `hosts/callisto/configuration.nix`
- **Base layer:** `modules/common.nix` directly (no `common-stateful` — there's no local disk to give it a root filesystem/bootloader).
- **`networking.hostId`:** none (not needed — no local ZFS root).
- **Boot:** `(modulesPath + "/installer/netboot/netboot-minimal.nix")`, with `boot.kernelParams = [ "copytoram" ]` so the served image is fully copied into RAM at boot. Branding is left off (opt-in, and GRUB would conflict with the bootloader-less netboot profile anyway).
- **Network identity:** no static config in this repo beyond a static `/etc/hosts` entry for `europa.home.jupiter.au` → `10.1.1.2`, added so the boot-time iSCSI login doesn't race DNS coming up.
- **Storage:** none locally. Persists state to europa over iSCSI: logs into `europa.home.jupiter.au:3260` automatically (`services.openiscsi`, initiator IQN `iqn.2026-06.au.jupiter:callisto`) and attaches the `db` and `loki` LUNs europa exports for it (see [06-storage-and-backups.md](06-storage-and-backups.md)). Those LUNs are mounted by label at `/var/lib/postgresql` and `/var/lib/loki` (`_netdev,nofail`); **first-time setup** is to `mkfs.ext4 -L db` / `-L loki` the attached LUNs once.
- **Network identity:** static `10.1.1.21/24` (`jupiter` site record) so the cams' syslog target and iSCSI resolve to a stable address. ⚠️ the wired NIC name (`enp0s31f6`) is the expected HP EliteDesk 800 G4 onboard interface — verify on real hardware.
- **Modules imported:** `common`, `services/postgresql`, `services/loki`.
- **Distinguishing responsibilities:**
  - Its evaluated build output (`kernel`, `netbootRamdisk`, `toplevel`) is consumed directly by `flake.nix`'s `pxeModule`, which feeds `ganymede`'s `jupiter.pxe` — see [01-architecture.md](01-architecture.md#3-the-mkhost-pattern-flakenix).
  - Runs **PostgreSQL** (`jupiter.services.postgresql`, data on the `db` LUN), serving two LAN consumers on ganymede: the **Home Assistant** VM's recorder and **n8n** (each its own role/db, scram-sha-256). HA is a HAOS VM, so only its db/role is provisioned here — its `recorder: db_url:` is set inside Home Assistant. Also runs **Loki + a grafana-alloy syslog receiver** (`jupiter.services.loki`, data on the `loki` LUN); the Wyze camera fleet forwards syslog to `callisto.home.jupiter.au:514`, which the receiver ingests into Loki.
  - Because that state sits on raw iSCSI zvols (which restic can't walk), `jupiter.services.stateBackup` lands an hourly `pg_dumpall` + Loki `rsync` on `europa:/tank/backups/callisto` (NFS), where europa's sanoid + restic snapshot it and ship it offsite — so the DB + logs are fully covered (see [06-storage-and-backups.md §8](06-storage-and-backups.md#8-diskless-host-state-backup-callisto--europa)).

---

## `himalia` (Lenovo ThinkPad T460s)

**Role:** personal laptop workstation.

- **Config:** `hosts/himalia/configuration.nix` (no `disko.nix` file — see below)
- **Base layer:** `modules/common-stateful.nix`
- **`networking.hostId`:** `c0ffee00`
- **Boot:** GRUB (Fallout theme).
- **Storage:** `jupiter.storage.profile = "impermanent"` (`modules/storage/zfs-profiles.nix`), `disk = "/dev/nvme0n1"` — no per-host `disko.nix` file. Root (`rpool/local/root`) is rolled back to a blank snapshot on every boot (erase-your-darlings); `/nix` and `/persist` survive. `jupiter.core.impermanence` (persistPath `/persist`, `persistAdminHome` on) declares which directories/files in `/etc`, `/var`, and the `io` user's home survive the rollback.
- **Modules imported:** `common-stateful` (transitively: `core/impermanence`, `desktop`, `storage/zfs-profiles`, `services/syncthing`, `branding`).
- **Feature toggles set:**
  ```nix
  jupiter = {
    branding.enable = true;
    core.impermanence.enable = true;
    home.enable = true;
    desktop = { enable = true; compositor = "niri"; };
    storage = { profile = "impermanent"; disk = "/dev/nvme0n1"; };
    services.syncthing.enable = true;
  };
  ```
- **Roaming:** `jupiter.home.enable` gives `io` a declarative home-manager
  environment (dotfiles + shared niri config) identical to the other personal
  machines; Syncthing roams the data dirs via europa. See the future
  `elara`/`carme` workstations below.
- **Distinguishing responsibilities:** the only host running a graphical desktop (Niri, see [03-software-inventory.md](03-software-inventory.md#4-desktop-class-currently-himalia)); runs Syncthing for user `io`, with a curated `.stignore` that explicitly re-includes `.claude`/`.gemini` (AI assistant state) while excluding most other dotfiles.

---

## Future hosts (scaffolds)

`hosts/elara/` and `hosts/carme/` are roaming personal workstations
that don't exist yet. Each is `impermanent` storage + `jupiter.desktop` (niri) +
`jupiter.home.enable` + Syncthing — the same portable `io` identity as `himalia`,
so logging in at any of them feels like the home PC. `carme` lives at
the second site and reaches europa over the headscale mesh (offline-tolerant
Syncthing, not NFS). They are **not** registered in `flake.nix` yet: their
`REPLACE-ME` disks would fail the `jupiter.storage` assertion. Bring one online
by filling in its disk + `hostId`, uncommenting its `mkHost` line, adding it to
the CI matrices, and generating its age key.

---

## Non-NixOS device classes

These live under `hosts/parents-house/` as templates/firmware build inputs, not `nixosConfigurations`. Full detail in [08-edge-devices.md](08-edge-devices.md).

| Device class | Path | Mechanism |
|---|---|---|
| Linksys MX4300 access points | `hosts/parents-house/access-points/` | Custom OpenWrt image (`make build-mx4300`), Batman-adv mesh, first-boot `uci-defaults` script |
| Wyze cameras | `hosts/parents-house/wyze-cams/` | `wz_mini_hacks` config template, secrets injected via `sops exec-env` |
