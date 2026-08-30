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

let
  # Session ladder numbers (arcade remediation W4c / plan §6.H). Explicit
  # because the upstream defaults park a crash-looping cabinet dead in
  # ~12 s (5 starts per 10 s with RestartSec=2) and "operator notices and
  # power-cycles" was the only recovery. The ladder, with numbers:
  #
  #   watchdog (WatchdogSec=90, pinged every 30 s by the launcher wrapper)
  #     -> SIGABRT to the main process
  #     -> Restart=always with RestartSec=5
  #     -> start limits (6 starts per 300 s, not 5 per 10 s)
  #     -> OnFailure escalation (arcade.nix: reboot, then boot-count guard
  #        to the rescue console after 3 failed ladders)
  sessionLadder = {
    # The wrapper's readiness budget: pegasus-fe must appear within 60 s
    # (the 60-second boot-to-playable signage number) and then settle
    # 10 s before READY=1 is asserted (first frames are cache scans, not
    # menu-accepting-input).
    readyWaitSeconds = 60;
    readySettleSeconds = 10;
    # WatchdogSec must comfortably exceed readyWait+settle; pings at half
    # intervals keep it fed during normal operation.
    watchdogSec = 90;
    watchdogPingSeconds = 30;
    # Crash-loop budget: 6 restarts per 300 s (a cabinet keeps trying
    # for minutes instead of parking dead at ~12 s).
    startLimitBurst = 6;
    startLimitIntervalSec = 300;
    restartSec = 5;
    # Notify deadline: Type=notify start timeout (cold-cache Pegasus
    # scans run long on the HD 520 kiosks).
    timeoutStartSec = 180;
  };
in
{
  # --- tty1 session stack (dashboard-gaming.nix + arcade-console.nix) -------

  # Launch a session mode through a PATH that resolves programs.* wrappers,
  # with the pam_systemd session env a plain system service lacks, and with
  # pam_systemd's ambient CAP_WAKE_ALARM cleared so downstream bubblewrap
  # sandboxes (Steam/Heroic/Lutris via umu -> pressure-vessel) don't refuse
  # to start. Rationale for each line lives in dashboard-gaming.nix's header.
  #
  # Since the W4c kiosk operability spec this is ALSO the supervision
  # wrapper: the script is the unit's Type=notify main process, asserts
  # READY=1 once the frontend reports menu-accepting-input (process-up +
  # settle — pegasus-fe has no readiness signal, so the wrapper's
  # process heuristic + settle window IS the spec's "small notify
  # wrapper"), feeds the systemd watchdog while the compositor lives,
  # clears the session-failure boot counter on the first good ready
  # (arcade.nix's OnFailure ladder guard), and exits with the
  # compositor's status so Restart=always owns recovery.
  mkSessionLauncher =
    name: user: command:
    pkgs.writeShellScript "jupiter-${name}-session" ''
      export PATH=/run/current-system/sw/bin:$PATH
      XDG_RUNTIME_DIR="/run/user/$(id -u ${user})"
      export XDG_RUNTIME_DIR
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
      NOTIFY="${pkgs.systemd}/bin/systemd-notify"
      PGR="${pkgs.procps}/bin/pgrep"

      # The session itself, under the ambient-cap scrub, in the
      # background: this wrapper must survive as the main process to
      # own the notify channel and the watchdog pings.
      ${pkgs.libcap}/bin/capsh --noamb -- -c 'exec ${command}' &
      child=$!

      seen=0
      i=0
      while [ "$i" -lt ${toString sessionLadder.readyWaitSeconds} ]; do
        i=$((i + 1))
        if "$PGR" -f 'pegasus-fe' >/dev/null 2>&1; then
          seen=1
          break
        fi
        if ! kill -0 "$child" 2>/dev/null; then break; fi
        sleep 1
      done
      if [ "$seen" = 1 ]; then
        # Menu-LOADING is not menu-ACCEPTING-INPUT: settle past the
        # first cache-scan frames before READY is asserted.
        j=0
        while [ "$j" -lt ${toString sessionLadder.readySettleSeconds} ]; do
          j=$((j + 1))
          kill -0 "$child" 2>/dev/null || break
          sleep 1
        done
        echo "jupiter-${name}: frontend process seen — asserting READY=1 after the settle window"
      else
        # A mode whose frontend never matches the pgrep heuristic still
        # reports ready after the full wait (the wrapper's supervision
        # is generic; only the readiness signal is frontend-specific).
        echo "jupiter-${name}: frontend process never matched — asserting READY=1 on the fallback budget"
      fi
      "$NOTIFY" READY=1
      # First good ready clears the failure-ladder boot counter (the
      # OnFailure escalation unit counts failed ladders across reboots;
      # a session that reaches ready is, by definition, not one).
      rm -f /var/lib/jupiter-arcade/failure-count 2>/dev/null || true

      # Watchdog feed: ping while the compositor lives. A hung WRAPPER
      # stops pinging and the watchdog fires (SIGABRT rung of the
      # ladder); a dead compositor takes the wrapper down via wait and
      # Restart=always owns the recovery.
      while kill -0 "$child" 2>/dev/null; do
        "$NOTIFY" WATCHDOG=1 || true
        sleep ${toString sessionLadder.watchdogPingSeconds} & waiter=$!
        wait "$waiter" 2>/dev/null || true
      done
      wait "$child"
      exit $?
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
  #
  # W4c: Type=notify (the launcher wrapper asserts READY=1 — the
  # boot-to-playable budget becomes a MEASURED start, not a hope), the
  # watchdog armed over the whole session lifetime, and the explicit
  # start-limit tuning of sessionLadder replacing the 5-per-10s upstream
  # default that parked crash-looping cabinets dead in ~12 s.
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
        # Explicit start limits (upstream default 5/10s parks a
        # crash-looping cabinet in ~12 s — the plan's §6.H finding).
        startLimitIntervalSec = sessionLadder.startLimitIntervalSec;
        startLimitBurst = sessionLadder.startLimitBurst;
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
          Type = "notify";
          NotifyAccess = "all";
          TimeoutStartSec = toString sessionLadder.timeoutStartSec;
          WatchdogSec = toString sessionLadder.watchdogSec;
          Restart = "always";
          RestartSec = toString sessionLadder.restartSec;
          TimeoutStopSec = 10;
        };
      }
      (lib.optionalAttrs conditionOnTty1 {
        unitConfig.ConditionPathExists = "/dev/tty1";
      })
    ];

  # jupiter-arcade.slice — the resource plane BOTH arcade sides join
  # (arcade remediation W4c/W4a): the europa webapp unit
  # (modules/services/arcade-webapp.nix) and the kiosk session unit
  # (modules/desktop/arcade.nix contribution) each set Slice= to this,
  # so the arcade plane is bounded on every host it exists on — never
  # the whole host, exactly the plan §6.A capacity-ledger rule. Defined
  # identically in BOTH modules (like gamescopePrograms: identical
  # definitions merge, divergent ones hard-fail eval). Unit-level caps
  # stay with the units (the webapp's MemoryMax=2G/CPUQuota=160%
  # tightens inside the slice's bounds); the slice caps the PLANE: the
  # webapp host's webapp+igir+Skyscraper children, the kiosk's
  # gamescope+pegasus+emulators (launched games inherit the session's
  # cgroup).
  jupiterArcadeSlice = {
    description = "jupiterOS Arcade resource plane (webapp pipeline + kiosk session)";
    wantedBy = [ "multi-user.target" ];
    sliceConfig = {
      MemoryMax = "3G";
      CPUAccounting = true;
      MemoryAccounting = true;
    };
  };

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
