{
  config,
  lib,
  pkgs,
  ...
}:

# Open driver for the Toshiba TCxWave integrated MSR (magstripe reader) — the
# reader behind the same "TCxWave IO Control" USB device (0x0f66:0x4500) as the
# customer display. Publishes each swiped card to MQTT so Home Assistant can
# trigger automations off a badge/card (who's home, unlock a door, run a scene).
#
# Approach: the MSR's keyboard interface (the 0001 collection) is a standard
# HID keyboard that injects card data as keystrokes in its default mode (the
# proprietary VSP driver only switches it to raw mode after install). Rather
# than reverse the 290-byte raw feature-report protocol — which is possible
# (MsrUsbDriver.dll exposes formatISOFeatureReport) but needs a physical swipe
# to decode and is fragile — this driver grabs that keyboard event device
# exclusively (so swipes never leak into the dashboard/chromium URL bar) and
# republishes the typed card string to MQTT. That is the card number HA needs,
# with zero protocol cracking and full robustness.
#
# The proprietary driver can't do any of this — it just turns the MSR into a
# COM port for a POS app. This one turns it into a smart-home input device.
#
# Confirmed live on amalthea 2026-07-25 via a raw evdev capture of a real
# swipe: the reader sends a genuine ISO 7811 track burst as US-QWERTY
# keystrokes, framed and terminated exactly like the standard — track 1 as
# `%B<pan>^<name>^<data>?`, track 2 as `;<pan>=<data>?`, each ending in
# Enter. Decoding it correctly requires tracking the Shift modifier (the '%'
# and '?' sentinels and track 1's name field are all shifted characters) —
# an earlier version of this module's keymap ignored Shift entirely, so it
# silently mangled every swipe even once the grab was working. The daemon
# below has NOT yet been re-verified end-to-end after that fix (i.e. the
# MQTT payload hasn't been checked against a live swipe with the corrected
# decode) — only the raw keystroke capture and the fix itself are confirmed.

