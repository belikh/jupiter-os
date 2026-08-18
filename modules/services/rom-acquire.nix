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
#   jupiter-rom-acquire : submits each declared system's torrent to the fleet
#                         aria2 JSON-RPC daemon (modules/services/aria2.nix,
#                         jupiter.services.aria2), fire-and-forget — the daemon
#                         downloads into <incomingDir>/<sys>/ and RESUMES any
#                         partial data + .aria2 control file already staged
#                         there. Acquisition completes asynchronously; see the
#                         verify gating below.
#   jupiter-rom-verify  : scripts/cartridge-verify.sh - igir hashes each staged
#                         set against its No-Intro DAT, quarantines unmatched/
#                         corrupt files, and promotes the verified ROMs into
#                         the cartridge games tree (the romScraper/arcade
#                         modules read from there). SKIPS any system whose
#                         staged tree still holds .aria2 control files (in-
#                         flight), so it is safe to run before a download has
#                         fully finished — promotion happens only for complete
#                         sets.
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

  # Inlined from scripts/ (single source of truth): the JSON-RPC client that
  # submits torrents to the fleet aria2 daemon (modules/services/aria2.nix).
  # script is testable standalone (scripts/aria2-rpc.sh), and this store path
  # is what the acquire oneshot actually runs.
  rpcScript = pkgs.writeShellScriptBin "jupiter-aria2-rpc" (
    builtins.readFile ../../scripts/aria2-rpc.sh
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
      JSON-RPC oneshot that submits each declared system's Minerva/Myrient
      torrent to the fleet aria2 daemon (jupiter.services.aria2) into its own
      incoming subdir (fire-and-forget), and an igir-backed verify oneshot that
      hash-checks each staged set against its No-Intro DAT, quarantines
      failures, and promotes the verified ROMs into the matching dataset tree
      (cartridge/optical/modern). Acquisition is manual (no timer) - start the
      units explicitly
    '';

    incomingDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/cache/incoming/nointro-nintendo";
      description = ''
        Download root managed by the aria2 daemon (the fleet aria2 service's
        writable set must include it - see
        <option>jupiter.services.aria2.extraWritableDirs</option>), one subdir
        per system. Each declared system's torrent is submitted to the daemon
        with <literal>dir=<dir>/<system>/</literal>, so the daemon RESUMES any
        partial data + .aria2 control file already staged there.
      '';
    };

    rpcHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Host of the aria2 JSON-RPC endpoint downloads are submitted to
        (the fleet daemon, <option>jupiter.services.aria2</option>).
      '';
    };

    rpcPort = lib.mkOption {
      type = lib.types.port;
      default = 6800;
      description = ''
        Port of the aria2 JSON-RPC endpoint. Defaults to aria2's
        <option>jupiter.services.aria2.rpcPort</option> (6800).
      '';
    };

    rpcSecretFile = lib.mkOption {
      type = lib.types.path;
      default = config.sops.secrets.jupiter_aria2_rpc_secret.path;
      description = ''
        File containing the aria2 RPC secret used to authenticate submissions.
        Defaults to the sops-declared <literal>jupiter_aria2_rpc_secret</literal>
        (declared here so the module is self-contained, identical to the one
        the aria2 daemon reads at startup).
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
      pkgs.bzip2
      pkgs.igir
      pkgs.p7zip
      pkgs.rsync
      pkgs.unzip
      verifyScript
    ];

    # The daemon runs as io:users, so the RPC secret must be readable by that
    # user (sops defaults to 0400 root:root). Identical declaration to the
    # aria2 module's so the two merge cleanly when both are enabled.
    sops.secrets.jupiter_aria2_rpc_secret = {
      owner = "io";
      group = "users";
      mode = "0400";
    };

    systemd.services.jupiter-rom-acquire = {
      description = "No-Intro Nintendo console ROM acquisition (aria2 JSON-RPC)";
      serviceConfig.Type = "oneshot";
      unitConfig.RequiresMountsFor = poolPaths;
      # Downloads land in the aria2 daemon, so this must run only when the
      # daemon is up. RequiresMountsFor on the incoming/torrent dirs stays.
      after = [ "aria2.service" ];
      wants = [ "aria2.service" ];
      environment = {
        INCOMING_DIR = cfg.incomingDir;
        TORRENT_DIR = cfg.torrentDir;
        SCRATCH_DIR = cfg.scratchDir;
        RPC_HOST = cfg.rpcHost;
        RPC_PORT = toString cfg.rpcPort;
        RPC_SECRET_FILE = cfg.rpcSecretFile;
      };
      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      script = ''
        set -euo pipefail
        mkdir -p "$SCRATCH_DIR" "$INCOMING_DIR"
        skipped=""
        submitted=0
        failed=0
        ${lib.concatMapStringsSep "\n" (name: ''
          __torrent="$TORRENT_DIR/${cfg.systems.${name}.torrent}"
          if [ -f "$__torrent" ]; then
            # Create the system dir as io:users so the daemon (which runs as
            # io) can write partials + .aria2 control files into it and RESUME
            # any already-staged data. install -d with -o/-g chowns existing
            # dirs too, covering the previously root-owned tree.
            install -d -o io -g users "$INCOMING_DIR/${name}"
            # Idempotent: re-adding a torrent the daemon already knows fails
            # asynchronously (its GID errors with code 12 "already registered")
            # and never becomes a duplicate active download — so a rerun just
            # re-logs GIDs. A hard submission failure (unreachable daemon,
            # timeout ingesting a large metainfo) aborts the unit via set -e;
            # capture the status explicitly so we do NOT swallow it (echo
            # would mask the failure like the ARG_MAX bug did).
            if gid="$(${lib.getExe rpcScript} submit-torrent "$__torrent" "$INCOMING_DIR/${name}")"; then
              echo "jupiter-rom-acquire: ${name} -> gid=$gid"
              submitted=$((submitted + 1))
            else
              echo "jupiter-rom-acquire: FAILED to submit ${name}" >&2
              failed=$((failed + 1))
            fi
          else
            echo "jupiter-rom-acquire: torrent not found, skipping ${name}: $__torrent" >&2
            skipped="$skipped ${name}"
          fi
        '') systemKeys}
        if [ "$submitted" -eq 0 ]; then
          echo "jupiter-rom-acquire: no torrents resolved under $TORRENT_DIR - nothing to fetch" >&2
          exit 1
        fi
        [ -n "$skipped" ] && echo "jupiter-rom-acquire: skipped:$skipped" >&2
        if [ "$failed" -gt 0 ]; then
          echo "jupiter-rom-acquire: $failed submission(s) FAILED - rerun after fixing (see above)" >&2
          exit 1
        fi
        # Fire-and-forget: submissions accepted; the daemon downloads in the
        # background. Progress is visible via AriaNg or
        # scripts/aria2-rpc.sh get-global-stat / tell-active.
        echo "jupiter-rom-acquire: submitted $submitted torrent(s) to aria2 RPC (fire-and-forget)"
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
