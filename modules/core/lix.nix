{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.jupiter.core.lix = {
    enable = lib.mkEnableOption "use Lix instead of standard Nix (faster flake evaluation, some compatibility differences)";
    default = true;
  };

  config = lib.mkIf config.jupiter.core.lix.enable {
    nix.package = lib.mkForce pkgs.lix;
  };
}