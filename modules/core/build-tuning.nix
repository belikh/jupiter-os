{
  config,
  lib,
  ...
}:

# Per-host CPU tuning via GCC `-march`. A host that sets `microarch` has its
# closure compiled for that instruction-set level rather than nixpkgs'
# portable baseline; CI builds it and pushes the result to Harmonia for every
# host to substitute. Fleet-wide the value must be the LOWEST common level
# every fleet CPU can execute AND every CI builder can run-check — since
# 2026-08-22 that is "x86-64-v3" (europa's Excavator CPUID-proves v3-complete;
# callisto/kiosks are Skylake-class; GH runners are all newer). One shared
# level means one shared closure family and honest gccarch tags everywhere.
#
# Prefer psABI levels ("x86-64-v2"/"v3"/"v4") over vendor names ("bdver4",
# "skylake"): vendor -march values enable extensions OUTSIDE any level
# (bdver4 implies XOP/FMA4/TBM/LWP/SSE4A and RDRND per gcc bug 116854), which
# SIGILL on whichever builder or host lacks them — zlib/gmp died exactly this
# way in CI run 32540930884. Level baselines carry no such surprises.
#
# CAUTION: this only changes what gets *built*, not what a host is willing to
# *run* — a host will happily boot a closure built with instructions its CPU
# doesn't have and crash with SIGILL the first time one is hit. Only set this
# once every executor's real capability is confirmed. Also: any remote
# builder must advertise the matching `gccarch-<level>` system-feature, or
# tagged derivations refuse to dispatch there at all ("missing system
# features").
#
# NOTE: GCC defines `-mtune=` ONLY for vendor targets — `-mtune=x86-64-v3`
# is an error ("bad value"), because the levels exist purely as -march ISA
# floors. So tune is a separate option below and defaults to null (generic
# scheduling). Setting a vendor tune re-schedules codegen but never adds
# instructions; it DOES fork your host out of the shared closure family, so
# leave it unset unless there is a measured reason.
let
  cfg = config.jupiter.build;
in
{
  options.jupiter.build.microarch = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "x86-64-v3";
    description = ''
      GCC `-march` target (a `nixpkgs.hostPlatform.gcc.arch` value). Prefer
      the psABI microarchitecture levels "x86-64-v2"/"x86-64-v3"/"x86-64-v4"
      over vendor names like "znver3": levels define exact, checkable ISA
      floors, while vendor targets silently enable extra extensions (see the
      header comment). Must be executable by EVERY fleet CPU and every CI
      builder — set it to the lowest common level, not this host's ceiling.

      Leave null (the default) to build the ordinary portable baseline every
      other nixpkgs consumer gets — the safe choice for any host whose real
      hardware isn't confirmed yet.

      Setting this invalidates cache.nixos.org for the host's ENTIRE closure
      (every derivation is tagged requiredSystemFeatures = ["gccarch-<arch>"]),
      so a private cache (Harmonia) must serve the result. CI declares the
      matching system-feature so it can build these tagged derivations.
    '';
  };

  options.jupiter.build.tune = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "znver1";
    description = ''
      Optional separate GCC `-mtune` target. Defaults to null (generic
      scheduling): the x86-64-psABI levels cannot be used as -mtune, and a
      non-null tune forks this host out of the shared tuned-closure family
      (different hashes from hosts leaving it unset). Never affects which
      instructions are emitted — only scheduling heuristics.
    '';
  };

  config = lib.mkIf (cfg.microarch != null) {
    nixpkgs.hostPlatform = {
      system = "x86_64-linux";
      gcc.arch = cfg.microarch;
    }
    // lib.optionalAttrs (cfg.tune != null) {
      gcc.tune = cfg.tune;
    };

    # Declare this host's own nix-daemon capable of building (not just
    # substituting) its own gccarch-tagged derivations. Without this, a host
    # whose tuned closure has any gap in Harmonia (missing OR
    # corrupted — observed 2026-07-18 on europa) hits a hard "missing system
    # features" error the moment it needs to build/--fallback on its own,
    # even though the host's CPU is BY DEFINITION capable of the target ISA
    # floor and can always correctly build+run it. This is the safe case the
    # module-level CAUTION above doesn't apply to — that caution is about a
    # remote builder (e.g. a CI runner) possibly running on different,
    # unconfirmed hardware; a correctly-tuned host building for itself has no
    # such gap.
    nix.settings.system-features = lib.mkAfter [ "gccarch-${cfg.microarch}" ];
  };
}
