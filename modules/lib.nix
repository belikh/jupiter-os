# Shared internal helpers for jupiter-os modules — import as
#
#   inherit (import ../lib.nix { inherit config lib pkgs; }) <helper>;
#
# This file is NOT a NixOS module (no options): it exists so the session
# launcher, tty1 seat wiring, service-hardening stanza, polkit unit-start
# rule and NFS mount options live exactly once instead of being copy-pasted
# between dashboard-gaming/arcade-console (session), nom-web/suno-web/
# suno-backup (hardening), touch-wake/customer-display (polkit) and
# cartridges/exodos (NFS options).
{
  config,
  lib,
  pkgs,
}:

{
  # --- tty1 session stack (dashboard-gaming.nix + arcade-console.nix) -------

  # Launch a session mode through a PATH that resolves programs.* wrappers,
  # with the pam_systemd session env a plain system service lacks, and with
  # pam_systemd's ambient CAP_WAKE_ALARM cleared so downstream bubblewrap
  # sandboxes (Steam/Heroic/Lutris via umu -> pressure-vessel) don't refuse
  # to start. Rationale for each line lives in dashboard-gaming.nix's header.
  mkSessionLauncher =
    name: user: command:
    pkgs.writeShellScript "jupiter-${name}-session" ''
      export PATH=/run/current-system/sw/bin:$PATH
      export XDG_RUNTIME_DIR="/run/user/$(id -u ${user})"
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
      exec ${pkgs.libcap}/bin/capsh --noamb -- -c 'exec ${command}'
    '';

  # A start/stoppable system unit that can grab DRM master on tty1, modelled
  # on nixpkgs' services.cage (pam_systemd seat session = DRM master).
  # `conditionOnTty1` controls the ConditionPathExists guard:
  #   - dashboard-gaming's on-demand kiosk units want it;
  #   - arcade-console's BOOT-path unit must NOT have it — systemd recorded
  #     the condition failed at job-dequeue time on callisto's iSCSI-root
  #     boot even with /dev/tty1 present, silently skipping the session.
  # stopIfChanged=false: a switch must not stop the live session (gamescope
  # ignores SIGTERM -> full stop-timeout hang); changes apply at the next
  # organic restart. TimeoutStopSec=10 matches Valve's gamescope-session.
  # Named mk* because it is a function returning the attrset, not the value.
  mkSessionOnTty1 =
    {
      conditionOnTty1 ? true,
    }:
    lib.mkMerge [
      {
        after = [
          "systemd-user-sessions.service"
          "systemd-logind.service"
          "getty@tty1.service"
        ];
        before = [ "graphical.target" ];
        conflicts = [
          "getty@tty1.service"
          "autovt@tty1.service"
          "cage-tty1.service"
        ];
        stopIfChanged = false;
        serviceConfig = {
          TTYPath = "/dev/tty1";
          TTYReset = true;
          TTYVHangup = true;
          TTYVTDisallocate = true;
          StandardInput = "tty-fail";
          StandardOutput = "journal";
          StandardError = "journal";
          UtmpIdentifier = "tty1";
          UtmpMode = "user";
          Restart = "always";
          RestartSec = 2;
          TimeoutStopSec = 10;
        };
      }
      (lib.optionalAttrs conditionOnTty1 {
        unitConfig.ConditionPathExists = "/dev/tty1";
      })
    ];

  # nixpkgs' own gamescope with the cap_sys_nice wrapper — the value both
  # console.nix's non-gamingMode path and arcade-console.nix assign. Shared
  # so the two can never silently diverge (identical definitions merge;
  # divergent ones hard-fail eval instead of half-applying).
  gamescopePrograms = {
    enable = true;
    capSysNice = true;
  };

  # --- service hardening (nom-web / suno-web / suno-backup) ------------------

  # The common sandbox stanza for the fleet's long-running Go services.
  # MemoryDenyWriteExecute stays false: the Go runtime needs writable+
  # executable memory. Consumers merge service-specific keys on top:
  #   serviceConfig = commonServiceHardening // { ...extras };
  commonServiceHardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
    ];
    RestrictNamespaces = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = false;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
  };

  # --- polkit (tcxwave-touch-wake + customer-display) ------------------------

  # Allow an unprivileged user to start/stop ONE system unit via polkit
  # (org.freedesktop.systemd1.manage-units), scoped to exactly that unit and
  # that user — no wildcard unit patterns.
  polkitUnitRule = user: unit: ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          subject.user == "${user}" &&
          action.lookup("unit") == "${unit}") {
        return polkit.Result.YES;
      }
    });
  '';

  # --- NFS (cartridges + exodos) ----------------------------------------------

  # Read-only, automounted, soft NFS mount options. soft: a dead europa must
  # not hang emulator reads forever; automount + idle-timeout: each mount
  # exists only while something uses it.
  nfsRoMountOptions = [
    "ro"
    "noatime"
    "soft"
    "noauto"
    "x-systemd.automount"
    "x-systemd.idle-timeout=10min"
    "x-systemd.mount-timeout=30"
  ];

  # --- shared Python scaffolding (customer-display + customer-msr) -----------

  # Common Python for the two TCx Wave hid/evdev daemons: paho-mqtt client
  # construction (the CallbackAPIVersion dance across paho versions),
  # credentials, reconnect policy, LWT, async connect, and the sops password
  # file read. Interpolated into each daemon's writePython3Bin source —
  # single source of truth, no python packaging gymnastics.
  #
  # make_mqtt_client returns the client; the caller passes on_connect
  # (subscriptions vs HA discovery differ per daemon) and calls
  # connect_async/loop_start itself.
  tcxwaveMqttPy = ''
    def make_mqtt_client(prefix, username, password, base, host, on_connect):
        import paho.mqtt.client as mqtt

        try:
            client = mqtt.Client(
                mqtt.CallbackAPIVersion.VERSION1,
                client_id='%s-%s-%d' % (prefix, host, os.getpid()),
            )
        except (AttributeError, TypeError):
            client = mqtt.Client(
                client_id='%s-%s-%d' % (prefix, host, os.getpid()))
        if username:
            client.username_pw_set(username, password or None)
        client.reconnect_delay_set(min_delay=2, max_delay=30)
        client.will_set('%s/%s/state' % (base, host),
                        payload='offline', retain=True)
        client.on_connect = on_connect
        return client


    def read_password_file(path):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError as e:
            print('cannot read password file: %s' % e, file=sys.stderr)
            return ""


    def short_hostname():
        return socket.gethostname().split('.')[0]
  '';
}
