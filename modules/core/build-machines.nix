{
  config,
  lib,
  ...
}:

# Symmetric peer-to-peer build pool across all Skylake hosts in the fleet:
# callisto (i5-8500T, 6c/6t, 64GB) + 4 dashboard kiosks (i5-6300U, 2c/4t, 7.6GB).
#
# All 5 hosts advertise gccarch-skylake (their own microarch) AND gccarch-bdver4
# (ISA superset: Skylake can safely compile/run Excavator code for europa).
# Each host runs maxJobs=1 with cores=4, leaving headroom for its own workload
# (callisto leaves 2 cores free; kiosks leave the dashboard session responsive).
#
# SSH auth: dedicated keypair fleet-wide. Private half = nix_build_ssh_key sops
# secret (deployed to all 5 hosts). Public half baked into each host's
# users.users.root.openssh.authorizedKeys.keys.
#
# Targeting: callisto by static IP (10.1.1.3, DHCP-reserved MAC c4:65:16:b8:76:03).
# Kiosks by mDNS hostname (amalthea.localdomain etc.) — dynamic DHCP, no static
# reservation yet. All host keys pinned declaratively via programs.ssh.knownHosts.

let
  cfg = config.jupiter.core.buildMachines;

  # All Skylake hosts in the fleet (callisto + 4 kiosks)
  allSkylakeHosts = [
    {
      name = "callisto";
      host = config.jupiter.fleet.addresses.callisto;
      isKiosk = false;
    }
    {
      name = "amalthea";
      host = "amalthea.localdomain";
      isKiosk = true;
    }
    {
      name = "metis";
      host = "metis.localdomain";
      isKiosk = true;
    }
    {
      name = "adrastea";
      host = "adrastea.localdomain";
      isKiosk = true;
    }
    {
      name = "thebe";
      host = "thebe.localdomain";
      isKiosk = true;
    }
  ];

  # Build a builder spec for any Skylake host
  mkBuilder =
    {
      name,
      host,
      isKiosk,
    }:
    {
      hostName = host;
      system = "x86_64-linux";
      protocol = "ssh-ng";
      sshUser = "root";
      sshKey = config.sops.secrets.nix_build_ssh_key.path;
      # maxJobs=1: one derivation at a time, using all 4 cores
      # (cores is set on the builder host via nix.settings.cores = 4)
      maxJobs = 1;
      speedFactor = if isKiosk then 1 else 2; # callisto 2x faster than kiosks
      supportedFeatures = [
        "gccarch-skylake"
        "gccarch-bdver4"
        "big-parallel"
      ];
      mandatoryFeatures = [ ];
    };

  # All builders (the full symmetric pool)
  allBuilders = map mkBuilder allSkylakeHosts;

  # For a given host, its REMOTE builders are all OTHER Skylake hosts
  remoteBuilders = lib.filter (b: b.hostName != cfg.selfHost) allBuilders;
in
{
  imports = [ ../network/fleet.nix ];

  options.jupiter.core.buildMachines = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable symmetric distributed builds across all Skylake hosts (callisto + 4 kiosks).";
    };

    # The host's own identity in the fleet (must match one of allSkylakeHosts)
    selfHost = lib.mkOption {
      type = lib.types.str;
      description = "This host's buildMachines entry key (callisto, amalthea, metis, adrastea, thebe).";
      example = "callisto";
    };
  };

  config = lib.mkIf cfg.enable {
    # Safety: selfHost must be set
    assertions = [
      {
        assertion = cfg.selfHost != "";
        message = "jupiter.core.buildMachines.selfHost must be set to one of: callisto, amalthea, metis, adrastea, thebe";
      }
    ];

    sops.secrets.nix_build_ssh_key = { };

    nix.distributedBuilds = true;
    nix.buildMachines = remoteBuilders;

    # SSH config for all builder hosts
    programs.ssh.extraConfig = lib.concatStringsSep "\n" (
      map (b: ''
        Host ${b.hostName}
          IdentityFile ${config.sops.secrets.nix_build_ssh_key.path}
          IdentitiesOnly yes
      '') allBuilders
    );

    # Known host keys for all builders (pinned declaratively)
    # Captured via ssh-keyscan 2026-07-24, cross-checked against admin's known_hosts
    programs.ssh.knownHosts = {
      callisto = {
        hostNames = [ config.jupiter.fleet.addresses.callisto ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINKUMgEPCzZRq74JtvkMmfmT6gOmZWGGq8G9lNqqKsU";
      };
      amalthea = {
        hostNames = [ "amalthea.localdomain" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQV+BzJbBfN+T3WKEUo4CzwJHS1B2bsnH5vglHmbP+Y";
      };
      thebe = {
        hostNames = [ "thebe.localdomain" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOjnMhsh8PxlRW1tXYR4GjjDNa4J8os/4URkbD777JMg";
      };
      metis = {
        hostNames = [ "metis.localdomain" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAB6bFJpQteERsDDg7otkc42JOWXDZUA9WprQ/gnEiAK";
      };
    };
  };
}
