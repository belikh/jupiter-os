# Bootstrap installer ISO for thebe: minimal NixOS live CD with the admin
# SSH key pre-authorized and Wi-Fi configured, so nixos-anywhere can drive the install headless over Wi-Fi.
let
  flake = builtins.getFlake (toString /home/io/Projects/jupiter-os);
  nixpkgs = flake.inputs.nixpkgs;
  adminKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICGxxtapYd7cY/NJjzTjdRQpuTKCs6jisSmKc5WfypZV forensic-analysis";
  sys = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
      (
        { lib, ... }:
        {
          # Headless bring-up: SSH in as root or nixos with the admin key.
          services.openssh.enable = true;
          services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
          users.users.root.openssh.authorizedKeys.keys = [ adminKey ];
          users.users.nixos.openssh.authorizedKeys.keys = [ adminKey ];
          isoImage.isoName = lib.mkForce "thebe-bootstrap.iso";

          # Disable NetworkManager to avoid conflict with wpa_supplicant
          networking.networkmanager.enable = lib.mkForce false;

          # Wireless configuration for the USB Wi-Fi adapter (NetGear A6210 / MediaTek MT7612U)
          networking.wireless = {
            enable = true;
            networks = {
              "jupiter.au" = {
                psk = "lolcats66";
              };
            };
          };

          # Proprietary firmware for MediaTek USB Wi-Fi
          nixpkgs.config.allowUnfree = true;
          hardware.enableRedistributableFirmware = true;

          # Speed up ISO compilation by using gzip
          isoImage.squashfsCompression = "gzip";

          # Keep the build lean
          documentation.enable = false;
        }
      )
    ];
  };
in
sys.config.system.build.isoImage
