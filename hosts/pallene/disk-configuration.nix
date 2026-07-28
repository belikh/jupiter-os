{
  lib,
  config,
  pkgs,
  modulesPath,
  ...
}:

# Disk-bootable NixOS configuration for a Kamatera VPS build server.
# The raw disk image is built with nixos-generators (10 GB, ext4, BIOS/MBR)
# and uploaded to Kamatera's private image library via a public URL served
# by europa's vps-image-server + Cloudflare Tunnel.
#
# On first boot boot.growPartition auto-expands the root partition to fill
# whatever disk size the VPS was created with. This is stateless: the VPS
# can be destroyed and recreated from a fresh private image at any size.

{
  # No common.nix — this is a standalone VPS, not a fleet member.
  # No ZFS, no impermanence, no sops-nix, no disko, no ha-linux-agent.
  # Modules imported below are the minimal set for a functional build server.

  system.stateVersion = "26.05";
  networking.hostName = "pallene";
  time.timeZone = "Australia/Brisbane";

  # ---- Bootloader -----------------------------------------------------------
  # Kamatera uses BIOS/MBR with SATA disks, not virtio. The raw format module
  # defaults to /dev/vda (virtio), so we override to /dev/sda here.
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
    efiSupport = false;
    efiInstallAsRemovable = false;
  };
  boot.loader.timeout = 0;

  # Auto-expand root partition on first boot (matches any disk size).
  boot.growPartition = true;

  # Serial console for Kamatera's VNC console.
  boot.kernelParams = [ "console=ttyS0" ];

  # ---- filesystems ----------------------------------------------------------
  # Also set by nixos-generators' raw format when built through it.
  # Defined here so `nix flake check` (which evaluates this config standalone)
  # also passes.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };

  # ---- SSH ------------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICGxxtapYd7cY/NJjzTjdRQpuTKCs6jisSmKc5WfypZV forensic-analysis"
  ];

  # ---- Nix ------------------------------------------------------------------
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # ---- Packages -------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    jq
  ];

  nixpkgs.config.allowUnfree = true;
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # ---- Disk image (10 GB) ---------------------------------------------------
  # Override the raw format's auto-sized image (which evaluates disk usage at
  # build time and may produce a larger image than needed) with a fixed 10 GB.
  # After compression (xz -9), the actual transfer size is ~1-2 GB.
  system.build.raw = lib.mkForce (import "${toString modulesPath}/../lib/make-disk-image.nix" {
    inherit lib config pkgs;
    diskSize = 10240;
    format = "raw";
  });
}
