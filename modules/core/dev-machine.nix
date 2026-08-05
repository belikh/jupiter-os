{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.jupiter.dev = {
    enable = lib.mkEnableOption "local dev machine configuration (trusted substituters, etc.)";

    user = lib.mkOption {
      type = lib.types.str;
      description = "Local username to add as trusted user";
    };

    useJupiterCache = lib.mkEnableOption "use jupiter-os Harmonia cache (cache.jupiter.au)";
  };

  config = lib.mkIf config.jupiter.dev.enable {
    # Add local user as trusted user for nix-daemon
    nix.settings.trusted-users = lib.mkForce [ "root" config.jupiter.dev.user ];

    # Use Harmonia binary cache
    nix.settings.substituters = lib.mkForce [
      "https://cache.jupiter.au"
      "https://cache.nixos.org"
    ];

    nix.settings.trusted-public-keys = lib.mkForce [
      "jupiter-os:jd6naJxSxt9xPtYTaOSQDOoeoHil5OsVy8ltpIBs9dQ="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];

    # Ensure nix-command + flakes available
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Faster evaluation
    nix.package = pkgs.lix;

    # Dev tooling
    environment.systemPackages = with pkgs; [
      nix-output-monitor
      git
      htop
      ripgrep
      fd
      jq
      wget
      curl
    ];
  };
}