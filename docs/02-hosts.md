# Hosts

Each section below covers one `nixosConfigurations.<host>` entry: its role,
network identity, storage, boot path, and the modules it imports. For the
package/service inventory see [03-software-inventory.md](03-software-inventory.md).
For module option details see [04-modules-reference.md](04-modules-reference.md).

---

## `lenovo`

**Role:** always-on bare-metal compute node — the fleet's "core services" box.

- **Config:** `hosts/lenovo/configuration.nix`, `hosts/lenovo/disko.nix`
- **Base layer:** `modules/common-stateful.nix`
- **`networking.hostId`:** `1e110000`
- **Network identity:** static `10.1.1.20/24` on bridge `br0` (`enp1s0` member), gateway `10.1.1.1`, `networking.useDHCP = false`. Points its own resolver at itself (`127.0.0.1`), overriding the fleet default.
- **Boot:** GRUB (Fallout theme) — `jupiter.branding.enable = true` on this host.
- **Storage:** single OS ZFS pool (`rpool`) on one disk — `root`, `nix`, and `var` datasets (`var` holds n8n state + libvirt VM images). ⚠️ `disko.nix`'s `device` is a placeholder (`REPLACE-ME-lenovo-os-disk`) — must be set to the real by-id path before install.
- **Modules imported:** `common-stateful`, `home-assistant-vm`, `n8n`, `cloudflared`, `headscale`, `backups`, `pxe-server`, `services/dns`.
- **Distinguishing responsibilities:**
  - Runs the fleet's only DNS resolver (`jupiter.dns`, domain `home.jupiter.au`), serving the LAN, IoT/Camera VLANs, and the headscale mesh.
  - Hosts the Home Assistant OS VM under libvirt/KVM.
  - Runs n8n (workflow automation) and exposes it, Home Assistant, and headscale to the internet via a single Cloudflare Tunnel.
  - Runs the PXE/Pixiecore netboot server that boots `elitedesk` — wired directly to `elitedesk`'s build output in `flake.nix` (see [01-architecture.md](01-architecture.md#3-the-mkhost-pattern-flakenix)).
  - restic backs up `/var/lib/n8n` and `/var/lib/libvirt/images` offsite.

---

## `nas`

**Role:** ZFS storage array; the fleet's backup and replication target.

- **Config:** `hosts/nas/configuration.nix`, `hosts/nas/disko.nix`
- **Base layer:** `modules/common-stateful.nix`
- **`networking.hostId`:** `deadbeef`
- **Network identity:** static `10.1.1.2/24` on `enp2s0f0`, gateway `10.1.1.1`, DHCP off. Optional 802.3ad LACP bonding across both 1GbE ports is wired in (`jupiter.nas.bond`) but currently **disabled** pending matching switch-side config.
- **Boot:** GRUB (Fallout theme).
- **Hardware notes** (from `modules/storage/zfs-tuning.nix` comments): HPE MicroServer Gen10, Opteron X3216 (2c/1.6GHz), 16GB ECC, dual BCM5720 1GbE, all-4Kn SATA disks. The serving ceiling is the 1GbE link and ARC size, not disk speed — tuning is built around that.
- **Storage:** see [06-storage-and-backups.md](06-storage-and-backups.md) for the full pool/dataset breakdown. Three pools:
  - `rpool` — OS SSD (Crucial MX500 500GB), disko-managed: `root`, `nix`, `var`, plus two zvols (`db`, `loki`) exported over iSCSI, and `netboot`/`scratch` filesystems.
  - `tank` — 18TB mirror, hand-created (not disko-managed), imported via `boot.zfs.extraPools`. New primary data pool.
  - `europa` — 10TB mirror, hand-created, frozen read-only legacy archive.
- **Modules imported:** `common-stateful`, `zfs-nas`, `storage/sanoid`, `storage/zfs-tuning`, `storage/nas-nfs`, `storage/iscsi`, `network/nas-bond`, `backups`.
- **Distinguishing responsibilities:**
  - Samba (SMB) shares: `media`, `personal`, read-only `archive`; discoverable via `samba-wsdd`.
  - NFS exports: `/tank/media` (read-only), `/srv/netboot` (read-only).
  - iSCSI target (LIO) exporting the `db` and `loki` zvols to `elitedesk`'s initiator.
  - sanoid snapshot policy on `tank/personal`, `tank/backups`, `tank/vm` (frequent) and `tank/media` (light).
  - restic backs up `/tank/personal` and `/tank/backups/homeassistant` offsite.
  - Runs Syncthing for user `io`.

---

## `dashboards` (`jupiter-dashboard`)

**Role:** 4x Toshiba TCx Wave touchscreen kiosk terminals, all sharing one NixOS image.

