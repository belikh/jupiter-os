{
  config,
  lib,
  ...
}:

# Delegates eligible builds to callisto (HP EliteDesk 800 G4 DM, i5-8500T
# Coffee Lake 6c/6t, 64GB RAM — dwarfs every other registered host) as a
# shared Nix remote builder, fleet-wide by default.
#
# callisto is diskless/netboot (see hosts/callisto/configuration.nix), so its
# SSH host key is regenerated every boot — there's no stable key to pin via
# publicHostKey, so host-key checking is disabled for that one Host entry
# instead. Authenticates as root using a dedicated keypair (not the admin's
# own): the private half is the nix_build_ssh_key sops secret, deployed
# fleet-wide; the public half is baked into callisto's own
# users.users.root.openssh.authorizedKeys.keys.
#
# Targeted by static IP, not hostname: no DNS resolver is registered yet
# (ganymede's future role), so "callisto" wouldn't resolve. UniFi DHCP
# reservation: MAC c4:65:16:b8:76:03 -> 10.1.1.3 (Default network).
#
# maxJobs = 1 mirrors callisto's local `nix.settings.max-jobs = 1`
# (hosts/callisto/configuration.nix): callisto is tuned for low-concurrency
# large-package work (cores=6, one derivation at a time using all 6 cores
# for internal -j6), NOT for many-concurrent-small-packages like pallene.
# Setting maxJobs=1 here tells dispatchers exactly how much concurrent work
# callisto will accept — anything higher would queue at the remote daemon
# rather than parallelize.

let
  cfg = config.jupiter.core.buildMachines;
in
{
  options.jupiter.core.buildMachines = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Delegate eligible builds to callisto as a remote Nix builder.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.nix_build_ssh_key = { };

    nix.distributedBuilds = true;
    nix.buildMachines = [
      {
        hostName = "10.1.1.3"; # callisto, DHCP-reserved (see comment above)
        system = "x86_64-linux";
        protocol = "ssh-ng";
        sshUser = "root";
        sshKey = config.sops.secrets.nix_build_ssh_key.path;
        # maxJobs mirrors callisto's local nix.settings.max-jobs = 1
        # (hosts/callisto/configuration.nix): callisto runs ONE derivation
        # at a time using all 6 cores (cores=6), the right shape for its
        # incremental shared-builder workload (large packages, low
        # concurrency) rather than pallene's full-closure-from-scratch
        # shape (cores=1, many parallel). See hosts/callisto/configuration.nix
        # for the workload-shape reasoning.
        maxJobs = 1;
        # speedFactor=2 (callisto is 2x faster than the requesting host's
        # own builder) is conservative — vs europa's Opteron X3216 the i5-8500T
        # is several times faster per core — but with a single builder
        # registered, dispatch happens regardless; the value only biases
        # choice once a second builder exists.
        speedFactor = 2;
        supportedFeatures = [
          "gccarch-btver2"
          "gccarch-skylake"
          "big-parallel"
        ];
        mandatoryFeatures = [ ];
      }
    ];

    programs.ssh.extraConfig = ''
      Host callisto
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
    '';
  };
}
