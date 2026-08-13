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
#                         directory, published out-of-band by
#                         jupiter-pxe-assets.service (below). Deliberately
#                         not a store path in this host's config: naming one
#                         would put the client's whole (differently-tuned)
#                         closure inside the server's, so building europa
#                         would also build callisto. That coupling is what
#                         this design removes.
#
# `root` is built entirely in flake.nix using an UNTUNED nixpkgs instance
# (nixpkgs.legacyPackages.x86_64-linux), not this host's own `pkgs` — on
# europa, `pkgs` is gccarch-bdver4-tuned (jupiter.build.microarch), and
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
      # interpolating one copies it into the store — which would put a store
      # path back into this host's config and silently reintroduce the exact
      # coupling this split removes. A runtime directory is a string.
      type = lib.types.str;
      default = "/var/lib/pxe-netboot";
      description = ''
        Mutable directory holding the HTTP-served half of the netboot chain.
        `''${assetsDir}/current` is a symlink to a built
        `pxe-netboot-assets` store path (boot.ipxe + bzImage + initrd) and is
        what nginx serves; it doubles as the indirect GC root pinning those
        paths. Populated by jupiter-pxe-assets.service, never by activation —
        a store path named here would drag the netbooting client's closure
        into this host's.
      '';
    };

    assetsFlakeRef = lib.mkOption {
      type = lib.types.str;
      default = "github:belikh/jupiter-os#pxe-netboot-assets";
      description = ''
        Flake reference jupiter-pxe-assets.service builds and links into
        `assetsDir`. Pulled from the pushed remote, matching the fleet's
        deploy discipline (hosts build from github:belikh/jupiter-os, so a
        change must be committed + pushed before it is publishable).
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

    systemd.tmpfiles.rules = [
      "d ${cfg.assetsDir} 0755 root root - -"
    ];

    # Publisher for the HTTP half. Manual/one-shot ON PURPOSE — no timer, no
    # wantedBy — because the assets must track callisto's DEPLOYED generation,
    # not whatever `main` happens to hold: boot.ipxe pins `init=` to a specific
    # toplevel, and stage-1 switch_roots into that path on callisto's own iSCSI
    # root, so publishing ahead of callisto's `nixos-rebuild switch` would
    # serve a path that doesn't exist there. Order of operations is therefore:
    # push to main → switch callisto → `systemctl start jupiter-pxe-assets`
    # here. A failed run changes nothing (the old `current` symlink, and its GC
    # root, stay put), so callisto keeps netbooting what it booted last time.
    systemd.services.jupiter-pxe-assets = {
      description = "Publish the PXE netboot assets (boot.ipxe + kernel + initrd)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Environment/path mirror nixpkgs' own nixos-upgrade.service (the other
      # unit in the tree that runs a flake-fetching `nix` command): nix needs
      # its envVars, a writable HOME for the eval/fetch cache, the proxy vars,
      # and the tarball-unpacking tools on PATH.
      environment =
        config.nix.envVars
        // {
          HOME = "/root";
        }
        // config.networking.proxy.envVars;
      path = [
        pkgs.coreutils
        pkgs.gnutar
        pkgs.xz.bin
        pkgs.gzip
        # No git: assetsFlakeRef is a `github:` (tarball) ref, and every flake
        # input is too, so nothing here shells out to git. Leaving it off keeps
        # a from-source git out of this host's microarch-tuned closure.
        config.nix.package.out
      ];
      serviceConfig.Type = "oneshot";
      # --out-link registers an indirect GC root, which is the only thing
      # keeping the served kernel/initrd alive in this host's store now that no
      # system closure references them. europa has a stateful root (no
      # impermanence), so the symlink survives reboots.
      script = ''
        exec nix build --refresh --print-build-logs \
          --out-link "${cfg.assetsDir}/current" "${cfg.assetsFlakeRef}"
      '';
    };

    networking.firewall.allowedUDPPorts = [ 69 ];
    networking.firewall.allowedTCPPorts = [ cfg.httpPort ];
  };
}
