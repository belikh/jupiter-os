{ config, lib, ... }:

# Loki log aggregation plus a syslog receiver (promtail) that ingests the Wyze
# camera fleet's forwarded syslog (they target elitedesk:514, see
# hosts/parents-house/wyze-cams) and pushes it into Loki.
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

    # Receive syslog and push it into Loki. Note: promtail's syslog target is
    # RFC5424-over-TCP; Wyze's rsyslog forwarder must be pointed at TCP:514. If a
    # source only speaks RFC3164/UDP, front it with rsyslog/vector instead.
    services.promtail = {
      enable = true;
      configuration = {
        server = {
          http_listen_port = 9080;
          grpc_listen_port = 0;
        };
        clients = [
          { url = "http://127.0.0.1:${toString cfg.httpPort}/loki/api/v1/push"; }
        ];
        scrape_configs = [
          {
            job_name = "syslog";
            syslog = {
              listen_address = "0.0.0.0:${toString cfg.syslogPort}";
              labels.job = "syslog";
            };
            relabel_configs = [
              {
                source_labels = [ "__syslog_message_hostname" ];
                target_label = "host";
              }
            ];
          }
        ];
      };
    };

    # promtail binds the privileged syslog port.
    systemd.services.promtail.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

    networking.firewall.allowedTCPPorts = [
      cfg.httpPort
      cfg.syslogPort
    ];
  };
}
