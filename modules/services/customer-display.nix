{
  config,
  lib,
  pkgs,
  ...
}:

# Cool text animations + transient notifications for the Toshiba TCxWave
# integrated customer-facing line display (2x20 VFD behind the "TCxWave IO
# Control" USB-HID device 0x0f66:0x4500). A playlist of effects (plasma,
# spectrum bars, matrix rain, a bouncing logo, an auto-playing snake, and a
# panning Mandelbrot) runs as the idle base; anything published to the daemon's
# MQTT topic overlays as a notification for a few seconds, then the animations
# resume. So the customer display is both a live smart-home notifier (which the
# proprietary driver can't do at all) AND a cool screensaver.
#
# Protocol (reverse-engineered from the glass 2026-07-25 and confirmed against
# Toshiba's own LdUsbDriver.dll, extracted from their published vsp_windows.zip):
# a 23-byte hidraw OUTPUT report written as
#   write(fd, [0x00 report-id] + [cmd][0x00][20 chars][0x00])
# Commands (vendor names): 0x01 ClearTopLine, 0x02 ClearBottomLine,
# 0x81 WriteTopLine, 0x82 WriteBottomLine, 0x42 DeviceInformationRequest (ACK
# byte0 = 0x01 ok / 0x02 data / 0x80 rejected). The display interface is the
# 0x0f66:0x4500 hidraw node that answers 0x42 with status 0x02 (its
# MSR/keylock/graphical siblings do not).
#
# Character set: explored empirically — this VFD's ROM is a Latin/ISO-8859-style
# font (accented letters in the high range), NOT CP437, so there are no block or
# box-drawing glyphs (the 0x41,0x00 "SelectCharacterSet CP437" returns OK but
# the physical font has no graphics). All effects therefore use a printable-
# ASCII density ramp (` .:-=+*#%@`), which renders cleanly and looks great.
#
# Verified live on amalthea 2026-07-25.

