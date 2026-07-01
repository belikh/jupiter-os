# Jupiter OS

A declarative, ZFS-backed NixOS monorepo for the Jupiter infrastructure.

> **Full documentation:** see [`docs/`](docs/README.md) for architecture,
> a per-host reference, the complete software inventory for every machine,
> networking/storage/secrets details, and operational runbooks. This README
> stays focused on the quick-start commands.

## Topology
Hosts are named after Jupiter's moons.
- **`ganymede`** (Lenovo compute node): Bare-metal NixOS host running the Home Assistant VM (HAOS) and `n8n`.
- **`europa`** (NAS): ZFS storage array. The central backup and replication target for the fleet.
- **`himalia`** (laptop): Personal workstation.
- **`metis` / `adrastea` / `amalthea` / `thebe`** (Toshiba TCx Wave dashboards): 4x Wayland kiosk touchscreen nodes, one per room (kitchen/office/jupiter-bedroom/robbie-room), each its own host pointing `jupiter.dashboardKiosk.url` at that room's dashboard.
- **`callisto`** (Elitedesk 800 G4): Diskless compute node (netboots from PXE).

## Secrets
Secrets are managed with `sops-nix` and `Age`. The master key is derived from the primary admin SSH key (`id_ed25519`).
All secrets live encrypted in `secrets/secrets.yaml`.

## Deployment

Build and test configurations locally using the `Makefile`:
```bash
make build-all          # build every host closure + mx4300 firmware
make test-ganymede      # build & boot a host in a QEMU VM
make check              # nix flake check (evaluates all hosts + deploy checks)
make fmt                # format Nix sources (nixfmt-rfc-style)
```

Deploy remotely using `deploy-rs` (all eight hosts are registered as nodes):
```bash
deploy .#ganymede
```

### Bootstrapping a new host
1. Generate the host's age key and add its public key to `.sops.yaml`, then
   re-encrypt: `sops updatekeys secrets/secrets.yaml`.
2. Add the host to `hosts/`, then to `nixosConfigurations` and `deploy.nodes`
   in `flake.nix`.
3. Partition + install with disko (for hosts with local disks), e.g. via
   `nixos-anywhere --flake .#<host> root@<ip>`. `callisto` is diskless and
   netboots from the PXE server on `ganymede`.

### Gaming profile (Bazzite-on-Nix)

`modules/gaming/console.nix` brings a modern Bazzite-style gaming experience to
any host, built on [Jovian-NixOS](https://github.com/Jovian-Experiments/Jovian-NixOS)
(the SteamOS gamescope "gaming mode") and [chaotic-nyx](https://github.com/chaotic-cx/nyx)
(CachyOS kernel, `mesa-git`, sched-ext/`scx`, `gamescope_git`). Both inputs are
injected into every host in `flake.nix`, so the options resolve everywhere and
nothing activates until a host opts in.

Attach it to a machine by toggling it in that host's `configuration.nix`:
```nix
jupiter.gaming.console = {
  enable = true;
  gpu = "amd";            # "amd" | "intel" | "nvidia"
  user = "io";            # owns Steam, autologs into gaming mode
  gamingMode.enable = true; # boot-to-Steam console/handheld session (optional)
  # decky.enable = true;    # Decky Loader
  # steamdeck.enable = true; # Steam Deck / handheld hardware quirks
  apps.minecraft = false;   # drop any individual app from the stack (all on by default)
  peripherals = {
    # controllers = true;       # Xbox pads via xpadneo/xone (on by default)
    racingWheels = true;        # Logitech FFB wheels (new-lg4ff), Oversteer, Solaar
    # openrgb = true;           # RGB peripheral / LED control
    # drawingTablet = true;     # OpenTabletDriver
  };
};
```
With `gamingMode.enable = false` you still get the full gaming software stack
(Steam, Proton-GE, gamescope, MangoHud, Lutris, Heroic, OBS VkCapture, …) on a
normal desktop; with it `true` the host boots into the SteamOS-like session.

Two ideas are borrowed from [GLF-OS](https://glfos.org) (the French gaming
NixOS distro):

- **À-la-carte app toggles** — the optional software stack is a data-driven
  catalogue (`appCatalog` in the module), surfaced as `apps.<name>` options
  that all default on. Enabling the profile gives you everything; set any to
  `false` (e.g. `apps.minecraft = false`) to slim it down. Steam, gamescope,
  gamemode and Proton-GE are the always-on core.
- **First-boot peripherals** (`peripherals`) — Xbox controllers (xpadneo/xone)
  plus a DualSense touchpad fix are on by default; force-feedback Logitech
  wheels (`new-lg4ff`) with Oversteer/Solaar, drawing tablets (OpenTabletDriver)
  and RGB control (OpenRGB) are one toggle away. (Fanatec's kernel driver is
  out-of-tree and not vendored here, unlike GLF-OS.)

> The chaotic module adds the `cache.chaotic.cx` substituter to every host (its
> recommended setup) so CachyOS kernel/Mesa builds are fetched, not rebuilt.

#### Dual-session dashboards (kiosk + gaming on separate VTs)

`modules/desktop/dashboard-gaming.nix` (`jupiter.dashboardGaming`, off by
default, wired into each of `hosts/{metis,adrastea,amalthea,thebe}`) turns a
dashboard unit into a dual-session box: the Cage/Chromium kiosk on VT 6 and a
gamescope/Steam session on VT 7, both live at once. systemd-logind hands DRM
master between them on VT switch, so flipping is just:
```bash
ssh root@<unit> jupiter-mode gaming      # or: dashboard | toggle
```
(Ctrl+Alt+F6 / Ctrl+Alt+F7 also work with a keyboard attached.) It reuses the
host's `services.cage` kiosk command (set per-host via
`jupiter.dashboardKiosk.url` in `modules/desktop/dashboard-kiosk.nix`) and
pulls in the Bazzite stack with stock kernel/Mesa and `gpu = "intel"`. The 4
dashboard kiosks are already separate hosts (`metis`/`adrastea`/`amalthea`/
`thebe`, one per room), so enable this on just the unit(s) you want.

**Home Assistant control:** with `jupiter.dashboardGaming.homeAssistant.enable`,
each unit runs an MQTT agent that emits HA discovery — HA auto-creates a
*Display Mode* `select` (Dashboard/Gaming) — accepts commands, and publishes the
live active VT (so manual Ctrl+Alt+F switches show up too). The broker is
Mosquitto on ganymede (`modules/services/mqtt.nix`, `jupiter.services.mqtt`,
`10.1.1.20:1883`), running **authenticated** — defining `users` disables
anonymous access automatically. The `homeassistant` and `dashboard` users share
plaintext passwords stored as sops secrets, so add them before deploying:
```bash
sops secrets/secrets.yaml      # add: mqtt_homeassistant, mqtt_dashboard
```
Then set the same `mqtt_homeassistant` password in Home Assistant's MQTT
integration (the HAOS VM connects to `10.1.1.20`). Plaintext over `1883` is fine
on the trusted LAN/headscale mesh; add a TLS listener if you want transport
encryption too.

> Because the broker on ganymede is authenticated and always-on, the
> `mqtt_homeassistant`/`mqtt_dashboard` secrets must exist in `secrets.yaml`
> before the next `deploy .#ganymede` (sops reads them at activation).

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
