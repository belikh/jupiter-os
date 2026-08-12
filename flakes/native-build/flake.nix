{
  description = ''
    Escape hatch for packages that fail on GitHub Actions' Azure runners not
    because of checkPhase (flake.nix's fleet-wide doCheck=false already
    covers that — see commit efd07fb) but because their OWN buildPhase
    compiles a gccarch-tuned binary and immediately *executes* it as an
    unavoidable, non-optional step (perl's miniperl bootstrap, autotools
    configure probes that run a test binary, cargo build.rs, ...). No Nix
    setting disables that — the only fix is building on hardware that
    actually has the target instructions.

    Confirmed via nom-31648410843-europa.jsonl (and three other post-fix
    runs, same signature every time):

      LD_LIBRARY_PATH=/build/perl-5.42.0 ./miniperl ...
      Illegal instruction (core dumped)
      Failed to build miniperl. Please run make minitest; exit 1

    perl-5.42.0 is currently the only offender (zlib's was checkPhase-only,
    already fixed by doCheck=false).

    Deliberately references jupiter-os's OWN nixosConfigurations.<host>.pkgs
    (via a relative path input) rather than re-importing nixpkgs by hand —
    that guarantees the exact same derivation hash the fleet's real tuned
    closures request, so building it here and letting Harmonia serve it
    actually lets CI substitute instead of rebuild. A hand-rolled
    `import nixpkgs { ... }` with matching-looking settings would NOT be
    guaranteed to hash-match and would defeat the whole point.

    Usage (run ON the host with matching real hardware -- building bdver4
    packages on anything else reproduces the exact failure this exists to
    avoid):

      ssh root@europa   -- nix build github:belikh/jupiter-os?dir=flakes/native-build#perl-bdver4
      ssh root@callisto -- nix build github:belikh/jupiter-os?dir=flakes/native-build#perl-skylake

    Both hosts already run Harmonia-fed/serving substituters ahead of
    cache.nixos.org (europa hosts Harmonia directly; callisto is on the
    tailnet), so once built, europa's Harmonia can serve perl-skylake too --
    callisto doesn't need to keep it locally, just needs to have built it
    once with the matching hardware. If a future package hits the same
    build-phase-self-execution failure, add its attribute name to `names`
    below.
  '';

  inputs.jupiter-os.url = "path:../..";

  outputs =
    { self, jupiter-os }:
    let
      # Packages confirmed (via the CI logs above) to execute their own
      # just-built binary as a normal, non-optional part of buildPhase --
      # not a checkPhase/doCheck matter at all.
      names = [ "perl" ];

      mkSet =
        suffix: pkgs:
        builtins.listToAttrs (
          map (n: {
            name = "${n}-${suffix}";
            value = pkgs.${n};
          }) names
        );
    in
    {
      packages.x86_64-linux =
        (mkSet "bdver4" jupiter-os.nixosConfigurations.europa.pkgs)
        // (mkSet "skylake" jupiter-os.nixosConfigurations.callisto.pkgs);
    };
}
