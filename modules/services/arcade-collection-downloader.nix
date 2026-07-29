{
  config,
  lib,
  pkgs,
  ...
}:

# Arcade collection torrent downloader — background service to archive game collections
# Runs on europa (NAS) to seed/download large game collection torrents

let
  cfg = config.jupiter.services.arcadeCollectionDownloader;
in
{
  options.jupiter.services.arcadeCollectionDownloader = {
    enable = lib.mkEnableOption "Background torrent downloader for arcade game collections";

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/downloads";
      description = "Directory where torrent downloads are saved";
    };

    # eXoWin9x torrent configuration
    exowin9x = {
      enable = lib.mkEnableOption "Download eXoWin9x (Windows 95/98 games, ~262 GB)";

      torrentUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://www.retro-exo.com/win9x.html";
        description = "URL to eXoWin9x torrent (user must download manually and provide path)";
      };

      maxConnections = lib.mkOption {
        type = lib.types.int;
        default = 16;
        description = "Maximum connections for transmission-daemon";
      };

      rateLimit = lib.mkOption {
        type = lib.types.int;
        default = 0; # unlimited
        description = "Download speed limit in KB/s (0 = unlimited)";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Create download directory
    systemd.tmpfiles.rules = [
      "d ${cfg.downloadDir} 0755 root root -"
      "d /tank/archive/retro/metadata/pegasus/collections 0755 root root -"
    ];

    # Transmission daemon for torrent downloading
    services.transmission = lib.mkIf cfg.exowin9x.enable {
      enable = true;
      settings = {
        # Core daemon settings
        rpc-enabled = false; # Disable RPC (not needed for background service)
        download-dir = cfg.downloadDir;
        incomplete-dir = "${cfg.downloadDir}/.incomplete";
        incomplete-dir-enabled = true;

        # Performance
        max-peer-connection-global = cfg.exowin9x.maxConnections;
        speed-limit-down = cfg.exowin9x.rateLimit;
        speed-limit-down-enabled = cfg.exowin9x.rateLimit > 0;

        # UPnP/PNP for NAT traversal
        utp-enabled = true;
        port-forwarding-enabled = false; # NAS is on internal LAN

        # Ratio/seeding
        ratio-limit = 2.0; # Seed to 2x the download size
        ratio-limit-enabled = true;
      };
    };

    # Service to monitor and extract completed torrents
    systemd.services.arcade-collection-processor = lib.mkIf cfg.exowin9x.enable {
      description = "Process and organize downloaded arcade collections";
      after = [ "transmission.service" ];
      wantedBy = [ "multi-user.target" ];

      # Run every 30 minutes to check for completed downloads
      startAt = "*:0/30";

      script = ''
        set -eu

        # Check for eXoWin9x Vol1 completion
        if [[ -f "${cfg.downloadDir}/eXoWin9x_Vol1_v"*.7z ]]; then
          ARCHIVE=$(ls -t "${cfg.downloadDir}"/eXoWin9x_Vol1_v*.7z | head -1)

          echo "Found completed eXoWin9x archive: $ARCHIVE"
          echo "Ready for extraction. Run: /root/jupiter-os/scripts/setup-exowin9x.sh $ARCHIVE"

          # Log completion for monitoring
          logger -t arcade-downloader "eXoWin9x Vol1 download complete: $ARCHIVE"
        fi
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };

    # Helper script to download torrent (user runs once with URL/torrent file)
    environment.etc."download-arcade-torrent.sh" = lib.mkIf cfg.exowin9x.enable {
      text = ''
        #!/bin/bash
        # Download arcade collection torrent to transmission watch directory
        #
        # Usage:
        #   /etc/download-arcade-torrent.sh /path/to/torrent/file.torrent
        # OR
        #   /etc/download-arcade-torrent.sh "https://example.com/torrent.torrent"

        set -eu

        TORRENT_PATH="''${1:-}"
        if [[ -z "$TORRENT_PATH" ]]; then
            echo "Usage: $0 <path-to-torrent-file-or-url>"
            echo ""
            echo "Steps:"
            echo "1. Download torrent from: ${cfg.exowin9x.torrentUrl}"
            echo "2. Copy to europa: scp eXoWin9x_Vol1.torrent root@10.1.1.2:/tmp/"
            echo "3. Run: ssh root@10.1.1.2 /etc/download-arcade-torrent.sh /tmp/eXoWin9x_Vol1.torrent"
            exit 1
        fi

        WATCH_DIR="/var/lib/transmission/.config/transmission-daemon/watch"
        mkdir -p "$WATCH_DIR"

        if [[ "$TORRENT_PATH" == http* ]]; then
            echo "Downloading torrent from: $TORRENT_PATH"
            curl -L -o "$WATCH_DIR/arcade-collection.torrent" "$TORRENT_PATH"
        else
            if [[ ! -f "$TORRENT_PATH" ]]; then
                echo "ERROR: Torrent file not found: $TORRENT_PATH"
                exit 1
            fi
            cp "$TORRENT_PATH" "$WATCH_DIR/arcade-collection.torrent"
        fi

        echo "✓ Torrent added to transmission watch directory"
        echo "  Download will start automatically"
        echo "  Monitor progress: tail -f /var/log/transmission.log"
        echo "  Download dir: ${cfg.downloadDir}"
      '';
      mode = "0755";
    };

    # Logging
    systemd.services.transmission.serviceConfig.StandardOutput = "journal";
    systemd.services.transmission.serviceConfig.StandardError = "journal";
    systemd.services.transmission.serviceConfig.SyslogIdentifier = "transmission";
  };
}
