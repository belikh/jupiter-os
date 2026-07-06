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
    version = "2.0.0";

    src = pkgs.fetchFromGitHub {
      owner = "affaan-m";
      repo = "ecc";
      rev = "4130457d674d2180c5af2c5f634f3cae4cbc6c4f";
      sha256 = "17sdpi95in7956imnkvw4682c44l4sa7fx9pq72wgb7v9d6k1whk";
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
