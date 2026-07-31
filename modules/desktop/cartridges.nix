{
  config,
  lib,
  pkgs,
  ...
}:

# Nintendo cartridge console collections (No-Intro NES/SNES/GB/GBC/GBA/N64) for
# the Pegasus arcade session. Sibling to modules/desktop/exodos.nix, but far
# simpler: cartridge ROMs are small leaf files read directly by retroarch over
# a read-only NFS mount, so — unlike the eXo zips — there is NO per-kiosk
# overlayfs, NO extract-on-first-run, and NO sudo extraction helper. Saves are
# redirected out of the read-only ROM tree into a per-kiosk persisted dir.
#
# The ROMs + their Pegasus metadata (metadata.pegasus.txt + media/) live on
# europa under /tank/archive/retro/games/cartridge/<system>/ — bulk-staged via
# Minerva torrents and scraped with Skyscraper (see
# modules/services/rom-acquire.nix and rom-scraper.nix on europa). This module
# only consumes the result: it mounts the tree read-only, points retroarch at
# it, persists saves, and contributes each <system>/ dir to
# jupiter.arcade.gameDirs.
#
# Pegasus has NO global launcher setting (each collection's metadata.pegasus.txt
# carries its own `launch:` line, written by Skyscraper on europa), so the only
# kiosk-side binary this module ships is the `jupiter-retroarch` wrapper that
# those launch lines invoke — a thin exec of retroarch.withCores so the metadata
# generator never needs to know a nix store path. See docs/adr/0001-* for the
# bulk-stage acquisition decision (reverses issue #30's on-demand design).
let
  cfg = config.jupiter.cartridges;

  # The cartridge catalogue. Facts about the systems, not per-host tunables
  # (the fleet is uniform). `core` is the libretro core basename retroarch
  # loads with `-L`; all five cores below are verified-present in this nixpkgs
  # (fceumm, snes9x, gambatte, mgba, mupen64plus). Virtual Boy / Pokemon Mini /
  # Game & Watch / FDS ROMs are downloading too but their cores are unverified
  # here — add them to this map once the core attr is confirmed.
  systems = {
    nes = {
      collection = "Nintendo Entertainment System";
      shortname = "nes";
      core = "fceumm";
    };
    snes = {
      collection = "Super Nintendo Entertainment System";
      shortname = "snes";
      core = "snes9x";
    };
    gb = {
      collection = "Nintendo Game Boy";
      shortname = "gb";
      core = "gambatte";
    };
    gbc = {
      collection = "Nintendo Game Boy Color";
      shortname = "gbc";
      core = "gambatte";
    };
    gba = {
      collection = "Nintendo Game Boy Advance";
      shortname = "gba";
      core = "mgba";
    };
    n64 = {
      collection = "Nintendo 64";
      shortname = "n64";
      core = "mupen64plus";
    };
  };

  systemNames = lib.attrNames systems;
  systemMount = name: "${cfg.roMountBase}/${name}";
  systemMounts = map systemMount systemNames;

  # One retroarch with exactly the cores the catalogue needs. `withCores`
  # builds a wrapper whose libretro dir holds just these cores, invocable as
  # `retroarch -L <core>`. Installed only via the jupiter-retroarch wrapper
  # below (not directly on PATH) so it doesn't collide with the bare retroarch
  # in modules/desktop/arcade.nix's extraEmulators.
  cores = lib.unique (map (s: s.core) (lib.attrValues systems));
  retroarchWithCores = pkgs.retroarch.withCores (c: map (name: c.${name}) cores);
  jupiterRetroarch = pkgs.writeShellScriptBin "jupiter-retroarch" ''
    exec "${lib.getExe retroarchWithCores}" "$@"
  '';

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
      Nintendo cartridge console collections (No-Intro NES/SNES/GB/GBC/GBA/N64)
      for the Pegasus arcade session: a read-only NFS mount of europa's scraped
      cartridge tree, retroarch with the needed libretro cores, per-kiosk
      persisted saves, and the per-system collection roots contributed to
      jupiter.arcade.gameDirs
    '';

    nfsHost = lib.mkOption {
      type = lib.types.str;
      default = "10.1.1.2"; # europa's static LAN IP
      description = ''
        NFS host serving the scraped cartridge tree. Defaults to europa.
        Addressed by IP for the same reason every other cross-host wire is
        (the fleet has no DNS yet).
      '';
    };

    nfsPath = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/cartridge";
      description = ''
        Path on the NFS host holding one per-system directory (nes/, snes/,
        …), each with its own metadata.pegasus.txt + ROMs + media/. A single
        ZFS dataset with directory children, so one NFS mount sees every
        system subdir (no crossmnt-submount trap, unlike the eXo datasets).
      '';
    };

    roMountBase = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/europa-cartridges";
      description = "Mount point for the read-only cartridge tree.";
    };

    sessionUser = lib.mkOption {
      type = lib.types.str;
      default = "gamer";
      description = ''
        User that owns retroarch saves/config. Must match
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
    # collection mount can stay read-only.
    jupiter.core.impermanence.users.${cfg.sessionUser}.directories = [
      "Saves"
      "States"
      ".config/retroarch"
    ];

    # The single read-only NFS mount of the whole cartridge tree. `soft` so a
    # dead europa doesn't hang retroarch reads forever; automount + idle-timeout
    # so the mount exists only while something uses it. No overlay: ROMs are
    # read directly and saves don't write back here.
    fileSystems.${cfg.roMountBase} = {
      device = "${cfg.nfsHost}:${cfg.nfsPath}";
      fsType = "nfs";
      options = [
        "ro"
        "noatime"
        "soft"
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=10min"
        "x-systemd.mount-timeout=30"
      ];
    };

    environment.systemPackages = [ jupiterRetroarch ];

    systemd.tmpfiles.rules = [
      "d ${cfg.sessionUserHome}/.config/retroarch 0755 ${cfg.sessionUser} users -"
      "d ${cfg.sessionUserHome}/Saves 0755 ${cfg.sessionUser} users -"
      "d ${cfg.sessionUserHome}/States 0755 ${cfg.sessionUser} users -"
    ];

    # Seed retroarch.cfg only when absent (retroarch rewrites it on exit with
    # the user's in-session choices, like Pegasus settings.txt).
    systemd.services.jupiter-cartridges-config = {
      description = "Seed retroarch config for ${cfg.sessionUser} (cartridge saves + exit combo)";
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
    # modeSpecs) must not start until the cartridge tree is mounted, else
    # Pegasus shows empty collections on a cold automount race.
    systemd.services."jupiter-arcade" = lib.mkIf config.jupiter.dashboardGaming.modes.arcade.enable {
      unitConfig.RequiresMountsFor = systemMounts;
    };
  };
}
