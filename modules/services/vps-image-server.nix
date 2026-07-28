{
  config,
  lib,
  pkgs,
  ...
}:

# Lightweight static file server for VPS disk images served via Kamatera's
# "Import from URL" flow. Stores images in /var/lib/vps-images/ and serves
# them on the configured port. The Cloudflare Tunnel (cloudflare-tunnel.nix)
# routes a public hostname to this port so Kamatera can download them.
#
# Usage: place the disk image (compressed with xz/gzip/...) in the directory,
# then Kamatera imports from https://<tunnel-hostname>/<filename>.
#
# Future: when pallene runs NixOS, it can host its own images and replace its
# disk via the Kamatera API directly — this module then becomes the fallback.

let
  cfg = config.jupiter.services.vpsImageServer;
in
{
  options.jupiter.services.vpsImageServer = {
    enable = lib.mkEnableOption "VPS disk image server (darkhttpd)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8084;
      description = "TCP port for the image server";
    };

    directory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/vps-images";
      description = "Directory containing disk images to serve";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.vps-image-server = {
      description = "VPS disk image server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      preStart = ''
        mkdir -p ${cfg.directory}
      '';

      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.darkhttpd} ${cfg.directory} --port ${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = 5;
        DynamicUser = true;
        StateDirectory = baseNameOf cfg.directory;
        StateDirectoryMode = "0755";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
      };
    };
  };
}
