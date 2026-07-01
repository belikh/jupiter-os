{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./core/impermanence.nix
    ./core/scheduler.nix
    ./desktop/default.nix
    ./gaming/bazzite.nix
    ./storage/zfs-profiles.nix
    ./storage/backup.nix
    ./services/syncthing.nix
    ./services/ha-agent.nix
    ./core/branding.nix
    ./home
  ];

  # Common configuration applied to all hosts.
  # Branding (GRUB Fallout theme, MOTD) is opt-in per host — see the hosts that
  # set jupiter.branding.enable. It is intentionally NOT enabled fleet-wide so
  # headless/netboot hosts don't have to force it back off.

  nixpkgs.config.allowUnfree = true;

  # Fleet-wide kernel default: CachyOS (chaotic-nyx) on every host except the
  # NAS (europa), which stays on plain linuxPackages to keep the backup hub
  # boring and well-tested (see hosts/europa/configuration.nix override).
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_cachyos;

  # Baseline admin tooling, present on every host (headless or not). Desktop and
  # per-host modules layer their own packages on top of this.
  environment.systemPackages = with pkgs; [
    git
    htop
    ripgrep
    fd
    jq
    fzf
    bat
    eza
    wget
    curl
    unzip
  ];

  system.stateVersion = "26.05";
  time.timeZone = "Australia/Brisbane";

  # Safer ZFS default (becomes the default in 26.11). NAS overrides explicitly.
  boot.zfs.forceImportRoot = lib.mkDefault false;

  # Everything uses OUR resolver (ganymede, 10.1.1.20). No public fallback, so
  # a leak can't bypass it. The resolver host overrides this to 127.0.0.1.
  networking.nameservers = lib.mkDefault [ "10.1.1.20" ];

  # SSH & Users
  services.openssh.enable = true;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # All secrets live in the one repo-level sops file; set it once here so
  # individual secret declarations don't have to repeat sopsFile.
  sops.defaultSopsFile = ../secrets/secrets.yaml;

  sops.secrets.io_password = {
    neededForUsers = true;
  };

  users.users.io = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    hashedPasswordFile = config.sops.secrets.io_password.path;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICGxxtapYd7cY/NJjzTjdRQpuTKCs6jisSmKc5WfypZV forensic-analysis"
    ];
  };

  # Make it easy to log into the VM for testing
  virtualisation.vmVariant = {
    # Test full bootloader (GRUB) in the VM instead of direct kernel boot
    virtualisation.useBootLoader = true;
    virtualisation.diskSize = 4096; # Increase disk size to fit the full closure

    # The NixOS VM disk builder uses a legacy BIOS MBR partition table by default
    boot.loader.grub = {
      efiSupport = lib.mkForce false;
      device = lib.mkForce "/dev/vda";
    };

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
