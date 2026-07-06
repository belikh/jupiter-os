#!/usr/bin/env python3
import os
import sys
import select
import time
import subprocess
import re

# Inactivity timeout in seconds (default: 5 minutes)
IDLE_TIMEOUT = 300

def get_wayland_env():
    """Gets the environment variables needed to communicate with the Cage compositor."""
    env = os.environ.copy()
    env['XDG_RUNTIME_DIR'] = '/run/user/1001'
    env['WAYLAND_DISPLAY'] = 'wayland-0'
    # Ensure standard NixOS binary paths are in PATH
    env['PATH'] = env.get('PATH', '') + ':/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin'
    return env

def run_wlr_randr(args):
    """Runs wlr-randr with the correct Wayland environment."""
    env = get_wayland_env()
    # Try running direct first, fall back to nix-shell if not installed in systemPackages
    try:
        subprocess.run(['wlr-randr'] + args, env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        # Fallback to nix-shell
        cmd = f"nix-shell -p wlr-randr --run 'wlr-randr {' '.join(args)}'"
        subprocess.run(cmd, env=env, shell=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def get_touchscreen_device():
    """Scans /proc/bus/input/devices to find the Atmel maXTouch event device path."""
    try:
        with open('/proc/bus/input/devices', 'r') as f:
            content = f.read()
    except Exception as e:
        print(f"Error reading input devices: {e}", file=sys.stderr)
        return None

    # Find the section for Atmel maXTouch
    # Sections are separated by double newlines
    devices = content.split('\n\n')
    for dev in devices:
        if "Atmel maXTouch Digitizer+Mouse" in dev:
            # Extract the event handler (e.g. event6)
            match = re.search(r'Handlers=.*?event(\d+)', dev)
            if match:
                event_num = match.group(1)
                dev_path = f"/dev/input/event{event_num}"
                # Verify we can open it
                if os.path.exists(dev_path):
                    return dev_path
    return None

def is_screen_enabled():
    """Checks the sysfs status to see if the eDP-1 screen is enabled."""
    try:
        with open('/sys/class/drm/card1-eDP-1/enabled', 'r') as f:
            status = f.read().strip()
            return status == "enabled"
    except Exception as e:
        # Fallback to wlr-randr query if sysfs is inaccessible
        print(f"Error reading sysfs connector state: {e}", file=sys.stderr)
        return True

def set_screen_power(power_on):
    """Powers the display panel eDP-1 ON or OFF."""
    state = "on" if power_on else "off"
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Powering screen {state.upper()}...")
    try:
        run_wlr_randr(['--output', 'eDP-1', f'--{state}'])
    except Exception as e:
        print(f"Error running wlr-randr: {e}", file=sys.stderr)

def main():
    print("TCx Wave Touch-Wake Daemon started.")
    
    # Locate device
    dev_path = get_touchscreen_device()
    if not dev_path:
        print("Error: Atmel touchscreen device not found in /proc/bus/input/devices", file=sys.stderr)
        sys.exit(1)
    print(f"Monitoring touchscreen at: {dev_path}")

    try:
        fd = open(dev_path, 'rb')
    except PermissionError:
        print(f"Permission denied. Run as root or add user to 'input' group.", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error opening {dev_path}: {e}", file=sys.stderr)
        sys.exit(1)

    last_activity = time.time()
    screen_on = is_screen_enabled()
    print(f"Initial screen state: {'ON' if screen_on else 'OFF'}")

    try:
        while True:
            # Calculate sleep timeout based on idle timer
            now = time.time()
            time_since_activity = now - last_activity
            
            if screen_on and time_since_activity >= IDLE_TIMEOUT:
                # Idle timeout reached -> Turn screen OFF
                set_screen_power(False)
                screen_on = False
                # Drain any stale events that happened during transition
                select.select([fd], [], [], 0.5)
                try:
                    os.read(fd.fileno(), 1024)
                except BlockingIOError:
                    pass
                continue

            # Wait for touch events
            # We timeout every 5 seconds to run the idle check loop
            r, _, _ = select.select([fd], [], [], 5.0)
            if r:
                # Activity detected! Read input reports to drain queue
                try:
                    os.read(fd.fileno(), 1024)
                except Exception:
                    pass
                
                last_activity = time.time()
                
                # If screen is off, wake it up
                if not screen_on:
                    set_screen_power(True)
                    screen_on = True
                    # Let the system stabilize
                    time.sleep(1)
                    
    except KeyboardInterrupt:
        print("\nExiting daemon.")
    finally:
        fd.close()

if __name__ == "__main__":
    main()
