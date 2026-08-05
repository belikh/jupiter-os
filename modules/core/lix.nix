{
  config,
  lib,
  ...
}:

let
  cfg = config.jupiter.core.lix;
in
{
  options.jupiter.core.lix = {
    enable = lib.mkEnableOption "use Lix instead of standard Nix (faster flake evaluation, some compatibility differences)";
  };

  config = lib.mkIf cfg.enable {
    nix.package = lib.mkForce pkgs.lix;
  };
}