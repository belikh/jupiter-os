{
  config,
  lib,
  pkgs,
  ...
}:

# A screensaver for the bare Linux virtual console — Matrix-style "cmatrix"
# rain, running continuously on tty1. europa is a headless NAS that normally
# has no monitor attached; this is purely for the moments a display gets
# plugged in (or a crash cart rolled up), so the box looks alive and
# unmistakably cool instead of sitting at a static login prompt.
#
# The service disables getty on the target VT and owns it exclusively
# (TTYVHangup is deliberately OFF — it would SIGHUP the very process we
# start). A login shell remains one keystroke away on any other tty
# (Ctrl+Alt+F2); getty elsewhere is untouched.

let
  cfg = config.jupiter.consoleScreensaver;

  # -l needs `setfont`/`consolechars` support COMPILED IN — cmatrix's
  # configure.ac probes for those programs at build time (AC_PATH_PROG) and
  # picks one of three #ifdef branches in cmatrix.c accordingly; if neither
  # was on PATH inside nixpkgs' (minimal, sandboxed) build environment, the
  # binary is compiled to unconditionally hit the "Unable to use both
  # setfont and consolechars" branch, no matter what's on $PATH at runtime.
  # Fix: rebuild with kbd (which provides setfont) as a build input so
  # configure finds it and defines HAVE_SETFONT.
  #
  # It also needs a console font literally named "matrix" on setfont's own
  # search path — nixpkgs' build doesn't install the font file cmatrix's own
  # upstream source ships right alongside the binary (matrix.psf.gz, next to
  # matrix.fnt). Since cmatrix always calls exactly `system("setfont
  # matrix")` (cmatrix.c), a PATH-shadowing `setfont` wrapper that redirects
  # the bare name "matrix" to our extracted font — and passes everything
  # else straight through to the real setfont — is the minimal fix, no
  # patching of cmatrix or kbd's compiled-in font directories required.
  cmatrixWithFontSupport = cfg.package.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.kbd ];
  });

  matrixFont = pkgs.runCommand "cmatrix-matrix-font" { } ''
    install -Dm444 ${cfg.package.src}/matrix.psf.gz $out/matrix.psf.gz
  '';

  setfontShim = pkgs.writeShellScriptBin "setfont" ''
    if [ "$1" = "matrix" ]; then
      exec ${pkgs.kbd}/bin/setfont ${matrixFont}/matrix.psf.gz
    fi
    exec ${pkgs.kbd}/bin/setfont "$@"
  '';
in
{
  options.jupiter.consoleScreensaver = {
    enable = lib.mkEnableOption "a Matrix-style cmatrix screensaver on the console";

    package = lib.mkPackageOption pkgs "cmatrix" { };

    tty = lib.mkOption {
      type = lib.types.ints.u8;
      default = 1;
      description = ''
        Virtual console (ttyN) to display the screensaver on. Defaults to 1
        so it shows on the primary VT the firmware hands off to.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cmatrixWithFontSupport ];

    # Free the VT from getty so cmatrix owns it exclusively. Otherwise getty
    # and cmatrix both hold /dev/ttyN open, cmatrix's stdin reads EOF, and it
    # exits immediately. A login shell stays available on any other tty.
    systemd.services."getty@tty${toString cfg.tty}".enable = lib.mkForce false;

    systemd.services.console-screensaver = {
      description = "cmatrix console screensaver on tty${toString cfg.tty}";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-logind.service" ];

      # ncurses needs to know it's on the Linux VT, not a generic terminal.
      environment.TERM = "linux";

      # setfontShim first so it shadows the real setfont on PATH for
      # cmatrix's internal `system("setfont matrix")` call.
      path = [
        setfontShim
        pkgs.kbd
      ];

      serviceConfig = {
        # idle: don't start until other jobs have settled, so boot messages
        # don't interleave with the screensaver.
        Type = "idle";
        StandardInput = "tty";
        StandardOutput = "tty";
        TTYPath = "/dev/tty${toString cfg.tty}";
        TTYReset = true;
        # Do NOT vhangup the tty on start — that SIGHUPs the very process we
        # just launched. We've cleared getty above instead.
        TTYVHangup = false;
        # Lowest CPU priority: this is pure eye-candy, so it must always yield
        # to real work — especially on a host (e.g. the NAS) where the same
        # cores serve ZFS/Samba/Attic. nice 19 = schedulable only when nothing
        # else wants the CPU.
        Nice = 19;
        # -b  bold (brighter glyphs against the black VT background).
        # -l  Linux console font mode — draws with the "matrix" console font
        #     (see setfontShim above for why this actually works on NixOS).
        # Run continuously; to log in, switch to another tty (Ctrl+Alt+F2).
        ExecStart = "${lib.getExe cmatrixWithFontSupport} -b -l";
        Restart = "always";
        RestartSec = "3";
      };
    };
  };
}
