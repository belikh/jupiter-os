{
  config,
  lib,
  pkgs,
  ...
}:

# Loki log aggregation plus a syslog receiver (grafana-alloy) that ingests the
# Wyze camera fleet's forwarded syslog (they target elitedesk:514, see
# hosts/parents-house/wyze-cams) and pushes it into Loki. promtail (the
# previous receiver) was removed upstream after reaching end of life.
#
# On elitedesk, `dataDir` lives on the iSCSI "loki" LUN exported by the NAS, so
# the log store survives the diskless node's reboots.

let
  cfg = config.jupiter.services.loki;
in
{
  options.jupiter.services.loki = {
    enable = lib.mkEnableOption "Loki log aggregation + syslog receiver";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/loki";
      description = "Persistent storage directory for Loki chunks + index.";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 3100;
    };

    syslogPort = lib.mkOption {
      type = lib.types.port;
      default = 514;
      description = "TCP port the syslog receiver listens on (RFC5424).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.loki = {
      enable = true;
      dataDir = cfg.dataDir;
      configuration = {
        auth_enabled = false;
        server.http_listen_port = cfg.httpPort;
        common = {
          ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
          };
          replication_factor = 1;
          path_prefix = cfg.dataDir;
        };
        schema_config.configs = [
          {
            from = "2024-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
        storage_config.filesystem.directory = "${cfg.dataDir}/chunks";
      };
    };

    # Receive syslog and push it into Loki. Note: the syslog listener is
    # RFC5424-over-TCP; Wyze's rsyslog forwarder must be pointed at TCP:514. If a
    # source only speaks RFC3164/UDP, front it with rsyslog/vector instead.
    services.alloy = {
      enable = true;
      configPath = pkgs.writeText "alloy-syslog-to-loki.alloy" ''
        loki.relabel "syslog" {
          forward_to = [loki.write.local.receiver]

          rule {
            source_labels = ["__syslog_message_hostname"]
            target_label  = "host"
          }
        }

        loki.source.syslog "wyze" {
          listener {
            address  = "0.0.0.0:${toString cfg.syslogPort}"
            protocol = "tcp"
            labels   = { job = "syslog" }
          }
          forward_to = [loki.relabel.syslog.receiver]
        }

        loki.write "local" {
          endpoint {
            url = "http://127.0.0.1:${toString cfg.httpPort}/loki/api/v1/push"
          }
        }
      '';
    };

    # alloy binds the privileged syslog port.
    systemd.services.alloy.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

    networking.firewall.allowedTCPPorts = [
      cfg.httpPort
      cfg.syslogPort
    ];
  };
}
