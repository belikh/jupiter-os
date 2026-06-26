{ config, pkgs, modulesPath, ... }:

{
  # Import the standard NixOS netboot minimal profile
  # This configures the system to run entirely from RAM (tmpfs)
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
    ../../modules/headscale.nix
    
    # Given its 64GB of RAM, this is a prime candidate to run the heavy lifting!
    # ../../modules/home-assistant-vm.nix
    # ../../modules/n8n.nix
  ];

  networking.hostName = "elitedesk";
  system.stateVersion = "24.05";

  # Ensure the image is fully copied to RAM on boot
  boot.kernelParams = [ "copytoram" ];

  # Setup standard SSH access for a netbooted environment
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... io@jupiter.au"
  ];
}
