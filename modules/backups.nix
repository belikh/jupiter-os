{ pkgs, ... }:

{
  # Restic Backup Configuration
  # This module automatically encrypts, deduplicates, and backs up critical paths
  # to a remote S3/B2/R2 bucket on a regular schedule.

  # Ensure the restic package is installed for manual recovery and snapshot commands
  environment.systemPackages = [ pkgs.restic ];

  # Note: The actual credentials for the repository and the S3 keys
  # will be securely loaded via sops-nix in your secrets.yaml once generated.

  services.restic.backups = {
    daily-cloud-backup = {
      # The paths you want to backup. These can be extended per-host if needed.
      paths = [
        "/var/lib/n8n"
        "/var/lib/libvirt/images" # Where the HAOS VM disk lives
        "/mnt/nas/important_data" # Placeholder for ZFS NAS important datasets
      ];

      # Exclude cache or temporary files
      exclude = [
        "/var/lib/**/tmp"
        "/var/lib/**/cache"
      ];

      # The repository location (e.g., s3:s3.us-west-004.backblazeb2.com/your-bucket)
      # repositoryFile = config.sops.secrets.restic_repo_url.path;
      repository = "s3:s3.us-west-004.backblazeb2.com/jupiter-os-backups"; # Placeholder

      # The password used to encrypt the backup locally before uploading
      # passwordFile = config.sops.secrets.restic_password.path;
      passwordFile = "/etc/nixos/restic-password.txt"; # Placeholder

      # Environment variables for S3 credentials (AWS_ACCESS_KEY_ID, etc.)
      # environmentFile = config.sops.secrets.restic_env.path;

      # Run every night at 2:00 AM
      timerConfig = {
        OnCalendar = "02:00";
        RandomizedDelaySec = "1h";
      };

      # Retention policy: Keep 7 daily, 4 weekly, and 6 monthly backups
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 6"
      ];
    };
  };
}
