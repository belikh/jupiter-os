{
  config,
  lib,
  pkgs,
  ...
}:

# HAOS guest host — G-E rung of the Jupiter Quarters overhaul (spec §7.2).
#
# callisto is the spec's designated landing zone for the green world: ONE
# hypervisor boundary on the fleet's ONE serving host, while the legacy
# lenovo box keeps serving until the G-F switch. This module enables the
# HOST layer only — libvirt + KVM + OVMF. The guest itself is defined
# imperatively (virsh define; domain XML authored per run-card) so the
# S/P/F/C ladder transitions never couple to a host rebuild.
#
# Extraction lane (no Proxmox tooling on this host): the G-B archive is a
# .vma.zst — VMA is a Proxmox-patched-qemu format, so extraction outside
# Proxmox uses the single-file Zlib-licensed python tool vendored in the
# ha-strategy repo (tools/vma.py, from jancc/vma-extractor). The VMA's
# disk-images come out as sparse RAW; HAOS's data partition is plain ext4
# (hassos-data), so pre-boot .storage edits (MQTT disable, cloudflared
# autostart off) are losetup+mount, no libguestfs.
#
# Day-0 shadow network: libvirt's DEFAULT NAT net (virbr0) — the guest can
# reach the internet but MUST NOT reach the LAN broker/perimeter before
# its .storage is sanitised (duplicate MQTT discovery + a second
# cloudflared connector would both corrupt the live estate).
#
# Sizing [OJ spec §7.2]: 4 vCPU / 6 GiB guest (lenovo's VM 100 proved the
# workload for years at 2 cores / 5,184 MB). Images on LOCAL disk, never
# the iSCSI root, so guest I/O cannot couple to europa.
let
  cfg = config.jupiter.services.haosGuestHost;
in
{
  options.jupiter.services.haosGuestHost = {
    enable = lib.mkEnableOption "libvirt + KVM + OVMF substrate for the HAOS guest (G-E)";

    imagesDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/libvirt/images";
      description = "Where guest disks live (local disk, NOT the iSCSI root).";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.libvirtd = {
      enable = true;
      # Guest lifecycle is operator/run-card driven — never boot-coupled:
      # a callisto reboot leaves the guest OFF until the run-card starts it.
      onBoot = "ignore";
      onShutdown = "shutdown";
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = true;
        verbatimConfig = ''
          # HAOS is an OVMF/UEFI guest (GPT); NixOS's module wires OVMF
          # paths for libvirt automatically when the package is present.
        '';
      };
    };

    environment.systemPackages = with pkgs; [
      OVMF # UEFI firmware payloads for the guest
      libvirt # virsh CLI (domain define/start/console for run-cards)
    ];

    boot.kernelModules = [
      "kvm_intel" # hardware virt (callisto: 6-core i5, vmx confirmed)
      "tun" # tap devices for later G-F LAN bridge attach
    ];

    # Images dir on local disk (created if absent)
    systemd.tmpfiles.rules = [ "d ${cfg.imagesDir} 0755 root root -" ];

    # The default NAT network's guests are LAN-untrusted-but-contained;
    # libvirt manages its own filtering — no host firewall rules for virbr0
    # admin traffic (this matches how every NixOS libvirt host runs).
    networking.firewall.trustedInterfaces = [ "virbr0" ];
  };
}
