{ config, pkgs, lib, ... }:

let
  antigravity-cli = pkgs.stdenv.mkDerivation rec {
    pname = "antigravity-cli";
    version = "1.0.16";

    src = pkgs.fetchurl {
      url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.0.16-4893150192467968/linux-x64/cli_linux_x64.tar.gz";
      sha512 = "2e3362fb360d350285c3a79891772652ea56608121e4e89091abe553e8203c379e30bac86bde109ecc0b3266cb6eb871a68ef28a993aeca7944456f0f720ae31";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];

    dontConfigure = true;
    dontBuild = true;

    unpackPhase = ''
      tar -xzf $src
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp antigravity $out/bin/agy
      chmod +x $out/bin/agy
    '';

    meta = with lib; {
      description = "Google Antigravity CLI";
      homepage = "https://antigravity.google";
      license = licenses.unfree;
      platforms = platforms.linux;
    };
  };
in
{
  environment.systemPackages = [
    antigravity-cli
  ];
}
