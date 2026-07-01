{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.jupiter.core.impermanence;
in
{

  options.jupiter.core.impermanence = {
    enable = lib.mkEnableOption "Enable impermanence (erase your darlings)";
    persistPath = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      description = "The path where persistent state is kept.";
    };
    persistAdminHome = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Persist the primary admin account (io)'s home directories. Turn off on
        appliance hosts (e.g. kiosks) that have no personal session and only
        need to persist a service account's state via `users` below.
      '';
    };
    extraDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Host-specific system directories to persist.";
    };
    extraFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Host-specific system files to persist.";
    };
    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            directories = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            files = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          };
        }
      );
      default = { };
      description = ''
        Extra per-user home paths to persist (relative to the user's home),
        e.g. a kiosk account's browser profile. Merged with the admin account
        when persistAdminHome is on.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Map essential system files and directories from the persistent store
    environment.persistence."${cfg.persistPath}" = {
      hideMounts = true;
      directories = [
        "/var/log"
        "/var/lib/nixos"
        "/var/lib/systemd/coredump"
        "/var/lib/libvirt"
        "/etc/NetworkManager/system-connections"
        "/var/lib/sops-nix" # Essential for secret decryption after reboot
      ]
      ++ cfg.extraDirectories;
      files = [
        "/etc/machine-id"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
      ]
      ++ cfg.extraFiles;
      # Persist the primary admin account's home (unless this is an appliance),
      # merged with any host-specific service accounts in `users`.
      users =
        (lib.optionalAttrs cfg.persistAdminHome {
          io = {
            directories = [
              "Downloads"
              "Music"
              "Pictures"
              "Documents"
              "Videos"
              "Projects"
              ".config"
              ".ssh"
              ".local/share/keyrings"
              ".local/share/direnv"
              ".gemini"
              ".claude"
            ];
            files = [
              ".bash_history"
            ];
          };
        })
        // cfg.users;
    };
  };
}
