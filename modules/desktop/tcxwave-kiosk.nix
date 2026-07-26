{
  config,
  lib,
  ...
}:

# Shared appliance profile for the 4 TCx Wave dashboard kiosks
# (amalthea/metis/adrastea/thebe) — identical 6140-E45 units, one per room.
# Every behavioral concern that is the same across the fleet lives here so the
# per-host files can hold ONLY what actually differs per unit: hostName,
# hostId, the OS disk by-id, and the dashboard URL (plus thebe's Wi-Fi).
#
# Add new kiosk features HERE, not in hosts/<name>/configuration.nix, or the
# fleet will drift again — that is exactly how thebe lost touch-wake and the
# ha-agent launcherApps while amalthea kept them.
#
# The mosquitto broker (modules/services/mqtt.nix) runs on callisto, not on
# any kiosk — all 4 kiosks are equally broker clients, pointed at callisto's
# static DHCP-reserved IP (10.1.1.3; callisto has no DNS/mDNS resolution yet,
# same reason build-machines.nix dials it by IP). The broker is
# infrastructure, not a dashboard feature, so it stays in callisto's host
# file rather than being pulled in here. (It used to run on amalthea; moved
# 2026-07-24 so the broker isn't coupled to a kiosk's impermanent/appliance
# lifecycle.)

let
  cfg = config.jupiter.tcxWaveKiosk;
