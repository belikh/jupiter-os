{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.jupiter.services.syncthing;
in
{
  options.jupiter.services.syncthing = {
    enable = mkEnableOption "Enable Syncthing for user io";

    dataDir = mkOption {
      type = types.str;
      default = "/home/io";
      description = ''
        Base directory for Syncthing's data, config/index, and the default
        location for new folders. On personal machines this is io's home
        (/home/io). On the NAS hub set it to a path on protected storage
        (e.g. /tank/personal) so the canonical synced copy is redundant,
        snapshotted, and in the offsite path — not stranded on the OS disk.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.syncthing = {
      enable = true;
      user = "io";
      dataDir = cfg.dataDir;
      configDir = "${cfg.dataDir}/.config/syncthing";
      overrideDevices = false; # Let the user manage devices via WebUI to avoid hardcoding IDs
      overrideFolders = false; # Let the user manage folders via WebUI
      guiAddress = "0.0.0.0:8384"; # Bind to all interfaces so you can access the UI over Headscale/LAN
    };

    # Open firewall for syncthing discovery, transfers, and GUI
    networking.firewall.allowedTCPPorts = [
      8384
      22000
    ];
    networking.firewall.allowedUDPPorts = [
      22000
      21027
    ];

    # Create a safe .stignore template at the sync root (the home dir on personal
    # machines, or the protected data path on the hub). Enables "Full Homedir
    # Syncing" without blowing up the database with cache/locks.
    system.activationScripts.syncthingIgnore = ''
            if [ ! -f ${cfg.dataDir}/.stignore ]; then
              cat << 'EOF' > ${cfg.dataDir}/.stignore
      # --- JUPITER OS HOMEDIR SYNC RULES ---

      # 1. Explicitly ignore high-churn/stateful directories that break if synced
      .cache
      .local/share
      .config
      .ssh
      .gnupg
      .mozilla
      .thunderbird
      .nix-profile
      .nix-defexpr
      .bash_history
      .Xauthority

      # 2. Ignore massive project build outputs
      node_modules
      target
      result

      # 3. Explicitly INCLUDE the AI brains we want to sync (must come before the .* rule)
      !.gemini
      !.claude

      # 4. Ignore all other hidden files/folders (prevents dotfile conflicts across machines)
      .*
      EOF
              chown io:users ${cfg.dataDir}/.stignore
            fi
    '';
  };
}
