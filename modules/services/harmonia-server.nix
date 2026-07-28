{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.harmonia;
in
{
  options.jupiter.services.harmonia = {
    enable = lib.mkEnableOption "the Harmonia binary cache server (replaces atticd)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port Harmonia listens on.";
    };

    signKeyPath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the Harmonia signing key (generated via
        nix-store --generate-binary-cache-key). Set via sops.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # If using SOPS secrets, uncomment the following line and declare
    # harmonia_sign_key in secrets/secrets.yaml.
    # sops.secrets.harmonia_sign_key = { };

    users.users.harmonia = {
      isSystemUser = true;
      group = "harmonia";
      home = "/var/lib/harmonia";
    };
    users.groups.harmonia = { };

    systemd.services.harmonia = {
      description = "Harmonia Nix binary cache";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "harmonia";
        Group = "harmonia";
        ExecStart = "${pkgs.harmonia}/bin/harmonia-cache";
        Restart = "on-failure";
        StateDirectory = "harmonia";
        RuntimeDirectory = "harmonia";
      };
    };

    systemd.services.harmonia.environment = lib.mkIf (cfg.signKeyPath != null) {
      SIGN_KEY_PATHS = cfg.signKeyPath;
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
