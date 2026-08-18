{
  config,
  lib,
  pkgs,
  ...
}:

# Nintendo console ROM collections (No-Intro cartridge + Non-Redump optical +
# modern disc/card sets) for the Pegasus arcade session. Sibling to
# modules/desktop/exodos.nix, but far simpler: every system here is a tree of
# leaf ROM/disc files read directly by its emulator over a read-only NFS mount,
# so — unlike the eXo zips — there is NO per-kiosk overlayfs, NO
# extract-on-first-run, and NO sudo extraction helper. Saves are redirected out
# of the read-only ROM tree into a per-kiosk persisted dir.
#
# The ROMs + their Pegasus metadata (metadata.pegasus.txt + media/) live on
# europa under /tank/archive/retro/games/<dataset>/<system>/ — bulk-staged via
# Minerva torrents and scraped with Skyscraper (see modules/services/rom-acquire
# .nix and rom-scraper.nix on europa). This module only consumes the result: it
# mounts each used dataset read-only, points the emulator at it, persists saves,
# and contributes each <system>/ dir to jupiter.arcade.gameDirs.
#
# Three datasets exist on europa (created by modules/storage/zfs-nas.nix), each
# tuned for its file shape:
#   cartridge (64K recordsize) — small leaf ROMs (NES/SNES/GB/.../NDS/FDS/VB/...)
#   optical   (1M recordsize)   — large disc images (GameCube/Wii)
#   modern    (1M recordsize)   — large disc/card images (3DS/Wii U)
# Each enabled system declares which dataset it lives on; this module mounts
# only the datasets actually used and contributes per-system collection roots.
#
# Launch strategy: libretro cores exist in nixpkgs for every system except Wii U,
# so 18 of 19 systems launch through the uniform `jupiter-retroarch -L <core>`
# wrapper (the launch line lives in each collection's metadata.pegasus.txt,
# written by Skyscraper on europa). Wii U has no libretro core, so it launches
# through the standalone `jupiter-cemu` wrapper instead (gate on needsCemu).
#
# Pegasus has NO global launcher setting, so the only kiosk-side binaries this
# module ships are those wrappers. See docs/adr/0001-* for the bulk-stage
# acquisition decision (reverses issue #30's on-demand design).
#
# BIOS note (operational): a few cores need non-redistributable BIOS/firmware
# dumps placed in retroarch's system dir (persisted at
# ~/.config/retroarch/system via the impermanence entry below), NOT in this repo:
#   - fds (fceumm)        : needs disksys.rom
#   - dsi (desmume2015)   : desmume has NO DSi support; true DSi-exclusive titles
#                           need melonds + dsi_bios7/9 + dsi_nand (switch core
#                           + provide BIOS). Most of the dsi set is plain NDS and
#                           boots on desmume2015 as-is.
#   - 3ds/new3ds (citra)  : some titles need bios/bfw files; the libretro citra
#                           core is unmaintained (frozen ~2024-01) but still
#                           builds in this nixpkgs.
# gw/pokemini/vb/nes/.../nds(desmume2015) need NO BIOS and work on day one.
let
  cfg = config.jupiter.cartridges;

  inherit (import ../lib.nix { inherit config lib pkgs; }) nfsRoMountOptions;

  # The console catalogue — DERIVED from scripts/cartridge-catalogue.tsv via
  # modules/services/arcade-catalogue.nix (single source of truth shared with
  # rom-acquire, rom-scraper, arcade-inventory and cartridge-scrape.sh).
  # Fields not already in the catalogue are derived: shortname = the key,
  # dataset = the catalogue's bucket (which europa ZFS dataset / NFS mount +
  # recordsize the ROMs live on). `core`/`emulator` attrs are OMITTED when
  # null so downstream `s ? core` presence checks keep working.
  #
  # nds/dsi use desmume2015 (HLE, no BIOS — works immediately). melonds has
  # better compat but needs bios7/bios9/firmware; switch once those are on-pool.
  #
  # gamecube/wii use the libretro `dolphin` core (uniform launch path). It is
  # "viable for most titles" with a known failure tail on some EA/Konami
  # dual-core games; switch to standalone dolphin-emu (also in nixpkgs) if a
  # kiosk needs one of those.
  systems = lib.mapAttrs (
    name: v:
    ({
      inherit (v) collection;
      shortname = name;
      dataset = v.bucket;
    })
    // (lib.optionalAttrs (v.core != null) { inherit (v) core; })
    // (lib.optionalAttrs (v.emulator != null) { inherit (v) emulator; })
  ) config.jupiter.arcade.catalogue;

  systemNames = lib.attrNames systems;
  systemValues = builtins.attrValues systems;

  # Datasets actually referenced by the catalogue (so only those get mounted).
  usedDatasets = lib.unique (map (s: s.dataset) systemValues);

  # Per-dataset mount point + NFS subpath. cartridge keeps the historical
  # /mnt/europa-cartridges path so deployed kiosks see no game_dirs churn for
  # the original six systems.
  datasetMount = {
    cartridge = cfg.roMountBase;
    optical = cfg.opticalMountBase;
    modern = cfg.modernMountBase;
  };
  datasetNfsDevice = d: "${cfg.nfsHost}:${cfg.nfsGamesRoot}/${d}";

  systemMount = name: "${datasetMount.${systems.${name}.dataset}}/${name}";
  systemMounts = map systemMount systemNames;

  # retroarch with exactly the cores the retroarch catalogue entries need.
  # `withCores` builds a wrapper whose libretro dir holds just these cores,
  # invocable as `retroarch -L <core>`. Installed only via jupiter-retroarch
  # (below) so it doesn't collide with the bare retroarch in arcade.nix.
  retroarchSystems = lib.filter (s: s ? core) systemValues;
  cores = lib.unique (map (s: s.core) retroarchSystems);
  retroarchWithCores = pkgs.retroarch.withCores (c: map (name: c.${name}) cores);

  # The metadata launch lines (written by Skyscraper on europa, sourced from
  # cartridge-scrape.sh's LAUNCH map) say `-L beetle-psx` — a short name.
  # RetroArch's -L wants the actual core FILE, and nixpkgs packages some
  # libretro cores under different filenames (the "beetle" cores are
  # mednafen_*), so `-L beetle-psx` fails with "built for dynamic libretro
  # cores, but path is not set" and NO hyphenated-name game ever launched
  # (observed: every PlayStation launch died instantly on callisto). This
  # wrapper resolves `-L <short>` against the wrapped retroarch's cores dir
  # — normalizing the beetle aliases — and passes everything else through.
  # Keeps the launch metadata stable regardless of nixpkgs' packaging names.
  # Games launch through a NESTED `gamescope -f` (gamescope inside the
  # session's gamescope). Why: gamescope is designed around a single primary
  # client (Steam's model) — Pegasus, the first client, composites perfectly,
  # but a game appearing later as a second X11 child gets mis-composited:
  # observed live on callisto, the emulator's content rendered corner-
  # clipped/zoomed with the rest of the output black (2026-08-16, both
  # windowed AND --fullscreen). Wrapping each game in its own inner
  # gamescope makes that inner instance a primary fullscreen client of the
  # outer session (identical position to Pegasus = proven correct), and the
  # emulator the sole primary client of the inner gamescope — the path every
  # Steam game under gamescope takes. Nested gamescope is the supported
  # pattern (Steam launches per-game gamescope exactly like this).
  # --fullscreen is kept for the inner client as defense in depth.
  jupiterRetroarch = pkgs.writeShellScriptBin "jupiter-retroarch" ''
    set -eu
    CORES_DIR="${retroarchWithCores}/lib/retroarch/cores"
    if [ "$#" -ge 2 ] && [ "''${1:-}" = "-L" ]; then
      name="$2"; shift 2
      case "$name" in
        *.so|/*) core="$name" ;;
        *)
          case "$name" in
            beetle-lynx) so="mednafen_lynx_libretro.so" ;;
            beetle-ngp) so="mednafen_ngp_libretro.so" ;;
            beetle-pce-fast) so="mednafen_pce_fast_libretro.so" ;;
            beetle-pcfx) so="mednafen_pcfx_libretro.so" ;;
            beetle-psx) so="mednafen_psx_libretro.so" ;;
            beetle-saturn) so="mednafen_saturn_libretro.so" ;;
            beetle-supergrafx) so="mednafen_supergrafx_libretro.so" ;;
            beetle-vb) so="mednafen_vb_libretro.so" ;;
            beetle-wswan) so="mednafen_wswan_libretro.so" ;;
            genesis-plus-gx) so="genesis_plus_gx_libretro.so" ;;
            mupen64plus) so="mupen64plus_next_libretro.so" ;;
            vice-x128) so="vice_x128_libretro.so" ;;
            vice-x64) so="vice_x64_libretro.so" ;;
            vice-xplus4) so="vice_xplus4_libretro.so" ;;
            vice-xvic) so="vice_xvic_libretro.so" ;;
            *) so="''${name}_libretro.so" ;;
          esac
          if [ -f "$CORES_DIR/$so" ]; then
            core="$CORES_DIR/$so"
          else
            echo "jupiter-retroarch: core '$name' ($so) not found in $CORES_DIR" >&2
            exit 1
          fi
          ;;
      esac
      set -- -L "$core" "$@"
    fi
    # The inner gamescope must NEST as a Wayland client of the session's
    # gamescope, not fight it for DRM master. Gamescope's backend auto-
    # selection only picks Wayland when WAYLAND_DISPLAY is set; the session
    # env exposes the parent socket as GAMESCOPE_WAYLAND_DISPLAY (usually
    # "gamescope-0") but leaves WAYLAND_DISPLAY unset — without this export
    # the inner instance tries the DRM backend, fails to take the seat
    # ("Could not take control of session: Device or resource busy"), and
    # crashes (observed live). Verified working with the export: inner
    # gamescope runs as a wayland client, spawns its own Xwayland (:1), and
    # the game runs inside (2026-08-16).
    export WAYLAND_DISPLAY="''${GAMESCOPE_WAYLAND_DISPLAY:-gamescope-0}"
    exec ${pkgs.gamescope}/bin/gamescope -f -- \
      "${lib.getExe retroarchWithCores}" --fullscreen "$@"
  '';

  # Wii U standalone path. Cemu has no libretro core; it loads a title via
  # `-g <file>` and `-f` forces fullscreen. Needs title keys/resources placed
  # on-pool (operational), like the BIOS files above.
  needsCemu = lib.any (s: (s.emulator or "retroarch") == "cemu") systemValues;
  jupiterCemu = pkgs.writeShellScriptBin "jupiter-cemu" ''
    exec "${lib.getExe pkgs.cemu}" -f -g "$1"
  '';

  # NFS mount options live in modules/lib.nix (nfsRoMountOptions) — shared
  # with exodos.nix so the two collections' mount semantics cannot drift.
  nfsMountOptions = nfsRoMountOptions;

  # retroarch.cfg seed: saves redirected out of the read-only ROM tree into
  # per-kiosk persisted dirs, and the keyboardless exit combo (Start+Select
  # opens the RGUI; Quit there returns to Pegasus) since the TCx Wave kiosks
  # have no keyboard. Mirrors the seed-only-when-absent pattern of
  # pegasus-config-seed in modules/desktop/arcade.nix.
  retroarchCfg = pkgs.writeText "retroarch.cfg" ''
    # Managed by modules/desktop/cartridges.nix.
    savefile_directory = ${cfg.sessionUserHome}/Saves
    savestate_directory = ${cfg.sessionUserHome}/States
    sort_savefiles_by_content_enable = "true"
    # Start+Select opens the RGUI; Quit there exits retroarch -> Pegasus resumes.
    input_menu_toggle_gamepad_combo = 2
  '';
in
{
  imports = [
    # arcade.nix declares jupiter.arcade.gameDirs (we contribute to it) and
    # owns the gamer user + Pegasus config seeding; dashboard-gaming.nix
    # (kiosks) and arcade-console.nix (boot-to-arcade appliances) own the
    # jupiter-arcade session unit we add mount deps to. Importing both here
    # keeps this module eval-safe regardless of import order in the host.
    ./arcade.nix
    ./dashboard-gaming.nix
    ./arcade-console.nix
    # BIOS deployment for cores that need it (FDS, optionally DSi/3DS)
    ./bios.nix
    # nfsHost default references the fleet topology module
    ../network/fleet.nix
    # the systems catalogue this module derives everything from
    ../services/arcade-catalogue.nix
  ];

  options.jupiter.cartridges = {
    enable = lib.mkEnableOption ''
      Nintendo console ROM collections (No-Intro cartridge + Non-Redump optical
      + modern disc/card sets) for the Pegasus arcade session: read-only NFS
      mounts of europa's scraped console trees across the cartridge/optical/
      modern datasets, retroarch with the needed libretro cores (plus standalone
      Cemu for Wii U), per-kiosk persisted saves, and the per-system collection
      roots contributed to jupiter.arcade.gameDirs
    '';

    nfsHost = lib.mkOption {
      type = lib.types.str;
      default = config.jupiter.fleet.addresses.europa; # static LAN reservation
      description = ''
        NFS host serving the scraped console trees. Defaults to europa.
        Addressed by IP for the same reason every other cross-host wire is
        (the fleet has no DNS yet).
      '';
    };

    nfsGamesRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games";
      description = ''
        Path on the NFS host under which the per-dataset trees live. Each
        dataset is read at `<nfsGamesRoot>/<dataset>/` (cartridge, optical,
        modern). Each enabled system is a subdirectory there with its own
        metadata.pegasus.txt + ROMs + media/. A single ZFS dataset per shape
        with directory children, so one NFS mount per dataset sees every
        system subdir (no crossmnt-submount trap, unlike the eXo datasets).
      '';
    };

    roMountBase = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/europa-cartridges";
      description = "Mount point for the read-only cartridge dataset tree.";
    };

    opticalMountBase = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/europa-optical";
      description = "Mount point for the read-only optical dataset tree (GameCube/Wii).";
    };

    modernMountBase = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/europa-modern";
      description = "Mount point for the read-only modern dataset tree (3DS/Wii U).";
    };

    sessionUser = lib.mkOption {
      type = lib.types.str;
      default = "gamer";
      description = ''
        User that owns retroarch/cemu saves/config. Must match
        modules/desktop/arcade.nix's sessionUser (the gamer account it creates).
      '';
    };

    sessionUserHome = lib.mkOption {
      type = lib.types.str;
      default = "/home/gamer";
      description = "Home directory of the session user (for retroarch save dirs).";
    };
  };

  config = lib.mkIf cfg.enable {
    # BIOS deployment for cores that require it (FDS, optionally DSi/3DS)
    jupiter.bios = {
      enable = true;
      sessionUser = cfg.sessionUser;
    };

    # Each per-system subdir is a Pegasus collection root (holds the
    # metadata.pegasus.txt Skyscraper generates on europa). Pegasus discovers
    # them via the game_dirs.txt arcade.nix seeds from this list.
    jupiter.arcade.gameDirs = systemMounts;

    # Persist retroarch saves + states per kiosk (erase-your-darlings root).
    # Redirected out of the read-only ROM tree via retroarch.cfg below, so the
    # collection mount can stay read-only. ~/.config/retroarch holds runtime
    # config + any BIOS files the operator drops under its system/ subdir.
    jupiter.core.impermanence.users.${cfg.sessionUser}.directories = [
      "Saves"
      "States"
      ".config/retroarch"
    ];

    # One read-only NFS mount per used dataset. `soft` so a dead europa doesn't
    # hang emulator reads forever; automount + idle-timeout so each mount exists
    # only while something uses it. No overlay: ROMs are read directly and saves
    # don't write back here.
    fileSystems = lib.genAttrs usedDatasets (d: {
      device = datasetNfsDevice d;
      fsType = "nfs";
      options = nfsMountOptions;
    });

    environment.systemPackages = [
      jupiterRetroarch
    ]
    ++ lib.optionals needsCemu [
      jupiterCemu
      pkgs.cemu
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.sessionUserHome}/.config/retroarch 0755 ${cfg.sessionUser} users -"
      "d ${cfg.sessionUserHome}/.config/retroarch/system 0755 ${cfg.sessionUser} users -"
      "d ${cfg.sessionUserHome}/Saves 0755 ${cfg.sessionUser} users -"
      "d ${cfg.sessionUserHome}/States 0755 ${cfg.sessionUser} users -"
    ];

    # Seed retroarch.cfg only when absent (retroarch rewrites it on exit with
    # the user's in-session choices, like Pegasus settings.txt).
    systemd.services.jupiter-cartridges-config = {
      description = "Seed retroarch config for ${cfg.sessionUser} (saves + exit combo)";
      wantedBy = [ "multi-user.target" ];
      before = [ "jupiter-arcade.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.sessionUser;
        Group = "users";
        # `install` is coreutils — a system unit's default PATH does not
        # include it on a bare system (found 2026-08-17 audit: the unit relied
        # on the ambient profile PATH, which is empty for systemd services).
        path = [ pkgs.coreutils ];
      };
      script = ''
        CFG="${cfg.sessionUserHome}/.config/retroarch/retroarch.cfg"
        if [ ! -f "$CFG" ]; then
          install -m 0644 ${retroarchCfg} "$CFG"
        fi
      '';
    };

    # The jupiter-arcade session (generated by dashboard-gaming.nix's arcade
    # modeSpecs on kiosks, or by arcade-console.nix on boot-to-arcade
    # appliances) must not start until every used console tree is mounted,
    # else Pegasus shows empty collections on a cold automount race.
    # WantsMountsFor, NOT RequiresMountsFor: these mounts idle-expire
    # (x-systemd.idle-timeout above), and Requires= propagates every expiry
    # into a stop of the session itself — observed live on callisto
    # 2026-08-16: the arcade died ~10 min after each boot because Pegasus
    # idles in menus holding no open NFS files, the automount expired, and
    # the Requires chain stopped jupiter-arcade.service. Ordering is all the
    # session needs; the automount re-triggers synchronously on next access.
    systemd.services."jupiter-arcade" =
      lib.mkIf (config.jupiter.dashboardGaming.modes.arcade.enable || config.jupiter.arcadeConsole.enable)
        {
          unitConfig.WantsMountsFor = systemMounts;
        };
  };
}
