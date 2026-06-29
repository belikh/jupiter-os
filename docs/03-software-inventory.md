# Software Inventory

This page lists every package and service configured on each machine, and on
each *class* of machine, as declared in this repo. "Software" here means
anything reaching a host through a NixOS module (`services.*`,
`environment.systemPackages`, `programs.*`) or, for the non-NixOS edge
devices, the firmware/config templates that ship to them.

Sources are cited as `module/host:line-ish` so this page can be diffed
against the actual `.nix` files when something changes.

## 1. Fleet-wide baseline (every NixOS host)

Applied by `modules/common.nix`, which every host imports — either directly
(`elitedesk`) or via `modules/common-stateful.nix` (`lenovo`, `nas`,
`dashboards`, `t460s`):

| Software | Source | Notes |
|---|---|---|
| OpenSSH server | `services.openssh.enable` | |
| sops-nix | `sops.age.sshKeyPaths`, `sops.defaultSopsFile` | Decrypts using the host's own SSH ed25519 host key; secrets default to `secrets/secrets.yaml` |
| Nix (flakes + nix-command) | `nix.settings.experimental-features` | |
| Automatic Nix GC | `nix.gc` | Weekly, `--delete-older-than 14d` |
| Base admin CLI | `environment.systemPackages` | `git`, `htop`, `ripgrep`, `fd`, `jq`, `fzf`, `bat`, `eza`, `wget`, `curl`, `unzip` — on every host, headless or not |
| User `io` | `users.users.io` | groups: `wheel`, `networkmanager`; password from sops secret `io_password`; SSH key auth |

Also wired in transitively but **disabled by default**, opted into per-host
via `jupiter.*` toggles (see [04-modules-reference.md](04-modules-reference.md)):
`jupiter.branding`, `jupiter.core.impermanence`, `jupiter.desktop`,
`jupiter.storage` (profile), `jupiter.services.syncthing`. Branding is enabled
on `lenovo`, `nas`, and `t460s`.

## 2. Hosts with local disks (`common-stateful.nix`)

In addition to the baseline above, `lenovo`, `nas`, `dashboards`, and `t460s`
get:

| Software | Source |
|---|---|
| `systemd-boot` (EFI), overridden to GRUB on hosts that enable `jupiter.branding` | `modules/common-stateful.nix` / `modules/core/branding.nix` |

## 3. Per-host inventory

### `lenovo`

| Software | Source | Purpose |
|---|---|---|
| libvirtd + QEMU/KVM (+ swtpm) | `modules/services/home-assistant-vm.nix` | Runs Home Assistant OS as a VM |
| `virt-manager`, `libvirt`, `qemu_kvm` (CLI tools) | `modules/services/home-assistant-vm.nix` | VM management |
| n8n | `modules/services/n8n.nix` | Workflow automation, `https://n8n.jupiter.au`, listens on `127.0.0.1:5678` |
| cloudflared | `modules/network/cloudflared.nix` | One tunnel exposing `headscale.jupiter.au`, `n8n.jupiter.au`, `ha.jupiter.au` |
| headscale | `modules/network/headscale.nix` | Tailscale-compatible mesh control plane, port 8080, `https://headscale.jupiter.au` |
| Pixiecore | `modules/network/pxe-server.nix` (`jupiter.pxe`) | Serves `elitedesk`'s netboot image |
| unbound | `modules/network/dns.nix` (`jupiter.dns`) | Authoritative resolver for `home.jupiter.au`, LAN-wide DNS |
| dnscrypt-proxy | `modules/network/dns.nix` | Anonymized/encrypted upstream DNS for unbound |

### `nas`