in
{
  imports = [
    ../services/tcxwave-power-tuning.nix
    ../services/tcxwave-touch-wake.nix
    ../services/ha-agent.nix
    ./dashboard-kiosk.nix
    ./dashboard-gaming.nix
    # eXoDOS + eXoWin3x launcher (Pegasus over NFS + per-kiosk overlayfs).
    # Pulled in here so all 4 kiosks get it identically; the actual mode toggle
    # is below in jupiter.dashboardGaming.modes.exodos.enable.
    ./exodos.nix
    # Open-source driver + animation for the integrated customer-facing line
    # display (0x0f66:0x4500). Verified live on amalthea 2026-07-25
    # (tcxwave-cdp-anim.service running against the real hardware). See the
    # module for the reverse-engineered protocol.
    ../services/customer-display.nix
    # MSR card-swipe -> MQTT publisher (same 0x0f66:0x4500 IO Control device).
    # Grabs the reader's keyboard interface so swipes publish to MQTT instead
    # of leaking into the dashboard. Confirmed live on amalthea 2026-07-25:
    # a real swipe decodes as a correct ISO 7811 track burst end-to-end (MQTT
    # payload verified against the real hardware, not just eval). See
    # modules/services/customer-msr.nix for the protocol notes.
    ../services/customer-msr.nix
  ];

  options.jupiter.tcxWaveKiosk = {
    enable = lib.mkEnableOption "TCx Wave dashboard kiosk appliance profile";

    dashboardUrl = lib.mkOption {
      type = lib.types.str;
      description = "Home Assistant dashboard URL this unit displays full-screen.";
      example = "https://iot.jupiter.au/main-floor/main";
    };

    disk = lib.mkOption {
      type = lib.types.str;
      description = ''
        OS disk /dev/disk/by-id path. disko will WIPE this device on install,
        so point it at the unit's real OS SSD/NVMe (NOT a data disk). Leave
        the REPLACE-ME placeholder on units that aren't installed yet.
      '';
    };

    wifi = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Join Wi-Fi via the USB adapter (thebe) instead of wired ethernet.
          A no-op on the wired units, which have a default route within ~1s
          of boot regardless.
        '';
      };

      network = lib.mkOption {
        type = lib.types.str;
        default = "jupiter.au";
        description = "SSID to join when wifi is enabled.";
      };

      psk = lib.mkOption {
        type = lib.types.str;
        default = "REDACTED";
        description = "WPA PSK for the SSID.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Stateless kiosk appliance: erase-your-darlings root so the box always
    # boots to a known-pristine state and can't accumulate drift.
    jupiter.storage = {
      profile = "impermanent";
      disk = cfg.disk;
    };

    jupiter.core.impermanence = {
      enable = true;
      persistAdminHome = false; # no personal session on a kiosk
      # Keep the Chromium profile so the HA dashboard's session/cache survive
      # reboots (faster warm-up, stays logged in), plus the admin (io) CLI
      # configs that are annoying to re-establish after an erase.
      users.kiosk.directories = [
        ".config/chromium"
        ".cache/chromium"
      ];
      users.io.directories = [
        ".gemini"
      ];
    };

    jupiter.dashboardKiosk = {
      enable = true;
      url = cfg.dashboardUrl;
    };

    # Dashboard ↔ gaming modes, switchable from Home Assistant. Adds a
    # jupiter-<mode>.service per enabled mode on a shared tty1; all session
    # modes plus the Cage dashboard collapse into one HA `select` (launcher
    # group "session"). `steam` is on by default (the debugged Deck-UI session);
    # heroic + lutris + exodos are opted in here so all 4 kiosks get the same
    # set of modes. Enabled here once so the fleet stays identical — do NOT
    # re-add per-host, or the fleet drifts (see header comment).
    jupiter.dashboardGaming = {
      enable = true;
      modes.heroic.enable = true;
      modes.lutris.enable = true;
      modes.exodos.enable = true;
    };

    # eXoDOS + eXoWin3x collection wiring (NFS mount of europa's read-only
    # eXo dataset, per-kiosk overlayfs for saves + first-run extraction,
    # Pegasus metadata regenerator). Defaults match europa's static IP and
    # the layout of /mnt/europa/games — override only if those change.
    jupiter.exodos.enable = true;

    jupiter.boot.falloutSplash.enable = true;

    # Cool animations on the integrated customer-facing line display (the 2x20
    # VFD behind 0x0f66:0x4500). Enabled here once for all 4 identical units;
    # the daemon autodetects the display and no-ops (retries) if absent, so a
    # unit without the peripheral just logs and waits. See
    # modules/services/customer-display.nix for the reverse-engineered protocol
    # and the animation playlist. Per-unit enablement happens at deploy time.
    jupiter.customerDisplay.enable = true;

    # MSR card-swipe -> MQTT. Enabled fleet-wide; the daemon no-ops (rescans)
    # if a unit has no MSR. See modules/services/customer-msr.nix.
    jupiter.customerMsr.enable = true;

    # Touch-wake: power the panel off after idleTimeout and wake it on touch.
    # Exposes tcxwave-screen-power.service, which ha-agent surfaces as the
    # "screen-power" HA switch below.
    jupiter.touchWake = {
      enable = true;
      idleTimeout = 300; # 5 minutes
    };

    sops.secrets.mqtt_ha_linux_agent = { };

    # ha-agent publishes CPU/governor/EPP sensors to the broker and exposes
    # the touch-wake screen-power unit as a Home Assistant light (dimmable,
    # on/off) rather than a plain switch — a single widget instead of a
    # switch-plus-brightness-slider pair. On/off still goes through
    # tcxwave-screen-power.service (the same unit touch-wake drives), so
    # both stay in sync; brightness writes go straight to the backlight
    # ha-linux-agent already has 0666 permission on. mqttHost defaults to
    # callisto's broker, addressed by static IP (see the module header
    # comment for why not by hostname).
    jupiter.services.haAgent = {
      enable = true;
      mqttHost = lib.mkDefault "10.1.1.3";
      # 1s poll so the screen light's on/off + brightness track physical
      # button/touch changes in HA without a noticeable lag (io: "i want
      # updates every second"). Applies to every sensor this agent exposes
      # fleet-wide (CPU/session/etc too), not just the screen.
      pollIntervalSecs = 1;
      launcherApps = [
        {
          id = "screen-power";
          name = "${config.networking.hostName} screen";
          unit = "tcxwave-screen-power.service";
          scope = "system";
          icon = "mdi:monitor";
          backlight = "";
        }
        {
          # The 2x20 VFD customer-facing line display (0x0f66:0x4500), not
          # the main screen above. No power/brightness command exists in its
          # protocol (see modules/services/customer-display.nix), so "off"
          # is this unit stopped — the daemon blanks the glass on SIGTERM
          # before exiting. "on" restarts it and it re-finds the display and
          # resumes the animation playlist. io: "it's very bright at night".
          id = "customer-display";
          name = "${config.networking.hostName} customer display";
          unit = "tcxwave-cdp-anim.service";
          scope = "system";
          icon = "mdi:message-text-outline";
        }
      ];
    };

    # USB Wi-Fi adapter (NetGear A6210 / MediaTek MT7612U). Only thebe has one;
    # the wired kiosks leave wifi.enable at its false default.
    networking.wireless = lib.mkIf cfg.wifi.enable {
      enable = true;
      networks."${cfg.wifi.network}".psk = cfg.wifi.psk;
    };

    # networking.wireless (wpa_supplicant) and NetworkManager can't both
    # manage the same interface (hard assertion failure) — NixOS requires
    # wifi devices marked unmanaged by NM if wpa_supplicant already owns
    # them. Only matters where both are on: this host's wifi.enable plus
    # jupiter.gaming.console's gamingMode.enable (which turns on NM for the
    # Deck UI's network onboarding — see modules/gaming/console.nix). Match
    # by device type, not interface name, so it doesn't need updating if the
    # adapter changes.
    networking.networkmanager.unmanaged = lib.mkIf cfg.wifi.enable [ "type:wifi" ];

    # Integrated 15" PCAP touchscreen: NO custom/kernel driver needed. The panel
    # is a USB HID multitouch device handled in-tree by `hid-multitouch`, and
    # cage/wlroots consumes it via libinput. If, on a real unit, touch is offset
    # or the panel is mounted rotated, that's a userspace calibration matrix —
    # NOT a driver — applied via a udev/libinput rule, e.g.:
    #   services.udev.extraHwdb = ''
    #     # 90° clockwise: LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1
    #     evdev:name:*Touch*:* ENV{LIBINPUT_CALIBRATION_MATRIX}="..."
    #   '';
    # Left out until verified on hardware so we don't ship a wrong transform.

    # ---- Idle-time distributed build server ---------------------------------
    # A kiosk spends ~99.9999% of its life displaying a static dashboard and
    # idling — let the rest of the fleet borrow its Skylake CPU for builds.
    # Advertising gccarch-skylake lets it BUILD any other host's
    # skylake-tagged closure (currently nobody's — callisto's microarch is a
    # roadmap entry); today the practical value is generic x86_64-linux build
    # capacity for any host's closure. The CPU itself is Skylake-class but the
    # kiosk's own closure stays untuned (no jupiter.build.microarch here) —
    # same "can build it without being it" pattern as callisto
    # (hosts/callisto/configuration.nix).
    #
    # gccarch-btver2 (added 2026-07-20, matching modules/core/build-machines.nix's
    # kioskBuilders supportedFeatures): makes kiosks eligible to help build
    # europa's btver2-tuned closure too — btver2 is a portable baseline ISA
    # subset, safe to compile/execute on any modern x86_64 CPU including
    # Skylake. This is the REMOTE side of that eligibility — nix's own
    # daemon here enforces system-features against what a dispatcher
    # requests, independent of what the dispatcher's --builders string
    # claims, so both sides need this tag or the remote refuses the job
    # ("missing system features", confirmed hitting this in practice before
    # this was added here). Caveat carried over from build-machines.nix: each
    # kiosk only has ~7.6GiB RAM vs callisto's 64GB — a large tuned
    # derivation (clang/llvm) landing here instead of callisto risks
    # swap-thrashing or OOM. Acceptable per that module's reasoning.
    #
    # The pubkey matches the private half deployed as nix_build_ssh_key sops
    # secret fleet-wide via modules/core/build-machines.nix.
    nix.settings.system-features = lib.mkAfter [
      "gccarch-skylake"
      "gccarch-btver2"
      "big-parallel"
    ];

    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILv1nEsuHqlA1ykn1p8wZmhhv1Y77cBxhgu2tAO3DhlP jupiter-fleet-nix-build"
    ];

    # Bluetooth + audio for the kiosk displays. Useful for connecting wireless
    # speakers/soundbars; started by default but no cost if no BT device is present.
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings.General = {
        ControllerMode = "dual"; # Both legacy and LE (better compatibility)
        Enable = "Source,Sink,Media,Socket";
      };
    };

    services.pulseaudio = {
      enable = true;
      systemWide = true;
      daemon.config = {
        resample-method = "speex-float-5";
      };
    };
  };
}
