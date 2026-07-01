{ config, lib, ... }:

# Per-host CPU microarchitecture tuning for the "rebuild the world" workflow
# (see docs/roadmap.md's "Ephemeral BinaryLane build server" section): the
# disposable build server compiles each host's closure targeting that host's
# own CPU rather than nixpkgs' portable baseline, then pushes the result to
# the attic cache for that host to pull.
#
# CAUTION: this only changes what gets *built*, not what a host is willing to
# *run* — a host will happily boot a closure built with instructions its CPU
# doesn't have and crash with SIGILL the first time one is hit. Only set this
# once a host's real CPU model is confirmed (most of this fleet is still
# pre-hardware — see docs/roadmap.md). Also: the build server's own CPU must
# support whatever `-march` you ask it to target, or any package whose build
# runs target-tuned code during its own checkPhase (not just compiles it)
# will fail loudly on the build server — a wasted build, not a broken host,
# but worth knowing before treating this as unattended-safe.
let
  cfg = config.jupiter.build;
in
{
  options.jupiter.build.microarch = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "skylake";
    description = ''
      GCC `-march`/`-mtune` target (a `nixpkgs.hostPlatform.gcc.arch` value,
      e.g. "skylake", "znver3") matching this host's actual CPU. Leave null
      (the default) to build the ordinary portable baseline every other
      nixpkgs consumer gets — the safe choice for any host whose real
      hardware isn't confirmed yet.
    '';
  };

  config = lib.mkIf (cfg.microarch != null) {
    nixpkgs.hostPlatform = {
      system = "x86_64-linux";
      gcc.arch = cfg.microarch;
      gcc.tune = cfg.microarch;
    };
  };
}