let
  cfg = config.jupiter.customerDisplay;

  cdpAnim =
    pkgs.writers.writePython3Bin "tcxwave-cdp-anim"
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
        import math
        import os
        import random
        import select
        import socket
        import struct
        import sys
        import threading
        import time

        VENDOR = 0x0F66
        PRODUCT = 0x4500
        OUT = 23

        CMD_CLEAR_TOP = 0x01
        CMD_CLEAR_BOT = 0x02
        CMD_WRITE_TOP = 0x81
        CMD_WRITE_BOT = 0x82
        CMD_QUERY = 0x42
        STATUS_DATA = 0x02

        WIDTH = 20
        HEIGHT = 2
        RAMP = " .:-=+*#%@"


        def _ioc(d, t, nr, sz):
            return (d << 30) | (sz << 16) | (ord(t) << 8) | nr


        HIDIOCGRAWINFO = _ioc(2, 'H', 0x03, 8)


        def _drain(fd):
            while True:
                r, _, _ = select.select([fd], [], [], 0.02)
                if not r:
                    return
                try:
                    os.read(fd, 64)
                except OSError:
                    return


        def _is_display(fd):
            _drain(fd)
            try:
                os.write(fd, b'\x00' + bytes([CMD_QUERY] + [0] * 22))
            except OSError:
                return False
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                return False
            try:
                return os.read(fd, 64)[0] == STATUS_DATA
            except OSError:
                return False


        def find_display():
            for n in range(8):
                p = '/dev/hidraw%d' % n
                if not os.path.exists(p):
                    continue
                try:
                    fd = os.open(p, os.O_RDWR | os.O_NONBLOCK)
                except OSError:
                    continue
                info = bytearray(8)
                try:
                    fcntl.ioctl(fd, HIDIOCGRAWINFO, info, True)
                    _, v, pd = struct.unpack('<Ihh', bytes(info))
                    ok = (v == VENDOR and pd == PRODUCT and _is_display(fd))
                except OSError:
                    ok = False
                os.close(fd)
                if ok:
                    return p
            return None


        class Display:
            def __init__(self, path):
                self.path = path
                self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)

            def _reopen(self):
                try:
                    os.close(self.fd)
                except OSError:
                    pass
                for _ in range(30):
                    p = find_display()
                    if p:
                        try:
                            self.fd = os.open(p, os.O_RDWR | os.O_NONBLOCK)
                            self.path = p
                            return
                        except OSError:
                            pass
                    time.sleep(2)

            def _cmd(self, payload):
                _drain(self.fd)
                try:
                    os.write(self.fd, b'\x00' + bytes(payload))
                except OSError:
                    self._reopen()

            def clear(self):
                self._cmd([CMD_CLEAR_TOP] + [0] * 22)
                self._cmd([CMD_CLEAR_BOT] + [0] * 22)

            def rows(self, top, bot):
                self._row(CMD_WRITE_TOP, top)
                self._row(CMD_WRITE_BOT, bot)

            def _row(self, cmdbyte, text):
                t = text.encode('latin1', 'replace')[:WIDTH].ljust(WIDTH, b' ')
                self._cmd([cmdbyte, 0x00] + list(t) + [0x00])

            def close(self):
                try:
                    os.close(self.fd)
                except OSError:
                    pass


        def grid():
            return [[' '] * WIDTH for _ in range(HEIGHT)]


        def to_rows(g):
            return ["".join(r) for r in g]


        def ramp(v):
            i = int(round(v * (len(RAMP) - 1)))
            return RAMP[max(0, min(len(RAMP) - 1, i))]


        class Plasma:
            def step(self, dt, t):
                g = grid()
                for y in range(HEIGHT):
                    for x in range(WIDTH):
                        v = (math.sin(x * 0.6 + t * 1.1)
                             + math.sin(y * 1.7 + t * 0.9)
                             + math.sin((x + y) * 0.4 + t * 1.5)
                             + math.sin(math.hypot(x - 10, y - 1) * 0.5 - t))
                        g[y][x] = ramp((v + 4) / 8)
                return to_rows(g)


        class Spectrum:
            def step(self, dt, t):
                g = grid()
                for x in range(WIDTH):
                    h = (math.sin(x * 0.7 + t * 3.0) + 1) / 2
                    h *= 0.6 + 0.4 * math.sin(x * 0.3 + t * 1.7)
                    levels = int(round(max(0.0, min(1.0, h)) * HEIGHT))
                    for y in range(HEIGHT):
                        yy = HEIGHT - 1 - y
                        if yy < levels:
                            g[y][x] = '#' if yy == levels - 1 else '='
                return to_rows(g)


        class MatrixRain:
            def __init__(self):
                self.head = [random.uniform(0, HEIGHT) for _ in range(WIDTH)]
                self.speed = [random.uniform(4, 9) for _ in range(WIDTH)]

            def step(self, dt, t):
                g = grid()
                for x in range(WIDTH):
                    self.head[x] += self.speed[x] * dt
                    if self.head[x] > HEIGHT + 1:
                        self.head[x] = 0.0
                        self.speed[x] = random.uniform(4, 9)
                    for y in range(HEIGHT):
                        d = self.head[x] - y
                        if -0.6 < d <= 0.4:
                            g[y][x] = random.choice('0123456789')
                        elif -1.4 < d <= -0.6:
                            g[y][x] = ':'
                return to_rows(g)


        class BouncingLogo:
            def __init__(self, text):
                self.text = text[:WIDTH]
                self.x = float(WIDTH - len(self.text)) / 2
                self.y = 0.0
                self.dx = 5.0
                self.dy = 0.9

            def step(self, dt, t):
                self.x += self.dx * dt
                self.y += self.dy * dt
                maxx = WIDTH - len(self.text)
                maxy = HEIGHT - 1
                if self.x < 0 or self.x > maxx:
                    self.dx *= -1
                    self.x = max(0.0, min(float(maxx), self.x))
                if self.y < 0 or self.y > maxy:
                    self.dy *= -1
                    self.y = max(0.0, min(float(maxy), self.y))
                g = grid()
                ix, iy = int(round(self.x)), int(round(self.y))
                for i, ch in enumerate(self.text):
                    if 0 <= ix + i < WIDTH:
                        g[iy][ix + i] = ch
                return to_rows(g)


        class Snake:
            DIRS = [(1, 0), (-1, 0), (0, 1), (0, -1)]

            def __init__(self):
                self.reset()

            def reset(self):
                self.body = [(5, 0), (4, 0), (3, 0), (2, 0)]
                self.d = (1, 0)
                self.food = self._spawn()
                self.acc = 0.0

            def _spawn(self):
                free = [(x, y) for x in range(WIDTH) for y in range(HEIGHT)
                        if (x, y) not in self.body]
                return random.choice(free) if free else (0, 0)

            def _draw(self):
                g = grid()
                fx, fy = self.food
                g[fy][fx] = '*'
                for i, (x, y) in enumerate(self.body):
                    g[y][x] = '@' if i == 0 else '#'
                return to_rows(g)

            def step(self, dt, t):
                self.acc += dt
                if self.acc < 0.18:
                    return self._draw()
                self.acc = 0.0
                hx, hy = self.body[0]
                best, best_d = self.d, 999
                for d in self.DIRS:
                    if d == (-self.d[0], -self.d[1]):
                        continue
                    nx, ny = hx + d[0], hy + d[1]
                    if not (0 <= nx < WIDTH and 0 <= ny < HEIGHT):
                        continue
                    if (nx, ny) in self.body[:-1]:
                        continue
                    dist = abs(nx - self.food[0]) + abs(ny - self.food[1])
                    if dist < best_d:
                        best_d, best = dist, d
                if best_d == 999:
                    self.reset()
                    return self._draw()
                self.d = best
                nh = (hx + self.d[0], hy + self.d[1])
                self.body.insert(0, nh)
                if nh == self.food:
                    self.food = self._spawn()
                else:
                    self.body.pop()
                if len(self.body) > WIDTH * HEIGHT - 2:
                    self.reset()
                return self._draw()


        class Mandelbrot:
            def step(self, dt, t):
                cx = -0.5 + 0.35 * math.sin(t * 0.05)
                cy = 0.30 * math.sin(t * 0.07)
                scale = 3.0 * (0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * 0.03)))
                g = grid()
                for y in range(HEIGHT):
                    for x in range(WIDTH):
                        cr = cx + (x / (WIDTH - 1) - 0.5) * scale
                        ci = cy + (y / (HEIGHT - 1) - 0.5) * scale * 0.25
                        zr = zi = 0.0
                        it = 0
                        while it < 48 and zr * zr + zi * zi < 4:
                            zr, zi = zr * zr - zi * zi + cr, 2 * zr * zi + ci
                            it += 1
                        g[y][x] = ramp(it / 48)
                return to_rows(g)


        class Notification:
            # Thread-safe transient overlay. While `active()` the render loop
            # shows this instead of the animation effect.
            def __init__(self):
                self.lock = threading.Lock()
                self.line1 = None
                self.line2 = None
                self.mode = 'auto'
                self.expires = 0.0

            def set(self, line1, line2, mode, ttl):
                with self.lock:
                    self.line1 = line1
                    self.line2 = line2
                    self.mode = mode
                    self.expires = time.time() + ttl

            def snapshot(self):
                with self.lock:
                    live = time.time() < self.expires
                    return (live and self.line1 is not None,
                            self.line1, self.line2, self.mode)


        def fit_line(text, off, mode):
            if not text:
                return ' ' * WIDTH
            if mode == 'static' or (mode == 'auto' and len(text) <= WIDTH):
                return text[:WIDTH].ljust(WIDTH)
            tape = (text + '   ') * 4
            return (tape[off % len(tape):] + tape)[:WIDTH].ljust(WIDTH)


        def parse_message(payload, notif, default_ttl):
            s = payload.decode('utf-8', 'replace').strip()
            if not s:
                return
            try:
                d = json.loads(s)
                if isinstance(d, dict):
                    notif.set(d.get('line1'), d.get('line2'),
                              d.get('mode', 'auto'),
                              float(d.get('ttl', default_ttl)))
                    return
                if isinstance(d, str):
                    notif.set(d, None, 'auto', default_ttl)
                    return
            except ValueError:
                pass
            notif.set(s, None, 'auto', default_ttl)


        def start_mqtt(notif, broker, port, username, password, base, host,
                       default_ttl):
            import paho.mqtt.client as mqtt

            try:
                client = mqtt.Client(
                    mqtt.CallbackAPIVersion.VERSION1,
                    client_id='cdp-%s-%d' % (host, os.getpid()),
                )
            except (AttributeError, TypeError):
                client = mqtt.Client(client_id='cdp-%s-%d' % (host, os.getpid()))

            if username:
                client.username_pw_set(username, password or None)
            client.reconnect_delay_set(min_delay=2, max_delay=30)
            client.will_set('%s/%s/state' % (base, host),
                             payload='offline', retain=True)
            subs = ['%s/%s' % (base, host), '%s/all' % base]

            def on_connect(c, _u, _flags, rc):
                if rc == 0:
                    for tp in subs:
                        c.subscribe(tp)
                    c.publish('%s/%s/state' % (base, host),
                              payload='online', retain=True)
                else:
                    print('mqtt connect rc=%s' % rc, file=sys.stderr)

            client.on_connect = on_connect
            client.on_message = lambda c, _u, m: parse_message(
                m.payload, notif, default_ttl)
            client.connect_async(broker, port, 60)
            client.loop_start()
            return client


        def render_simulate(top, bot):
            border = '+' + '-' * WIDTH + '+'
            sys.stdout.write('\033[2J\033[H' + border + '\n|' + top +
                             '|\n|' + bot + '|\n' + border + '\n')
            sys.stdout.flush()


        def main():
            ap = argparse.ArgumentParser()
            ap.add_argument('--backend', default='hidraw',
                            choices=['hidraw', 'simulate'])
            ap.add_argument('--fps', type=float, default=12.0)
            ap.add_argument('--message', default='JUPITER OS')
            ap.add_argument('--per-effect', type=float, default=10.0)
            ap.add_argument('--notif-ttl', type=float, default=8.0)
            ap.add_argument('--mqtt', action='store_true')
            ap.add_argument('--broker', default='10.1.1.3')
            ap.add_argument('--port', type=int, default=1883)
            ap.add_argument('--username', default="")
            ap.add_argument('--password-file', default="")
            ap.add_argument('--topic', default='ha-linux-agent/customer-display')
            args = ap.parse_args()
            delay = 1.0 / max(args.fps, 0.1)
            host = socket.gethostname().split('.')[0]

            notif = Notification()
            if args.mqtt:
                password = ""
                if args.password_file:
                    try:
                        with open(args.password_file) as f:
                            password = f.read().strip()
                    except OSError as e:
                        print('cannot read password file: %s' % e,
                              file=sys.stderr)
                start_mqtt(notif, args.broker, args.port, args.username,
                           password, args.topic, host, args.notif_ttl)
                print('mqtt: %s@%s:%d %s/*' %
                      (args.username, args.broker, args.port, args.topic),
                      file=sys.stderr)

            playlist = [
                ('plasma', Plasma()),
                ('spectrum', Spectrum()),
                ('rain', MatrixRain()),
                ('bounce', BouncingLogo(args.message)),
                ('snake', Snake()),
                ('mandelbrot', Mandelbrot()),
            ]

            disp = None
            if args.backend == 'hidraw':
                while True:
                    p = find_display()
                    if p:
                        disp = Display(p)
                        break
                    print('customer display not found; retrying...',
                          file=sys.stderr)
                    time.sleep(5)
                disp.clear()
                print('tcxwave-cdp-anim: dev=%s' % disp.path, file=sys.stderr)

            idx = 0
            name, effect = playlist[0]
            spent = 0.0
            off = 0
            last = time.time()
            print('effect: %s' % name, file=sys.stderr)
            while True:
                now = time.time()
                dt = min(now - last, 0.25)
                last = now
                top, bot = effect.step(dt, now)
                live, n1, n2, mode = notif.snapshot()
                if live:
                    top = fit_line(n1 or "", off, mode)
                    bot = (fit_line(n2, off, 'auto') if n2 is not None
                           else (host + '  ' + time.strftime('%H:%M'))[:WIDTH])
                if disp:
                    disp.rows(top, bot)
                else:
                    render_simulate(top, bot)
                off += 1
                spent += dt
                if spent >= args.per_effect and not live:
                    spent = 0.0
                    idx = (idx + 1) % len(playlist)
                    name, effect = playlist[idx]
                    if disp:
                        disp.clear()
                    print('effect: %s' % name, file=sys.stderr)
                time.sleep(delay)


        if __name__ == '__main__':
            try:
                main()
            except KeyboardInterrupt:
                pass
      '';
