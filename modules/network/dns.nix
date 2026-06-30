{ config, lib, ... }:

with lib;
let
  cfg = config.jupiter.dns;

  # "host.fqdn" -> "10.1.1.x"  becomes unbound local-data A + PTR records,
  # giving us split-horizon internal names without publishing them anywhere.
  aRecords = mapAttrsToList (fqdn: ip: ''"${fqdn}. IN A ${ip}"'') cfg.records;
  ptrRecords = mapAttrsToList (fqdn: ip: ''"${ip} ${fqdn}"'') cfg.records;
in
{
  options.jupiter.dns = {
    enable = mkEnableOption "self-hosted anonymized resolver + internal split-horizon DNS";

    domain = mkOption {
      type = types.str;
      default = "home.jupiter.au";
      description = "Internal split-horizon zone served authoritatively to LAN clients.";
    };

    allowedNetworks = mkOption {
      type = types.listOf types.str;
      default = [
        "127.0.0.0/8"
        "::1/128"
      ];
      description = "Networks permitted to query this resolver.";
    };

    records = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        "europa.home.jupiter.au" = "10.1.1.2";
      };
      description = "Internal FQDN -> IPv4 records (A + PTR) for the split-horizon zone.";
    };
  };

  config = mkIf cfg.enable {
    # ---- Front resolver: unbound -------------------------------------------
    # Serves the LAN, caches aggressively (reconciles "fast" with the latency
    # that anonymized relaying adds), validates DNSSEC, and hosts the internal
    # zone. CRITICAL: it is a PURE FORWARDER to dnscrypt-proxy — the forward-zone
    # "." below means it never recurses to the public root/authoritative servers
    # in cleartext via the ISP, which would defeat the anonymity goal.
    services.unbound = {
      enable = true;
      resolveLocalQueries = false; # we set resolv.conf ourselves (127.0.0.1)
      settings = {
        server = {
          interface = [
            "0.0.0.0"
            "::"
          ];
          port = 53;
          access-control = map (n: "${n} allow") cfg.allowedNetworks;
          do-ip6 = true;

          hide-identity = true;
          hide-version = true;
          qname-minimisation = true; # send minimal info downstream
          harden-glue = true;
          harden-dnssec-stripped = true;
          aggressive-nsec = true;

          # Speed: cache hard, prefetch popular names, serve slightly-stale.
          prefetch = true;
          prefetch-key = true;
          cache-min-ttl = 60;
          cache-max-ttl = 86400;
          serve-expired = true;
          msg-cache-size = "128m";
          rrset-cache-size = "256m";

          # Internal split-horizon zone (not published anywhere public).
          local-zone = [ ''"${cfg.domain}." static'' ];
          local-data = aRecords;
          local-data-ptr = ptrRecords;
        };

        # Everything external -> dnscrypt-proxy (anonymized, encrypted). No
        # recursion path exists, so nothing leaks to the ISP in cleartext.
        forward-zone = [
          {
            name = ".";
            forward-addr = "127.0.0.1@5353";
          }
        ];
      };
    };

    # ---- Encrypted + anonymized upstream: dnscrypt-proxy --------------------
    # Anonymized DNSCrypt routing: the relay sees our IP but not the query; the
    # resolver sees the query but not our IP -> no single party links the two.
    services.dnscrypt-proxy = {
      enable = true;
      settings = {
        listen_addresses = [ "127.0.0.1:5353" ];
        ipv6_servers = true;
        block_ipv6 = false;

        # Only trustworthy upstreams.
        require_dnssec = true;
        require_nolog = true;
        require_nofilter = true;

        dnscrypt_servers = true; # needed for anonymized routing
        doh_servers = false;
        odoh_servers = false;

        cache = true;
        cache_size = 4096;

        # Startup-only: used once to fetch the signed resolver/relay lists over
        # HTTPS. Kept to encrypted-capable resolvers; system DNS is ignored.
        ignore_system_dns = true;
        bootstrap_resolvers = [
          "9.9.9.9:53"
          "1.1.1.1:53"
        ];
        netprobe_timeout = 60;

        sources = {
          public-resolvers = {
            urls = [
              "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
              "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
            ];
            cache_file = "/var/lib/dnscrypt-proxy/public-resolvers.md";
            minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
          };
          relays = {
            urls = [
              "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md"
              "https://download.dnscrypt.info/resolvers-list/v3/relays.md"
            ];
            cache_file = "/var/lib/dnscrypt-proxy/relays.md";
            minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
          };
        };

        # Route ALL queries through anonymizing relays (relay != resolver
        # operator). `via = ["*"]` lets dnscrypt pick compatible relays; review
        # with `dnscrypt-proxy -list-all-relays` and pin specific ones if wanted.
        anonymized_dns = {
          routes = [
            {
              server_name = "*";
              via = [ "*" ];
            }
          ];
          skip_incompatible = true;
        };
      };
    };

    networking.firewall.allowedTCPPorts = [ 53 ];
    networking.firewall.allowedUDPPorts = [ 53 ];
  };
}
