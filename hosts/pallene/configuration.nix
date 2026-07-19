{
  modulesPath,
  ...
}:

# EPHEMERAL, GENERIC BUILD SERVER. Never a persistent fleet member: BinaryLane
# boots a disposable VPS from this ONE stable ISO (`make pallene-iso` — only
# needs rebuilding when this file, build-server.nix, or wireguard.nix itself
# changes), it rebuilds whatever hosts and git ref it's told at server-create
# time (see modules/services/build-server.nix's runtime-parameters block),
# pushes the result(s) to the attic cache, then deletes itself. No storage
# profile, no impermanence, no backup, no branding, no desktop — as minimal
# as the stock installer media allows, plus the one module that does the
# actual work.
#
# Zero secrets baked into the Nix store: BinaryLane API token, attic push
# token, R2 credentials, and the WireGuard mesh key all arrive via cloud-init
# user_data at boot (scripts/binarylane-build-server.sh builds and sends that
# blob) — this ISO is safe to keep in R2 indefinitely with nothing sensitive
# in it, and rotating any credential never needs a rebuild.
#
# Registered via flake.nix's mkIsoHost (not mkHost) so the common flake-module
# injection (sops-nix, impermanence, disko, ha-linux-agent) is skipped — this
# box never survives past one run and has no persistent host key to decrypt
# against. Named after a small, distant Jupiter moon, matching this fleet's
# convention — fitting for a host only briefly in orbit.
{
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    ../../modules/services/build-server.nix
  ];

  networking.hostName = "pallene";

  # Kernel console on the serial port so the boot + the jupiter-build-server
  # service output is visible under QEMU -nographic (and over any serial
  # console BinaryLane exposes). Harmless alongside the VGA console.
  boot.kernelParams = [
    "console=ttyS0"
    "console=tty0"
  ];

  # WireGuard kernel module still needed even without the declarative
  # networking.wireguard.interfaces module below — see build-server.nix's
  # runScript for why pallene doesn't use that module.
  boot.kernelModules = [ "wireguard" ];
  networking.firewall.allowedUDPPorts = [ 51820 ];

  jupiter.services.buildServer = {
    enable = true;
    # europa's atticd reached DIRECTLY over the UniFi WireGuard mesh, NOT via
    # the Cloudflare Tunnel — the tunnel returns HTTP 524 on any NAR that takes
    # >100s to transfer, so gcc/glibc/rustc-class paths can never move through
    # it. The UDM (UniFi WG server) routes the mesh onto the home LAN, so
    # pallene reaches europa at its LAN IP. atticd listens on *:8080.
    atticServer = "http://10.1.1.2:8080";

    # ---- WireGuard build mesh: deliberately NOT the shared
    # jupiter.network.wireguard module (modules/network/wireguard.nix) -------
    # That module is a fine fit for europa (server side: key from sops at
    # ACTIVATION time, no boot race) but a bad one for pallene: it declares
    # peer/endpoint/allowedIPs as NixOS options fixed at ISO BUILD time, while
    # only the private key came from cloud-init user-data — a half-runtime
    # design that was inconsistent and, on 2026-07-18, coincided with a run
    # whose WireGuard interface never came up and whose networking then broke
    # entirely (undiagnosed — the box went fully unreachable before any log
    # could be pulled).
    #
    # These values are just the DEFAULT mesh identity, baked here same as
    # before — every one of them is still fully overridable at runtime via
    # cloud-init user-data (WG_PEER_PUBLIC_KEY / WG_ENDPOINT / WG_ALLOWED_IPS
    # / WG_ADDRESS), which build-server.nix's runScript configures directly
    # with `ip`/`wg` right after it loads user-data and secrets — inheriting
    # that correct ordering for free instead of needing its own systemd-unit
    # dependency dance. See runScript's "wireguard mesh" section.
    wireguardEnable = true;
    wireguardAddress = "192.168.5.2/32";
    # The UDM (UniFi WG server).
    wireguardPeerPublicKey = "gw6gm9TpSBFOqifygp8XLfEEDGgebzD4tEFgXCSawE4=";
    wireguardEndpoint = "neptune.jupiter.au:51820";
    wireguardAllowedIPs = [
      "10.1.1.0/24" # home LAN — europa/attic lives here at 10.1.1.2
      "192.168.5.0/24" # the WG mesh itself
    ];
  };

  # SSH for direct investigation: bake the admin key so the box is reachable by
  # SSH (root, key-only) right after boot. The live CD's sshd otherwise has no
  # usable creds (empty passwords are rejected), which forced blind console
  # debugging. PermitRootLogin yes + the key lets me get in early and inspect
  # the swap setup / build start directly instead of waiting hours.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICGxxtapYd7cY/NJjzTjdRQpuTKCs6jisSmKc5WfypZV forensic-analysis"
  ];

}
