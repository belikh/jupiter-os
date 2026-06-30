{
  config,
  lib,
  pkgs,
  ...
}:

# PostgreSQL server. On elitedesk its data directory lives on the iSCSI "db" LUN
# exported by the NAS, so it survives the diskless node's reboots.
#
# `databases` provisions one role + owned database each, sets the role's password
# from a sops secret, and (via per-database `allowedClients`) opens scram-sha-256
# network access from specific CIDRs — so consumers on other hosts (e.g. n8n and
# the Home Assistant VM on lenovo) can connect. Local peer auth still works for
# admin.

let
  cfg = config.jupiter.services.postgresql;

  dbNames = lib.attrNames cfg.databases;

  # pg_hba host lines: per database, per allowed client CIDR. Each role may only
  # reach its own database.
  hbaLines = lib.concatLists (
    lib.mapAttrsToList (
      name: db: map (cidr: "host ${name} ${name} ${cidr} scram-sha-256") db.allowedClients
    ) cfg.databases
  );

  anyNetwork = hbaLines != [ ];
in
{
  options.jupiter.services.postgresql = {
    enable = lib.mkEnableOption "PostgreSQL server";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/postgresql";
      description = "Data directory root (a versioned subdir is created beneath it).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_16;
      defaultText = "pkgs.postgresql_16";
      description = "PostgreSQL package/version.";
    };

    databases = lib.mkOption {
      default = { };
      description = ''
        Databases to provision, keyed by name. Each gets a login role of the same
        name owning a database of the same name, with its password set from
        passwordFile and network access from allowedClients.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            passwordFile = lib.mkOption {
              type = lib.types.path;
              description = "sops secret holding this role's password (readable by the postgres user).";
            };
            allowedClients = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "10.1.1.20/32" ];
              description = "CIDRs allowed to connect to this database over TCP (scram-sha-256).";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      package = cfg.package;
      dataDir = "${cfg.dataDir}/${cfg.package.psqlSchema}";
      enableTCPIP = anyNetwork;

      ensureDatabases = dbNames;
      ensureUsers = map (name: {
        inherit name;
        ensureDBOwnership = true;
      }) dbNames;

      settings.password_encryption = "scram-sha-256";
      authentication = lib.mkIf anyNetwork (lib.concatStringsSep "\n" hbaLines);
    };

    # Set role passwords from their secret files (idempotent). psql's :'var'
    # quoting avoids injection from the password contents.
    systemd.services.postgresql-jupiter-roles = lib.mkIf (cfg.databases != { }) {
      description = "Set Jupiter PostgreSQL role passwords from secrets";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
      };
      script = lib.concatStrings (
        lib.mapAttrsToList (name: db: ''
          ${cfg.package}/bin/psql -v ON_ERROR_STOP=1 \
            -v pw="$(cat ${db.passwordFile})" \
            -tAc "ALTER ROLE \"${name}\" WITH LOGIN PASSWORD :'pw'"
        '') cfg.databases
      );
    };

    networking.firewall.allowedTCPPorts = lib.mkIf anyNetwork [ 5432 ];

    # Don't start the DB until its (iSCSI-backed) data directory is mounted.
    systemd.services.postgresql.unitConfig.RequiresMountsFor = [ cfg.dataDir ];
  };
}
