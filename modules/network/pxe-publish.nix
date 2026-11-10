{
  config,
  lib,
  pkgs,
  ...
}:

# Callisto builds its own PXE netboot assets and writes them to europa.
#
# jupiter-pxe-publish builds github:belikh/jupiter-os#pxe-netboot-assets on
# this host (boot.ipxe + bzImage + initrd) and copies the three files into
# <dir>/releases/<store-hash>/ on the callisto-scoped NFS export
# (/tank/services/callisto on europa, mounted at /mnt/europa). It then points
# <dir>/current at the new release with a relative symlink. europa's nginx
# serves <assetsDir>/current, where assetsDir is the same directory seen from
# europa (modules/network/pxe-server.nix).
#
# Because the build happens here, the toplevel that boot.ipxe pins with
# `init=` is already in this host's store when the assets are published. The
# old rule "switch callisto first, then publish" no longer applies. The build
# result is linked under /var/lib/jupiter-pxe so the toplevel stays
# GC-rooted.
#
# Manual by design: it never runs from a timer, so a reboot only ever picks
# up assets someone published on purpose.

let
  cfg = config.jupiter.pxe.publish;

  publishScript = pkgs.writeShellScript "jupiter-pxe-publish" ''
    set -euo pipefail
    dir=${lib.escapeShellArg cfg.dir}
    keep=${toString cfg.keep}

    mkdir -p /var/lib/jupiter-pxe
    out=$(nix build --refresh --print-build-logs --print-out-paths \
      --out-link /var/lib/jupiter-pxe/result ${lib.escapeShellArg cfg.flakeRef})
    id=$(basename "$out" | cut -c1-32)

    mkdir -p "$dir/releases"
    rel="$dir/releases/$id"
    if [ ! -d "$rel" ]; then
      tmp="$dir/releases/.tmp-$id"
      rm -rf "$tmp"
      mkdir "$tmp"
      for f in boot.ipxe bzImage initrd; do
        cp -L "$out/$f" "$tmp/$f"
      done
      sync -f "$tmp"
      mv -T "$tmp" "$rel"
    fi

    # Relative target: the same link resolves from europa's side of the export.
    ln -sfn "releases/$id" "$dir/current.new"
    mv -T "$dir/current.new" "$dir/current"
    echo "published $id -> $dir/current"

    # Keep the newest $keep releases (current is always the newest).
    ls -1dt "$dir"/releases/*/ 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -rf
  '';
in
{
  options.jupiter.pxe.publish = {
    enable = lib.mkEnableOption "building this host's PXE netboot assets and publishing them to europa";

    dir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/europa/pxe";
      description = ''
        Directory on europa's callisto export that receives the assets, as seen
        from this host. europa serves the same directory as
        jupiter.pxe.assetsDir (/tank/services/callisto/pxe).
      '';
    };

    flakeRef = lib.mkOption {
      type = lib.types.str;
      default = "github:belikh/jupiter-os#pxe-netboot-assets";
      description = "Flake attribute built on this host. It must be pushed before it can be published.";
    };

    keep = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Releases kept under <dir>/releases for rollback.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.jupiter-pxe-publish = {
      description = "Build the PXE netboot assets and publish them to europa";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ cfg.dir ];
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
        config.nix.package.out
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = publishScript;
      };
    };
  };
}
