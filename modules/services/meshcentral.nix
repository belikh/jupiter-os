{
  config,
  lib,
  pkgs,
  ...
}:

# MeshCentral — a web-based remote monitoring and management server. Agents
# installed on machines connect back to this server; the web UI provides remote
# desktop, terminal, file access, and device inventory.
#
# The package is the owner's fork (pkgs/meshcentral, github:belikh/MeshCentral)
# — see that file for the pin. Placement on europa is a named stack-guide
# exception (§1), packaged with buildNpmPackage per the §3 exception, and its
# NeDB state is the §5 exception.
#
# Deployment shape: MeshCentral can terminate TLS itself (leave `tlsOffload`
# null, as europa does) or sit behind a TLS-terminating proxy. When
# `tlsOffload` is set to the proxy's address, MeshCentral serves plain HTTP on
# `port` and trusts forwarded headers from that address; `aliasPort` is the
# port advertised to agents, which the proxy must publish.
#
# europa serves it LAN-only: MeshCentral's own TLS on :443, firewall opened for
# the trusted segment, no tunnel and no public ingress. If it is ever exposed
# beyond the LAN, put an authenticating perimeter (Cloudflare Access or
# equivalent) in front — it is a remote-control plane (stack-guide §4).
let
  cfg = config.jupiter.services.meshcentral;

  configFormat = pkgs.formats.json { };

  # The initial config.json MeshCentral reads on first boot. It is written to
  # the data directory only if absent, so the server's runtime edits (agent
  # settings, generated session keys) are never clobbered by a redeploy. Change
  # a Nix option after first boot and the generated file no longer matches —
  # edit the live config.json, or remove it and switch to regenerate.
  configFile = pkgs.writeText "meshcentral-config.json" (
    builtins.toJSON (
      {
        settings = {
          port = cfg.port;
          aliasPort = cfg.aliasPort;
          redirPort = cfg.redirPort;
          selfUpdate = cfg.selfUpdate;

          # MeshCentral's automatic backups default to a directory beside the
          # application (a read-only Nix store path here, which logs an EACCES
          # warning and silently disables backups). Point them at the writable
          # state directory instead.
          autobackup = {
            backuppath = "${builtins.dirOf cfg.dataDir}/backups";
          };
        }
        // lib.optionalAttrs (cfg.cert != null) { cert = cfg.cert; }
        // lib.optionalAttrs (cfg.tlsOffload != null) { tlsOffload = cfg.tlsOffload; }
        // lib.optionalAttrs (cfg.trustedProxy != null) { trustedProxy = cfg.trustedProxy; }
        // cfg.settings;
        domains = cfg.domains;
      }
      // cfg.extraConfig
    )
  );
