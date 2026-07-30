{
  config,
  lib,
  pkgs,
  ...
}:

# eXo collection launch stack (eXoDOS + eXoWin3x + eXoWin9x) for the TCx Wave
# kiosks' Pegasus arcade session.
#
# The curated eXo collections live on europa as one ZFS dataset each under
# tank/archive/retro/games/curated/{exo-dos,exo-win3x,exo-win9x}, exported RO
# over NFS. This module mounts EACH collection dataset separately (an
# overlayfs lower must not span NFS crossmnt submount boundaries — a single
# mount of curated/ would show three empty dirs through the overlay), layers
# a per-kiosk persisted overlayfs on top so game saves and first-run
# extractions land locally without ever writing back to europa, and
# regenerates Pegasus metadata from each collection's LaunchBox XML before
# the arcade session starts.
#
# The gamescope session unit itself (`jupiter-arcade.service`) is generated
# by modules/desktop/dashboard-gaming.nix's `arcade` modeSpecs entry; this
# module owns everything AROUND that session for the eXo collections: the
# mounts, the metadata generator, the exo-launch wrapper, and the extraction
# helper. Pegasus config seeding (game_dirs.txt/settings.txt/themes) is owned
# by modules/desktop/arcade.nix — this module only contributes its merged
# collection roots to jupiter.arcade.gameDirs.
#
# See scripts/exo-to-pegasus.py (LaunchBox XML -> Pegasus metadata converter)
# and scripts/exo-launch.sh (per-game extract-if-needed + dosbox launcher) —
# both are kept in scripts/ for standalone testing and inlined into this
# module's closure via path interpolation so there's a single source of truth.
let
  cfg = config.jupiter.exodos;

  # The collection catalogue. Not an option: the fleet is uniform and the
  # values are facts about the eXo releases on europa, not per-host tunables.
  #  - xml:      platform XML relative to the collection root (eXoWin9x's is
  #              assembled once on europa from Content/XOWin9xMetadata.zip's
  #              xml/all fragment — see docs/exo-win9x-normalization below)
  #  - conf:     per-game emulator conf filename (the `file:` launch anchor)
  #  - emulator: binary exo-launch execs (dosbox = dosbox-staging)
  #  - rewrites: ApplicationPath case fixes (Windows XMLs vs case-sensitive
  #              ZFS; eXoWin3x's XML says eXoWin3X for 1062 of 1139 games)
  collections = {
    exo-dos = {
      xml = "xml/MS-DOS.xml";
      collection = "eXoDOS";
      shortname = "dos";
      emulator = "dosbox";
      conf = "dosbox.conf";
      rewrites = [ ];
    };
    exo-win3x = {
      xml = "xml/Windows 3x.xml";
      collection = "eXoWin3x";
      shortname = "win3x";
      emulator = "dosbox-x";
      conf = "dosbox.conf";
      rewrites = [ "eXoWin3X:eXoWin3x" ];
    };
    exo-win9x = {
      xml = "xml/Windows 9x.xml";
      collection = "eXoWin9x";
      shortname = "win9x";
      emulator = "dosbox-x";
      conf = "Play.conf";
      rewrites = [ ];
    };
  };

  collectionNames = lib.attrNames collections;
  roMount = name: "${cfg.roMountBase}/${name}";
  mergeMount = name: "${cfg.mergeMountBase}/${name}";
  mergeMounts = map mergeMount collectionNames;

  # The per-game launcher: extracts the matching .zip on first run (into the
  # overlay upper), then execs the emulator from <collection>/eXo/ as CWD so
  # the per-game conf's [autoexec] relative mounts resolve correctly.
  # See scripts/exo-launch.sh for the full eXo layout explanation.
  exoLauncher = pkgs.writeShellScriptBin "exo-launch" (builtins.readFile ../../scripts/exo-launch.sh);

  # Privileged extraction helper invoked via `sudo -n` from exo-launch.
  # overlayfs's ovl_permission checks write on BOTH upper AND lower for
  # creates in directories that exist in both layers; the NFS lower's mode
  # bits are inconsistent and the export is read-only, so non-root extraction
  # dies with EACCES. Tried a setuid wrapper first (security.wrappers) but
  # bash drops setuid on exec, leaving the wrapper unprivileged. Tried
  # running the whole session as root, but gamescope crashes on
  # libseat_open_seat when User=root (no proper logind seat for root on this
  # kiosk). `sudo` is the right primitive: it sets full root creds (not just
  # the setuid bit), so bash doesn't drop, and the rest of the session still
  # runs unprivileged as `gamer` (preserving gamescope's logind/DRM/seat
  # access).
  # The script unzips then chowns back to the calling user so dosbox (as
  # gamer) can later write saves into the per-game dir — by then upper-only.
  exoExtractHelper = pkgs.writeShellScriptBin "exo-extract-helper" ''
    #!${pkgs.runtimeShell}
    # Invoked as root via: /run/wrappers/bin/sudo -n exo-extract-helper \
    #   <zip> <target-parent> <target-name> <chown-user> <chown-group>
    set -eu
    ZIP=$1
    TARGET_PARENT=$2
    TARGET_NAME=$3
    CHOWN_USER=$4
    CHOWN_GROUP=$5
    if [ ! -f "$ZIP" ]; then
      echo "exo-extract-helper: zip not found: $ZIP" >&2
      exit 1
    fi
    # Drop kernel dentry+inode caches before extraction. Overlayfs over NFS
    # accumulates stale positive dentries when an extraction is interrupted
    # (or when dosbox mounts a target that doesn't exist on the lower) — the
    # phantom entries make `[ -d ]` see a populated dir, and unzip -o tries
    # to unlink them as "old" files, getting ENOENT, erroring out (exit 50)
    # and leaving the game unlaunchable. drop_caches=2 clears dentries+inodes
    # only (pagecache stays); ~5s of cold-cache cost is acceptable for a
    # once-per-game extraction on a kiosk.
    echo 2 > /proc/sys/vm/drop_caches
    "${pkgs.unzip}/bin/unzip" -q -o "$ZIP" -d "$TARGET_PARENT"
    # A few eXo zips carry a top-level dir whose case differs from the conf
    # dir the caller derived TARGET_NAME from (hugo3Jd's zip extracts
    # hugo3jd), so chown what was actually created, not what was expected.
    if [ ! -d "$TARGET_PARENT/$TARGET_NAME" ]; then
      ALT=$("${pkgs.coreutils}/bin/ls" -A "$TARGET_PARENT" \
        | "${pkgs.gnugrep}/bin/grep" -ixF -- "$TARGET_NAME" | head -1)
      if [ -n "$ALT" ]; then
        TARGET_NAME=$ALT
      fi
    fi
    "${pkgs.coreutils}/bin/chown" -R "$CHOWN_USER:$CHOWN_GROUP" "$TARGET_PARENT/$TARGET_NAME"
    # TCx Wave kiosk touch panel is 1024x768 native. The eXoWin3x collection
    # ships with Win3.x configured for screen-size=640 (640x480), which makes
    # the Win3.x desktop smaller than the panel — dosbox scales it up and the
    # touch coordinates don't map 1:1. The bundled S3 driver supports up to
    # 1600x1200; bumping screen-size to 1024 (1024x768 256-color) makes the
    # desktop fill the panel and touch land where your finger does. Idempotent
    # sed — only edits the [DISPLAY] screen-size line, only if SYSTEM.INI
    # exists (so DOS/Win9x extractions, which have no WINDOWS/SYSTEM.INI, are
    # untouched). Color depth (color-format=8) stays at 256.
    SYSINI="$TARGET_PARENT/$TARGET_NAME/WINDOWS/SYSTEM.INI"
    if [ -f "$SYSINI" ]; then
      "${pkgs.gnused}/bin/sed" -i 's/^screen-size=.*/screen-size=1024/' "$SYSINI"
    fi
  '';

  # VBMOUSE.DRV — Win3.x absolute mouse driver (javispedro/vbados, GPLv2).
  # dosbox-x implements VBMOUSE's int33 absolute-coordinate extension natively,
  # so installing this as MOUSE.DRV in each Win3.x image makes Win3.x read
  # absolute coordinates from the host — i.e. your finger on the touchscreen
  # maps 1:1 to the Windows cursor, no more "cursor drifts randomly" PS/2
  # relative-mode behavior. We don't need VBMOUSE.EXE (the DOS TSR); the .DRV
  # alone works against dosbox-x's builtin int33 absolute API.
  # Prebuilt fetched from upstream (compilation needs OpenWatcom and is more
  # hassle than it's worth for a 2.7KB binary we don't change).
  vbadosZip = pkgs.fetchurl {
    url = "https://depot.javispedro.com/vbox/vbados/vbados.zip";
    hash = "sha256-gk10cx1xn/TIynkU9vk+VUgS/KOp74xEMXwdpygYTSc=";
  };
  vbmouseDrv = pkgs.runCommand "vbmouse" { preferLocalBuild = true; } ''
    ${pkgs.unzip}/bin/unzip -p ${vbadosZip} VBMOUSE.DRV > $out
  '';

  # One exo-to-pegasus.py invocation per collection, against the merged
  # (writable) view: the XML is read through the overlay and the generated
  # metadata.pegasus.txt lands in the persisted upper unless europa already
  # ships a fresh copy in the lower (the script's mtime check skips those).
  generatorCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: c: ''
      ${pkgs.python3.interpreter} ${../../scripts/exo-to-pegasus.py} \
        --xml '${mergeMount name}/${c.xml}' \
        --root '${mergeMount name}' \
        --collection '${c.collection}' \
        --shortname '${c.shortname}' \
        --emulator '${c.emulator}' \
        --conf-name '${c.conf}' ${lib.concatMapStringsSep " " (r: "--rewrite '${r}'") c.rewrites}
    '') collections
  );
