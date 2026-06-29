# Architecture

## 1. What this repository is

Jupiter OS is a single Nix flake that declaratively describes an entire home
lab: five NixOS hosts, one OpenWrt firmware image, two Terraform (terranix)
stacks, and the secrets that glue them together. There is no host-specific
state outside this repo and `secrets/secrets.yaml` — rebuilding a machine
from the flake is the supported way to change it.

```
flake.nix              entry point: hosts, packages, deploy targets, dev shell
hosts/<name>/           per-host configuration.nix (+ disko.nix where relevant)
modules/                 reusable NixOS modules behind a jupiter.* namespace
terraform/<stack>/      terranix (Nix-authored HCL) for unifi + cloudflare
secrets/secrets.yaml    sops-nix + age encrypted secrets
packages/               custom derivations (OpenWrt firmware, fonts)
```

See [02-hosts.md](02-hosts.md) for the fleet, [03-software-inventory.md](03-software-inventory.md)
for what's installed where, and [04-modules-reference.md](04-modules-reference.md) for the
`jupiter.*` option surface referenced throughout this page.

## 2. Fleet topology

| Host | Role | Disk | Notes |
|---|---|---|---|
| `lenovo` | Bare-metal compute node: Home Assistant (VM), n8n, network DNS resolver, Cloudflare tunnel ingress, headscale, PXE server | Local (ZFS) | Always-on "core services" box |
| `nas` | ZFS storage array (`tank` + `europa` pools) | Local (ZFS) | Backup/replication target for the fleet, iSCSI/NFS/SMB server |
| `dashboards` (`jupiter-dashboard`) | 4x Toshiba TCx Wave touchscreen kiosks running a Home Assistant dashboard | Local (ZFS) | One NixOS image shared by all four physical units |
| `elitedesk` | Diskless compute node, netboots from `lenovo`'s PXE server | None (RAM only) | Persists state to the NAS over iSCSI |
| `t460s` | Personal laptop workstation | Local (ZFS, impermanent) | Niri desktop, erase-your-darlings on every boot |

Two additional non-NixOS device classes are managed from this repo as
config/firmware templates rather than `nixosConfigurations`:

- **Linksys MX4300 access points** (`hosts/parents-house/access-points`) — custom OpenWrt firmware built via `nix-openwrt-imagebuilder`.
- **Wyze cameras** (`hosts/parents-house/wyze-cams`) — `wz_mini_hacks` config templates.

See [08-edge-devices.md](08-edge-devices.md).

## 3. The `mkHost` pattern (`flake.nix`)

Every `nixosConfigurations.<host>` is built by a local `mkHost` helper:

```nix
mkHost = hostPath: extraModules: nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    ({ ... }: { imports = [ sops-nix.nixosModules.sops impermanence.nixosModules.impermanence disko.nixosModules.disko ]; })
    hostPath
  ] ++ extraModules;
};
```

This injects the three flake-provided modules (sops-nix, impermanence, disko)
into every host **via a lexical closure** rather than `specialArgs`. The
project convention (see `CLAUDE.md`) is to keep using this closure-injection
style for any new flake-level module wiring, rather than reaching for
`specialArgs`.

