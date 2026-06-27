{ lib, stdenvNoCC, unzip }:

stdenvNoCC.mkDerivation rec {
  pname = "share-tech-mono";
  version = "1.0";

  src = ./Share_Tech_Mono.zip;

  nativeBuildInputs = [ unzip ];

  unpackPhase = ''
    unzip $src
  '';

  installPhase = ''
    mkdir -p $out/share/fonts/truetype
    cp *.ttf $out/share/fonts/truetype/
  '';

  meta = with lib; {
    description = "Share Tech Mono font";
    homepage = "https://fonts.google.com/specimen/Share+Tech+Mono";
    license = licenses.ofl;
    platforms = platforms.all;
  };
}
