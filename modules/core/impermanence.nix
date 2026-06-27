{ config, pkgs, lib, inputs, ... }:

with lib;
let
  cfg = config.jupiter.core.impermanence;
in
{
  imports = [
    inputs.impermanence.nixosModules.impermanence
  ];

  options.jupiter.core.impermanence = {
    enable = mkEnableOption "Enable impermanence (erase your darlings)";
    persistPath = mkOption {
      type = types.str;
      default = "/persist";
      description = "The path where persistent state is kept.";
    };
  };

  config = mkIf cfg.enable {
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
      ];
      files = [
        "/etc/machine-id"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
      ];
      # Persist user files for the primary admin account
      users.io = {
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
    };
  };
}
