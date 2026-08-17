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
    # jupiterOS Arcade: Pegasus frontend for the HA-switchable gaming session.
    ./arcade.nix
    # eXo collection launch stack (eXoDOS/eXoWin3x/eXoWin9x from europa over
    # NFS + per-kiosk overlayfs + exo-launch). Contributes the collections
    # Pegasus shows; arcade.nix owns Pegasus itself.
    ./exodos.nix
    # Nintendo cartridge console collections (No-Intro NES/SNES/GB/GBC/GBA/N64)
    # from europa over a read-only NFS mount + retroarch with cores + per-kiosk
    # persisted saves. Sibling contributor to exodos.nix; see
    # modules/desktop/cartridges.nix and docs/adr/0001-*.
    ./cartridges.nix
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
    # Tailscale client for Jupiter tailnet
    ../../modules/services/tailscale.nix
    # mqttHost default references the fleet topology module
    ../network/fleet.nix
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
        default = "";
        description = ''
          WPA PSK for the SSID. Must be set via sops secrets for deployed hosts.
          See secrets/secrets.yaml for the encrypted value.
        '';
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
    # group "session"). ONLY `arcade` mode is enabled (Pegasus frontend;
    # dashboard-gaming.nix sets jupiter.arcade.enable from this mode toggle).
    jupiter.dashboardGaming = {
      enable = true;
      modes.arcade.enable = true;
    };

    # eXo collections (eXoDOS/eXoWin3x/eXoWin9x) in the arcade session:
    # per-collection NFS mounts of europa's curated datasets + per-kiosk
    # overlayfs for saves/extractions + exo-launch. See
    # modules/desktop/exodos.nix.
    jupiter.exodos.enable = true;

    # Nintendo cartridge console collections (No-Intro NES/SNES/GB/GBC/GBA/N64)
    # in the arcade session: read-only NFS mount of europa's scraped cartridge
    # tree + retroarch with the needed libretro cores + per-kiosk saves.
    # ROMs + metadata are bulk-staged/scraped on europa (rom-acquire/rom-scraper);
    # this module only consumes them. See modules/desktop/cartridges.nix.
    jupiter.cartridges.enable = true;

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

    # Power/kernel tuning (TLP, zram, i915 power-saving): the module is
    # mkEnableOption-gated (default off — it was an ungated side-effecting
    # module until 2026-08-17), and every kiosk wants it, so flip it HERE
    # rather than per-host. A non-kiosk host importing this profile gets it
    # too, which is the point of the profile.
    jupiter.tcxWavePowerTuning.enable = true;

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
      mqttHost = lib.mkDefault config.jupiter.fleet.addresses.callisto;
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
    # the wired kiosks leave wifi.enable at its false default. NetworkManager
    # manages the connection declaratively via ensureProfiles with PSK from sops.
    sops.secrets.wifi_psk = lib.mkIf cfg.wifi.enable { };

    # nixpkgs' hardware/xone.nix (hardware.xone.enable, on for every kiosk via
    # modules/gaming/console.nix's arcade-mode Xbox controller support)
    # unconditionally adds mt76x2u — thebe's own wifi chip — to
    # boot.blacklistedKernelModules alongside xpad. Confirmed live
    # (2026-07-30): `modprobe --showconfig` showed `blacklist mt76x2u` coming
    # from /etc/modprobe.d/nixos.conf, traced to that nixpkgs module, not
    # anything in this repo. Two clean reboots with the blacklist in place
    # showed wlp0s20f0u4u5 never appearing and no mt76x2u in `lsmod`, while a
    # bare `modprobe mt76x2u` (which ignores blacklist entries — those only
    # gate udev-alias/systemd-modules-load autoload) loaded it immediately
    # and it associated normally. Only thebe has this adapter, so only thebe
    # needs to override the blacklist; mkForce replaces the whole merged list
    # (tcxwave-power-tuning.nix's "pcspkr" + xone.nix's "xpad"/"mt76x2u"), so
    # the entries thebe still wants (xpad, still needed to avoid conflicting
    # with xone/xpadneo; pcspkr) have to be repeated here explicitly.
    boot.blacklistedKernelModules = lib.mkIf cfg.wifi.enable (
      lib.mkForce [
        "xpad"
        "pcspkr"
      ]
    );
    boot.kernelModules = lib.mkIf cfg.wifi.enable [ "mt76x2u" ];

    # Declarative NetworkManager profile for wifi. The PSK is NOT inlined into
    # the profile (ensureProfiles are world-readable in the nix store); instead
    # the connection marks the secret agent-owned (psk-flags = 1) and
    # nm-file-secret-agent supplies it at runtime from the sops-decrypted file
    # — the accepted modern method (see CLAUDE.md). This replaces an earlier
    # environmentFiles + envsubst + custom-service pipeline that raced the
    # ensure-profiles unit and shipped an empty PSK.
    networking.networkmanager.ensureProfiles = lib.mkIf cfg.wifi.enable {
      secrets.entries = [
        {
          matchId = cfg.wifi.network;
          matchSetting = "802-11-wireless-security";
          key = "psk";
          file = config.sops.secrets.wifi_psk.path;
        }
      ];
      profiles."${cfg.wifi.network}" = {
        connection = {
          id = cfg.wifi.network;
          type = "wifi";
          permissions = ""; # system connection (no session agent on a headless kiosk)
          autoconnect = true;
        };
        wifi = {
          ssid = cfg.wifi.network;
          mode = "infrastructure";
          hidden = false;
        };
        wifi-security = {
          auth-alg = "open";
          # jupiter.au is WPA3-Personal, SAE-only (confirmed live: every
          # jupiter.au BSSID's RSN-FLAGS list "sae" with no "psk" — unlike
          # e.g. OPTUS_31CCB8N's transition-mode "psk sae"). key-mgmt =
          # "wpa-psk" here silently broke autoconnect: NetworkManager's
          # policy-driven candidate matching (nm_policy_device_recheck_auto_activate)
          # correctly excludes a wpa-psk profile against an SAE-only AP and
          # never even attempts it — zero log output, connection just never
          # comes up on its own. A forced `nmcli connection up` bypasses that
          # candidate check and connects anyway, which is why 696336e/739be01
          # both looked verified (manual test) but never actually fixed
          # unassisted autoconnect. NM reuses the same `psk` property/secret
          # for the SAE password, so psk-flags/nm-file-secret-agent wiring
          # below is unchanged.
          key-mgmt = "sae";
          psk-flags = 1; # NM_SECRET_AGENT_OWNED — value from nm-file-secret-agent
        };
        ipv4 = {
          method = "auto";
        };
        ipv6 = {
          method = "auto";
          addr-gen-mode = "stable-privacy";
        };
      };
    };

    # NOTE: do NOT disable networking.wireless here. NetworkManager does not
    # run its own supplicant — it drives wpa_supplicant as a D-Bus backend
    # (nixpkgs' networkmanager.nix forces wireless.enable=true +
    # dbusControlled=true whenever NM is on). The D-Bus fi.w1.wpa_supplicant1
    # service only ships with the wpa_supplicant package and is only
    # registered while wireless.enable=true, so forcing it false leaves NM
    # with no Wi-Fi backend and the adapter never associates. Commit 696336e
    # made that mistake and stranded thebe offline.

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

    # Tailscale client for Jupiter tailnet. Reusable tag:fleet pre-auth key,
    # shared fleet-wide via sops — self-registers on switch, no manual
    # `headscale auth register` step needed.
    sops.secrets.tailscale_fleet_authkey = { };
    jupiter.services.tailscale = {
      enable = true;
      # NOT https://headscale.jupiter.au: that's Cloudflare-Tunnel-fronted,
      # and cloudflared cannot carry the TS2021/DERP protocols at all
      # (github.com/cloudflare/cloudflared#883, confirmed live). Goes
      # through the public neptune.jupiter.au:8080 port-forward instead,
      # where headscale terminates real TLS itself (see
      # hosts/europa/configuration.nix's jupiter.services.headscale.tls).
      serverUrl = "https://neptune.jupiter.au:8080";
      tags = [ "tag:fleet" ];
      acceptRoutes = true;
      authKeyFile = config.sops.secrets.tailscale_fleet_authkey.path;
    };

    # ---- Own closure: tuned for the CPU --------------------------------------
    # Skylake-class i5-6300U. CI (.github/workflows/ci.yml, main-only) builds
    # and pushes this to Harmonia — the kiosk itself only ever substitutes the
    # result, so the ~7.6GiB RAM caveat below (about ACCEPTING remote build
    # jobs FROM other hosts) doesn't apply to tuning its own closure.
    # Verify Harmonia has it before switching: `nix path-info --substituters
    # http://10.1.1.2:5000 <toplevel>`.
    jupiter.build.microarch = "skylake";

    # ---- Idle-time distributed build server ---------------------------------
    # A kiosk spends ~99.9999% of its life displaying a static dashboard and
    # idling — let the rest of the fleet borrow its Skylake CPU for builds.
    # Advertising gccarch-skylake lets it BUILD any other host's
    # skylake-tagged closure (now callisto's and its own too); today the
    # practical value is generic x86_64-linux build capacity for any host's
    # closure. Same "can build it without being it" pattern as callisto
    # (hosts/callisto/configuration.nix) for OTHER hosts' derivations. This
    # kiosk's own closure is tuned above (skylake); callisto's is too now.
    #
    # gccarch-bdver4 (matching modules/core/build-machines.nix's
    # kioskBuilders supportedFeatures): makes kiosks eligible to help build
    # europa's bdver4-tuned (Excavator) closure too — Skylake is an ISA
    # superset of Excavator's standard extensions (AVX2/FMA/BMI/F16C), so a
    # Skylake kiosk can safely compile and run-check europa's bdver4 code.
    # This is the REMOTE side of that eligibility — nix's own
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
      "gccarch-bdver4"
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
      systemWide = false; # Per-user mode, running as the gamer user
    };
  };
}
