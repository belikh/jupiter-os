{
  config,
  lib,
  pkgs,
  ...
}:

# No-Intro Nintendo console ROM acquisition + verification (europa-side).
#
# Declarifies the old transient `ninty-rom-dl` unit that ran aria2 by hand
# against the 17 Minerva/Myrient No-Intro Nintendo torrents. Two manual
# oneshots (NO timer - ROM acquisition is a one-time provisioning step, kicked
# explicitly via `systemctl start`):
#
#   jupiter-rom-acquire : aria2 each declared system's torrent into its own
#                         incoming subdir, built straight from `systems`.
#   jupiter-rom-verify  : scripts/cartridge-verify.sh - igir hashes each staged
#                         set against its No-Intro DAT, quarantines unmatched/
#                         corrupt files, and promotes the verified ROMs into
#                         the cartridge games tree (the romScraper/arcade
#                         modules read from there).
#
# DATs are non-redistributable and live on-pool (never in this repo); a missing
# DAT degrades verify to promote-without-checking for that system rather than
# blocking ("better partial than blocked").
#
# igir command reference: https://igir.io/commands/ and
# https://igir.io/output/reporting/ (the `move test report` combination).
let
  cfg = config.jupiter.services.romAcquire;

  # Derived from the console-system catalogue (scripts/cartridge-catalogue.tsv
  # via modules/services/arcade-catalogue.nix) — single source of truth shared
  # with rom-scraper, arcade-inventory, cartridges and cartridge-scrape.sh.
  # torrent: canonical Minerva/Myrient No-Intro basenames (NES = Headerless
  # per the fleet choice; cartridge-era under "No-Intro - Nintendo -", optical
  # and Wii U under "No-Intro - Non-Redump - Nintendo -"). `bucket` routes the
  # verify oneshot's promotion destination: cartridge -> games/cartridge/<sys>,
  # optical -> games/optical/<sys>, modern -> games/modern/<sys> — matching the
  # ZFS datasets in modules/storage/zfs-nas.nix and the kiosk-side mounts in
  # modules/desktop/cartridges.nix. `core` is informational (cartridges.nix's
  # view — same TSV — is what launches); null for Wii U (Cemu standalone).
  defaultSystems = lib.mapAttrs (_: v: {
    inherit (v) torrent core bucket;
  }) config.jupiter.arcade.catalogue;

  systemKeys = lib.attrNames cfg.systems;

  # Bucket -> destination tree root on the pool. The verify oneshot promotes
  # each system's staged ROMs into <root>/<sys>/, so the bucket a system is
  # assigned decides which ZFS dataset (and thus NFS export + recordsize) it
  # lands on. Matches the kiosk-side per-dataset mounts in cartridges.nix.
  bucketDir = {
    cartridge = cfg.cartridgeDir;
    optical = cfg.opticalDir;
    modern = cfg.modernDir;
  };
  usedBuckets = lib.unique (map (name: cfg.systems.${name}.bucket) systemKeys);
  systemsInBucket = bucket: lib.filter (name: cfg.systems.${name}.bucket == bucket) systemKeys;

  # Inlined from scripts/ (single source of truth) exactly the way exodos/
  # romScraper wrap their driver scripts, so the store path carries the
  # script's runtime shell from writeShellScriptBin.
  verifyScript = pkgs.writeShellScriptBin "jupiter-cartridge-verify" (
    builtins.readFile ../../scripts/cartridge-verify.sh
  );

  # Pool paths the oneshots touch - used for RequiresMountsFor so neither unit
  # can start before europa's tank is mounted.
  poolPaths = [
    cfg.incomingDir
    cfg.torrentDir
    cfg.datDir
    cfg.cartridgeDir
    cfg.opticalDir
    cfg.modernDir
    cfg.scratchDir
  ];
