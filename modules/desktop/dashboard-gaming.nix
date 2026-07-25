{
  config,
  pkgs,
  lib,
  ...
}:

# Dashboard ↔ gaming modes for the TCx Wave kiosks, switchable from Home
# Assistant. Normally the kiosk shows the Cage + Chromium dashboard; HA can flip
# it to any enabled gamescope session — Steam (Deck UI), Heroic, or Lutris — and
# back. All session modes share a single tty1 and are mutually exclusive.
#
# --- Why a custom service, not Jovian's native session ---------------------
# Jovian-NixOS's gamescope "gaming mode" session is a *systemd user unit*
# (gamescope-session.service) that boots via an SDDM *autologin* into the
# gamescope-wayland session (see jovian's modules/steam/autostart.nix). SDDM
# and Cage both want to own the graphical seat / tty1, so jovian's
# autoStart=true would boot straight into gaming and fight cage. Instead we
# keep jovian's *software stack* (Steam, gamescope + its cap_sys_nice wrapper,
# Proton, the gamescope-wsi Vulkan layer) but run each session ourselves as a
# single start/stoppable SYSTEM service on a SHARED tty1, modelled on Cage's
# own PAM/logind seat wiring. Only one session owns the display at a time.
#
# --- Switching model -------------------------------------------------------
# ha-linux-agent's backend-launcher (modules/services/ha-agent.nix) collapses
# the dashboard plus every enabled mode into ONE HA `select` via launcher group
# "session": selecting a mode best-effort-stops the others, then starts it. A
# systemd `Conflicts=` mesh between every pair of session units (each mode unit
# conflicts cage-tty1 and all sibling modes) is a belt-and-suspenders backstop
# — the launcher's mutual exclusion is best-effort and sequential, not atomic.
# No chvt, no polkit-for-chvt, no extra VTs.

