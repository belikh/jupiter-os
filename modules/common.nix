{
  config,
  pkgs,
  lib,
  ...
}:

# Base layer shared by every host. Kept deliberately boring for the bootstrap:
# the stock nixpkgs kernel (cached, ZFS-supported), no custom substituters, no
# opt-in fleet features. Fleet-wide toggles return here as the machines that
# need them are brought back up.
{
  imports = [
    ./core/impermanence.nix
    ./storage/zfs-profiles.nix
  ];

  nixpkgs.config.allowUnfree = true;

  # Baseline admin tooling, present on every host (headless or not).
  environment.systemPackages = with pkgs; [
    git
    htop
    ripgrep
    fd
    jq
    wget
    curl
  ];

  system.stateVersion = "26.05";
  time.timeZone = "Australia/Brisbane";

  # UEFI systemd-boot everywhere by default. (The old tree layered GRUB +
  # branding on some hosts; that returns as an opt-in module later.)
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Left unset, systemd-boot maps `null` to "menu-force" — wait forever at the
  # boot menu. Never what an appliance or headless host wants after an
  # unattended reboot.
  boot.loader.timeout = lib.mkDefault 3;

  # Force-import the root pool in initrd. These are single-disk appliances
  # with no shared/multipath storage, so the split-brain protection that
  # forceImportRoot=false buys is irrelevant here — but it DOES break the
  # first boot after a nixos-anywhere install: disko creates rpool under the
  # installer's hostId, and on first boot the host's own hostId differs, so
  # ZFS refuses the import without -f. Forcing it is safe and lets a fresh
  # install boot unattended. (After the first import under the host's own
  # hostId, subsequent boots match anyway.)
  boot.zfs.forceImportRoot = lib.mkDefault true;

  # DNS comes from DHCP (the UDM gateway) during the bootstrap phase — the
  # ganymede resolver doesn't exist yet. When it's brought back up, pin
  # networking.nameservers here again.

  # SSH & Users
  services.openssh.enable = true;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # All secrets live in the one repo-level sops file; set it once here so
  # individual secret declarations don't have to repeat sopsFile.
  sops.defaultSopsFile = ../secrets/secrets.yaml;

  # sops secrets are read at ACTIVATION time, not build time — `nix build`
  # and CI work without the age key.
  sops.secrets.io_password = {
    neededForUsers = true;
  };

  users.users.io = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPasswordFile = config.sops.secrets.io_password.path;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICGxxtapYd7cY/NJjzTjdRQpuTKCs6jisSmKc5WfypZV forensic-analysis"
    ];
  };

  # Make it easy to log into the VM for testing (`make test-<host>` /
  # scripts/boot-smoke.sh). io and root intentionally share the same hardcoded
  # hash ("test") — this variant only ever runs as an ephemeral local QEMU VM,
  # never deployed.
  virtualisation.vmVariant = {
    # Test the full UEFI bootloader path in the VM instead of direct kernel
    # boot — matches real hardware (disko's ESP is an EF00 UEFI System
    # Partition). Forcing legacy BIOS here would test a GPT disk with no BIOS
    # boot partition, which hangs at the bootloader.
    virtualisation.useBootLoader = true;
    virtualisation.useEFIBoot = true;
    virtualisation.diskSize = 4096;

    # With useBootLoader, only kernelParams baked into the boot entries reach
    # the kernel — this is what makes boot output visible to
    # scripts/boot-smoke.sh's captured serial log.
    boot.kernelParams = [ "console=ttyS0" ];

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

  # Nix basics
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
