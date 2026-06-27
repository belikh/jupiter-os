{ config, pkgs, lib, ... }:

{
  imports = [
    ./core/impermanence.nix
    ./desktop/default.nix
    ./storage/zfs-impermanent.nix
    ./services/syncthing.nix
    ./branding.nix
  ];

  # Common configuration applied to all hosts
  jupiter.branding.enable = true;

  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "24.05";
  time.timeZone = "Australia/Brisbane";

  # Safer ZFS default (becomes the default in 26.11). NAS overrides explicitly.
  boot.zfs.forceImportRoot = lib.mkDefault false;

  # Everything uses OUR resolver (lenovo, 10.1.1.20). No public fallback, so a
  # leak can't bypass it. The resolver host overrides this to 127.0.0.1.
  networking.nameservers = lib.mkDefault [ "10.1.1.20" ];

  # SSH & Users
  services.openssh.enable = true;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

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

  # Make it easy to log into the VM for testing
  virtualisation.vmVariant = {
    users.users.io = {
      hashedPasswordFile = lib.mkForce null;
      password = lib.mkForce null;
      initialHashedPassword = lib.mkForce null;
      hashedPassword = "$6$R3/so5inPSNTcI7n$/K9cml/ZTsJFoVOfcJh6Hug8lOmFK1CU8czgmMYUa3sl883t1Dmhlkl23ENUYACyTOZNRErj4yVJd1ND.wuEq.";
    };
    users.users.root = {
      hashedPasswordFile = lib.mkForce null;
      password = lib.mkForce null;
      initialHashedPassword = lib.mkForce null;
      hashedPassword = "$6$R3/so5inPSNTcI7n$/K9cml/ZTsJFoVOfcJh6Hug8lOmFK1CU8czgmMYUa3sl883t1Dmhlkl23ENUYACyTOZNRErj4yVJd1ND.wuEq.";
    };
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
