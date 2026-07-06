{
  config,
  pkgs,
  lib,
  ...
}:

# Fallout-themed Plymouth boot splash. The theme (vendored under
# ./themes/fallout/) is "Urko Mint Dark" by Urko31 (GPLv3, see LICENSE in that
# dir) with the background + spinner swapped for Fallout artwork and a rotated
# gear animation. It was taken from a theme tarball a user dropped in, not
# fetched from a URL — there's no upstream flake input for it.
#
# One bug was patched when vendoring: the original fallout.script referenced a
# `motif` sprite that was never defined (dead code left over from the Mint
# theme it forked from), which made the per-frame refresh callback throw and
# spam the plymouth log. Those four references were removed — nothing else in
# the theme changed.
#
# Buildability: plymouth ships in nixpkgs and runs on the stock kernel, so this
# doesn't touch the ZFS/kernel/microarch rules. Enabling it only flips on
# nixpkgs' own boot.plymouth and points it at this theme package.

let
  cfg = config.jupiter.boot.falloutSplash;

  # Packages the theme into share/plymouth/themes/fallout/ and rewrites the
  # .plymouth manifest's hardcoded /usr/share/... paths to this derivation's
  # store path. The rewrite matters: nixpkgs' plymouth initrd setup greps for
  # store paths in *.plymouth and relocates them into the initramfs; a
  # /usr/share path would be left dangling in the initrd.
  falloutTheme = pkgs.stdenv.mkDerivation {
    pname = "plymouth-theme-fallout";
    version = "0-unstable-2018-09-08";
    src = ./themes/fallout;

    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/plymouth/themes/fallout/dialog
      cp fallout.plymouth fallout.script background.png spinner.png \
        $out/share/plymouth/themes/fallout/
      cp dialog/*.png $out/share/plymouth/themes/fallout/dialog/

      substituteInPlace $out/share/plymouth/themes/fallout/fallout.plymouth \
        --replace-fail \
          "/usr/share/plymouth/themes/fallout" \
          "$out/share/plymouth/themes/fallout"
      runHook postInstall
    '';
  };
in
{
  options.jupiter.boot.falloutSplash = {
    enable = lib.mkEnableOption "Fallout Plymouth boot splash";
  };

  config = lib.mkIf cfg.enable {
    boot.plymouth = {
      enable = true;
      theme = "fallout";
      themePackages = [ falloutTheme ];
    };
  };
}
