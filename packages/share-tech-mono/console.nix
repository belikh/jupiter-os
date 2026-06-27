{ lib, stdenvNoCC, unzip, fontforge, bdf2psf }:

stdenvNoCC.mkDerivation rec {
  pname = "share-tech-mono-console";
  version = "1.0";

  src = ./Share_Tech_Mono.zip;

  nativeBuildInputs = [ unzip fontforge bdf2psf ];

  unpackPhase = ''
    unzip $src
  '';

  buildPhase = ''
    # Convert TTF to BDF at 24 pixels (good size for TTY)
    fontforge -lang=ff -c 'Open("ShareTechMono-Regular.ttf"); Generate("ShareTechMono.bdf")'

    # Convert BDF to PSF using bdf2psf translation tables
    bdf2psf ShareTechMono.bdf \
      ${bdf2psf}/share/bdf2psf/standard.equivalents \
      ${bdf2psf}/share/bdf2psf/ascii.set+${bdf2psf}/share/bdf2psf/useful.set+${bdf2psf}/share/bdf2psf/linux.set \
      256 ShareTechMono.psf

    gzip ShareTechMono.psf
  '';

  installPhase = ''
    mkdir -p $out/share/consolefonts
    cp ShareTechMono.psf.gz $out/share/consolefonts/
  '';

  meta = with lib; {
    description = "Share Tech Mono console font";
    license = licenses.ofl;
    platforms = platforms.linux;
  };
}
