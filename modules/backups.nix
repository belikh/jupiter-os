{ config, pkgs, lib, ... }:

{
  options = {
    jupiter.backups.paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of absolute paths to include in the backup.";
    };
  };

  config = {
    sops.secrets.restic_password = {
      sopsFile = ../secrets/secrets.yaml;
    };
    
    sops.secrets.restic_env = {
      sopsFile = ../secrets/secrets.yaml;
    };

    # Ensure the restic package is installed for manual recovery and snapshot commands
    environment.systemPackages = [ pkgs.restic ];

    services.restic.backups = {
      daily-cloud-backup = {
        # Dynamically set from host configuration
        paths = config.jupiter.backups.paths;

        # Exclude cache or temporary files
        exclude = [
          "/var/lib/**/tmp"
          "/var/lib/**/cache"
        ];

        # The repository location (e.g., s3:s3.us-west-004.backblazeb2.com/your-bucket)
        repository = "s3:s3.us-west-004.backblazeb2.com/jupiter-os-backups"; # Placeholder

        # The password used to encrypt the backup locally before uploading
        passwordFile = config.sops.secrets.restic_password.path;

        # Environment variables for S3 credentials (AWS_ACCESS_KEY_ID, etc.)
        environmentFile = config.sops.secrets.restic_env.path;

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
  };
}
