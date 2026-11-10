{
  config,
  lib,
  pkgs,
  ...
}:

# iSCSI root for a systemd stage 1 initrd.
#
# Vendored and adapted from nixpkgs PR #545932 (sochotnicky, closed unmerged):
# nixpkgs removed boot.iscsi-initiator together with the scripted initrd
# (NixOS/nixpkgs#573038, 26.11), and the old option name is now a
# mkRemovedOptionModule stub, so this module lives under jupiter.boot.iscsiRoot.
#
# The initrd runs iscsid and the target login as real units, ordered
#   network-online.target -> iscsid -> iscsi-login
#     -> initrd-root-device.target -> sysroot.mount
# Initrd networking is boot.initrd.network.enable (systemd-networkd in the
# initrd). Its address stays on the NIC across switch-root because nixpkgs
# defaults initrd networks to KeepConfiguration=dhcp-on-stop.
#
# Stage 2 keeps iscsid (services.openiscsi) so the kernel session that carries
# / can recover from a dropped connection. `nic` optionally gives stage-2
# networkd a matching DHCP .network so the lease is renewed; without it the NIC
# is unmanaged after switch-root and the address expires with the lease.

let
  cfg = config.jupiter.boot.iscsiRoot;

  # Static iscsid.conf: upstream default plus extraConfig. A normal derivation
  # avoids import-from-derivation.
  iscsidConf = pkgs.runCommand "iscsid-initrd.conf" { } ''
    cat ${pkgs.openiscsi}/etc/iscsi/iscsid.conf > "$out"
    cat >> "$out" <<'EOF'

    ${lib.optionalString (cfg.extraConfig != null) cfg.extraConfig}
    EOF
  '';

  # Assemble /etc/iscsi/{iscsid.conf,initiatorname.iscsi} in the initrd's
  # writable /etc before iscsid starts.
  prepConf = pkgs.writeShellScript "iscsi-initrd-prep" ''
    set -eu
    mkdir -p /etc/iscsi /run/lock/iscsi
    cp ${iscsidConf} /etc/iscsi/iscsid.conf
    chmod +w /etc/iscsi/iscsid.conf
    echo "InitiatorName=${cfg.name}" > /etc/iscsi/initiatorname.iscsi
  '';

  # Discover the portal and log into the root target. Retried because iscsid
  # may not have opened its socket the instant this unit starts.
  loginScript = pkgs.writeShellScript "iscsi-root-login" ''
    set -eu
    discover() {
      ${pkgs.openiscsi}/bin/iscsiadm -m discovery -t sendtargets \
        -p ${lib.escapeShellArg cfg.discoverPortal} --debug ${toString cfg.logLevel} || true
    }
    discover
    n=0
    until ${pkgs.openiscsi}/bin/iscsiadm -m node \
        -T ${lib.escapeShellArg cfg.target} \
        -p ${lib.escapeShellArg cfg.discoverPortal} --login; do
      n=$((n + 1))
      if [ "$n" -ge ${toString cfg.loginAttempts} ]; then
        echo "iscsi-root-login: giving up after $n attempts" >&2
        exit 1
      fi
      sleep 1
      discover
    done
  '';
in
{
  options.jupiter.boot.iscsiRoot = {
    enable = lib.mkEnableOption "root filesystem over iSCSI, logged in from the systemd initrd";

    name = lib.mkOption {
      type = lib.types.str;
      example = "iqn.2026-07.au.jupiter:callisto";
      description = "Initiator IQN. Must match the node ACL on the target.";
    };

    discoverPortal = lib.mkOption {
      type = lib.types.str;
      example = "10.1.1.2:3260";
      description = ''
        Portal as address:port. Use an IP: the initrd has no name resolution.
      '';
    };

    target = lib.mkOption {
      type = lib.types.str;
      example = "iqn.2026-07.au.jupiter:europa:callisto-root";
      description = "Target IQN that carries the root filesystem.";
    };

    logLevel = lib.mkOption {
      type = lib.types.ints.between 0 8;
      default = 1;
      description = "iscsid and iscsiadm --debug level in the initrd.";
    };

    loginAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Login attempts, one second apart, before the initrd gives up.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Lines appended to the initrd iscsid.conf.";
    };

    nic = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "eno1";
      description = ''
        Name of the NIC that carries the iSCSI session. When set, stage-2
        networkd manages it with DHCPv4 and ClientIdentifier=mac, so the lease
        is renewed and the address matches the one the initrd obtained. When
        null the NIC stays unmanaged in stage 2.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Same constraint the nixpkgs module imposed: the root NIC is configured by
    # networkd, not by the scripted networking units.
    networking.useNetworkd = true;
    networking.useDHCP = false;

    services.openiscsi = {
      enable = true;
      inherit (cfg) name;
    };

    boot.initrd = lib.mkMerge [
      {
        network.enable = true;
        # Keep the initrd address on the NIC: the root filesystem is on it.
        network.flushBeforeStage2 = false;
        kernelModules = [ "iscsi_tcp" ];

        # makeInitrdNG follows ELF dependencies only, so every store path the
        # scripts reference is listed explicitly.
        systemd.storePaths = [
          pkgs.openiscsi
          iscsidConf
          prepConf
          loginScript
        ];

        systemd.services.iscsid = {
          description = "Open-iSCSI daemon (initrd)";
          wantedBy = [ "initrd.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          before = [ "iscsi-login.service" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "simple";
            ExecStartPre = prepConf;
            ExecStart = "${pkgs.openiscsi}/bin/iscsid --foreground --no-pid-file --debug ${toString cfg.logLevel}";
          };
        };

        systemd.services.iscsi-login = {
          description = "Discover and log into the iSCSI root target (initrd)";
          wantedBy = [ "initrd-root-device.target" ];
          requires = [ "iscsid.service" ];
          wants = [ "network-online.target" ];
          after = [
            "iscsid.service"
            "network-online.target"
          ];
          before = [
            "initrd-root-device.target"
            "sysroot.mount"
          ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = loginScript;
          };
        };
      }
      (lib.mkIf (cfg.nic != null) {
        # Initrd side of the DHCP identity: MAC-based client id, so a
        # MAC-keyed DHCP reservation yields the same address as in stage 2.
        systemd.network.networks."10-iscsi-root" = {
          matchConfig.Name = cfg.nic;
          networkConfig.DHCP = "ipv4";
          dhcpV4Config.ClientIdentifier = "mac";
        };
      })
    ];

    systemd.network.networks = lib.mkIf (cfg.nic != null) {
      "10-iscsi-root" = {
        matchConfig.Name = cfg.nic;
        networkConfig = {
          DHCP = "ipv4";
          # The root filesystem lives behind this NIC: never flush its lease
          # when networkd restarts.
          KeepConfiguration = "dynamic";
        };
        dhcpV4Config.ClientIdentifier = "mac";
      };
    };
  };
}
