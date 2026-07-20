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
#
# Why the launcher + kbd_mode dance (the lesson of two reverted attempts):
#
# cmatrix's `-l` mode draws codepoints 166–217 (cmatrix.c:443-444) via
# ncurses addch() under the A_ALTCHARSET attribute (cmatrix.c:672, 731).
# This is the pre-Unicode VT100 alt-charset idiom: ncurses emits SO/SI
# shift codes and the byte value (e.g. 0xA6) is meant to be interpreted
# by the kernel VT as a DIRECT GLYPH INDEX into the loaded console font
# (matrix.psf has the katakana at exactly those indices). For that to
# work, three things all have to be true:
#
#   1. cmatrix must be compiled with HAVE_SETFONT or HAVE_CONSOLECHARS
#      defined, otherwise `-l` calls c_die() at cmatrix.c:406 before
#      ever reaching the draw loop. nixpkgs builds cmatrix in a sandbox
#      without kbd on PATH, so configure.ac's AC_PATH_PROG finds neither
#      tool, defines neither macro, and emits only AC_MSG_WARN. The fix
#      is to rebuild cmatrix with kbd as a native build input.
#
#   2. cmatrix's internal `system("setfont matrix")` (cmatrix.c:400)
#      must find a font literally named "matrix" on setfont's search
#      path. nixpkgs' cmatrix package doesn't install matrix.psf.gz
#      (it's in the source tarball but Makefile.am's install-data-local
#      only fires if /usr/share/consolefonts already exists, which it
#      doesn't in the build sandbox). The setfontShim below intercepts
#      the bare name "matrix" and redirects it to our extracted font.
#
#   3. THE ONE BOTH PRIOR ATTEMPTS MISSED — the kernel VT must be in
#      K_XLATE (ASCII) mode, NOT K_UNICODE. Modern Linux boots with
#      vt.default_utf8=1 (since 2007) and systemd re-asserts K_UNICODE
#      on every VT. In UTF-8 mode the kernel IGNORES the G0/G1 + SO/SI
#      alt-charset mechanism entirely and decodes all input as UTF-8
#      sequences. cmatrix's single bytes 0xA6–0xD9 are stray UTF-8
#      continuation bytes — they render as U+FFFD replacement glyphs,
#      i.e. exactly the "garbage" we saw on callisto. The launcher
#      toggles the VT to K_XLATE for cmatrix's lifetime; ExecStopPost
#      restores K_UNICODE on the way out (even if cmatrix is SIGKILLed).

let
  cfg = config.jupiter.consoleScreensaver;

  # (1) above — rebuild cmatrix with kbd visible at configure time so
  # HAVE_SETFONT gets defined. Without this, `-l` hits the c_die branch
  # at cmatrix.c:406 ("Unable to use both setfont and consolechars")
  # before the draw loop ever runs.
  cmatrixWithFontSupport = cfg.package.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.kbd ];
  });

  # (2) above — ship the matrix.psf.gz that cmatrix's source ships next
  # to the binary but nixpkgs' package never installs.
  matrixFont = pkgs.runCommand "cmatrix-matrix-font" { } ''
    install -Dm444 ${cfg.package.src}/matrix.psf.gz $out/matrix.psf.gz
  '';

  # PATH-shadowing setfont wrapper: cmatrix always calls exactly
  # `system("setfont matrix")` (bare name, no path) on startup and
  # `system("setfont")` on exit. Redirect the bare "matrix" arg to our
  # extracted font; pass everything else through to the real setfont
  # unmodified (so cmatrix's exit-time `setfont` still does whatever it
  # would have done without us).
  setfontShim = pkgs.writeShellScriptBin "setfont" ''
    if [ "$1" = "matrix" ]; then
      exec ${pkgs.kbd}/bin/setfont ${matrixFont}/matrix.psf.gz
    fi
    exec ${pkgs.kbd}/bin/setfont "$@"
  '';

  # (3) above — the launcher. Toggles the VT out of UTF-8 mode, then
  # execs cmatrix. ExecStopPost in the service unit below toggles it
  # back. Using exec (not a child process) means systemd's service
  # lifecycle tracks cmatrix directly; ExecStopPost still fires whether
  # cmatrix exits cleanly, is SIGTERM'd, or is SIGKILL'd.
  cmatrixLauncher = pkgs.writeShellScriptBin "cmatrix-console-launcher" ''
    ${pkgs.kbd}/bin/kbd_mode -a -C /dev/tty${toString cfg.tty}
    exec ${lib.getExe cmatrixWithFontSupport} ${lib.escapeShellArgs cfg.extraFlags}
  '';

  ttyDev = "/dev/tty${toString cfg.tty}";
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

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "-b"
        "-l"
      ];
      defaultText = lib.literalExpression ''[ "-b" "-l" ]'';
      description = ''
        Extra command-line flags passed to cmatrix. Defaults to `-b -l`
        (bold + Linux console-font mode). `-l` requires the kbd_mode
        toggle and the matrix.psf font, both of which this module sets
        up; removing `-l` falls back to plain ASCII rain.
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

      # setfontShim first on PATH so it shadows the real setfont for
      # cmatrix's internal `system("setfont matrix")` call. kbd provides
      # kbd_mode (used by the launcher) and the real setfont the shim
      # delegates to.
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
        TTYPath = ttyDev;
        TTYReset = true;
        # Do NOT vhangup the tty on start — that SIGHUPs the very process we
        # just launched. We've cleared getty above instead.
        TTYVHangup = false;
        # Lowest CPU priority: this is pure eye-candy, so it must always yield
        # to real work — especially on a host (e.g. the NAS) where the same
        # cores serve ZFS/Samba/Attic. nice 19 = schedulable only when nothing
        # else wants the CPU.
        Nice = 19;
        # The launcher toggles the VT to K_XLATE (non-UTF-8) mode before
        # exec'ing cmatrix — see the module-level comment for why this is
        # required for `-l` to render anything other than garbage on a
        # modern kernel.
        ExecStart = "${lib.getExe cmatrixLauncher}";
        # Restore K_UNICODE on the VT after cmatrix exits — fires on clean
        # exit, SIGTERM, and SIGKILL alike. Decoupling the restore from the
        # launcher means we're safe even if the launcher is killed before
        # it can run any cleanup of its own.
        ExecStopPost = "${pkgs.kbd}/bin/kbd_mode -u -C ${ttyDev}";
        Restart = "always";
        RestartSec = "3";
      };
    };
  };
}
