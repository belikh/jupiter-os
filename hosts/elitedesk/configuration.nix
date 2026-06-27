{
  config,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
    ../../modules/common.nix
    ../../modules/headscale.nix
  ];

  networking.hostName = "elitedesk";

  # Ensure the image is fully copied to RAM on boot
  boot.kernelParams = [ "copytoram" ];

  # Diskless compute node: persists DB + Loki to the NAS over iSCSI.
  # Auto-discovers and logs into the NAS target at boot, attaching the LUNs as
  # local block devices (e.g. /dev/disk/by-path/...-iscsi-...:nas.target0-lun-0).
  # TODO: set discoverPortal to the NAS's pinned static LAN IP once networking
  # is finalised (placeholder 10.1.1.10). First-time only: mkfs each LUN, then
  # mount where the DB/Loki services expect their data.
  services.openiscsi = {
    enable = true;
    name = "iqn.2026-06.au.jupiter:elitedesk"; # matches the NAS ACL
    enableAutoLoginOut = true;
    discoverPortal = "10.1.1.10:3260";
  };
}
