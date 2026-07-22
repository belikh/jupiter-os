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
    ./core/antigravity-cli.nix
    ./core/ecc.nix
    ./core/zed.nix
    ./boot/fallout-splash.nix
    ./core/build-tuning.nix
    ./core/build-machines.nix
    ./core/attic-substituter.nix
    ./core/branding.nix
    ./storage/zfs-profiles.nix
  ];

  # Dev/agent tooling — default-on for the bootstrap so the admin has them on
  # the live host (amalthea), but mkDefault so appliance hosts (NAS, kiosks)
  # that never run interactive dev sessions can opt out per-host.
  jupiter.core.ecc.enable = lib.mkDefault true;
  jupiter.core.zed.enable = lib.mkDefault true;
  jupiter.core.antigravity.enable = lib.mkDefault true;
  jupiter.core.branding.enable = true;

  nixpkgs.config.allowUnfree = true;
  hardware.enableRedistributableFirmware = lib.mkDefault true;

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

  # Passwordless root in the initrd's emergency shell only (never the real
  # system — root stays locked there). Without this, a boot-time failure
  # (e.g. a ZFS import that needs manual intervention) drops to a completely
  # inaccessible "root account is locked" prompt, since the initrd is a
  # separate minimal environment that never shares the real system's
  # /etc/shadow — confirmed the hard way bringing up amalthea, where a ZFS
  # import failure was undebuggable without this. On fleet-wide by default;
  # flip to `false` here to disable everywhere, or override per-host with a
  # plain (non-mkDefault) assignment in that host's configuration.nix.
  boot.initrd.systemd.emergencyAccess = lib.mkDefault true;

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

  # Root also trusts callisto's own key (not just io's): callisto is the
  # fleet's nixos-rebuild coordinator for tuned hosts (europa's --build-host
  # is callisto, and --target-host needs root@<host> to actually land the
  # closure) — discovered missing during europa's first successful full
  # closure build, which built everything correctly then failed at the very
  # last "copy to target" step with a bare "Host key verification failed" /
  # "Permission denied", since callisto had never been added here.
  users.users.root.openssh.authorizedKeys.keys = config.users.users.io.openssh.authorizedKeys.keys ++ [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGDIfzWbqrIXRa3cxN15nk5kn57EyYuDP9JsJWrW2hPu root@callisto"
  ];

  # Make it easy to log into the VM for testing (`make test-<host>` /
  # scripts/boot-smoke.sh). io and root intentionally share the same hardcoded
  # hash ("test") — this variant only ever runs as an ephemeral local QEMU VM,
  # never deployed.
  virtualisation.vmVariant = {
    # The Fallout splash is pointless in the headless serial QEMU VM (no
    # display to render to) and just bloats the initrd, so force it off for
    # `make test-<host>` / boot-smoke runs.
    jupiter.boot.falloutSplash.enable = lib.mkForce false;
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