`extraModules` exists so a host can pull in build products computed from
*another* host's evaluated config. The one user of this today is the PXE
server: `lenovo` is built with an extra `pxeModule` that reads
`self.nixosConfigurations.elitedesk.config.system.build` and feeds the
resulting kernel/initrd/cmdline straight into `jupiter.pxe` — so the image
Pixiecore serves can never drift from the `elitedesk` flake output. See
[02-hosts.md](02-hosts.md#elitedesk) and
[04-modules-reference.md](04-modules-reference.md#jupiterpxe-modulespxe-servernix).

## 4. The `jupiter.*` module namespace

Cross-host functionality is written once under `modules/` and exposed as a
feature toggle in the `jupiter.*` option namespace (per `CLAUDE.md`). Hosts
opt in by setting the option in their `configuration.nix` rather than
inlining the underlying NixOS config. For example, `t460s` turns on a desktop
environment with:

```nix
jupiter.desktop = {
  enable = true;
  compositor = "niri";
};
```

instead of setting `programs.niri.enable` directly. This keeps host files
short and declarative, and keeps the "what does this toggle actually do"
question answerable in one place (the module). The full option surface is
catalogued in [04-modules-reference.md](04-modules-reference.md).

## 5. Two base layers: `common.nix` vs `common-stateful.nix`

Every host config imports one of two foundation modules:

- **`modules/common.nix`** — the true baseline. Pulls in (but does not
  enable) branding, impermanence, the desktop profile, the impermanent-ZFS-root
  layer, and Syncthing — each opt-in per host via its `jupiter.*` toggle; sets
  timezone, Nix flakes/GC, `allowUnfree`, a base admin CLI toolset
  (`git`/`ripgrep`/`jq`/…) installed on every host, the default DNS resolver
  (`10.1.1.20`), OpenSSH, `sops.defaultSopsFile`, the `io` admin user
  (sops-encrypted password, SSH key auth), and a `virtualisation.vmVariant` so
  `make test-<host>` works. Imported directly by `elitedesk` (diskless — no
  local root filesystem to declare).
- **`modules/common-stateful.nix`** — `common.nix` plus a bootloader
  (`systemd-boot`) and a fallback `fileSystems."/"`. Imported by every host
  that owns local disks: `lenovo`, `nas`, `dashboards`, `t460s`. Each of
  those hosts then layers its own `disko.nix` over the fallback filesystem.

`elitedesk` is the only host that skips `common-stateful.nix`, because it has
no disk to partition — it boots the NixOS *netboot-minimal* installer profile
into RAM instead (`boot.kernelParams = [ "copytoram" ]`).

## 6. Bootloader/branding interaction

`jupiter.branding` (RobCo/Fallout-themed GRUB, green console, MOTD) is opt-in:
it defaults off and each host that wants it sets `jupiter.branding.enable =
true`. `lenovo`, `nas`, and `t460s` enable it and boot through GRUB with the
Fallout theme. The two hosts that don't want it simply leave it off:

- `dashboards` — boot speed matters on a wall-mounted kiosk nobody watches POST on; uses the plain `systemd-boot` menu set by `common-stateful.nix`.
- `elitedesk` — headless netboot image; GRUB would conflict with the bootloader-less netboot profile anyway.

Keeping branding opt-in (rather than on-by-default and force-disabled) means
no host has to `mkForce` it back off.

## 7. Network-wide design choices

- **Single internal resolver.** `lenovo` runs `jupiter.dns` (unbound, authoritative for the internal `home.jupiter.au` split-horizon zone, forwarding everything else to a local `dnscrypt-proxy`). Every other host's default nameserver is `10.1.1.20` (set in `common.nix`); `lenovo` itself points at `127.0.0.1`. See [05-networking.md](05-networking.md).
- **Mesh access via headscale**, exposed publicly only through a Cloudflare Tunnel on `lenovo` (`headscale.jupiter.au`).
- **Diskless compute offloaded to the NAS.** `elitedesk` has no disk; the NAS exports two zvols over iSCSI for its stateful services.
- **Backups are restic→S3 (Backblaze B2)** for the irreplaceable subset of data only; bulk/reproducible data relies on local ZFS redundancy (mirrors) instead.

## 8. CI and formatting

`.github/workflows/ci.yml` runs on every push/PR to `master`:

1. **`check`** — `nixfmt-rfc-style --check .`, then `nix flake check --no-build` (evaluates every host plus deploy-rs checks).
2. **`build`** — a matrix job that builds `system.build.toplevel` for each of `lenovo`, `t460s`, `nas`, `dashboards`, `elitedesk`. sops secrets are read at activation time, not build time, so CI needs no decryption key.
3. **`boot-test`** — a matrix job that boots each *disk* host (`lenovo`, `t460s`, `nas`, `dashboards`) in a headless QEMU VM (KVM) via `scripts/boot-smoke.sh` and asserts it reaches multi-user, catching bootloader/disko/impermanence/unit-ordering regressions a pure build can't. `elitedesk` is a diskless netboot image, so it's covered by `build` only.

See [09-operations.md](09-operations.md) for the full command reference.