- **Config:** `hosts/dashboards/configuration.nix`, `hosts/dashboards/disko.nix`
- **Base layer:** `modules/common-stateful.nix`
- **`networking.hostId`:** `da58b0a4`
- **Boot:** branding left off (`jupiter.branding` is opt-in and not enabled here) — uses the plain `systemd-boot` menu for fastest boot, since these are wall-mounted appliances nobody watches POST.
- **Hardware:** Intel Core i5-6500U (Skylake-U, 2c/4t, 15W TDP) + integrated HD Graphics 520 (Gen9), built-in 15" touchscreen panel.
- **Storage:** single small OS ZFS pool (`root` + `nix` only — no bulk data). ⚠️ `disko.nix`'s `device` is a placeholder (`REPLACE-ME-dashboard-os-disk`).
- **Modules imported:** `common-stateful`, `services/tcxwave-power-tuning`.
- **Display/UI:** Wayland-only kiosk via `services.cage` running Chromium in `--kiosk` mode, loading the Home Assistant `jupiter-ops` dashboard (`https://ha.jupiter.au/jupiter-ops`). `services.xserver` is explicitly disabled. VA-API hardware video decode is enabled for the HD 520 iGPU. A dedicated `kiosk` user (in `video`+`render` groups) runs the session.
- **Power/boot tuning** (`services/tcxwave-power-tuning.nix`): latest kernel for newest `i915`/`intel_pstate` support, i915 RC6/FBC/PSR/fastboot, no `mitigations=off` (renders arbitrary remote content), zero-timeout bootloader, systemd-stage-1 initrd with a trimmed module set, zram swap, TLP for runtime PM, thermald, and volatile (RAM-only) journald logging.

---

## `elitedesk` (HP EliteDesk 800 G4)

**Role:** diskless compute node, netboots from `lenovo`'s PXE server.

- **Config:** `hosts/elitedesk/configuration.nix`
- **Base layer:** `modules/common.nix` directly (no `common-stateful` — there's no local disk to give it a root filesystem/bootloader).
- **`networking.hostId`:** none (not needed — no local ZFS root).
- **Boot:** `(modulesPath + "/installer/netboot/netboot-minimal.nix")`, with `boot.kernelParams = [ "copytoram" ]` so the served image is fully copied into RAM at boot. Branding is left off (opt-in, and GRUB would conflict with the bootloader-less netboot profile anyway).
- **Network identity:** no static config in this repo beyond a static `/etc/hosts` entry for `nas.home.jupiter.au` → `10.1.1.2`, added so the boot-time iSCSI login doesn't race DNS coming up.
- **Storage:** none locally. Persists state to the NAS over iSCSI: logs into `nas.home.jupiter.au:3260` automatically (`services.openiscsi`, initiator IQN `iqn.2026-06.au.jupiter:elitedesk`) and attaches the `db` and `loki` LUNs the NAS exports for it (see [06-storage-and-backups.md](06-storage-and-backups.md)). **Note:** the LUNs are provisioned and the initiator is wired up, but as of this repo's current state no `services.loki`/database NixOS module is declared on this host yet — the comments describing "DB + Loki persistence" describe the intended consumer, not an already-running service.
- **Modules imported:** `common`.
- **Distinguishing responsibilities:**
  - Its evaluated build output (`kernel`, `netbootRamdisk`, `toplevel`) is consumed directly by `flake.nix`'s `pxeModule`, which feeds `lenovo`'s `jupiter.pxe` — see [01-architecture.md](01-architecture.md#3-the-mkhost-pattern-flakenix).
  - The Wyze camera fleet forwards syslog to `elitedesk.home.jupiter.au:514` (see [08-edge-devices.md](08-edge-devices.md)), implying a log receiver is expected here too — also not yet declared as a NixOS service in this repo.

---

## `t460s` (Lenovo ThinkPad T460s)

**Role:** personal laptop workstation.

- **Config:** `hosts/t460s/configuration.nix` (no `disko.nix` file — see below)
- **Base layer:** `modules/common-stateful.nix`
- **`networking.hostId`:** `c0ffee00`
- **Boot:** GRUB (Fallout theme).
- **Storage:** **impermanent** ZFS root, disko layout supplied dynamically by `modules/storage/zfs-impermanent.nix` (gated by `jupiter.storage.zfs.enable`) rather than a per-host `disko.nix` file — disk is `/dev/nvme0n1`. Root (`rpool/local/root`) is rolled back to a blank snapshot on every boot (erase-your-darlings); `/nix` and `/persist` survive. `jupiter.core.impermanence` (persistPath `/persist`) declares which directories/files in `/etc`, `/var`, and the `io` user's home survive the rollback.
- **Modules imported:** `common-stateful` (transitively: `core/impermanence`, `desktop`, `storage/zfs-impermanent`, `services/syncthing`, `branding`).
- **Feature toggles set:**
  ```nix
  jupiter = {
    core.impermanence.enable = true;
    desktop = { enable = true; compositor = "niri"; };
    storage.zfs = { enable = true; disk = "/dev/nvme0n1"; };
    services.syncthing.enable = true;
  };
  ```
- **Distinguishing responsibilities:** the only host running a graphical desktop (Niri, see [03-software-inventory.md](03-software-inventory.md#desktop-class-t460s)); runs Syncthing for user `io`, with a curated `.stignore` that explicitly re-includes `.claude`/`.gemini` (AI assistant state) while excluding most other dotfiles.

---

## Non-NixOS device classes

These live under `hosts/parents-house/` as templates/firmware build inputs, not `nixosConfigurations`. Full detail in [08-edge-devices.md](08-edge-devices.md).

| Device class | Path | Mechanism |
|---|---|---|
| Linksys MX4300 access points | `hosts/parents-house/access-points/` | Custom OpenWrt image (`make build-mx4300`), Batman-adv mesh, first-boot `uci-defaults` script |
| Wyze cameras | `hosts/parents-house/wyze-cams/` | `wz_mini_hacks` config template, secrets injected via `sops exec-env` |
