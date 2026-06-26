{ pkgs, ... }:

{
  # Libvirt configuration for running HAOS as a VM
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
    };
  };

  # Network bridge configuration is explicitly left to the host machine configuration
  # to avoid NIC name mismatch lockouts.

  # Useful tools for managing the VM
  environment.systemPackages = with pkgs; [
    virt-manager
    libvirt
    qemu_kvm
  ];
}