let
  cfg = config.jupiter.customerMsr;

  inherit (import ../lib.nix { inherit config lib pkgs; }) tcxwaveMqttPy;

  msrDaemon =
    pkgs.writers.writePython3Bin "tcxwave-msr"
      {
        libraries = [ pkgs.python3Packages.paho-mqtt ];
        flakeIgnore = [
          "E127"
          "E128"
          "E501"
          "E731"
          "W503"
          "W504"
        ];
      }
      ''
        import argparse
        import fcntl
        import json
        import os
        import select
        import socket
        import struct
        import sys
        import time

        # Shared MQTT/password/hostname scaffolding (modules/lib.nix) —
        # identical in customer-display.nix's daemon.
        ${tcxwaveMqttPy}

        VENDOR = 0x0F66
        PRODUCT = 0x4500

        EV_KEY = 1
        KEY_ENTER = 28
        KEY_LEFTSHIFT = 42
        KEY_RIGHTSHIFT = 54
        EV_EVENT = struct.Struct('<QQHhi')  # sec, usec, type, code, value
        EV_SIZE = EV_EVENT.size             # 24 on 64-bit


        def _ioc(d, t, nr, sz):
            return (d << 30) | (sz << 16) | (ord(t) << 8) | nr


        EVIOCGRAB = _ioc(1, 'E', 0x90, 4)
        EVIOCGID = _ioc(2, 'E', 0x02, 8)

        # US-QWERTY char per evdev keycode, unshifted / shifted. The reader
        # emits a real ISO 7811 track burst (confirmed live on amalthea
        # 2026-07-25): track 1 is framed `%B<pan>^<name>^<data>?`, track 2 is
        # `;<pan>=<data>?` — both sentinels ('%', '^', '?') and track 1's
        # name field (letters) only decode correctly if Shift is tracked, so
        # this must stay a (code -> (lo, hi)) map, not a flat one.
        KMAP = {
            2: ('1', '!'), 3: ('2', '@'), 4: ('3', '#'), 5: ('4', '$'),
            6: ('5', '%'), 7: ('6', '^'), 8: ('7', '&'), 9: ('8', '*'),
            10: ('9', '('), 11: ('0', ')'), 12: ('-', '_'), 13: ('=', '+'),
            16: ('q', 'Q'), 17: ('w', 'W'), 18: ('e', 'E'), 19: ('r', 'R'),
            20: ('t', 'T'), 21: ('y', 'Y'), 22: ('u', 'U'), 23: ('i', 'I'),
            24: ('o', 'O'), 25: ('p', 'P'), 26: ('[', '{'), 27: (']', '}'),
            30: ('a', 'A'), 31: ('s', 'S'), 32: ('d', 'D'), 33: ('f', 'F'),
            34: ('g', 'G'), 35: ('h', 'H'), 36: ('j', 'J'), 37: ('k', 'K'),
            38: ('l', 'L'), 39: (';', ':'), 40: ("'", '"'), 41: ('`', '~'),
            43: ('\\', '|'), 44: ('z', 'Z'), 45: ('x', 'X'), 46: ('c', 'C'),
            47: ('v', 'V'), 48: ('b', 'B'), 49: ('n', 'N'), 50: ('m', 'M'),
            51: (',', '<'), 52: ('.', '>'), 53: ('/', '?'), 57: (' ', ' '),
        }


        def find_msr_event():
            for n in range(64):
                p = '/dev/input/event%d' % n
                if not os.path.exists(p):
                    continue
                try:
                    fd = os.open(p, os.O_RDWR | os.O_NONBLOCK)
                except OSError:
                    continue
                try:
                    buf = bytearray(8)
                    fcntl.ioctl(fd, EVIOCGID, buf)
                    _, vendor, product, _v = struct.unpack('<HHHH',
                                                            bytes(buf))
                    if vendor == VENDOR and product == PRODUCT:
                        os.close(fd)
                        return p
                except OSError:
                    pass
                os.close(fd)
            return None


        def digits(s):
            return "".join(c for c in s if c.isdigit())


        def publish_discovery(client, base, host):
            # Home Assistant MQTT discovery: a retained config payload at
            # homeassistant/sensor/<node_id>/<object_id>/config makes HA
            # auto-create the entity, no manual YAML/UI sensor needed.
            # Re-published on every (re)connect so it survives an HA
            # restart clearing its discovery cache.
            node_id = 'tcxwave_%s' % host
            state_topic = '%s/%s' % (base, host)
            config = {
                'name': 'Card Swipe',
                'unique_id': '%s_msr' % node_id,
                'state_topic': state_topic,
                'value_template': '{{ value_json.card }}',
                'json_attributes_topic': state_topic,
                'availability_topic': '%s/%s/state' % (base, host),
                'payload_available': 'online',
                'payload_not_available': 'offline',
                'icon': 'mdi:credit-card-scan',
                'device': {
                    'identifiers': [node_id],
                    'name': 'TCxWave %s' % host,
                    'manufacturer': 'Toshiba',
                    'model': 'TCxWave IO Control',
                },
            }
            client.publish('homeassistant/sensor/%s/msr/config' % node_id,
                            payload=json.dumps(config), qos=1, retain=True)


        def connect_mqtt(broker, port, username, password, base, host):
            # Client construction/credentials/LWT/reconnect live in the shared
            # tcxwaveMqttPy block (modules/lib.nix) — identical scaffolding to
            # customer-display.nix; only on_connect (HA discovery instead of
            # topic subscriptions) differs per daemon.
            def on_connect(c, _u, _f, rc):
                if rc == 0:
                    c.publish('%s/%s/state' % (base, host),
                              payload='online', retain=True)
                    publish_discovery(c, base, host)
                else:
                    print('mqtt connect rc=%s' % rc, file=sys.stderr)

            client = make_mqtt_client('msr', username, password, base, host,
                                      on_connect)
            client.connect_async(broker, port, 60)
            client.loop_start()
            return client


        def main():
            ap = argparse.ArgumentParser()
            ap.add_argument('--broker', default='${config.jupiter.fleet.addresses.callisto}')
            ap.add_argument('--port', type=int, default=1883)
            ap.add_argument('--username', default="")
            ap.add_argument('--password-file', default="")
            ap.add_argument('--topic', default='ha-linux-agent/msr')
            args = ap.parse_args()
            host = short_hostname()

            password = read_password_file(args.password_file) \
                if args.password_file else ""
            client = connect_mqtt(args.broker, args.port, args.username,
                                  password, args.topic, host)
            pub = '%s/%s' % (args.topic, host)
            print('msr: publishing to %s' % pub, file=sys.stderr)

            path = None
            fd = None
            swipe = ""
            shift = False
            last = 0.0
            chunk = b""
            while True:
                if path is None:
                    path = find_msr_event()
                    if path is None:
                        print('MSR not found; retrying...', file=sys.stderr)
                        time.sleep(5)
                        continue
                    try:
                        fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
                        fcntl.ioctl(fd, EVIOCGRAB, 1)  # exclusive: no leak
                        print('msr: grabbed %s' % path, file=sys.stderr)
                    except OSError as e:
                        print('open/grab failed: %s' % e, file=sys.stderr)
                        path = None
                        fd = None
                        time.sleep(3)
                        continue

                r, _, _ = select.select([fd], [], [], 0.5)
                if r:
                    try:
                        chunk = os.read(fd, EV_SIZE * 32)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        # device gone (e.g. USB reenumerate) — rescan
                        try:
                            os.close(fd)
                        except OSError:
                            pass
                        fd = None
                        path = None
                        continue
                while len(chunk) >= EV_SIZE:
                    _s, _u, typ, code, val = EV_EVENT.unpack(chunk[:EV_SIZE])
                    chunk = chunk[EV_SIZE:]
                    if typ != EV_KEY or val == 2:  # ignore non-key + autorepeat
                        continue
                    if code in (KEY_LEFTSHIFT, KEY_RIGHTSHIFT):
                        shift = bool(val)
                        continue
                    if val != 1:
                        continue
                    last = time.time()
                    if code == KEY_ENTER:
                        if swipe:
                            publish(client, pub, host, swipe)
                        swipe = ""
                    elif code in KMAP:
                        swipe += KMAP[code][1 if shift else 0]
                # flush a partial swipe if it stalls mid-read
                if swipe and time.time() - last > 0.6:
                    publish(client, pub, host, swipe)
                    swipe = ""


        def publish(client, topic, host, swipe):
            # Only the PAN digits cross the wire. The RAW magstripe track
            # (sentinels, field separators, LRC, and on track1 the cardholder
            # NAME + expiry + discretionary data incl. CVV-ish service codes)
            # is deliberately NOT published or logged: mosquitto on callisto
            # retains topic history for every fleet host, and MQTT has no
            # per-message confidentiality — a full track in a topic is a
            # PCI-DSS non-starter sitting next to the kiosk network.
            card = digits(swipe)
            payload = json.dumps({
                'host': host,
                'card': card,
                'ts': int(time.time()),
            })
            try:
                client.publish(topic, payload=payload, qos=1, retain=False)
                print('swipe: card=%s' % card, file=sys.stderr)
            except Exception as e:
                print('publish failed: %s' % e, file=sys.stderr)


        if __name__ == '__main__':
            try:
                main()
            except KeyboardInterrupt:
                pass
      '';
