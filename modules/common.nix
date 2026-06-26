{ config, pkgs, ... }:

{
  # Common configuration applied to all hosts

  system.stateVersion = "24.05";
  time.timeZone = "Australia/Brisbane";

  # SSH & Users
  services.openssh.enable = true;

  sops.secrets.io_password = {
    sopsFile = ../secrets/secrets.yaml;
    neededForUsers = true;
  };

  users.users.io = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "docker"
    ];
    hashedPasswordFile = config.sops.secrets.io_password.path;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICGxxtapYd7cY/NJjzTjdRQpuTKCs6jisSmKc5WfypZV forensic-analysis"
    ];
  };

  # Nix Basics
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
