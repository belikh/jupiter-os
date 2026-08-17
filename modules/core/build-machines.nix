{
  config,
  lib,
  ...
}:

# Delegates eligible builds to callisto (HP EliteDesk 800 G4 DM, i5-8500T
# Coffee Lake 6c/6t, 64GB RAM — dwarfs every other registered host) and the
# 4 idle dashboard kiosks as a shared pool of remote Nix builders,
# fleet-wide by default.
#
# callisto's SSH host key is pinned via programs.ssh.knownHosts below
# (captured 2026-07-24 once it gained a persistent iSCSI root — see
# hosts/callisto/configuration.nix), with the build key wired through
# programs.ssh.extraConfig (IdentitiesOnly). adrastea is omitted from
# knownHosts: not installed yet, add its key once provisioned.
# Authenticates as root using a dedicated keypair (not the admin's
# own): the private half is the nix_build_ssh_key sops secret, deployed
# fleet-wide; the public half is baked into callisto's own and every kiosk's
# users.users.root.openssh.authorizedKeys.keys.
#
# Callisto is targeted by static IP, not hostname: no DNS resolver is
# registered yet (ganymede's future role), so "callisto" wouldn't resolve.
# UniFi DHCP reservation: MAC c4:65:16:b8:76:03 -> 10.1.1.3 (Default network).
#
# Kiosks are targeted by mDNS hostname (amalthea.localdomain etc.) rather
# than static IP: they're on dynamic DHCP (no UniFi reservation yet), so a
# hostname follows the host across reboots but an IP wouldn't. A static IP
# per kiosk is the future cleanup (one less avahi-dependent hop); mDNS works
# today.
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

  # The 4 dashboard kiosks — identical Skylake TCx Wave units, idle 99.9999%
  # of the time, wired as build servers via modules/desktop/tcxwave-kiosk.nix.
  # maxJobs=1 (not 2) matches the kiosk workload: a single derivation at a
  # time using whatever cores the kiosk has free, leaving headroom for the
  # dashboard session so builds never visibly stutter the kiosk UI. Real
  # core count TODO if/when we want to push harder.
  #
  # gccarch-bdver4 (added so kiosks can help build europa's Excavator-tuned
  # closure): the kiosks aren't themselves bdver4-tuned, this only makes them
  # ELIGIBLE to build bdver4-tagged derivations for other hosts (europa) —
  # Skylake is an ISA superset of Excavator's standard extensions (AVX2/FMA/
  # BMI/F16C), so a Skylake kiosk can safely compile and run-check europa's
  # bdver4 code. Caveat: each kiosk only has ~7.6GiB RAM
  # (vs callisto's 64GB) — a large tuned derivation (e.g. clang/llvm) landing
  # on a kiosk instead of callisto risks swap-thrashing or OOM. Acceptable
  # for now since callisto's higher speedFactor biases dispatch there first;
  # revisit (e.g. a kiosk-specific supportedFeatures split, or capping which
  # derivations may land here) if that actually bites in practice.
  mkKioskBuilder = hostName: {
    inherit hostName;
    system = "x86_64-linux";
    protocol = "ssh-ng";
    sshUser = "root";
    sshKey = config.sops.secrets.nix_build_ssh_key.path;
    maxJobs = 1;
    speedFactor = 1;
    supportedFeatures = [
      "gccarch-skylake"
      "gccarch-bdver4"
      "big-parallel"
    ];
    mandatoryFeatures = [ ];
  };
  kioskBuilders = map mkKioskBuilder [
    "amalthea.localdomain"
    "metis.localdomain"
    "adrastea.localdomain"
    "thebe.localdomain"
  ];
in
{
  imports = [ ../network/fleet.nix ];

  options.jupiter.core.buildMachines = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Delegate eligible builds to callisto (+ the dashboard kiosks, see includeKiosks) as remote Nix builders.";
    };

    includeKiosks = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also wire the 4 dashboard kiosks as builders. europa sets this to
        false: it delegates to callisto ALONE (the kiosks' 7.6GiB RAM is a
        swap/OOM risk for its large tuned derivations, and their
        gccarch-bdver4 advert would re-open the Excavator path europa must
        not delegate — see advertiseBdver4).
      '';
    };

    advertiseBdver4 = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Include gccarch-bdver4 in callisto's supportedFeatures. europa MUST
        keep this false: callisto is Coffee Lake/Skylake with no XOP/TBM/FMA4
        (Excavator-only extensions bdver4 code may emit). Advertising it
        (pre-08fd609) made perl's miniperl bootstrap SIGILL while "building
        on europa" — actually mis-executing on callisto. Delegation is safe
        for europa NOW precisely because europa is untuned: its derivations
        carry no gccarch-* tag. Revisit only together with microarch tuning.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.nix_build_ssh_key = { };

    nix.distributedBuilds = true;
    nix.buildMachines = [
      {
        hostName = config.jupiter.fleet.addresses.callisto; # DHCP-reserved (see comment above)
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
        # gccarch-bdver4 is conditional (see advertiseBdver4): hosts whose
        # tuned closures may legally execute there must not send Excavator
        # code to a Coffee Lake builder.
        supportedFeatures = [
          "gccarch-skylake"
          "big-parallel"
        ]
        ++ lib.optional cfg.advertiseBdver4 "gccarch-bdver4";
        mandatoryFeatures = [ ];
      }
    ]
    ++ lib.optionals cfg.includeKiosks kioskBuilders;

    # callisto now has a persistent iSCSI root with a stable host key
    # (captured 2026-07-24 onwards). Pin it here and enable strict checking
    # like the kiosks. Configure SSH to use the build key for nix-copy-closure.
    #
    # Keyed on the literal address (not "callisto"): nix.buildMachines dials
    # callisto by IP (see hostName above), and ssh_config Host patterns match
    # the literal argument passed to ssh, not a resolved/aliased name.
    programs.ssh.extraConfig = ''
      Host ${config.jupiter.fleet.addresses.callisto}
        IdentityFile ${config.sops.secrets.nix_build_ssh_key.path}
        IdentitiesOnly yes
    '';

    # Kiosk + callisto host keys, pinned declaratively instead of relying on an
    # imperative /etc/ssh/ssh_known_hosts edit (which doesn't survive a
    # rebuild — that file is a plain Nix store symlink). Captured via
    # ssh-keyscan 2026-07-24, cross-checked against the admin's own
    # known_hosts. adrastea omitted: not installed yet (hostname
    # unresolvable), add its key here once it's provisioned.
    programs.ssh.knownHosts = {
      callisto = {
        hostNames = [ config.jupiter.fleet.addresses.callisto ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINKUMgEPCzZRq74JtvkMmfmT6gOmZWGGq8G9lNqqKsU";
      };
    }
    // lib.optionalAttrs cfg.includeKiosks {
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
