{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.pxe;
in
{
  # Pixiecore is an all-in-one tool that acts as a DHCP proxy and serves iPXE
  # to boot machines on the local network without interfering with the main
  # DHCP server. In "boot" mode it serves the kernel/initrd itself, so no
  # separate web server is needed.
  #
  # The kernel/initrd/cmdLine below are wired directly to callisto's
  # netboot build products in flake.nix (the only host that lives in this repo
  # and needs them), so the served image always matches the flake — there is no
  # manual "copy the artifacts into a webroot" step.
  options.jupiter.pxe = {
    enable = lib.mkEnableOption "Pixiecore netboot server for the diskless fleet";

    kernel = lib.mkOption {
      type = lib.types.str;
      description = "Path (nix store) or URL to the netboot kernel (bzImage).";
    };

    initrd = lib.mkOption {
      type = lib.types.str;
      description = "Path (nix store) or URL to the netboot initrd.";
    };

    cmdLine = lib.mkOption {
      type = lib.types.str;
      default = "loglevel=4";
      description = ''
        Kernel command line. For a NixOS netboot image this must include
        `init=<toplevel>/init` so the booted kernel finds its closure.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.pixiecore = {
      enable = true;
      openFirewall = true;
      mode = "boot";
      kernel = cfg.kernel;
      initrd = cfg.initrd;
      cmdLine = cfg.cmdLine;
    };
  };
}
