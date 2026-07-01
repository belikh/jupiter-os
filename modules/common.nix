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
    ./core/build-tuning.nix
    ./desktop/default.nix
    ./gaming/console.nix
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

  # Fleet-wide bootloader timeout. Left unset, NixOS's systemd-boot module
  # maps `null` to `"menu-force"` — always show the menu and wait forever for
  # a keypress, never auto-boot. Harmless on a desk with a monitor attached,
  # but every headless/remote/diskless host here (and any host recovering
  # from an unattended reboot with nobody physically present) would just hang
  # at the boot menu indefinitely. A few seconds is enough to interrupt by
  # hand if you're at the console, without meaningfully slowing anyone down.
  boot.loader.timeout = lib.mkDefault 3;

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

  # Make it easy to log into the VM for testing. io and root intentionally
  # share the same hardcoded hash below ("test") — this variant only ever
  # runs as an ephemeral local QEMU VM (`make test-<host>`), never deployed,
  # so a second hardcoded password would add no real security value, just an
  # extra literal to keep in sync.
  virtualisation.vmVariant = {
    # Test full bootloader (GRUB) in the VM instead of direct kernel boot.
    virtualisation.useBootLoader = true;
    virtualisation.diskSize = 4096; # Increase disk size to fit the full closure

    # Real hardware boots UEFI (disko's ESP is an EF00 UEFI System Partition;
    # jupiter.storage's zfs-profiles.nix defaults efiSupport/device to match).
    # Forcing legacy BIOS here instead (as this used to do) tests a completely
    # different, unsupported boot path: a GPT disk with no BIOS boot
    # partition, which is exactly what made every VM boot-test hang at
    # "Welcome to GRUB!" once CI got far enough to actually reach it. Setting
    # useEFIBoot makes qemu-vm.nix's own mkVMOverride point GRUB at "nodev"
    # for us — consistent with the real UEFI config, not fighting it.
    virtualisation.useEFIBoot = true;

    # With useBootLoader, the kernel is booted by the VM's own bootloader
    # reading its normal boot entries, not qemu-vm.nix's direct-kernel-boot
    # path — so `$QEMU_KERNEL_PARAMS`/`-append` never reaches it, only
    # `boot.kernelParams` baked into those entries does. Without this, only
    # OVMF/systemd-boot's own firmware-level serial writes ever reach
    # scripts/boot-smoke.sh's captured log; the kernel boots (or hangs)
    # completely invisibly to it, making every past boot-test result a guess.
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

  # Nix Basics
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Pull CPU-tuned closures from europa's attic cache (the "rebuild the
  # world" BinaryLane build server, see docs/roadmap.md) ahead of
  # cache.nixos.org's generic baseline. Listed now so every host is ready the
  # moment the cache has real content — but the trusted-public-keys entry
  # below is a REPLACE-ME placeholder until `attic cache create jupiter-os`
  # is actually run on europa and its real public key is retrieved (`attic
  # cache info jupiter-os`); an untrusted/invalid key just means Nix silently
  # skips this substituter and falls back to cache.nixos.org, so this is safe
  # to carry as-is until then.
  nix.settings.substituters = lib.mkBefore [ "https://attic.jupiter.au/jupiter-os" ];
  nix.settings.trusted-public-keys = lib.mkBefore [
    "jupiter-os:REPLACE-ME-once-attic-cache-create-has-run-on-europa="
  ];

  # Friendly nudge, not a hard assertion — an unreplaced placeholder key just
  # means Nix skips this substituter, so it must not block `nix build` /
  # `nix flake check` / CI (same reasoning as the storage.disk REPLACE-ME
  # warning in modules/storage/zfs-profiles.nix).
  warnings = lib.optional (lib.any (lib.hasInfix "REPLACE-ME") config.nix.settings.trusted-public-keys) ''
    modules/common.nix's attic trusted-public-keys is still the REPLACE-ME
    placeholder on host "${config.networking.hostName}" — run
    `attic cache create jupiter-os` on europa, then `attic cache info
    jupiter-os` to get the real key (see docs/roadmap.md).
  '';

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
}
