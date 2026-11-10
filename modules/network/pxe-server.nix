{
  config,
  lib,
  pkgs,
  ...
}:

# Plain TFTP netboot server — UniFi's own DHCP server handles PXE directly
# (Network Boot / DHCP options 66-67, set by hand in the UniFi console
# pointing at this host + "ipxe.efi"), so no DHCP-proxy tool is needed here.
#
# The netboot chain is served from TWO roots, and the split is load-bearing:
#
#   `root` (TFTP)       — ipxe.efi/undionly.kpxe only. A store path built in
#                         flake.nix, part of THIS host's closure. Nothing in
#                         it references the netbooting client's config.
#   `assetsDir` (HTTP)  — boot.ipxe + the client's kernel/initrd. A MUTABLE
#                         directory on callisto's NFS export, written by
#                         callisto's jupiter-pxe-publish.service
#                         (modules/network/pxe-publish.nix). Deliberately
#                         not a store path in this host's config: naming one
#                         would put the client's whole (differently-tuned)
#                         closure inside the server's, so building europa
#                         would also build callisto. That coupling is what
#                         this design removes.
#
# `root` is built entirely in flake.nix using an UNTUNED nixpkgs instance
# (nixpkgs.legacyPackages.x86_64-linux), not this host's own `pkgs` — on
# europa, `pkgs` is gccarch-x86-64-v3-tuned (jupiter.build.microarch), and
# building ipxe/syslinux/mtools under that tag means rebuilding that whole
# toolchain from source (nothing that unrelated is in Harmonia, and
# cache.nixos.org only has the portable build). Confirmed: plain
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
        Pre-built TFTP root — the chainload binaries
        (ipxe.efi/undionly.kpxe) and nothing else. Built in flake.nix with
        an untuned nixpkgs instance, not this module's own `pkgs`. The
        kernel/initrd deliberately do NOT live here; see `assetsDir`.
      '';
    };

    assetsDir = lib.mkOption {
      # str, NOT path: types.path accepts a Nix path literal, and
      # interpolating one copies it into the store, which would put a store
      # path back into this host's config and reintroduce the coupling this
      # split removes. A runtime directory is a string.
      type = lib.types.str;
      default = "/tank/services/callisto/pxe";
      description = ''
        Directory holding the HTTP-served half of the netboot chain.
        `''${assetsDir}/current` is a relative symlink to
        `releases/<hash>` (boot.ipxe + bzImage + initrd) and is what nginx
        serves. The directory lives on the callisto-scoped NFS export, where
        callisto's jupiter-pxe-publish.service writes it. This host never
        builds the assets.
      '';
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = ''
        Port serving `assetsDir`'s current assets over plain HTTP, for iPXE's
        kernel/initrd fetch. TFTP's lockstep ack-per-block design (atftpd
        here) is fine for the tiny ipxe.efi/undionly.kpxe chainload binary —
        that's all the NIC's PXE ROM firmware itself can speak — but is badly
        slow for the actual kernel+initrd (tens of MB). iPXE has a native HTTP
        client once it's running, so boot.ipxe fetches those two over HTTP
        instead (confirmed slow via TFTP bringing callisto up 2026-07-23).
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
        root = "${cfg.assetsDir}/current";
      };
    };

    # The assets live on a ZFS dataset that must be mounted before nginx
    # resolves `current`.
    systemd.services.nginx.unitConfig.RequiresMountsFor = [ cfg.assetsDir ];

    networking.firewall.allowedUDPPorts = [ 69 ];
    networking.firewall.allowedTCPPorts = [ cfg.httpPort ];
  };
}