let
  cfg = config.jupiter.dashboardGaming;

  # Launch a mode's session through a PATH that resolves the programs.steam /
  # heroic / lutris wrappers (/run/current-system/sw/bin). The explicit
  # XDG_RUNTIME_DIR / DBUS env is needed because a plain systemd service does
  # NOT inherit the full pam_systemd session env that jovian's SDDM-launched
  # gamescope-session gets — without XDG_RUNTIME_DIR gamescope can't create its
  # Wayland socket and segfaults early on this iGPU.
  #
  # NOTE: we deliberately use the PLAIN system gamescope, NOT jovian's
  # cap_sys_nice wrapper at /run/wrappers/bin/gamescope — that wrapper is not
  # needed here (plain gamescope loses only scheduling priority, acceptable on
  # these kiosks) and stripping it keeps one fewer variable in play. It was
  # also ruled out as the cause of the bwrap failure below (commit 3ce5226).
  #
  # capsh --noamb: pam_systemd puts CAP_WAKE_ALARM in this session's *ambient*
  # capability set for any seat/VT session (systemic, not something our unit
  # config requests; these units' own AmbientCapabilities= is empty). Ambient
  # capabilities survive every fork/exec down the tree, so the bundled
  # bubblewrap that Steam, Heroic AND Lutris all spawn (via umu →
  # pressure-vessel → bwrap, for Proton games) inherits CAP_WAKE_ALARM and
  # refuses to start ("Unexpected capabilities but not setuid, old file caps
  # config?" — bwrap treats "has caps but isn't setuid" as a sandbox escape
  # risk). Clearing the ambient set here, before gamescope ever execs the app,
  # means nothing downstream inherits it. The dashboard (Chromium under cage)
  # never hits this because it doesn't sandbox with bwrap.
  mkLauncher =
    mode: command:
    pkgs.writeShellScript "jupiter-${mode}-session" ''
      export PATH=/run/current-system/sw/bin:$PATH
      export XDG_RUNTIME_DIR="/run/user/$(id -u ${cfg.sessionUser})"
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
      exec ${pkgs.libcap}/bin/capsh --noamb -- -c 'exec ${command}'
    '';

  # Shared tty1 PAM/logind seat wiring — a start/stoppable system unit that can
  # grab DRM master on tty1. Modelled on nixpkgs' services.cage: pam_systemd
  # registers a seat session on the VT, which is what grants DRM master. tty1
  # is SHARED with cage and every other mode (not a separate VT per session):
  # the launcher's group mutex stops the others before this starts, so only one
  # ever holds the display.
  sessionOnTty1 = {
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
    unitConfig.ConditionPathExists = "/dev/tty1";
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
    };
  };

  # Single source of truth for the mode catalogue. Drives both the option
  # interface (modes.<name>.enable / .command, generated below) and the session
  # units / launcher / polkit / HA select / impermanence wiring. Adding a mode
  # is one entry here — e.g. a future retroarch mode. The steam entry preserves
  # the debugged Steam/Deck-UI session byte-for-byte (same command, same
  # capsh/PATH/XDG/DBUS launcher, same persisted dirs).
  #
  # `command` must NOT pass gamescope's -e/--steam flag for non-Steam apps:
  # -e and --steam are the SAME getopt flag (gamescope main.cpp:2579), Steam-
  # only — it injects STEAM_GAMESCOPE_* env the Steam client reads and switches
  # gamescope to its Steam-controlled connector strategy. Heroic/Lutris use
  # plain `gamescope -f -- <app>`.
  #
  # `persist` are the XDG paths each app writes login/library state to
  # (researched against the apps' own sources): Heroic nests config+auth+library
  # metadata under ~/.config/heroic and installs games to ~/Games/Heroic; Lutris
  # splits config (~/.config/lutris) and data (~/.local/share/lutris, incl. the
  # pga.db library DB) — both are persisted because Lutris falls back
  # config→data when the config dir is absent. Caches stay ephemeral.
  modeSpecs = {
    steam = {
      enableDefault = true;
      command = "gamescope --steam -e -- steam -gamepadui";
      description = "gamescope/Steam session (tty1)";
      icon = "mdi:steam";
      persist = [
        ".steam"
        ".local/share/Steam"
        ".config/Steam"
        ".config/gamescope"
      ];
    };
    heroic = {
      enableDefault = false;
      command = "gamescope -f -- heroic";
      description = "gamescope/Heroic session (tty1)";
      icon = "mdi:gamepad-variant";
      persist = [
        ".config/heroic"
        "Games/Heroic"
      ];
    };
    lutris = {
      enableDefault = false;
      command = "gamescope -f -- lutris";
      description = "gamescope/Lutris session (tty1)";
      icon = "mdi:gamepad";
      persist = [
        ".config/lutris"
        ".local/share/lutris"
      ];
    };
    # Pegasus over the eXoDOS + eXoWin3x collection. Everything around the
    # session (NFS mount of europa, overlayfs, metadata generator, exo-launch
    # wrapper) is wired in modules/desktop/exodos.nix and pulled in by
    # tcxwave-kiosk.nix. pegasus-fe is the binary name (not `pegasus`).
    # Persisted dirs cover Pegasus config + the per-kiosk first-run extraction
    # cache under the gamer home (overlay upper lives at /var/lib/exo-overlay
    # instead and is persisted via impermanence.extraDirectories from
    # exodos.nix directly).
    exodos = {
      enableDefault = false;
      command = "gamescope -f -- pegasus-fe";
      description = "gamescope/eXo (DOS + Win3.x) session (tty1)";
      icon = "mdi:controller-classic";
      persist = [
        ".config/pegasus-frontend"
        ".cache/pegasus-frontend"
      ];
    };
  };

  # The modes this host has enabled, in catalogue declaration order.
  enabledModes = lib.filter (m: cfg.modes.${m}.enable) (lib.attrNames modeSpecs);

  # Sibling mode units a given mode must conflict with (cage-tty1 is already in
  # sessionOnTty1.conflicts). With N modes this is what makes the mutual-
  # exclusion backstop pairwise-complete.
  siblings = m: map (other: "jupiter-${other}.service") (lib.remove m enabledModes);