in
{
  imports = [ ./arcade-catalogue.nix ];

  options.jupiter.services.romAcquire = {
    enable = lib.mkEnableOption ''
      No-Intro Nintendo console ROM acquisition + verification: an aria2
      oneshot that fetches each declared system's Minerva/Myrient torrent into
      its own incoming subdir, and an igir-backed verify oneshot that
      hash-checks each staged set against its No-Intro DAT, quarantines
      failures, and promotes the verified ROMs into the matching dataset tree
      (cartridge/optical/modern). Acquisition is manual (no timer) - start the
      units explicitly
    '';

    incomingDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/cache/incoming/nointro-nintendo";
      description = ''
        aria2 download roots, one subdir per system. Each declared system's
        torrent is fetched into <dir>/<system>/.
      '';
    };

    torrentDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/minerva-torrents";
      description = ''
        Directory holding the Minerva/Myrient No-Intro Nintendo .torrent files
        on europa, named per each system's
        <option>jupiter.services.romAcquire.systems.*.torrent</option>.
      '';
    };

    cartridgeDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/cartridge";
      description = ''
        Verified-playable destination tree for the cartridge bucket: verified
        ROMs for a system land in <dir>/<system>/. Each system's `bucket`
        decides which destination root it promotes into.
      '';
    };

    opticalDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/optical";
      description = ''
        Verified-playable destination tree for the optical bucket (GameCube/Wii
        disc images): verified ROMs land in <dir>/<system>/.
      '';
    };

    modernDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/modern";
      description = ''
        Verified-playable destination tree for the modern bucket (3DS/Wii U):
        verified ROMs land in <dir>/<system>/.
      '';
    };

    datDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/no-intro-dats";
      description = ''
        Non-redistributable No-Intro DATs (on-pool, not in this repo), one per
        system: <dir>/<system>.dat. A missing DAT degrades verify to
        promote-without-checking for that system rather than blocking.
      '';
    };

    scratchDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/scratch";
      description = ''
        Working area: igir audit CSV reports land in <dir>/reports/, quarantined
        (unmatched/corrupt) ROMs in <dir>/quarantine/.
      '';
    };

    systems = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            torrent = lib.mkOption {
              type = lib.types.str;
              description = ''
                Basename of this system's Minerva/Myrient No-Intro .torrent file
                under <option>torrentDir</option>.
              '';
            };
            core = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                libretro/RetroArch core identifier for this system
                (informational; the kiosk-side modules/desktop/cartridges.nix
                systems map is the source of truth for cores). Defaults follow
                the conventional libretro core per system. null for systems with
                no libretro core (Wii U -> standalone Cemu).
              '';
            };
            bucket = lib.mkOption {
              type = lib.types.enum [
                "cartridge"
                "optical"
                "modern"
              ];
              default = "cartridge";
              description = ''
                Which destination tree this system promotes into on verify:
                cartridge (<option>cartridgeDir</option>), optical
                (<option>opticalDir</option>), or modern
                (<option>modernDir</option>). Matches the ZFS datasets in
                modules/storage/zfs-nas.nix and the kiosk-side per-dataset NFS
                mounts in modules/desktop/cartridges.nix.
              '';
            };
          };
        }
      );
      default = defaultSystems;
      description = ''
        Console systems to acquire + verify. Keys are short system names used
        for the incoming/destination/DAT subdirs; each value names its torrent
        basename, libretro core (informational), and the bucket whose
        destination tree its verified ROMs promote into. Defaults derive from
        scripts/cartridge-catalogue.tsv (every system the fleet stages — the
        catalogue is shared with the scraper, inventory, kiosk mounts and the
        scrape script, so the views cannot drift).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.aria2
      pkgs.bzip2
      pkgs.igir
      pkgs.p7zip
      pkgs.rsync
      pkgs.unzip
      verifyScript
    ];

    systemd.services.jupiter-rom-acquire = {
      description = "No-Intro Nintendo console ROM acquisition (aria2)";
      serviceConfig.Type = "oneshot";
      unitConfig.RequiresMountsFor = poolPaths;
      environment = {
        INCOMING_DIR = cfg.incomingDir;
        TORRENT_DIR = cfg.torrentDir;
        SCRATCH_DIR = cfg.scratchDir;
      };
      script = ''
        set -euo pipefail
        mkdir -p "$SCRATCH_DIR" "$INCOMING_DIR"
        INPUT="$SCRATCH_DIR/aria2-input.txt"
        : > "$INPUT"
        skipped=""
        ${lib.concatMapStringsSep "\n" (name: ''
          __torrent="$TORRENT_DIR/${cfg.systems.${name}.torrent}"
          if [ -f "$__torrent" ]; then
            mkdir -p "$INCOMING_DIR/${name}"
            {
              printf '%s\n' "$__torrent"
              printf '  dir=%s\n' "$INCOMING_DIR/${name}"
              printf '\n'
            } >> "$INPUT"
          else
            echo "jupiter-rom-acquire: torrent not found, skipping ${name}: $__torrent" >&2
            skipped="$skipped ${name}"
          fi
        '') systemKeys}
        if [ ! -s "$INPUT" ]; then
          echo "jupiter-rom-acquire: no torrents resolved under $TORRENT_DIR - nothing to fetch" >&2
          exit 1
        fi
        [ -n "$skipped" ] && echo "jupiter-rom-acquire: skipped:$skipped" >&2
        exec ${lib.getExe pkgs.aria2} \
          --input-file="$INPUT" \
          --continue=true \
          --allow-overwrite=true \
          --file-allocation=none \
          --max-concurrent-downloads=6 \
          --enable-dht=true \
          --bt-enable-lpd=true \
          --listen-port=51413 \
          --dht-listen-port=51413 \
          --seed-time=0
      '';
    };

    systemd.services.jupiter-rom-verify = {
      description = "No-Intro Nintendo console ROM verification + promotion (igir)";
      serviceConfig.Type = "oneshot";
      unitConfig.RequiresMountsFor = poolPaths;
      # Both pool paths and the igir/rsync store paths are handed to the script
      # explicitly so it is robust to a sanitized PATH. CARTRIDGE_DIR is set
      # per-bucket in the script (not here) so each bucket promotes into its own
      # destination tree (cartridge/optical/modern).
      environment = {
        INCOMING_DIR = cfg.incomingDir;
        DAT_DIR = cfg.datDir;
        SCRATCH_DIR = cfg.scratchDir;
        IGIR = lib.getExe pkgs.igir;
        RSYNC = lib.getExe pkgs.rsync;
      };
      script = ''
        set -uo pipefail
        rc=0
        ${lib.concatMapStringsSep "\n" (bucket: ''
          # cartridge-verify.sh reads CARTRIDGE_DIR from its env to pick the
          # destination root for this bucket's systems. Run each bucket in turn
          # so an empty bucket (nothing staged) is a no-op and a failure in one
          # bucket does not skip the rest (matching the script's own resilience).
          echo "jupiter-rom-verify: bucket '${bucket}' -> ${bucketDir.${bucket}}"
          CARTRIDGE_DIR="${bucketDir.${bucket}}" ${lib.getExe verifyScript} ${lib.concatStringsSep " " (systemsInBucket bucket)} || rc=1
        '') usedBuckets}
        exit "$rc"
      '';
    };
  };
}
