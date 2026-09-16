{ ... }:

# Snapshot policy (sanoid) for the NAS `tank` pool.
#
# Redundancy model (tank is a two-disk mirror):
#   - tank mirror           -> survives a drive failure
#   - sanoid snapshots      -> accident / ransomware / "oops rm" recovery
#   - restic -> cloud       -> offsite copy of the irreplaceable set
#                              (configured via jupiter.backups.paths in the host)
#
# Bulk/expendable datasets (surveillance, downloads) are intentionally NOT
# snapshotted — they churn heavily and are disposable.
# tank/junk is intentionally NOT snapshotted — it's in-flight transfer data.
{
  services.sanoid = {
    enable = true;

    templates.important = {
      hourly = 36;
      daily = 30;
      monthly = 6;
      yearly = 1;
      autosnap = true;
      autoprune = true;
    };

    templates.bulk = {
      hourly = 0;
      daily = 7;
      monthly = 1;
      yearly = 0;
      autosnap = true;
      autoprune = true;
    };

    # Block-volume template, for the iSCSI zvol only. A zvol holding a host's
    # live root is not an append-only archive: every `nixos-rebuild` rewrites
    # large parts of the store, so a snapshot's cost scales with the churn
    # between it and the next one, not with age. The `important` window (36
    # hourly + 30 daily + 6 monthly + 1 yearly = up to 73 snapshots) held ~173G
    # of the 280G zvol on a 464G pool shared with europa's /nix, and on
    # 2026-09-01 the pool hit 100%: callisto's root went read-only and europa's
    # next boot was an ENOSPC cascade (no random seed, no utmp, no nix-daemon
    # socket, no resolvconf, no nginx).
    #
    # `monthly`/`yearly` are 0 on purpose. The OLDEST snapshot in the chain
    # carries every block changed since it was taken, and that grows without
    # bound between prunes — the single Sep-1 monthly held 67.2G by Sep 17
    # (measured), dwarfing the 100M-1.4G daily deltas. On a churning zvol a
    # long-horizon snapshot is the most expensive one there is. Six-hourly +
    # weekly is the rollback window that actually pays for itself; anything
    # older belongs in restic, not in snapshots that starve the host pool.
    templates.zvol = {
      hourly = 6;
      daily = 7;
      monthly = 0;
      yearly = 0;
      autosnap = true;
      autoprune = true;
    };

    datasets = {
      # Irreplaceable / important — frequent snapshots, recursive.
      "tank/personal" = {
        useTemplate = [ "important" ];
        recursive = true;
      };
      "tank/backups" = {
        useTemplate = [ "important" ];
        recursive = true;
      };
      "tank/vm" = {
        useTemplate = [ "important" ];
        recursive = true;
      };

      # Re-acquirable bulk — light snapshots.
      "tank/media" = {
        useTemplate = [ "bulk" ];
        recursive = true;
      };

      # Suno library backup (modules/services/suno-backup.nix): irreplaceable
      # (Suno could delete/change retention any time — the whole point), so it
      # IS snapshotted unlike the re-acquirable retro ROMs; but it's a
      # slow-growing append-only archive of large immutable files, so the light
      # `bulk` cadence (daily/monthly) fits better than tank/backups's hourly
      # `important`. Non-recursive into tank/archive (only this dataset, not
      # the rest of tank/archive/retro — the arcade datasets that need
      # snapshots are covered individually below).
      "tank/archive/suno" = {
        useTemplate = [ "bulk" ];
        recursive = true;
      };

      # ---- jupiterOS Arcade (W1-T3) ----------------------------------------
      # tank/archive/retro/state holds the arcade-webapp's SQLite store:
      # operator curation and verification history — the one arcade asset
      # that cannot be re-acquired (ROMs re-download, DATs re-fetch, the
      # curation record is labour). It was the explicitly-excluded
      # irreplaceable dataset before this. Hourly `important`: the DB
      # churns with every verify/scrape cycle and is tiny.
      "tank/archive/retro/state" = {
        useTemplate = [ "important" ];
        recursive = true;
      };

      # The No-Intro DAT packs: re-acquirable in principle, but they are the
      # verification baseline for the whole pipeline (and for the W4b DAT
      # lock), non-redistributable (No-Intro's terms — no committed copy can
      # exist), and a daily snapshot is cheap insurance for the exact bytes
      # every promotion was verified against.
      "tank/archive/retro/metadata/no-intro-dats" = {
        useTemplate = [ "bulk" ];
        recursive = true;
      };

      # Skyscraper's scrape cache: regenerating it means re-hitting
      # ScreenScraper/TGDB rate limits for tens of thousands of titles —
      # irreplaceable-in-time even though it is derived data. Light cadence:
      # large, append-mostly, rarely read back.
      "tank/archive/retro/metadata/skyscraper-cache" = {
        useTemplate = [ "bulk" ];
        recursive = true;
      };

      # Deliberately still NOT snapshotted under tank/archive/retro: the
      # games/* ROM trees (re-acquirable bulk — that is ADR-0001's entire
      # premise), cache/scratch/downloads (in-flight), and the generated
      # metadata/pegasus* trees (fully regenerable by the webapp, and
      # byte-equivalence-tested against the repo's golden corpus).

      # callisto's iSCSI-root zvol (hosts/callisto/configuration.nix): the
      # diskless host's ENTIRE persistent state lives here — nix store, fleet
      # Postgres, MQTT config, the opencode/hyperresearch rig. Snapshots are
      # cheap insurance against a bad activation or rm on a box that cannot
      # boot without this very volume — but this is a zvol, so it uses the
      # light `zvol` template, not `important`: see that template's comment
      # for why 73 snapshots filled the pool on 2026-09-01.
      # NOTE 2026-08-26: the live target-served volume is on rpool — older
      # docs/plans saying tank/services/callisto-root describe a pre-migration
      # leftover (both zvols exist; only rpool is LIO-backed).
      "rpool/services/callisto-root" = {
        useTemplate = [ "zvol" ];
        recursive = true;
      };

      # tank/surveillance, tank/downloads, tank/junk:
      # no snapshots (churny/disposable/in-flight).
    };
  };
}
