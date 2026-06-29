# Jupiter OS

A declarative, ZFS-backed NixOS monorepo for the Jupiter infrastructure.

## Topology
- **Lenovo Compute Node**: Bare-metal NixOS host running the Home Assistant VM (HAOS) and `n8n`.
- **Jupiter NAS**: ZFS storage array. The central backup and replication target for the fleet.
- **T460s Laptop**: Personal workstation.
- **Toshiba Dashboards**: 4x Wayland Kiosk touchscreen nodes.
- **Elitedesk 800 G4**: Diskless compute node (netboots from PXE).

## Secrets
Secrets are managed with `sops-nix` and `Age`. The master key is derived from the primary admin SSH key (`id_ed25519`).
All secrets live encrypted in `secrets/secrets.yaml`.

## Deployment

Build and test configurations locally using the `Makefile`:
```bash
make build-all          # build every host closure + mx4300 firmware
make test-lenovo        # build & boot a host in a QEMU VM
make check              # nix flake check (evaluates all hosts + deploy checks)
make fmt                # format Nix sources (nixfmt-rfc-style)
```

Deploy remotely using `deploy-rs` (all five hosts are registered as nodes):
```bash
deploy .#lenovo
```

### Bootstrapping a new host
1. Generate the host's age key and add its public key to `.sops.yaml`, then
   re-encrypt: `sops updatekeys secrets/secrets.yaml`.
2. Add the host to `hosts/`, then to `nixosConfigurations` and `deploy.nodes`
   in `flake.nix`.
3. Partition + install with disko (for hosts with local disks), e.g. via
   `nixos-anywhere --flake .#<host> root@<ip>`. `elitedesk` is diskless and
   netboots from the PXE server on `lenovo`.

### Gaming profile (Bazzite-on-Nix)

`modules/gaming/bazzite.nix` brings a modern Bazzite-style gaming experience to
any host, built on [Jovian-NixOS](https://github.com/Jovian-Experiments/Jovian-NixOS)
(the SteamOS gamescope "gaming mode") and [chaotic-nyx](https://github.com/chaotic-cx/nyx)
(CachyOS kernel, `mesa-git`, sched-ext/`scx`, `gamescope_git`). Both inputs are
injected into every host in `flake.nix`, so the options resolve everywhere and
nothing activates until a host opts in.

Attach it to a machine by toggling it in that host's `configuration.nix`:
```nix
jupiter.gaming.bazzite = {
  enable = true;
  gpu = "amd";            # "amd" | "intel" | "nvidia"
  user = "io";            # owns Steam, autologs into gaming mode
  gamingMode.enable = true; # boot-to-Steam console/handheld session (optional)
  # decky.enable = true;    # Decky Loader
  # steamdeck.enable = true; # Steam Deck / handheld hardware quirks
};
```
With `gamingMode.enable = false` you still get the full gaming software stack
(Steam, Proton-GE, gamescope, MangoHud, Lutris, Heroic, OBS VkCapture, …) on a
normal desktop; with it `true` the host boots into the SteamOS-like session.

> The chaotic module adds the `cache.chaotic.cx` substituter to every host (its
> recommended setup) so CachyOS kernel/Mesa builds are fetched, not rebuilt.

#### Dual-session dashboards (kiosk + gaming on separate VTs)

`modules/desktop/dashboard-gaming.nix` (`jupiter.dashboardGaming`, off by
default, wired into `hosts/dashboards`) turns a dashboard unit into a
dual-session box: the Cage/Chromium kiosk on VT 6 and a gamescope/Steam
session on VT 7, both live at once. systemd-logind hands DRM master between
them on VT switch, so flipping is just:
```bash
ssh root@<unit> jupiter-mode gaming      # or: dashboard | toggle
```
(Ctrl+Alt+F6 / Ctrl+Alt+F7 also work with a keyboard attached.) It reuses the
host's `services.cage` kiosk command and pulls in the Bazzite stack with stock
kernel/Mesa and `gpu = "intel"`. All four dashboards share one config/hostId,
so split a unit into its own host before enabling it on just one.

### Network / DNS (Terraform via terranix)
The UniFi and Cloudflare configs are authored in Nix under `terraform/` and
applied through the Makefile (secrets injected from `secrets.yaml` as `TF_VAR_*`):
```bash
make tf-plan-unifi      # review changes
make tf-apply-unifi
make tf-plan-cloudflare
make tf-apply-cloudflare
```
> Note: `tf-apply-cloudflare` needs a `cloudflare_api_token` entry in
> `secrets/secrets.yaml` (add it with `sops secrets/secrets.yaml`).

### Edge firmware (Linksys MX4300 APs)
```bash
make build-mx4300       # renders secret templates via sops, builds OpenWrt image
```

## CI
`.github/workflows/ci.yml` runs formatting + `nix flake check` and builds every
host closure on each push/PR.