| Software | Source | Purpose |
|---|---|---|
| ZFS (`zfs` CLI) | `hosts/nas/configuration.nix` (`environment.systemPackages`) + `modules/storage/zfs-nas.nix` | Pool/dataset management |
| Samba (`samba` CLI + `services.samba`) | `hosts/nas/configuration.nix`, `modules/storage/zfs-nas.nix` | SMB shares: `media`, `personal`, `archive` (read-only) |
| `samba-wsdd` | `modules/storage/zfs-nas.nix` | Windows network discovery |
| sanoid (+ `syncoid`) | `hosts/nas/configuration.nix`, `modules/storage/sanoid.nix` | ZFS snapshot policy on `tank` |
| NFS server | `modules/storage/nas-nfs.nix` | Exports `/tank/media` (ro), `/srv/netboot` (ro) |
| LIO iSCSI target (`services.target`) | `modules/storage/iscsi.nix` (`jupiter.nas.iscsi`) | Exports `db`/`loki` zvols to `elitedesk` |
| restic | `modules/services/backups.nix` | Offsite backup of `/tank/personal`, `/tank/backups/homeassistant`, `/tank/backups/lenovo` — the fleet's only offsite egress |
| syncoid | `modules/storage/replication.nix` (`jupiter.replication`) | Hourly pull of `lenovo:rpool/var` → `tank/backups/lenovo` |
| Syncthing | `modules/services/syncthing.nix` (`jupiter.services.syncthing.enable = true`) | File sync for user `io` |
| LACP bonding driver config | `modules/network/nas-bond.nix` (`jupiter.nas.bond`, currently disabled) | 802.3ad across both 1GbE ports, not yet enabled |

### `dashboards` (TCx Wave kiosks ×4)

| Software | Source | Purpose |
|---|---|---|
| Cage (Wayland kiosk compositor) | `hosts/dashboards/configuration.nix` (`services.cage`) | Wraps a single fullscreen app |
| Chromium | `hosts/dashboards/configuration.nix` | `--kiosk --incognito` loading `https://ha.jupiter.au/jupiter-ops`; VA-API decode flags, background-networking/sync/update/extensions all disabled |
| `intel-media-driver` (iHD VA-API), `libvdpau-va-gl` | `modules/services/tcxwave-power-tuning.nix` | Hardware video decode for the HD 520 (Gen9) iGPU |
| TLP | `modules/services/tcxwave-power-tuning.nix` | Runtime power management (CPU governor, SATA/PCIe link power, USB autosuspend, WoL off) |
| thermald | `modules/services/tcxwave-power-tuning.nix` | Thermal management |
| `powertop` | `modules/services/tcxwave-power-tuning.nix` | Diagnostics only (TLP already covers the equivalent of `powertop --auto-tune`) |
| zram swap (lz4) | `modules/services/tcxwave-power-tuning.nix` | Swap without disk wakeups |
| `linuxPackages_latest` | `modules/services/tcxwave-power-tuning.nix` | Newest `i915`/`intel_pstate` support |

User `kiosk` (groups `video`, `render`) runs the Cage/Chromium session. No
`services.xserver` (Wayland-only). `services.xserver.enable` is explicitly
disabled.

### `elitedesk`

| Software | Source | Purpose |
|---|---|---|
| NixOS netboot-minimal profile | `(modulesPath + "/installer/netboot/netboot-minimal.nix")` | Diskless boot image, copied fully to RAM (`copytoram`) |
| `open-iscsi` initiator | `hosts/elitedesk/configuration.nix` | Auto-login to the NAS's iSCSI target at boot |

