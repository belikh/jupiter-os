{ config, pkgs, ... }:

{
  # Libvirt configuration for running HAOS as a VM
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
      ovmf = {
        enable = true;
        packages = [ pkgs.OVMFFull.fd ];
      };
    };
  };

  # Create a network bridge so HAOS gets a real IP on the local network
  networking = {
    useDHCP = false;
    bridges.br0.interfaces = [ "eno1" ]; # Adjust 'eno1' to match the Lenovo's actual NIC
    interfaces.br0.useDHCP = true;
  };

  # Useful tools for managing the VM
  environment.systemPackages = with pkgs; [
    virt-manager
    libvirt
    qemu_kvm
  ];
}
