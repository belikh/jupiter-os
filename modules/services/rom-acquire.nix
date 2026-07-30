{
  config,
  lib,
  pkgs,
  ...
}:

# No-Intro Nintendo cartridge ROM acquisition + verification (europa-side).
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

  # Canonical Minerva/Myrient No-Intro Nintendo cartridge torrent basenames
  # (the leaf name under Myrient's No-Intro/Nintendo/ tree, prefixed with the
  # Minerva naming scheme). NES is the Headerless set per the fleet choice; the
  # rest follow the standard Myrient No-Intro Nintendo leaf names.
  defaultSystems = {
    nes = {
      torrent = "Minerva_Myrient - No-Intro - Nintendo - Nintendo Entertainment System (Headerless).torrent";
      core = "fceumm";
    };
    snes = {
      torrent = "Minerva_Myrient - No-Intro - Nintendo - Super Nintendo Entertainment System.torrent";
      core = "snes9x";
    };
    gb = {
      torrent = "Minerva_Myrient - No-Intro - Nintendo - Game Boy.torrent";
      core = "gambatte";
    };
    gbc = {
      torrent = "Minerva_Myrient - No-Intro - Nintendo - Game Boy Color.torrent";
      core = "gambatte";
    };
    gba = {
      torrent = "Minerva_Myrient - No-Intro - Nintendo - Game Boy Advance.torrent";
      core = "mgba";
    };
    n64 = {
      torrent = "Minerva_Myrient - No-Intro - Nintendo - Nintendo 64 (BigEndian).torrent";
      core = "mupen64plus";
    };
  };

  systemKeys = lib.attrNames cfg.systems;

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
    cfg.scratchDir
  ];
in
{
  options.jupiter.services.romAcquire = {
    enable = lib.mkEnableOption ''
      No-Intro Nintendo cartridge ROM acquisition + verification: an aria2
      oneshot that fetches each declared system's Minerva/Myrient torrent into
      its own incoming subdir, and an igir-backed verify oneshot that
      hash-checks each staged set against its No-Intro DAT, quarantines
      failures, and promotes the verified ROMs into the cartridge games tree.
      Acquisition is manual (no timer) - start the units explicitly
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
        Verified-playable destination tree: verified ROMs for a system land in
        <dir>/<system>/.
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
              type = lib.types.str;
              description = ''
                libretro/RetroArch core identifier for this system
                (informational; consumed by a future frontend module). Defaults
                follow the conventional libretro core per system.
              '';
            };
          };
        }
      );
      default = defaultSystems;
      description = ''
        Cartridge systems to acquire + verify. Keys are short system names used
        for the incoming/cartridge/DAT subdirs; each value names its torrent
        basename and libretro core. Defaults to the six cartridge systems
        (nes, snes, gb, gbc, gba, n64).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.aria2
      pkgs.igir
      pkgs.rsync
      verifyScript
    ];

    systemd.services.jupiter-rom-acquire = {
      description = "No-Intro Nintendo cartridge ROM acquisition (aria2)";
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
      description = "No-Intro Nintendo cartridge ROM verification + promotion (igir)";
      serviceConfig.Type = "oneshot";
      unitConfig.RequiresMountsFor = poolPaths;
      # Both pool paths and the igir/rsync store paths are handed to the script
      # explicitly so it is robust to a sanitized PATH.
      environment = {
        INCOMING_DIR = cfg.incomingDir;
        DAT_DIR = cfg.datDir;
        CARTRIDGE_DIR = cfg.cartridgeDir;
        SCRATCH_DIR = cfg.scratchDir;
        IGIR = lib.getExe pkgs.igir;
        RSYNC = lib.getExe pkgs.rsync;
      };
      script = ''
        exec ${lib.getExe verifyScript} ${lib.concatStringsSep " " systemKeys}
      '';
    };
  };
}
