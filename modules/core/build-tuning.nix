{
  config,
  lib,
  ...
}:

# Per-host CPU microarchitecture tuning for the "rebuild the world" workflow:
# the disposable BinaryLane build server (pallene) compiles each host's
# closure targeting that host's own CPU rather than nixpkgs' portable
# baseline, then pushes the result to the attic cache for that host to pull.
#
# CAUTION: this only changes what gets *built*, not what a host is willing to
# *run* — a host will happily boot a closure built with instructions its CPU
# doesn't have and crash with SIGILL the first time one is hit. Only set this
# once a host's real CPU model is confirmed. Also: the build server's own CPU
# must support whatever `-march` you ask it to target, or any package whose
# build runs target-tuned code during its own checkPhase (not just compiles
# it) will fail loudly on the build server — a wasted build, not a broken
# host, but worth knowing before treating this as unattended-safe.
let
  cfg = config.jupiter.build;
in
{
  options.jupiter.build.microarch = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "btver2";
    description = ''
      GCC `-march`/`-mtune` target (a `nixpkgs.hostPlatform.gcc.arch` value,
      e.g. "btver2", "znver3") matching this host's actual CPU. Leave null
      (the default) to build the ordinary portable baseline every other
      nixpkgs consumer gets — the safe choice for any host whose real
      hardware isn't confirmed yet.

      Setting this invalidates cache.nixos.org for the host's ENTIRE closure
      (every derivation is tagged requiredSystemFeatures = ["gccarch-<arch>"]),
      so a private attic cache must serve the result. The build server
      (modules/services/build-server.nix) declares the matching system-feature
      so it can build these tagged derivations.
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
