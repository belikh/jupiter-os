{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.jupiter.core.lix = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "use Lix instead of standard Nix (faster flake evaluation, some compatibility differences)";
    };
  };

  config = lib.mkIf config.jupiter.core.lix.enable {
    nix.package = lib.mkForce pkgs.lix;
  };
}
