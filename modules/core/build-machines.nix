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
# callisto is diskless/netboot (see hosts/callisto/configuration.nix), so its
# SSH host key is regenerated every boot — there's no stable key to pin via
# publicHostKey, so host-key checking is disabled for that one Host entry
# instead. Authenticates as root using a dedicated keypair (not the admin's
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
# hostname follows the host across reboots but an IP wouldn't. The same
# *.localdomain convention the kiosks already use for their ha-agent MQTT
# broker (modules/desktop/tcxwave-kiosk.nix). A static IP per kiosk is the
# future cleanup (one less avahi-dependent hop); mDNS works today.
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
  # gccarch-btver2 (proven manually against europa's closure on 2026-07-20,
  # dispatched alongside callisto via a one-off --builders flag): the kiosks
  # aren't themselves btver2-tuned, this only makes them ELIGIBLE to build
  # btver2-tagged derivations for other hosts (europa) — btver2 is a portable
  # baseline ISA subset, safe to execute/compile on any modern x86_64 CPU
  # including these Skylake units. Caveat: each kiosk only has ~7.6GiB RAM
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
      "gccarch-btver2"
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
  options.jupiter.core.buildMachines = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Delegate eligible builds to callisto + the dashboard kiosks as remote Nix builders.";
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
    ]
    ++ kioskBuilders;

    # callisto's SSH host key regenerates every diskless boot — there's no
    # stable key to pin, so disable host-key checking for it specifically
    # (other build machines, including the kiosks, keep the default strict
    # checking). The kiosks have stable SSH host keys (persistent root disk).
    programs.ssh.extraConfig = ''
      Host callisto
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
    '';
  };
}
