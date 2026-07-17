{
  config,
  lib,
  ...
}:

# The Jupiter build-mesh WireGuard interface.
#
# Why this exists: the Cloudflare Tunnel that fronts europa's atticd
# (attic.jupiter.au) has a hard ~100s origin timeout — it returns HTTP 524 on
# any single NAR upload/download larger than what fits in that window, which
# means gcc/glibc/rustc-class paths can NEVER move over the tunnel. The first
# "rebuild the world" run banked only the small paths and lost every big one.
#
# This interface gives the ephemeral build server (pallene) a DIRECT route to
# europa (the attic host), bypassing the tunnel entirely for attic push/pull.
# europa is the always-on server peer (listen on wireguardPort, forwarded from
# the home router); pallene is the roaming client peer that dials europa's
# public endpoint. Once the interface is up, pallene reaches europa at
# europa's mesh IP (e.g. 10.10.0.1), and build-server.nix points attic at
# http://<europa-mesh-ip>:8080 instead of https://attic.jupiter.au.
#
# Ops prerequisite (one-time, manual): forward wireguardPort/UDP on the home
# router to europa, and set pallene's peer `endpoint` to europa's public WG
# endpoint (WAN IP or DDNS hostname). See hosts/pallene/configuration.nix.

let
  cfg = config.jupiter.network.wireguard;
in
{
  options.jupiter.network.wireguard = {
    enable = lib.mkEnableOption "the Jupiter build-mesh WireGuard interface";

    interfaceName = lib.mkOption {
      type = lib.types.str;
      default = "jupwg";
      description = "Name of the WireGuard interface.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      description = ''
        This host's WireGuard IPv4/CIDR on the mesh (e.g. "10.10.0.1/24").
        europa is the .1 server peer, pallene the .2 roaming client.
      '';
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = ''
        UDP port the server peer (europa) listens on. The client peer does not
        need to listen, but opening the port is harmless. Forward this on the
        home router to europa for the roaming build server to reach it.
      '';
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to this host's WireGuard private key. On europa this is a sops
        secret decrypted at activation; on pallene (no persistent host key) it
        is baked into the ISO via the pallene-secrets materialization.
      '';
    };

    peers = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = ''
        Peer entries, shape of `networking.wireguard.interfaces.<if>.peers`.
        Each peer needs at least `publicKey` and `allowedIPs`; a roaming client
        additionally sets `endpoint` and `persistentKeepalive`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    networking.wireguard.interfaces.${cfg.interfaceName} = {
      ips = [ cfg.address ];
      inherit (cfg) listenPort privateKeyFile peers;
    };

    # Allow inbound WG handshacks on the server peer (harmless on the client).
    networking.firewall.allowedUDPPorts = [ cfg.listenPort ];
  };
}
