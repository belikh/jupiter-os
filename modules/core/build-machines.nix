{
  config,
  lib,
  ...
}:

# Delegates eligible builds to callisto (i5, 64GB RAM — dwarfs every other
# registered host) as a shared Nix remote builder, fleet-wide by default.
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
        # TODO: confirm the i5's real core count and adjust; 4 is a
        # conservative placeholder, not a measured value.
        maxJobs = 4;
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