in
{
  options.jupiter.customerDisplay = {
    enable = lib.mkEnableOption "TCxWave customer display animation + notifier";

    backend = lib.mkOption {
      type = lib.types.enum [
        "hidraw"
        "simulate"
      ];
      default = "hidraw";
      description = ''
        `hidraw` drives the real VFD. `simulate` renders a 2x20 to the journal
        for QEMU/CI hosts with no customer display attached.
      '';
    };

    fps = lib.mkOption {
      type = lib.types.float;
      default = 12.0;
      description = "Animation frame rate. 12 fps is smooth on a 2x20 VFD.";
    };

    message = lib.mkOption {
      type = lib.types.str;
      default = "JUPITER OS";
      description = "Text used by the bouncing-logo effect.";
    };

    perEffect = lib.mkOption {
      type = lib.types.float;
      default = 10.0;
      description = "Seconds per animation effect before cycling.";
    };

    notificationTtl = lib.mkOption {
      type = lib.types.float;
      default = 8.0;
      description = ''
        Seconds an MQTT notification overlays the animations before they
        resume (overridable per-message via the JSON `ttl` field).
      '';
    };

    mqtt = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Subscribe for transient notifications from Home Assistant.";
      };

      broker = lib.mkOption {
        type = lib.types.str;
        default = "10.1.1.3";
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
          `ha-linux-agent/#` — the topic root this daemon subscribes under.
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
        default = "ha-linux-agent/customer-display";
        description = ''
          Topic root. The daemon subscribes to `<topic>/<host>` and
          `<topic>/all`. Payload is plain text (→ row 1) or JSON
          `{line1, line2, mode, ttl}` (`mode`: auto|scroll|static). It overlays
          for `ttl` seconds (default notificationTtl), then animations resume.
          Liveness is retained on `<topic>/<host>/state`.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.tcxwave-cdp-anim = {
      description = "TCxWave customer display animation + notifier";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart =
          "${cdpAnim}/bin/tcxwave-cdp-anim"
          + " --backend ${cfg.backend}"
          + " --fps ${toString cfg.fps}"
          + " --message ${lib.escapeShellArg cfg.message}"
          + " --per-effect ${toString cfg.perEffect}"
          + " --notif-ttl ${toString cfg.notificationTtl}"
          + lib.optionalString cfg.mqtt.enable (
            " --mqtt"
            + " --broker ${cfg.mqtt.broker}"
            + " --port ${toString cfg.mqtt.port}"
            + " --username ${cfg.mqtt.username}"
            + " --topic ${cfg.mqtt.topic}"
            + lib.optionalString (cfg.mqtt.passwordFile != null) (" --password-file ${cfg.mqtt.passwordFile}")
          );
        Restart = "always";
        RestartSec = "5s";
        # Root so it can open the video-group /dev/hidrawN node, read the sops
        # password file, and stay below the dashboard. Eye-candy -> Nice 19.
        User = "root";
        Nice = 19;
      };
    };
  };
}
