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
    # Plain assignment: nothing else in the tree sets nix.package, so mkForce
    # would only beat a future host-level override for no reason.
    nix.package = pkgs.lix;
  };
}