in
{
  imports = [ ../gaming/console.nix ];

  options.jupiter.dashboardGaming = {
    enable = lib.mkEnableOption "Dashboard ↔ gaming mode switch for a Cage kiosk (Home Assistant controlled)";

    sessionUser = lib.mkOption {
      type = lib.types.str;
      default = "gamer";
      description = ''
        User that owns the game libraries and runs every session mode. Kept
        separate from the kiosk user so Steam/Heroic/Lutris state lives in its
        own home (and gets its own impermanence persistence — see below).
      '';
    };

    # Per-mode options generated from `modeSpecs`, mirroring console.nix's
    # appCatalog pattern. `steam` defaults on (preserving the original always-on
    # gaming session); heroic/lutris default off and are opted into per-profile
    # (tcxwave-kiosk.nix turns them on fleet-identically).
    modes = lib.mapAttrs (name: spec: {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = spec.enableDefault;
        description = "Expose a ${name} gamescope session mode, switchable from Home Assistant.";
      };
      command = lib.mkOption {
        type = lib.types.str;
        default = spec.command;
        description = ''
          Session command for the ${name} mode's tty1 unit. Runs with
          /run/current-system/sw/bin on PATH so the programs.* wrappers
          resolve, under capsh --noamb (see mkLauncher).
        '';
      };
    }) modeSpecs;
  };

  config = lib.mkIf cfg.enable {
    # --- Gaming software stack (Jovian), NO SDDM autostart -------------------
    # Stock kernel + stock Mesa: these are low-power Intel (HD 520) kiosks on
    # ZFS, not CachyOS boxes. gamingMode.autoStart = false is load-bearing:
    # jovian's autoStart would enable SDDM (conflicts with cage); we drive each
    # session via the jupiter-<mode> services below instead.
    jupiter.gaming.console = {
      enable = true;
      gpu = "intel";
      user = cfg.sessionUser;
      cachyOsKernel = false;
      mesaGit = false;
      gamingMode = {
        enable = true;
        autoStart = false;
      };
    };

    users.users.${cfg.sessionUser} = {
      isNormalUser = true;
      extraGroups = [
        "video"
        "render"
        "input"
        "audio"
      ];
    };

    # --- One start/stoppable session service per enabled mode (shared tty1) --
    # NOT wantedBy anything: cage-tty1 auto-starts at boot (dashboard by
    # default); each mode is started on demand by its HA select entry. The
    # generated mode units and the cage-tty1 backstop conflict are folded into
    # one mkMerge so this module defines `systemd.services` exactly once (a
    # single module can't assign the same path twice without mkMerge).
    systemd.services = lib.mkMerge [
      # Each unit is keyed jupiter-<mode> (NOT the bare mode name): systemd
      # derives the .service filename from the attr key, so this name is what
      # the launcherApps/polkit/conflicts entries below all reference.
      (builtins.listToAttrs (
        map (
          m:
          lib.nameValuePair "jupiter-${m}" (
            lib.mkMerge [
              sessionOnTty1
              {
                description = modeSpecs.${m}.description;
                conflicts = siblings m;
                serviceConfig = {
                  ExecStart = "${mkLauncher m cfg.modes.${m}.command}";
                  User = cfg.sessionUser;
                  PAMName = "jupiter-${m}";
                };
              }
            ]
          )
        ) enabledModes
      ))
      # Backstop mutual exclusion at the unit level: cage-tty1 conflicts every
      # enabled mode unit (each mode unit already conflicts cage-tty1 + siblings
      # via sessionOnTty1 + `siblings` above).
      { cage-tty1.conflicts = map (m: "jupiter-${m}.service") enabledModes; }
    ];

    # pam_systemd on each session => a logind seat session on tty1 => DRM master.
    security.pam.services = lib.genAttrs (map (m: "jupiter-${m}") enabledModes) (_: {
      startSession = true;
    });

    # ha-linux-agent runs as an unprivileged systemd --user service (user io),
    # so starting/stopping these SYSTEM units from the HA select needs a
    # narrowly-scoped polkit rule — io, these unit names, start+stop only.
    # (cage's module already pulls polkit in, so security.polkit.enable is on.)
    security.polkit.extraConfig =
      let
        unitChecks = lib.concatStringsSep " || " (
          map (u: ''unit == "${u}"'') (
            [ "cage-tty1.service" ] ++ map (m: "jupiter-${m}.service") enabledModes
          )
        );
      in
      ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              subject.user == "io") {
            var unit = action.lookup("unit");
            var verb = action.lookup("verb");
            if ((verb == "start" || verb == "stop") && (${unitChecks})) {
              return polkit.Result.YES;
            }
          }
        });
      '';

    # --- Home Assistant control: one `select` over dashboard + every mode ----
    # Profiles sharing group "session" collapse into a single HA select
    # (ha-agent.nix). cage-tty1 (the dashboard) is the always-on default; each
    # enabled mode is a sibling. (tcxwave-kiosk.nix appends the screen-power
    # `light` profile to this same list — list options concatenate, so the two
    # definitions coexist without conflict.)
    jupiter.services.haAgent.launcherApps = [
      {
        id = "dashboard";
        name = "${config.networking.hostName} dashboard";
        unit = "cage-tty1.service";
        scope = "system";
        group = "session";
        icon = "mdi:monitor-dashboard";
      }
    ]
    ++ map (m: {
      id = m;
      name = "${config.networking.hostName} ${m}";
      unit = "jupiter-${m}.service";
      scope = "system";
      group = "session";
      icon = modeSpecs.${m}.icon;
    }) enabledModes;

    # --- Impermanence: keep each enabled mode's state across reboots ---------
    # Without this the impermanent kiosk root wipes Steam/Heroic/Lutris login,
    # library manifest and config on every reboot. (Game files themselves live
    # under each app's install dir — .local/share/Steam/steamapps, Games/Heroic,
    # per-game for Lutris — which the matching persist entries also cover.)
    jupiter.core.impermanence.users.${cfg.sessionUser}.directories = lib.unique (
      lib.concatMap (m: modeSpecs.${m}.persist) enabledModes
    );
  };
}
