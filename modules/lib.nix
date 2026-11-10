# Shared internal helpers for jupiter-os modules — import as
#
#   inherit (import ../lib.nix { inherit config lib pkgs; }) <helper>;
#
# This file is NOT a NixOS module (no options): it exists so the
# service-hardening stanza, polkit unit-start rule and the shared Python MQTT
# scaffolding live exactly once instead of being copy-pasted between
# nom-web/suno-web/suno-backup (hardening) and touch-wake/customer-display
# (polkit).
{
  config,
  lib,
  pkgs,
}:

{
  # jupiter-arcade.slice — the resource plane of the europa arcade webapp
  # (modules/services/arcade-webapp.nix). Unit-level caps stay with the unit
  # (the webapp's MemoryMax=2G/CPUQuota=160% tightens inside the slice's
  # bounds); the slice caps the plane: the webapp plus its igir and
  # Skyscraper children.
  jupiterArcadeSlice = {
    description = "jupiterOS Arcade resource plane (webapp pipeline)";
    wantedBy = [ "multi-user.target" ];
    sliceConfig = {
      MemoryMax = "3G";
      CPUAccounting = true;
      MemoryAccounting = true;
    };
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
