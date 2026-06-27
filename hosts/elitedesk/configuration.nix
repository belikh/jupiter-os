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
  # local block devices. First-time only: mkfs each LUN, then mount where the
  # DB/Loki services expect their data.
  services.openiscsi = {
    enable = true;
    name = "iqn.2026-06.au.jupiter:elitedesk"; # matches the NAS ACL
    enableAutoLoginOut = true;
    discoverPortal = "nas.home.jupiter.au:3260";
  };

  # Static hosts entry so the boot-time iSCSI attach doesn't race the resolver
  # coming up (the NAS target must resolve before openiscsi logs in).
  networking.hosts."10.1.1.2" = [ "nas.home.jupiter.au" ];
}
