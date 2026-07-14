{
  config,
  lib,
  ...
}:

let
  cfg = config.jupiter.core.branding;
in
{
  options.jupiter.core.branding = {
    enable = lib.mkEnableOption "Jupiter OS distribution branding (os-release name/id + version tag)";
  };

  config = lib.mkIf cfg.enable {
    # /etc/os-release: NAME="Jupiter OS", ID=jupiter,
    # PRETTY_NAME="Jupiter OS <nixpkgs-release> (<codename>, jupiter)".
    system.nixos.distroName = "Jupiter OS";
    system.nixos.distroId = "jupiter";

    # Tag rather than override system.nixos.version: the nixpkgs release
    # (e.g. 26.11.20260616.567a49d) and codename (e.g. Zokor) stay visible in
    # `nixos-version` and os-release for cache/support decisions, while the
    # "jupiter" tag marks the closure as ours. Buildability-safe: this only
    # reassembles the toplevel (os-release + label); it does not touch the
    # btver2-tuned package set, so a tuned closure substitutes unchanged.
    system.nixos.tags = [ "jupiter" ];
  };
}
