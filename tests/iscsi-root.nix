# iSCSI root on a systemd stage-1 initrd, through jupiter.boot.iscsiRoot
# (modules/boot/iscsi-root.nix). Adapted from nixpkgs PR #545932's
# iscsi-root-systemd test; differences from the PR: the device under test is
# the vendored module, addressing is DHCP with a 2-minute lease (callisto's
# shape: initrd DHCP, then stage-2 networkd renewal), and the script outlives
# the lease to prove the root session survives renewal.
#
# `target` exports a block device over iSCSI, `initiatorAuto` installs a NixOS
# system onto it, and `initiatorRootDisk` (whose initrd is a systemd initrd)
# boots with that iSCSI LUN as its root filesystem.
{ pkgs, lib, ... }:
let
  initiatorName = "iqn.2020-08.org.linux-iscsi.initiatorhost:example";
  targetName = "iqn.2003-01.org.linux-iscsi.target.x8664:sn.acf8fd9c23af";
in
{
  name = "iscsi-root";
  meta.maintainers = with lib.maintainers; [
    sochotnicky
  ];

  nodes = {
    target =
      {
        config,
        pkgs,
        lib,
        ...
      }:
      {
        services.target = {
          enable = true;
          config = {
            fabric_modules = [ ];
            storage_objects = [
              {
                dev = "/dev/vdb";
                name = "test";
                plugin = "block";
                write_back = true;
                wwn = "92b17c3f-6b40-4168-b082-ceeb7b495522";
              }
            ];
            targets = [
              {
                fabric = "iscsi";
                tpgs = [
                  {
                    enable = true;
                    attributes = {
                      authentication = 0;
                      generate_node_acls = 1;
                    };
                    luns = [
                      {
                        alias = "94dfe06967";
                        alua_tg_pt_gp_name = "default_tg_pt_gp";
                        index = 0;
                        storage_object = "/backstores/block/test";
                      }
                    ];
                    node_acls = [
                      {
                        mapped_luns = [
                          {
                            alias = "d42f5bdf8a";
                            index = 0;
                            tpg_lun = 0;
                            write_protect = false;
                          }
                        ];
                        node_wwn = initiatorName;
                      }
                    ];
                    portals = [
                      {
                        ip_address = "[::]";
                        iser = false;
                        offload = false;
                        port = 3260;
                      }
                    ];
                    tag = 1;
                  }
                ];
                wwn = targetName;
              }
            ];
          };
        };

        networking.firewall.allowedTCPPorts = [ 3260 ];
        networking.firewall.allowedUDPPorts = [
          3260
          67
        ];

        # DHCP for the initiator on the test vlan, 2-minute leases (dnsmasq's
        # minimum) so the script can run past T1 renewal and lease expiry.
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            port = 0;
            interface = "eth1";
            bind-interfaces = true;
            dhcp-authoritative = true;
            dhcp-range = "192.168.1.100,192.168.1.150,255.255.255.0,2m";
          };
        };

        virtualisation.memorySize = 2048;
        virtualisation.emptyDiskImages = [ 2048 ];
      };

    initiatorAuto =
      {
        nodes,
        config,
        pkgs,
        ...
      }:
      {
        services.openiscsi = {
          enable = true;
          enableAutoLoginOut = true;
          discoverPortal = "target";
          name = initiatorName;
        };

        environment.systemPackages = with pkgs; [
          xfsprogs
        ];

        system.extraDependencies = [ nodes.initiatorRootDisk.system.build.toplevel ];

        nix.settings = {
          substituters = lib.mkForce [ ];
          hashed-mirrors = null;
          connect-timeout = 1;
        };
      };

    initiatorRootDisk =
      {
        nodes,
        config,
        pkgs,
        modulesPath,
        lib,
        ...
      }:
      {
        imports = [ ../modules/boot/iscsi-root.nix ];

        boot.loader.grub.enable = false;

        boot.kernelParams = lib.mkOverride 5 [
          "boot.shell_on_fail"
          "console=tty1"
          # Same kernel parameter callisto's PXE entry passes.
          "ip=dhcp"
        ];

        # defaults to true, puts some code in the initrd that tries to mount an overlayfs on /nix/store
        virtualisation.writableStore = false;

        fileSystems = lib.mkOverride 5 {
          "/" = {
            fsType = "xfs";
            device = "/dev/sda";
            options = [ "_netdev" ];
          };
        };

        jupiter.boot.iscsiRoot = {
          enable = true;
          # No initrd DNS, so point at the target's IP rather than its hostname.
          discoverPortal = "${nodes.target.networking.primaryIPAddress}:3260";
          name = initiatorName;
          target = targetName;
          # The test vlan-1 NIC's MAC (qemu-common.qemuNicMac vlan node).
          mac =
            (pkgs.callPackage "${modulesPath}/../lib/qemu-common.nix" { }).qemuNicMac 1
              config.virtualisation.test.nodeNumber;
        };
      };
  };

  testScript =
    { nodes, ... }:
    ''
      target.start()
      target.wait_for_unit("iscsi-target.service")

      initiatorAuto.start()

      initiatorAuto.wait_for_unit("iscsid.service")
      initiatorAuto.wait_for_unit("iscsi.service")
      initiatorAuto.get_unit_info("iscsi")

      initiatorAuto.succeed("set -x; while ! test -e /dev/sda; do sleep 1; done")

      initiatorAuto.succeed("mkfs.xfs /dev/sda")
      initiatorAuto.succeed("mkdir /mnt && mount /dev/sda /mnt")
      initiatorAuto.succeed(
          "nixos-install --no-bootloader --no-root-passwd --system ${nodes.initiatorRootDisk.system.build.toplevel}"
      )
      initiatorAuto.succeed("umount /mnt && rmdir /mnt")
      initiatorAuto.shutdown()

      # Boot the systemd-stage-1 machine off its iSCSI root.
      initiatorRootDisk.start()
      initiatorRootDisk.wait_for_unit("multi-user.target")
      initiatorRootDisk.wait_for_unit("iscsid")
      # Confirm we are really running off the network disk.
      initiatorRootDisk.succeed("test \"$(findmnt -no SOURCE /)\" = /dev/sda")
      initiatorRootDisk.succeed("touch /test")

      # The initiator got its address from DHCP in the initrd and renews it in
      # stage 2. Run past the 2-minute lease: if nothing renewed it, the
      # address would expire and the root session would die with it.
      initiatorRootDisk.succeed("ip -4 addr | grep -q 'inet 192.168.1.1'")
      initiatorRootDisk.succeed("iscsiadm -m session")
      initiatorRootDisk.sleep(200)
      initiatorRootDisk.succeed("ip -4 addr | grep -q 'inet 192.168.1.1'")
      initiatorRootDisk.succeed("iscsiadm -m session")
      initiatorRootDisk.succeed("touch /after-lease && sync")

      # Restarting networkd must not drop the address that carries /.
      initiatorRootDisk.succeed("systemctl restart systemd-networkd")
      initiatorRootDisk.sleep(5)
      initiatorRootDisk.succeed("ip -4 addr | grep -q 'inet 192.168.1.1'")
      initiatorRootDisk.succeed("touch /after-networkd-restart && sync")
      initiatorRootDisk.shutdown()
    '';
}
