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
      # tank/archive/retro which stays unsnapshotted).
      "tank/archive/suno" = {
        useTemplate = [ "bulk" ];
        recursive = true;
      };

      # callisto's iSCSI-root zvol (hosts/callisto/configuration.nix): the
      # diskless host's ENTIRE persistent state lives here — nix store, fleet
      # Postgres, MQTT config, the opencode/hyperresearch rig. Hourly
      # `important` snapshots are the cheapest insurance against a bad
      # activation or rm on a box that cannot boot without this very volume.
      # NOTE 2026-08-26: the live target-served volume is on rpool — older
      # docs/plans saying tank/services/callisto-root describe a pre-migration
      # leftover (both zvols exist; only rpool is LIO-backed).
      "rpool/services/callisto-root" = {
        useTemplate = [ "important" ];
        recursive = true;
      };

      # tank/surveillance, tank/downloads, tank/junk:
      # no snapshots (churny/disposable/in-flight).
    };
  };
}
