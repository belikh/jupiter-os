{ ... }:

# Snapshot policy (sanoid) for the NAS `tank` pool.
#
# Redundancy model (no second on-box pool — europa is a frozen archive, not a
# backup target):
#   - tank's 18TB MIRROR  -> survives a drive failure
#   - sanoid snapshots    -> accident / ransomware / "oops rm" recovery
#   - restic -> cloud     -> offsite copy of the irreplaceable set
#                            (configured via jupiter.backups.paths in the host)
#
# Bulk/expendable datasets (surveillance, downloads) are intentionally NOT
# snapshotted — they churn heavily and are disposable.
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

      # tank/surveillance, tank/downloads, tank/netboot, tank/archive:
      # no snapshots (churny/disposable, or static cold storage).
    };
  };

  # NOTE: no syncoid here. There is no local replication target — europa is a
  # full, frozen archive on the 10TB mirror, not a backup pool. If a dedicated
  # backup target is added later, wire `services.syncoid` to replicate
  # tank/personal + tank/backups onto it.
}
