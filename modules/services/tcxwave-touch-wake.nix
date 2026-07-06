{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.touchWake;

  touchWakeScript = pkgs.writers.writePython3Bin "tcxwave-touch-wake" {} ''
    import sys
    import os
    import select
    import time
    import subprocess
    import re

    # Inactivity timeout in seconds (configured via NixOS options)
    IDLE_TIMEOUT = ${toString cfg.idleTimeout}


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


    def get_touchscreen_device():
        """Scans devices to find the Atmel maXTouch event device path."""
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
                if match:
                    event_num = match.group(1)
                    dev_path = f"/dev/input/event{event_num}"
                    if os.path.exists(dev_path):
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
      bindsTo = [ "cage-tty1.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.writeShellScript "tcxwave-screen-on" ''
          export XDG_RUNTIME_DIR=/run/user/1001
          export WAYLAND_DISPLAY=wayland-0
          ${pkgs.wlr-randr}/bin/wlr-randr --output eDP-1 --on
        ''}";
        ExecStop = "${pkgs.writeShellScript "tcxwave-screen-off" ''
          export XDG_RUNTIME_DIR=/run/user/1001
          export WAYLAND_DISPLAY=wayland-0
          ${pkgs.wlr-randr}/bin/wlr-randr --output eDP-1 --off
        ''}";
        User = "root";
      };
    };

    systemd.services.tcxwave-touch-wake = {
      description = "TCx Wave Touch-Wake Daemon";
      after = [ "cage-tty1.service" "tcxwave-screen-power.service" ];
      bindsTo = [ "cage-tty1.service" ];
      wantedBy = [ "multi-user.target" ];
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
