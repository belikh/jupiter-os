{ ... }:

# Snapshot policy (sanoid) for the NAS `tank` pool.
#
# Redundancy model (tank is currently a single vdev — will become a mirror
# once the sdc file transfer completes):
#   - tank mirror (future) -> survives a drive failure
#   - sanoid snapshots     -> accident / ransomware / "oops rm" recovery
#   - restic -> cloud      -> offsite copy of the irreplaceable set
#                             (configured via jupiter.backups.paths in the host)
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

      # tank/surveillance, tank/downloads, tank/junk:
      # no snapshots (churny/disposable/in-flight).
    };
  };
}