in
{
  imports = [ ../network/fleet.nix ];

  options.jupiter.customerMsr = {
    enable = lib.mkEnableOption "TCxWave MSR card-swipe -> MQTT publisher";

    mqtt = {
      broker = lib.mkOption {
        type = lib.types.str;
        default = config.jupiter.fleet.addresses.callisto;
        description = "Mosquitto broker address (the fleet broker on callisto).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 1883;
        description = "Mosquitto broker port.";
      };

      username = lib.mkOption {
        type = lib.types.str;
        default = "ha-linux-agent";
        description = ''
          MQTT user. Defaults to the fleet `ha-linux-agent` identity, whose ACL
          (modules/services/mqtt.nix on callisto) grants readwrite on
          `ha-linux-agent/#`.
        '';
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = config.sops.secrets.mqtt_ha_linux_agent.path or null;
        defaultText = lib.literalExpression "config.sops.secrets.mqtt_ha_linux_agent.path";
        description = "File with the MQTT user's plaintext password (a sops secret).";
      };

      topic = lib.mkOption {
        type = lib.types.str;
        default = "ha-linux-agent/msr";
        description = ''
          Topic root. Each swipe publishes JSON `{host, card, raw, ts}` to
          `<topic>/<host>` (QoS 1, not retained — swipes are events). `card`
          is the digits-only card number; `raw` includes track sentinels.
          The daemon also self-registers as a Home Assistant MQTT-discovery
          sensor (`homeassistant/sensor/tcxwave_<host>/msr/config`, retained)
          on every connect, so no manual HA-side sensor config is needed —
          the ACL for this ("readwrite homeassistant/#") already exists on
          the `ha-linux-agent` MQTT user (modules/services/mqtt.nix).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.tcxwave-msr = {
      description = "TCxWave MSR card-swipe publisher";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart =
          "${msrDaemon}/bin/tcxwave-msr"
          + " --broker ${cfg.mqtt.broker}"
          + " --port ${toString cfg.mqtt.port}"
          + " --username ${cfg.mqtt.username}"
          + " --topic ${cfg.mqtt.topic}"
          + lib.optionalString (cfg.mqtt.passwordFile != null) (" --password-file ${cfg.mqtt.passwordFile}");
        Restart = "always";
        RestartSec = "5s";
        # Root so it can EVIOCGRAB the input device and read the sops password.
        User = "root";
        Nice = 19;
      };
    };
  };
}
