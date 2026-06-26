{ config, pkgs, ... }:

{
  # Pixiecore is an all-in-one tool that acts as a DHCP proxy and serves iPXE 
  # to boot machines on the local network without interfering with your main DHCP server.
  services.pixiecore = {
    enable = true;
    openFirewall = true;
    mode = "boot";
    
    # We point these to the built artifacts of the elitedesk and dashboards configurations
    kernel = "http://10.1.1.20/netboot/bzImage";
    initrd = "http://10.1.1.20/netboot/initrd";
    cmdLine = "init=/init loglevel=4 copytoram";
  };

  # Use Nginx to quickly serve the large kernel and initrd files to booting machines
  services.nginx = {
    enable = true;
    virtualHosts."default" = {
      root = "/var/www/netboot";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
