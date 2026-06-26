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
}
