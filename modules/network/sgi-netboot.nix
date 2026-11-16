{
  config,
  lib,
  ...
}:

# BOOTP + TFTP netboot server for SGI workstations (Indy PROM).
#
# The SGI PROM's `bootp()` device broadcasts a plain BOOTP request, then
# fetches the named file over TFTP and jumps to it. UniFi's DHCP server
# cannot serve this (it has no per-client BOOTP file for a 1993 PROM), so one
# dnsmasq instance does both halves. It is fenced so it cannot interfere with
# UniFi DHCP on the same LAN:
#
#   - `dhcp-range=<network>,static`: only the MACs listed in `clients` are
#     ever answered; there is no dynamic pool.
#   - `dhcp-ignore=tag:!bootp`: only plain BOOTP is answered. DHCP requests,
#     including those from the same MAC once the booted OS runs its own DHCP
#     client, are left to UniFi.
#   - `port=0`: no DNS, and `resolveLocalQueries = false` keeps the host's
#     resolv.conf untouched.
#
# Two PROM limits are handled in the dnsmasq settings:
#
#   - The PROM reads the TFTP server's data port as a signed 16-bit number,
#     so `tftp-port-range` stays below 32768.
#   - The PROM requests whatever name is typed at its prompt; dnsmasq returns
#     `bootFile` in the BOOTP reply, so boot with `boot -f bootp()<bootFile>`.
#
# `root` is a mutable directory, not a store path: the boot image is rebuilt
# out of tree (the IRIX 7 kernel, `tools/indy-netboot.sh <root>`) and must not
# enter this host's closure.

let
  cfg = config.jupiter.sgiNetboot;
in
{
  options.jupiter.sgiNetboot = {
    enable = lib.mkEnableOption "BOOTP/TFTP netboot server for SGI PROM clients";

    interface = lib.mkOption {
      type = lib.types.str;
      example = "eno1";
      description = "LAN interface the SGI clients are reached on.";
    };

    serverAddress = lib.mkOption {
      type = lib.types.str;
      example = "10.1.1.3";
      description = "This host's address on `interface`; sent as the BOOTP next-server.";
    };

    network = lib.mkOption {
      type = lib.types.str;
      example = "10.1.1.0";
      description = "Network address of the LAN, for dnsmasq's static-only range.";
    };

    clients = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "08:00:69:12:12:12" = "10.1.1.112";
      };
      description = "MAC address to IPv4 address for each SGI client. Only these MACs are answered.";
    };

    bootFile = lib.mkOption {
      type = lib.types.str;
      default = "irix7";
      description = "File name, relative to `root`, returned in the BOOTP reply.";
    };

    root = lib.mkOption {
      # str, not path: a path literal would be copied into the store.
      type = lib.types.str;
      default = "/var/lib/sgi-netboot";
      description = "Mutable TFTP root holding the boot image.";
    };

    owner = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User that owns `root` and writes the boot image into it.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        port = 0;
        interface = cfg.interface;
        bind-interfaces = true;
        dhcp-range = "${cfg.network},static";
        dhcp-host = lib.mapAttrsToList (mac: ip: "${mac},${ip}") cfg.clients;
        dhcp-ignore = "tag:!bootp";
        dhcp-boot = "${cfg.bootFile},,${cfg.serverAddress}";
        enable-tftp = true;
        tftp-root = cfg.root;
        tftp-port-range = "20000,32000";
        log-dhcp = true;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.root} 0755 ${cfg.owner} root -"
    ];

    networking.firewall.allowedUDPPorts = [
      67
      69
    ];
    networking.firewall.allowedUDPPortRanges = [
      {
        from = 20000;
        to = 32000;
      }
    ];
  };
}
