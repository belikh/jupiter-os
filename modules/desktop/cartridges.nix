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
# so 16 of 17 systems launch through the uniform `jupiter-retroarch -L <core>`
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

  # The console catalogue. Facts about the systems, not per-host tunables (the
  # fleet is uniform). `dataset` selects which europa ZFS dataset (and thus NFS
  # mount + recordsize) the ROMs live on. `core` is the libretro core basename
  # retroarch loads with `-L`; systems without a `core` attr use the standalone
  # `emulator` field instead (currently only wiiu → cemu, which has no libretro
  # core).
  #
  # nds/dsi use desmume2015 (HLE, no BIOS — works immediately). melonds has
  # better compat but needs bios7/bios9/firmware; switch once those are on-pool.
  #
  # gamecube/wii use the libretro `dolphin` core (uniform launch path). It is
  # "viable for most titles" with a known failure tail on some EA/Konami
  # dual-core games; switch to standalone dolphin-emu (also in nixpkgs) if a
  # kiosk needs one of those.
  systems = {
    # --- original cartridge sets ---
    nes = {
      collection = "Nintendo Entertainment System";
      shortname = "nes";
      core = "fceumm";
      dataset = "cartridge";
    };
    snes = {
      collection = "Super Nintendo Entertainment System";
      shortname = "snes";
      core = "snes9x";
      dataset = "cartridge";
    };
    gb = {
      collection = "Nintendo Game Boy";
      shortname = "gb";
      core = "gambatte";
      dataset = "cartridge";
    };
    gbc = {
      collection = "Nintendo Game Boy Color";
      shortname = "gbc";
      core = "gambatte";
      dataset = "cartridge";
    };
    gba = {
      collection = "Nintendo Game Boy Advance";
      shortname = "gba";
      core = "mgba";
      dataset = "cartridge";
    };
    n64 = {
      collection = "Nintendo 64";
      shortname = "n64";
      core = "mupen64plus";
      dataset = "cartridge";
    };
    # --- cartridge-era extras (small leaf ROMs, No-Intro Nintendo) ---
    fds = {
      collection = "Nintendo Famicom Disk System";
      shortname = "fds";
      core = "fceumm"; # same engine as NES; needs disksys.rom BIOS (see header)
      dataset = "cartridge";
    };
    virtualboy = {
      collection = "Nintendo Virtual Boy";
      shortname = "virtualboy";
      core = "beetle-vb";
      dataset = "cartridge";
    };
    pokemonmini = {
      collection = "Nintendo Pokemon Mini";
      shortname = "pokemonmini";
      core = "pokemini"; # FreeBIOS fallback, no BIOS required
      dataset = "cartridge";
    };
    gameandwatch = {
      collection = "Nintendo Game & Watch";
      shortname = "gameandwatch";
      core = "gw"; # runs .mgw simulators, no BIOS required
      dataset = "cartridge";
    };
    nds = {
      collection = "Nintendo DS";
      shortname = "nds";
      core = "desmume2015"; # HLE, no BIOS. melonds (better) needs bios7/9+firmware
      dataset = "cartridge";
    };
    dsi = {
      collection = "Nintendo DSi";
      shortname = "dsi";
      core = "desmume2015"; # no DSi mode; boots the NDS-compatible majority
      dataset = "cartridge";
    };
    # --- optical (large disc images, Non-Redump Nintendo) ---
    gamecube = {
      collection = "Nintendo GameCube";
      shortname = "gamecube";
      core = "dolphin";
      dataset = "optical";
    };
    wii = {
      collection = "Nintendo Wii";
      shortname = "wii";
      core = "dolphin";
      dataset = "optical";
    };
    # --- modern (large disc/card images) ---
    "3ds" = {
      collection = "Nintendo 3DS";
      shortname = "3ds";
      core = "citra"; # libretro citra is unmaintained but builds here
      dataset = "modern";
    };
    new3ds = {
      collection = "Nintendo New 3DS";
      shortname = "new3ds";
      core = "citra";
      dataset = "modern";
    };
    # --- Wii U: no libretro core; standalone Cemu ---
    wiiu = {
      collection = "Nintendo Wii U";
      shortname = "wiiu";
      emulator = "cemu"; # no `core` attr → standalone launch path
      dataset = "modern";
    };
  };

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
  jupiterRetroarch = pkgs.writeShellScriptBin "jupiter-retroarch" ''
    exec "${lib.getExe retroarchWithCores}" "$@"
  '';

  # Wii U standalone path. Cemu has no libretro core; it loads a title via
  # `-g <file>` and `-f` forces fullscreen. Needs title keys/resources placed
  # on-pool (operational), like the BIOS files above.
  needsCemu = lib.any (s: (s.emulator or "retroarch") == "cemu") systemValues;
  jupiterCemu = pkgs.writeShellScriptBin "jupiter-cemu" ''
    exec "${lib.getExe pkgs.cemu}" -f -g "$1"
  '';

  # Shared NFS mount options (read-only, automounted, soft) for every dataset.
  nfsMountOptions = [
    "ro"
    "noatime"
    "soft"
    "noauto"
    "x-systemd.automount"
    "x-systemd.idle-timeout=10min"
    "x-systemd.mount-timeout=30"
  ];

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
    # owns the gamer user + Pegasus config seeding; dashboard-gaming.nix owns
    # the jupiter-arcade session unit we add mount deps to.
    ./arcade.nix
    ./dashboard-gaming.nix
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
      default = "10.1.1.2"; # europa's static LAN IP
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
    fileSystems = builtins.listToAttrs (
      map (d: {
        name = datasetMount.${d};
        value = {
          device = datasetNfsDevice d;
          fsType = "nfs";
          options = nfsMountOptions;
        };
      }) usedDatasets
    );

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
      };
      script = ''
        CFG="${cfg.sessionUserHome}/.config/retroarch/retroarch.cfg"
        if [ ! -f "$CFG" ]; then
          install -m 0644 ${retroarchCfg} "$CFG"
        fi
      '';
    };

    # The jupiter-arcade session (generated by dashboard-gaming.nix's arcade
    # modeSpecs) must not start until every used console tree is mounted, else
    # Pegasus shows empty collections on a cold automount race.
    systemd.services."jupiter-arcade" = lib.mkIf config.jupiter.dashboardGaming.modes.arcade.enable {
      unitConfig.RequiresMountsFor = systemMounts;
    };
  };
}
