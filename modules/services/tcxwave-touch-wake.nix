{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.touchWake;

  touchWakeScript = pkgs.writers.writePython3Bin "tcxwave-touch-wake" { } ''
    import sys
    import os
    import fcntl
    import select
    import time
    import subprocess
    import re

    # Inactivity timeout in seconds (configured via NixOS options)
    IDLE_TIMEOUT = ${toString cfg.idleTimeout}

    # EVIOCGBIT(EV_ABS, len): _IOC_READ, 'E', 0x20+EV_ABS(3), len -- lets us
    # ask a candidate event node "do you actually report ABS_MT_POSITION_X",
    # rather than trusting /proc/bus/input/devices parse order.
    EV_ABS = 3
    ABS_MT_POSITION_X = 0x35


    def _ioc(d, t, nr, sz):
        return (d << 30) | (sz << 16) | (ord(t) << 8) | nr


    EVIOCGBIT_ABS = _ioc(2, 'E', 0x20 + EV_ABS, 8)


    def run_systemctl(args):
        """Runs systemctl to control display state service."""
        try:
            subprocess.run(
                ["systemctl"] + args,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as e:
            print(f"Error running systemctl {args}: {e}", file=sys.stderr)


    def _reports_multitouch(dev_path):
        """True iff this event node's EV_ABS bitmap has ABS_MT_POSITION_X set.

        The Atmel touch controller is a composite USB device exposing THREE
        separate "Atmel maXTouch Digitizer+Mouse" event nodes (confirmed live
        on amalthea 2026-07-25) -- only one of them carries real multitouch
        coordinates; the others are near-empty legacy mouse-emulation
        collections that never fire on an actual finger touch. Picking the
        first name match (the old approach) grabbed one of the empty ones,
        which is why touch-wake never saw a real touch to begin with.
        """
        try:
            fd = os.open(dev_path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            return False
        try:
            buf = bytearray(8)
            fcntl.ioctl(fd, EVIOCGBIT_ABS, buf, True)
            byte_i, bit_i = ABS_MT_POSITION_X // 8, ABS_MT_POSITION_X % 8
            return bool(buf[byte_i] & (1 << bit_i))
        except OSError:
            return False
        finally:
            os.close(fd)


    def get_touchscreen_device():
        """Finds the Atmel maXTouch event node that actually reports
        multitouch, not just the first name match."""
        try:
            with open("/proc/bus/input/devices", "r") as f:
                content = f.read()
        except Exception as e:
            print(f"Error reading input devices: {e}", file=sys.stderr)
            return None

        devices = content.split("\n\n")
        for dev in devices:
            if "Atmel maXTouch Digitizer+Mouse" in dev:
                match = re.search(r"Handlers=.*?event(\d+)", dev)
                if not match:
                    continue
                dev_path = f"/dev/input/event{match.group(1)}"
                if os.path.exists(dev_path) and _reports_multitouch(dev_path):
                    return dev_path
        return None


    def is_screen_enabled():
        """Checks if the tcxwave-screen-power systemd service is active."""
        try:
            res = subprocess.run(
                ["systemctl", "is-active", "tcxwave-screen-power.service"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            return res.stdout.strip() == "active"
        except Exception as e:
            print(f"Error checking service status: {e}", file=sys.stderr)
            return True


    def set_screen_power(power_on):
        """Powers display panel ON/OFF via tcxwave-screen-power.service."""
        state = "start" if power_on else "stop"
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] Running systemctl {state} on screen-power service...")
        run_systemctl([state, "tcxwave-screen-power.service"])


    def main():
        print("TCx Wave Touch-Wake Daemon started.")

        dev_path = get_touchscreen_device()
        if not dev_path:
            msg = "Error: Atmel touchscreen device not found"
            print(msg, file=sys.stderr)
            sys.exit(1)
        print(f"Monitoring touchscreen at: {dev_path}")

        try:
            fd = open(dev_path, "rb")
        except Exception as e:
            print(f"Error opening {dev_path}: {e}", file=sys.stderr)
            sys.exit(1)

        last_activity = time.time()
        screen_on = is_screen_enabled()
        print(f"Initial screen state: {'ON' if screen_on else 'OFF'}")

        try:
            while True:
                now = time.time()
                time_since_activity = now - last_activity

                if screen_on and time_since_activity >= IDLE_TIMEOUT:
                    set_screen_power(False)
                    screen_on = False
                    # Drain any stale events that happened during transition
                    select.select([fd], [], [], 0.5)
                    try:
                        os.read(fd.fileno(), 1024)
                    except BlockingIOError:
                        pass
                    continue

                r, _, _ = select.select([fd], [], [], 5.0)
                if r:
                    try:
                        os.read(fd.fileno(), 1024)
                    except Exception:
                        pass

                    last_activity = time.time()

                    if not screen_on:
                        set_screen_power(True)
                        screen_on = True
                        time.sleep(1)

        except KeyboardInterrupt:
            print("\nExiting daemon.")
        finally:
            fd.close()


    if __name__ == "__main__":
        main()
  '';
in
{
  options.jupiter.touchWake = {
    enable = lib.mkEnableOption "TCx Wave Touch-Wake Daemon for display wake-on-touch";
    idleTimeout = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Inactivity timeout in seconds before screen powers off.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Systemd service for physical screen power (starts = ON, stops = OFF)
    systemd.services.tcxwave-screen-power = {
      description = "TCx Wave Display Power Control (DPMS)";
      after = [ "cage-tty1.service" ];
      # partOf (NOT bindsTo): restart/stop WITH cage so the daemon tracks the
      # compositor, but without bindsTo's "forcibly stop if the bound unit is
      # re-evaluated" semantic — which killed the daemon on every nixos-rebuild
      # switch (Restart=always does not override a binding-initiated stop).
      partOf = [ "cage-tty1.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # wlr-randr --off only disables the DRM mode/CRTC; it does not touch
        # the panel backlight (confirmed live on amalthea 2026-07-25: after
        # --off, /sys/class/backlight/*/brightness stayed at max and the
        # panel stayed visibly lit — the compositor's own state was "off"
        # while the physical screen was not). Drive the backlight brightness
        # directly too, on whatever backlight device the kernel exposes
        # (varies by driver — acpi_video0 here — so iterate rather than
        # hardcode it).
        #
        # Deliberately brightness only, NOT bl_power: this panel assembly's
        # touch digitizer (a separate USB device) shares a power rail with
        # the backlight, and bl_power=4 cuts that rail — confirmed live: with
        # bl_power=4 a real touch produced zero events anywhere in the input
        # subsystem (evdev, raw hidraw, usbmon all silent); restoring
        # bl_power to 0 while leaving brightness at 0 (still visibly dark)
        # brought touch events back immediately. brightness=0 alone gives
        # the correct dark appearance without that side effect.
        ExecStart = "${pkgs.writeShellScript "tcxwave-screen-on" ''
          export XDG_RUNTIME_DIR=/run/user/1001
          export WAYLAND_DISPLAY=wayland-0
          ${pkgs.wlr-randr}/bin/wlr-randr --output eDP-1 --on
          for bl in /sys/class/backlight/*; do
            [ -d "$bl" ] || continue
            cat "$bl/max_brightness" > "$bl/brightness" 2>/dev/null || true
          done
        ''}";
        ExecStop = "${pkgs.writeShellScript "tcxwave-screen-off" ''
          export XDG_RUNTIME_DIR=/run/user/1001
          export WAYLAND_DISPLAY=wayland-0
          ${pkgs.wlr-randr}/bin/wlr-randr --output eDP-1 --off
          for bl in /sys/class/backlight/*; do
            [ -d "$bl" ] || continue
            echo 0 > "$bl/brightness" 2>/dev/null || true
          done
        ''}";
        User = "root";
      };
    };

    systemd.services.tcxwave-touch-wake = {
      description = "TCx Wave Touch-Wake Daemon";
      after = [
        "cage-tty1.service"
        "tcxwave-screen-power.service"
      ];
      # partOf (NOT bindsTo): restart/stop WITH cage so the daemon tracks the
      # compositor, but without bindsTo's "forcibly stop if the bound unit is
      # re-evaluated" semantic — which killed the daemon on every nixos-rebuild
      # switch (Restart=always does not override a binding-initiated stop).
      #
      # partOf only propagates cage's STOPS down to this unit, never its
      # STARTS back up — so the very first time cage-tty1 stopped (a
      # nixos-rebuild switch, a dashboard<->gaming toggle) this daemon went
      # down and nothing ever started it again; Restart=always only fires on
      # an unexpected exit, not a deliberate propagated stop. Confirmed dead
      # on all 4 kiosks 2026-07-25. Also wanting cage-tty1.service (not just
      # multi-user.target) closes the loop: starting cage now also starts
      # this, matching partOf's stop-together half with a start-together half.
      partOf = [ "cage-tty1.service" ];
      wantedBy = [
        "multi-user.target"
        "cage-tty1.service"
      ];
      serviceConfig = {
        ExecStart = "${touchWakeScript}/bin/tcxwave-touch-wake";
        Restart = "always";
        RestartSec = "5s";
        User = "root";
        Environment = [
          "XDG_RUNTIME_DIR=/run/user/1001"
          "WAYLAND_DISPLAY=wayland-0"
          "PYTHONUNBUFFERED=1"
        ];
      };
    };

    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "tcxwave-screen-power.service" &&
            subject.user == "io") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