No GUI, no branding, no local storage. Intended to also run a database and
Loki (per comments in `hosts/nas/configuration.nix`/`disko.nix` and the Wyze
cam syslog target in `hosts/parents-house/wyze-cams/wz_mini.conf.tmpl`), but
those service modules are not yet present in this repo — see
[02-hosts.md](02-hosts.md#elitedesk-hp-elitedesk-800-g4) for the caveat.

### `t460s`

Everything in the [Desktop class](#4-desktop-class-currently-t460s) below,
plus:

| Software | Source | Purpose |
|---|---|---|
| Syncthing | `modules/services/syncthing.nix` | File sync for user `io`, GUI on `:8384` |
| ZFS impermanence rollback service | `modules/storage/zfs-profiles.nix` (`profile = "impermanent"`) | Rolls `rpool/local/root` back to `@blank` every boot |

## 4. Desktop class (currently `t460s`)

Enabled via `jupiter.desktop.enable = true` (`modules/desktop/default.nix`).
Applies to any host that opts in, regardless of which compositor it picks.

**Always installed when the desktop profile is enabled** (the base admin CLI —
`git`, `ripgrep`, `jq`, … — comes from the fleet-wide baseline in
[§1](#1-fleet-wide-baseline-every-nixos-host), not from here):

| Category | Packages |
|---|---|
| AI coding prereqs | `nodejs` (for installing `@anthropic-ai/claude-code`, `@google/antigravity` globally) |
| GUI essentials | `google-chrome`, `vscode`, `pavucontrol`, `mpv` |
| Fonts | `inter`, `jetbrains-mono`, `material-symbols`, `share-tech-mono` (custom package, `packages/share-tech-mono`) |

**Compositor: `niri`** (`programs.niri.enable`) — `t460s`'s choice — additionally installs:

| Category | Packages |
|---|---|
| Niri shell stack | `ags`, `dart-sass`, `awww`, `matugen` (Dank Linux / DankMaterialShell-style Material You theming, replacing waybar/fuzzel/mako) |
| Terminal/clipboard/utils | `kitty`, `wl-clipboard`, `xdg-utils`, `brightnessctl` |

**Compositor: `gnome`** — alternative, not currently used by any host — enables `services.xserver`, GDM, and `services.desktopManager.gnome` instead of the package list above.

**Compositor: `none`** — desktop profile packages/fonts only, no compositor enabled.

`jupiter.branding`'s `services.displayManager.ly` (TTY-matrix-themed login) is enabled automatically whenever `jupiter.desktop.enable` is true and branding is on.

## 5. Development / CI tooling (not deployed to any host)

`shell.nix` (`nix develop`) provides the repo's own dev shell:

| Tool | Purpose |
|---|---|
| `terraform` | Apply terranix-rendered HCL |
| `sops` | Edit/decrypt `secrets/secrets.yaml` |
| `age` | Generate/manage host age keys |
| `deploy-rs` | Remote deploy to fleet hosts |

CI (`.github/workflows/ci.yml`) additionally uses `nixfmt-rfc-style` (also the
flake's `formatter`) and `DeterminateSystems/nix-installer-action` +
`magic-nix-cache-action`.

## 6. Edge devices (non-NixOS)

See [08-edge-devices.md](08-edge-devices.md) for full detail.

### Linksys MX4300 access points

Built by `packages/openwrt-builder` (`nix-openwrt-imagebuilder`, target
`qualcommax/ipq807x`, profile `linksys_mx4300`):

| Package | Purpose |
|---|---|
| `nano` | On-device editing |
| `tcpdump` | Mesh/roaming debugging |
| `iperf3` | Mesh throughput testing |
| `wpad-mesh-openssl` | 802.11s mesh + WPA |
| `batctl-default`, `kmod-batman-adv` | Batman-adv mesh networking |
| `kmod-8021q` | VLAN tagging (Cameras/IOT) |
| `sqm-scripts` | Smart queue management / QoS |

Configured at first boot by `99-mesh-setup.sh` (rendered from the `.tmpl` in
this repo): Batman-adv mesh (`BATMAN_IV`) on the 5GHz-high radio, VLAN
bridges for Cameras (VLAN 2) and IOT (VLAN 3), client APs on 2.4GHz/5GHz-low,
remote syslog to `elitedesk.home.jupiter.au`.

### Wyze cameras

Run third-party `wz_mini_hacks` firmware; this repo only supplies a rendered
config (`wz_mini.conf`, from `wz_mini.conf.tmpl`):

| Feature | Setting |
|---|---|
| RTSP server | enabled, port 8554, credentials from sops |
| Dropbear SSH | enabled, password from sops |
| Syslog | forwarded to `elitedesk.home.jupiter.au:514` |
