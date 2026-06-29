# Edge Devices

`hosts/parents-house/` holds templates and build inputs for two device
classes at a remote site (the user's parents' house). Neither is a
`nixosConfigurations` entry — they're not NixOS hosts, so they're built/
rendered differently from the main fleet.

## 1. Linksys MX4300 access points

**Path:** `hosts/parents-house/access-points/`
**Firmware:** custom OpenWrt, built by `packages/openwrt-builder/default.nix`
using the `nix-openwrt-imagebuilder` flake input.

### Build configuration (`flake.nix` → `packages.mx4300-firmware`)

```nix
nix-openwrt-imagebuilder.lib.build {
  target = "qualcommax/ipq807x";   # ipq807x moved under qualcommax in OpenWrt 23.x+
  profile = "linksys_mx4300";
  packages = [ "nano" "tcpdump" "iperf3" ] ++ extraPackages;
  files = ../../hosts/parents-house/access-points/mx4300-files;
};
```

`extraPackages` (declared in `flake.nix`): `wpad-mesh-openssl`,
`batctl-default`, `kmod-batman-adv`, `kmod-8021q`, `sqm-scripts`.

`files` injects `mx4300-files/` directly into the firmware image, including
the first-boot script below.

### First-boot configuration (`99-mesh-setup.sh.tmpl`)

Runs once via OpenWrt's `uci-defaults` mechanism. Templated with
`${PARENTS_MESH_SECRET}` / `${PARENTS_WIFI_SECRET}`, rendered by
`make build-mx4300` via `sops exec-env` + `envsubst` (see
[07-secrets-management.md](07-secrets-management.md#5-where-secrets-surface-outside-nixos-activation)).
The rendered `.sh` (without the `.tmpl` suffix) is gitignored and deleted
immediately after the firmware build.

What it configures, end to end:

1. **System:** hostname `parents-ap`, remote syslog to `elitedesk.home.jupiter.au`.
2. **DNS:** LAN clients point at `10.1.1.20` — the same anonymized resolver the main site uses (see [05-networking.md](05-networking.md)).
3. **Radios:** radio0 (2.4GHz) and radio1 (5GHz-low) for client APs; radio2 (5GHz-high) reserved as a dedicated mesh backhaul.
4. **Mesh:** Batman-adv (`BATMAN_IV` routing algorithm) over an 802.11s mesh (`mesh_id = jupiter-parents-mesh`, SAE encryption) on radio2's `bat0` interface, bridged into the LAN.
5. **VLANs:** `cameras` (VLAN 2, bridges `eth0.2` + `bat0.2`) and `iot` (VLAN 3, bridges `eth0.3` + `bat0.3`) — mirroring the main site's VLAN scheme so the same firewall/DNS posture extends across both sites.
6. **Client SSIDs:**
   - `Jupiter-Parents` (2.4GHz + 5GHz-low, main LAN, WPA2-PSK)
   - `Jupiter-Cameras` (2.4GHz, VLAN 2, WPA2-PSK, client-isolated)
   - `Jupiter-IOT` (2.4GHz, VLAN 3, WPA2-PSK, client-isolated)

## 2. Wyze cameras

**Path:** `hosts/parents-house/wyze-cams/`
**Firmware:** third-party `wz_mini_hacks` (not built by this repo) — this
repo only supplies a rendered runtime config.

### Config template (`wz_mini.conf.tmpl`)

Rendered the same way as the AP script (`sops exec-env` + `envsubst` via
`make build-mx4300`), using secret `WYZE_PASSWORD` for both fields below. The
rendered `wz_mini.conf` is gitignored.

| Setting | Value |
|---|---|
| RTSP server | enabled, port 8554, user `admin`, password from `WYZE_PASSWORD` — primarily so the cameras can be pulled into Home Assistant |
| Dropbear SSH | enabled, password from `WYZE_PASSWORD` |
| Syslog | enabled, forwarded to `elitedesk.home.jupiter.au:514` |

As noted in [02-hosts.md](02-hosts.md#elitedesk-hp-elitedesk-800-g4) and
[03-software-inventory.md](03-software-inventory.md#elitedesk), nothing in
this repo currently declares a syslog *receiver* on `elitedesk` — the cameras
(and the MX4300 APs) are both configured to ship logs there, but the
service that would ingest them isn't part of the flake yet.

## 3. Rendering and building edge-device artifacts

```bash
make build-mx4300
```

This single target (see `Makefile`):

1. Renders both `.tmpl` files above via `sops exec-env ... envsubst`.
2. Builds `.#mx4300-firmware`.
3. Deletes the rendered plaintext files immediately afterward.

There's no equivalent `make` target to *flash* the AP firmware or push the
Wyze config to a physical camera — both are manual steps outside this repo's
scope once the artifacts are built/rendered.
