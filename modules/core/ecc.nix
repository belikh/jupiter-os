{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.core.ecc;

  ecc = pkgs.buildNpmPackage rec {
    pname = "ecc-universal";
    # Rev-suffixed so the version string identifies the pinned commit
    # (upstream tags moved past this rev).
    version = "2.0.0-unstable-2026-07-19";

    src = pkgs.fetchFromGitHub {
      owner = "affaan-m";
      repo = "ecc";
      rev = "4130457d674d2180c5af2c5f634f3cae4cbc6c4f";
      sha256 = "sha256-E/IwTUv7rMfFwTd1d5QmlBAmkCF8T1ujKenYWFK8TZ8=";
    };

    postPatch = ''
      cp ${./ecc-package-lock.json} package-lock.json
    '';

    npmDepsHash = "sha256-f1rKXZ3xKPsQ+dwSYRJizvTKZdmXHmK47PC+p39n2WA=";

    dontNpmBuild = true;
    dontNpmCheck = true;

    meta = with lib; {
      description = "Harness-native agent operating system (Everything Claude Code)";
      homepage = "https://github.com/affaan-m/ecc";
      license = licenses.mit;
      mainProgram = "ecc";
    };
  };
in
{
  options.jupiter.core.ecc = {
    enable = lib.mkEnableOption "Everything Claude Code (ECC)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ ecc ];
  };
}
