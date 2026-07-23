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

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = ''
        Port serving `root` over plain HTTP, for iPXE's kernel/initrd fetch.
        TFTP's lockstep ack-per-block design (atftpd here) is fine for the
        tiny ipxe.efi/undionly.kpxe chainload binary — that's all the NIC's
        PXE ROM firmware itself can speak — but is badly slow for the actual
        kernel+initrd (tens of MB). iPXE has a native HTTP client once it's
        running, so netboot.ipxe fetches those two over HTTP instead
        (confirmed slow via TFTP bringing callisto up 2026-07-23).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.atftpd = {
      enable = true;
      root = cfg.root;
    };

    services.nginx = {
      enable = true;
      virtualHosts."pxe-assets" = {
        listen = [
          {
            addr = "0.0.0.0";
            port = cfg.httpPort;
          }
        ];
        root = cfg.root;
      };
    };

    networking.firewall.allowedUDPPorts = [ 69 ];
    networking.firewall.allowedTCPPorts = [ cfg.httpPort ];
  };
}