in
{
  imports = [
    # arcade.nix declares jupiter.arcade.gameDirs (we define it below) and
    # owns the Pegasus frontend + config seeding; dashboard-gaming.nix
    # declares the jupiter-arcade session mode this module hooks. Importing
    # them here keeps this module eval-safe regardless of import order in the
    # host (NixOS dedups module imports by path).
    ./arcade.nix
    ./dashboard-gaming.nix
  ];

  options.jupiter.exodos = {
    enable = lib.mkEnableOption ''
      eXoDOS + eXoWin3x + eXoWin9x launch stack for the Pegasus arcade
      session: per-collection NFS mounts of europa's read-only curated
      datasets, an overlayfs per collection for local saves/extractions,
      LaunchBox-XML metadata generation, and the exo-launch wrapper
    '';

    nfsHost = lib.mkOption {
      type = lib.types.str;
      default = "10.1.1.2"; # europa's static LAN IP (hosts/europa/configuration.nix)
      description = ''
        NFS host serving the curated eXo collections. Defaults to europa's
        static DHCP reservation. Addressed by IP rather than hostname for the
        same reason every other cross-host wire in this repo is (the fleet
        has no DNS yet).
      '';
    };

    curatedNfsPath = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/curated";
      description = ''
        Path on the NFS host holding one dataset per eXo collection
        (exo-dos, exo-win3x, exo-win9x).
      '';
    };

    roMountBase = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/europa-games";
      description = "Base dir for the per-collection read-only NFS mounts.";
    };

    mergeMountBase = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/exo-games";
      description = ''
        Base dir for the per-collection merged overlayfs views (NFS lower +
        persisted RW upper). Pegasus reads the collections from here.
      '';
    };

    overlayBase = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/exo-overlay";
      description = ''
        Persisted overlay storage; each collection gets <base>/<name>/upper
        and <base>/<name>/work. Game saves and first-run extractions land
        here per-kiosk. Added to impermanence's extraDirectories below.
      '';
    };

    sessionUser = lib.mkOption {
      type = lib.types.str;
      default = "gamer";
      description = ''
        User that runs the arcade session and owns extracted game files.
        Must match modules/desktop/dashboard-gaming.nix's sessionUser.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # --- Pegasus wiring ------------------------------------------------------
    # arcade.nix's pegasus-config-seed writes these into the gamer user's
    # game_dirs.txt; each entry is a merged collection root holding the
    # generated metadata.pegasus.txt.
    jupiter.arcade.gameDirs = mergeMounts;

    # --- Persisted overlay storage ------------------------------------------
    # extraDirectories is a no-op on non-impermanent hosts (the dir just lives
    # in the regular root fs). On kiosks (the actual target) it bind-mounts
    # from /persist so saves + first-run extractions survive the
    # erase-your-darlings root wipe.
    jupiter.core.impermanence.extraDirectories = [ cfg.overlayBase ];

    systemd.tmpfiles.rules = [
      "d ${cfg.overlayBase} 0755 root root -"
    ]
    ++ lib.concatMap (name: [
      "d ${cfg.overlayBase}/${name} 0755 root root -"
      "d ${cfg.overlayBase}/${name}/upper 0755 ${cfg.sessionUser} users -"
      "d ${cfg.overlayBase}/${name}/work 0755 ${cfg.sessionUser} users -"
    ]) collectionNames;

    # Allow the session user to run only the extraction helper as root with no
    # password. See exoExtractHelper above for why root is required.
    security.sudo.extraRules = [
      {
        users = [ cfg.sessionUser ];
        runAs = "root";
        commands = [
          {
            command = "${lib.getExe exoExtractHelper}";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # --- Per-collection mounts ----------------------------------------------
    # Each collection is its own ZFS dataset on europa, so each gets its own
    # NFS mount (a single mount of curated/ would hide the child datasets
    # behind crossmnt submounts the overlay can't see through) and its own
    # overlayfs. `soft` so a dead europa doesn't hang dosbox reads forever;
    # automount + idle-timeout so mounts exist only while something uses them.
    fileSystems = lib.mkMerge (
      map (name: {
        ${roMount name} = {
          device = "${cfg.nfsHost}:${cfg.curatedNfsPath}/${name}";
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
        # overlayfs: NFS RO lower + persisted RW upper. Game saves and
        # first-run extractions land in the upper layer; the underlying eXo
        # collection on europa stays pristine. `depends` makes this mount
        # unit Require+After the NFS mount unit.
        ${mergeMount name} = {
          device = "overlay";
          fsType = "overlay";
          options = [
            "lowerdir=${roMount name}"
            "upperdir=${cfg.overlayBase}/${name}/upper"
            "workdir=${cfg.overlayBase}/${name}/work"
            "noauto"
            "x-systemd.automount"
            "x-systemd.idle-timeout=10min"
          ];
          depends = [ (roMount name) ];
        };
      }) collectionNames
    );

    # --- Packages: launcher wrapper, extraction helper, dosboxen -------------
    # dosbox-staging (binary `dosbox`) for the DOS collection, dosbox-x for
    # Win3.x and Win9x. Pegasus itself comes from arcade.nix.
    environment.systemPackages = [
      exoLauncher
      exoExtractHelper
      pkgs.unzip
      pkgs.dosbox-staging
      pkgs.dosbox-x
    ];

    # Per-emulator override confs, passed to dosbox AFTER the per-game conf
    # so our values win. See scripts/exo-launch.sh.
    # The TCx Wave panel is 1024x768 native (gamescope selects that mode).
    # eXo's per-game dosbox.conf ships with fullscreen=false and a huge
    # windowresolution (e.g. 2560x1920), which in dosbox-x shows a menu bar
    # that eats vertical space and squeezes the game into the remaining area
    # with ugly scaling. fullscreen=true hides the menu bar AND fills the
    # panel at native res — touch maps 1:1.
    environment.etc = {
      "exo/dosbox-override.conf".source = pkgs.writeText "dosbox-override.conf" ''
        [sdl]
        fullscreen=true
        fullresolution=1024x768
        windowresolution=1024x768
        output=openglnb
        autolock=true

        [render]
        aspect=true

        [mixer]
        nosound=false
        rate=44100
        prebuffer=20
      '';
      # Win3.x / Win9x (dosbox-x) override. fullscreen at native res hides the
      # dosbox-x menu bar (which otherwise eats vertical space and squeezes
      # the game).
      "exo/dosbox-x-override.conf".source = pkgs.writeText "dosbox-x-override.conf" ''
        [sdl]
        fullscreen=true
        fullresolution=1024x768
        windowresolution=1024x768
        output=openglnb
        autolock=true

        [render]
        aspect=true

        [mixer]
        nosound=false
        rate=44100
        prebuffer=20
      '';
      # VBMOUSE.DRV — Win3.x absolute mouse driver. exo-launch.sh copies this
      # over MOUSE.DRV in each Win3.x game before launch so the cursor tracks
      # the touchscreen 1:1 instead of drifting randomly (PS/2 relative mode).
      "exo/VBMOUSE.DRV".source = vbmouseDrv;
    };

    # --- Metadata regenerator (runs once per session start) -----------------
    # Idempotent: scripts/exo-to-pegasus.py skips writing when its output is
    # newer than the source XML (europa keeps a canonical copy in each
    # collection root, so this is normally a no-op). Runs before the Pegasus
    # session so Pegasus always sees fresh metadata; a regeneration writes
    # via the overlay, landing in the persisted upper.
    systemd.services.jupiter-exodos-metadata = {
      description = "eXo: regenerate Pegasus metadata from LaunchBox XML";
      serviceConfig.Type = "oneshot";
      # No RemainAfterExit: we want this re-triggered every time the session
      # starts (Requires= below pulls it in), so a collection update on
      # europa is reflected on the next session entry.
      unitConfig.RequiresMountsFor = mergeMounts;
      script = ''
        set -e
        ${generatorCommands}
      '';
    };

    # --- Session unit wiring ------------------------------------------------
    # The jupiter-arcade.service unit itself is generated by
    # modules/desktop/dashboard-gaming.nix's `arcade` modeSpecs entry; this
    # just adds the mount + metadata deps so the session always launches into
    # mounted, metadata-ready collections. Gated on the mode's own enable so
    # this is inert on hosts that haven't turned the mode on.
    systemd.services."jupiter-arcade" = lib.mkIf config.jupiter.dashboardGaming.modes.arcade.enable {
      requires = [ "jupiter-exodos-metadata.service" ];
      after = [ "jupiter-exodos-metadata.service" ];
      unitConfig.RequiresMountsFor = mergeMounts;
    };
  };
}