in
{
  options.jupiter.services.meshcentral = {
    enable = lib.mkEnableOption "MeshCentral — web-based remote monitoring and management server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/meshcentral { nodejs = pkgs.nodejs_22; };
      defaultText = lib.literalExpression "pkgs.callPackage ../../pkgs/meshcentral { nodejs = pkgs.nodejs_22; }";
      description = ''
        The MeshCentral package to run. Defaults to the in-tree build of the
        owner's fork (pkgs/meshcentral). The flake also exposes it as
        <literal>.#meshcentral</literal> for standalone rebuilds.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 443;
      description = ''
        Port MeshCentral serves the web UI and agent connections on. With
        <option>tlsOffload</option> set this is a plain-HTTP origin port (a
        high port published by the proxy); left null it is the HTTPS port and
        normally stays 443.
      '';
    };

    aliasPort = lib.mkOption {
      type = lib.types.port;
      default = cfg.port;
      description = ''
        Port advertised to agents. Defaults to <option>port</option>; set it to
        443 when a reverse proxy publishes TLS there while MeshCentral listens
        on a high port.
      '';
    };

    redirPort = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = ''
        Port for the HTTP→HTTPS redirect listener. Set to 0 to disable the
        redirect listener entirely (e.g. when something else already owns :80).
      '';
    };

    cert = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "mesh.jupiter.au";
      description = ''
        Server name MeshCentral gives to agents and puts on its generated
        certificate (<literal>settings.cert</literal>) — a public DNS name, or
        a LAN address for a directly-TLS'd LAN-only instance. Leave null only
        to let MeshCentral fall back to its detected hostname.
      '';
    };

    tlsOffload = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.bool lib.types.str);
      default = null;
      example = "127.0.0.1";
      description = ''
        Trust a TLS-terminating proxy in front of MeshCentral. Set to the
        proxy's source address (the bare address, or <literal>true</literal> to
        trust any) and MeshCentral stops doing TLS itself, serving plain HTTP on
        <option>port</option>. Use the proxy's loopback address (e.g.
        <literal>127.0.0.1</literal>) for a proxy on the same host.
      '';
    };

    trustedProxy = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1";
      description = ''
        Addresses whose <literal>X-Forwarded-*</literal> headers are trusted
        when TLS is NOT offloaded (the proxy speaks HTTPS to MeshCentral).
        Distinct from <option>tlsOffload</option>; see the upstream config
        reference.
      '';
    };

    selfUpdate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow MeshCentral to update itself in place. Off by default — the
        running version is a Nix store path and self-update would fight it.
      '';
    };

    title = lib.mkOption {
      type = lib.types.str;
      default = "JupiterOS";
      description = ''
        Site title written into the default <option>domains</option> entry. Has
        no effect if <option>domains</option> is overridden.
      '';
    };

    certUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://mesh.jupiter.au/";
      description = ''
        Public URL agents validate the server certificate against
        (<literal>domains."".certUrl</literal>). Required when a proxy
        terminates TLS, otherwise agents reject the certificate. Written into
        the default <option>domains</option> entry; has no effect if
        <option>domains</option> is overridden.
      '';
    };

    domains = lib.mkOption {
      type = configFormat.type;
      default = {
        "" = {
          title = cfg.title;
        }
        // lib.optionalAttrs (cfg.certUrl != null) {
          certUrl = cfg.certUrl;
        };
      };
      defaultText = lib.literalExpression ''{ "" = { title = cfg.title; }; }'';
      description = ''
        The <literal>domains</literal> section of config.json, keyed by DNS
        domain (the empty key is the default domain). Set
        <literal>domains."".certUrl</literal> to the public URL agents should
        validate against when behind a proxy.
      '';
    };

    settings = lib.mkOption {
      type = configFormat.type;
      default = { };
      description = ''
        Extra keys merged into the config.json <literal>settings</literal>
        section (overriding the explicit options above on conflict). Initial
        config only — see the header note about first-boot generation.
      '';
    };

    extraConfig = lib.mkOption {
      type = configFormat.type;
      default = { };
      description = "Extra top-level config.json sections (e.g. <literal>smtp</literal>).";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/meshcentral/data";
      description = ''
        MeshCentral's data directory (<literal>--datapath</literal>): config,
        NeDB databases, certificates, and generated agent binaries. Lives under
        the unit's StateDirectory by default, so it is created and owned for the
        dynamic service user automatically.
      '';
    };

    filesDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/meshcentral/files";
      description = ''
        MeshCentral's file directory (<literal>--filespath</literal>): uploaded
        files and the transfer staging area.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open <option>port</option> and (when non-zero) <option>redirPort</option>
        in the firewall for the LAN. Off by default, so a deployment that fronts
        MeshCentral with its own proxy (or another host) chooses explicitly
        whether to also admit direct LAN traffic.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.jupiter-meshcentral = {
      description = "MeshCentral remote monitoring and management server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      preStart = ''
        if [ ! -e "${cfg.dataDir}/config.json" ]; then
          ${pkgs.coreutils}/bin/install -Dm600 ${configFile} "${cfg.dataDir}/config.json"
        fi
      '';

      serviceConfig = {
        Type = "simple";
        ExecStart = "${lib.getExe cfg.package} --datapath=${cfg.dataDir} --filespath=${cfg.filesDir}";
        WorkingDirectory = "/var/lib/meshcentral";
        Restart = "on-failure";
        RestartSec = "10s";

        DynamicUser = true;
        StateDirectory = "meshcentral";
        StateDirectoryMode = "0750";
        # Writable even if a host overrides dataDir/filesDir off the
        # StateDirectory: ProtectSystem=strict makes everything else read-only.
        ReadWritePaths = [
          cfg.dataDir
          cfg.filesDir
        ];

        # Node needs writable+executable memory (JIT), so unlike the Go
        # services this cannot use commonServiceHardening's stanza wholesale.
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      }
      // lib.optionalAttrs (cfg.port < 1024 || cfg.redirPort < 1024) {
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall (
      [ cfg.port ] ++ lib.optional (cfg.redirPort != 0) cfg.redirPort
    );
  };
}
