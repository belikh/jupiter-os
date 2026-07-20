{ config, lib, ... }:

# Plain TFTP netboot server — UniFi's own DHCP server handles PXE directly
# (Network Boot / DHCP options 66-67, set by hand in the UniFi console
# pointing at this host + "ipxe.efi"), so no DHCP-proxy tool is needed here.
#
# `root` is built entirely in flake.nix using an UNTUNED nixpkgs instance
# (nixpkgs.legacyPackages.x86_64-linux), not this host's own `pkgs` — on
# europa, `pkgs` is gccarch-btver2-tuned (jupiter.build.microarch), and
# building ipxe/syslinux/mtools under that tag means rebuilding that whole
# toolchain from source (nothing that unrelated is in the private Attic,
# and cache.nixos.org only has the portable build). Confirmed: plain
# `nixpkgs#ipxe` substitutes in seconds; the tuned one pulled in a full
# stage0 bootstrap. This module only wires the (untuned, pre-built) result
# into atftpd — it has no pkgs of its own to get that wrong with again.

let
  cfg = config.jupiter.pxe;
in
{
  options.jupiter.pxe = {
    enable = lib.mkEnableOption "TFTP netboot server for the diskless fleet";

    root = lib.mkOption {
      type = lib.types.path;
      description = ''
        Pre-built TFTP root (ipxe.efi/undionly.kpxe + the netboot
        kernel/initrd under fixed names) — built in flake.nix with an
        untuned nixpkgs instance, not this module's own `pkgs`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.atftpd = {
      enable = true;
      root = cfg.root;
    };

    networking.firewall.allowedUDPPorts = [ 69 ];
  };
}
