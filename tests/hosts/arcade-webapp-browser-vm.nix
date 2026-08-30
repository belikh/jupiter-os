{
  config,
  lib,
  pkgs,
  ...
}:

# arcade-webapp-browser-vm — the L3 browser lane host (arcade remediation
# plan §6.E / W3). It is the L2 VM harness (tests/hosts/arcade-webapp-vm.nix
# — the REAL module, REAL igir/aria2, deterministic fixture corpus) plus
# chromium-in-VM Playwright: after the in-VM smoke completes, a
# chromium-driven browser exercises the dashboard as a REAL browser —
# htmx's native HX-Request header, real fragment swaps, real poll timers.
# This is the only lane that could ever have seen the lifetime 403 (every
# browser-originated mutation silently rejected because the server
# demanded a header htmx never sends); the Go unit tests and the L2 smoke
# replay the server's own assumption about the client instead.
#
# Playwright comes from the pinned nixpkgs' in-tree packaging
# (pkgs/development/web/playwright + development/python-modules/playwright
# at the locked rev): python3Packages.playwright with the patched driver
# location, and the browsers resolved through PLAYWRIGHT_BROWSERS_PATH
# from playwright-driver's browsers linkFarm — exactly the wiring of
# nixpkgs' own nixos/tests/playwright-python.nix at this pin, with the
# browsers narrowed to the chromium channel (no firefox/webkit downloads
# in the VM closure). No CDN fetch ever happens.
#
# The browser service writes /run/arcade-browser-verdict (PASS/FAIL) and
# prints ARCADE-WEBAPP-BROWSER markers on the serial console; the
# runNixOSTest driver in flake.nix asserts BOTH verdicts (smoke + browser)
# before teardown.
#
# The service runs AFTER jupiter-arcade-webapp-smoke: the smoke leaves a
# known end-state (everything unhidden, corpus verified), and the browser
# assertions are written against that state. Sequencing also means the
# browser lane can never mask a smoke failure or vice versa — the driver
# reports whichever verdict failed by name.
let
  # Python with ONLY playwright added — the lane's runtime surface.
  browserPython = pkgs.python3.withPackages (ps: [ ps.playwright ]);

  # The Playwright script is a reviewed repo file, not an inline blob:
  # tests/browser/arcade-webapp-browser.py. Referenced as a flake-tracked
  # store path so the check is bit-reproducible from the tree.
  browserScript = ../../tests/browser/arcade-webapp-browser.py;

  verdictPath = "/run/arcade-browser-verdict";

  # Runs unredirected: the unit's journal+console outputs put the lane's
  # markers BOTH on the serial console (console=ttyS0) and in the journal
  # the runNixOSTest driver dumps on failure — the run-1 lesson: a
  # ttyS0-only redirect left journalctl empty and hid the FAIL reasons
  # from the driver's failure path. A verdict file that ALWAYS exists
  # after the unit ran: a chromium that dies before Python writes its
  # verdict must still leave FAIL behind — otherwise the driver burns
  # its whole timeout waiting for a file a crashed process never wrote
  # (the ADV-P1-04 lesson, one costume on).
  browserRunner = pkgs.writeShellScript "arcade-webapp-browser-run" ''
    set -uo pipefail
    rm -f ${verdictPath}
    ${browserPython}/bin/python ${browserScript}
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "ARCADE-WEBAPP-BROWSER: FAIL: browser process exited rc=$rc"
      [ -f ${verdictPath} ] || echo FAIL > ${verdictPath}
      exit 1
    fi
    [ "$(cat ${verdictPath})" = "PASS" ] || exit 1
  '';
in
{
  imports = [ ./arcade-webapp-vm.nix ];

  # NOTE: no networking.hostName override — the runNixOSTest framework's
  # own default ("machine", lower priority) is overridden by the base
  # file's "arcade-webapp-vm", exactly as the L2 node behaves; the check
  # name (arcade-webapp-browser-vm) is what identifies this lane.

  system.stateVersion = "26.05";

  systemd.services.jupiter-arcade-webapp-browser = {
    description = "arcade-webapp L3 browser lane (chromium-in-VM Playwright)";
    # Strictly after the smoke: known end-state, and neither lane can
    # race the other's assertions. The smoke is a oneshot without
    # RemainAfterExit, so After+Wants is what pins us to its completion.
    after = [
      "network.target"
      "jupiter-arcade-webapp-smoke.service"
    ];
    wants = [ "jupiter-arcade-webapp-smoke.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      # In-tree playwright browser resolution (see the header note) —
      # chromium channel only; the linkFarm layout matches the driver's
      # internal browsers.json revision at this pin.
      PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers-chromium}";
      ARCADE_BASE_URL = "http://127.0.0.1:${toString config.jupiter.services.arcadeWebapp.port}";
      ARCADE_BROWSER_VERDICT = verdictPath;
      # chromium insists on a writable HOME even headless.
      HOME = "/tmp";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${browserRunner}";
      # journal AND console: the driver's failure path dumps the journal
      # (nixos-test-driver machine.succeed journalctl), while the console
      # leg reaches the serial line the -L build log streams. Both carry
      # the lane's PASS/FAIL markers.
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      # A wedged chromium must fail loud and bounded, never eat the
      # driver's budget silently.
      TimeoutStartSec = "600";
    };
  };
}
