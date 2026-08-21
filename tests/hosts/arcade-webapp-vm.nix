{
  config,
  lib,
  pkgs,
  ...
}:

# arcade-webapp-vm — the minimal test host for the jupiterOS Arcade
# pipeline webapp (gauntlet plan §4 Phase 1: `make test-arcade-webapp`).
#
# It runs the REAL module (modules/services/arcade-webapp.nix) against a
# deterministic fixture tree built at eval time from the same sources the
# Phase 0 corpus uses: fixturegen's dummy ROMs, the committed Logiqx DATs
# (pkgs/arcade-webapp/testdata/dats), the REAL fleet catalogue TSV (the
# module's own store copy — 61 systems, so the scan also proves empty
# systems collapse out of the card wall), plus synthetic Skyscraper
# db.xml caches to exercise the coverage heuristic. The state dir is VM
# tmpfs; secret-path options point at /dev/null (Phase 1 only checks
# presence — no secret values exist in this host by construction).
#
# The in-VM assertions live in jupiter-arcade-webapp-smoke.service: wait
# for /healthz, wait for the startup scan to land, assert the dashboard
# renders the expected per-system counts/coverage, exercise /rescan and
# the partials, then print the PASS marker and power off. The driver
# (scripts/test-arcade-webapp.sh) greps the serial log for the marker.
#
# Deliberately NOT importing modules/common.nix — this is a test fixture,
# not a fleet host: no sops, no impermanence, no branding, just the
# module under test plus enough of a system to boot and curl.
let
  # fixturegen from the same in-tree source the webapp builds from
  # (default.nix's subPackages parameter exists for exactly this).
  fixturegen = pkgs.callPackage ../../pkgs/arcade-webapp {
    subPackages = [ "cmd/fixturegen" ];
  };

  dats = ../../pkgs/arcade-webapp/testdata/dats;

  # The whole fixture tree as one store path — read-only by construction,
  # exactly like the pool trees on europa.
  fixture = pkgs.stdenv.mkDerivation {
    name = "arcade-webapp-vm-fixture";
    nativeBuildInputs = [ fixturegen ];
    buildCommand = ''
      set -euo pipefail
      mkdir -p \
        $out/games/cartridge \
        $out/games/optical \
        $out/games/modern \
        $out/metadata/no-intro-dats \
        $out/metadata/skyscraper-cache/nes \
        $out/metadata/skyscraper-cache/snes \
        $out/cache/incoming

      # Deterministic dummy ROM tree: nes (5), snes (4), gb (4) — the
      # committed DATs' hashes match these bytes (internal/fixture).
      fixturegen --roms $out/games/cartridge

      cp ${dats}/nes.dat ${dats}/snes.dat ${dats}/gb.dat \
        $out/metadata/no-intro-dats/

      # Synthetic Skyscraper resource caches (presence-level coverage):
      # nes 3 of 5 games covered (60%), snes 4 of 4 (100%), gb none
      # (no db.xml -> 0%). Shape per Skyscraper's CACHE.md: a flat list of
      # <resource id=...> entries; distinct ids = covered games.
      cat > $out/metadata/skyscraper-cache/nes/db.xml <<'XML'
      <?xml version="1.0" encoding="UTF-8"?>
      <db>
        <resource id="f1000000000000000000000000000000000000000" type="description" source="ScreenScraper" timestamp="1">Starlit Vault</resource>
        <resource id="f1000000000000000000000000000000000000000" type="cover" source="ScreenScraper" timestamp="1">covers/starlit.png</resource>
        <resource id="f2000000000000000000000000000000000000000" type="description" source="ScreenScraper" timestamp="1">Mecha Garden</resource>
        <resource id="f3000000000000000000000000000000000000000" type="description" source="thegamesdb" timestamp="1">Pogo Postman</resource>
      </db>
      XML
      cat > $out/metadata/skyscraper-cache/snes/db.xml <<'XML'
      <?xml version="1.0" encoding="UTF-8"?>
      <db>
        <resource id="a100000000000000000000000000000000000000" type="description" source="ScreenScraper" timestamp="1">Astral Almari</resource>
        <resource id="a200000000000000000000000000000000000000" type="description" source="ScreenScraper" timestamp="1">Bakery Bandits</resource>
        <resource id="a300000000000000000000000000000000000000" type="description" source="ScreenScraper" timestamp="1">Turbo Tadpole</resource>
        <resource id="a400000000000000000000000000000000000000" type="description" source="ScreenScraper" timestamp="1">Vault of Vertigo</resource>
      </db>
      XML
    '';
  };

  port = 8094;

  # In-VM assertions. Failures print FAIL lines (the driver shows the log
  # tail); success prints the marker and powers the VM off. All output is
  # forced onto /dev/ttyS0 — NOT /dev/console: the QEMU runner appends its
  # own "console=ttyS0 … console=tty0", so /dev/console lands on the
  # headless VGA device and journal/console plumbing never reaches the
  # serial line the driver greps.
  smoke = pkgs.writeShellScript "arcade-webapp-vm-smoke" ''
    exec > /dev/ttyS0 2>&1
    set -uo pipefail
    fail() {
      echo "ARCADE-WEBAPP-VM: FAIL: $*" >&2
      systemctl poweroff || true
      exit 1
    }
    pass() {
      echo "ARCADE-WEBAPP-VM: PASS"
      systemctl poweroff || true
    }

    echo "smoke: waiting for the webapp on :${toString port}"
    up=0
    for _ in $(seq 1 60); do
      if curl -sf "http://127.0.0.1:${toString port}/healthz" >/dev/null 2>&1; then up=1; break; fi
      sleep 1
    done
    [ "$up" = 1 ] || fail "service never answered /healthz"
    echo "smoke: /healthz ok"

    # Startup scan lands in the DB; the card wall then carries the fixture
    # counts. data-system/data-games/data-coverage come straight from the
    # scan (nes 5 roms 60% covered, snes 4/100%, gb 4/0).
    echo "smoke: waiting for the startup scan to render fixture cards"
    page=""
    for _ in $(seq 1 60); do
      page=$(curl -sf "http://127.0.0.1:${toString port}/" || true)
      if grep -q 'data-system="nes" data-games="5" data-coverage="60"' <<<"$page"; then break; fi
      sleep 1
    done
    grep -q 'data-system="nes" data-games="5" data-coverage="60"' <<<"$page" \
      || fail "dashboard never rendered nes 5/60%"
    grep -q 'data-system="snes" data-games="4" data-coverage="100"' <<<"$page" \
      || fail "snes card missing/wrong (want 4 games, 100%)"
    grep -q 'data-system="gb" data-games="4" data-coverage="0"' <<<"$page" \
      || fail "gb card missing/wrong (want 4 games, 0%)"
    grep -q '2026-08-21' <<<"$page" || fail "fixture DAT date not rendered"
    grep -q '58 catalogue systems empty' <<<"$page" \
      || fail "empty-systems footer missing (61 catalogue rows - 3 active = 58)"
    echo "smoke: dashboard renders fixture counts + DAT currency + coverage"

    # Partials are fragment-shaped (htmx targets).
    frag=$(curl -sf "http://127.0.0.1:${toString port}/partials/systems" || fail "GET /partials/systems")
    grep -q '<html' <<<"$frag" && fail "systems partial rendered the full layout"
    frag2=$(curl -sf "http://127.0.0.1:${toString port}/partials/status" || fail "GET /partials/status")
    grep -q 'id="status-panel"' <<<"$frag2" || fail "status partial missing its panel id"

    # Rescan endpoint: 202 + the status fragment, then a second scan run
    # must appear in the runs table.
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${toString port}/rescan")
    [ "$code" = 202 ] || [ "$code" = 200 ] || fail "POST /rescan -> $code, want 202/200"
    echo "smoke: rescan accepted (HTTP $code)"
    for _ in $(seq 1 60); do
      status=$(curl -sf "http://127.0.0.1:${toString port}/partials/status" || true)
      n=$(grep -o '<td>scan</td>' <<<"$status" | wc -l)
      [ "$n" -ge 2 ] && break
      sleep 1
    done
    [ "''${n:-0}" -ge 2 ] || fail "rescan did not record a second run"
    echo "smoke: rescan recorded in runs table"

    pass
  '';
in
{
  imports = [ ../../modules/services/arcade-webapp.nix ];

  networking.hostName = "arcade-webapp-vm";

  system.stateVersion = "26.05";

  # Bootability assertions only (`nix flake check` evaluates every host's
  # toplevel, which demands a root fileSystem + a bootloader choice). The
  # VM itself boots direct-kernel via the QEMU runner and never touches
  # either — grub "nodev" is the classic inert placeholder for that.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  boot.loader.grub.devices = [ "nodev" ];

  jupiter.services.arcadeWebapp = {
    enable = true;
    inherit port;
    cartridgeRoot = "${fixture}/games/cartridge";
    opticalRoot = "${fixture}/games/optical";
    modernRoot = "${fixture}/games/modern";
    datDir = "${fixture}/metadata/no-intro-dats";
    skyscraperCacheDir = "${fixture}/metadata/skyscraper-cache";
    incomingDir = "${fixture}/cache/incoming";
    # VM state dir — deliberately NOT /tmp: the service hardening includes
    # PrivateTmp, so a /tmp state dir would exist only in the unit's
    # private tmpfs namespace and fail ReadWritePaths at step NAMESPACE.
    # /var/lib is unaffected; tmpfiles (module) creates it before start.
    # ADR-0002 D3's on-pool rule is a europa concern; the schema + WAL
    # behaviour are what's under test here.
    stateDir = "/var/lib/arcade-webapp-state";
    # No legacy inventory in the fixture — absence is tolerated by design.
    inventoryFile = null;
    # Secret-path options exist but hold no secrets in this host: /dev/null
    # is present-and-empty (the app logs presence only in Phase 1).
    aria2SecretFile = "/dev/null";
    screenscraperCredsFile = "/dev/null";
    tgdbApikeyFile = "/dev/null";
  };

  # In-VM assertions (see smoke above). Runs after the webapp; prints the
  # PASS/FAIL marker on the serial console the driver greps (stdout →
  # /dev/console, NOT the journal — the headless VM never surfaces journal
  # output), then powers the VM off either way.
  systemd.services.jupiter-arcade-webapp-smoke = {
    description = "arcade-webapp VM smoke assertions";
    after = [
      "network.target"
      "jupiter-arcade-webapp.service"
    ];
    wants = [ "jupiter-arcade-webapp.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${smoke}";
      StandardOutput = "console";
      StandardError = "console";
    };
    path = with pkgs; [
      curl
      gnugrep
      gnused
      systemd
      coreutils
    ];
  };

  # Minimal VM shape for `nixos-rebuild build-vm` / the driver script: a
  # serial getty for debugging (the QEMU runner already wires
  # console=ttyS0) and DNS via QEMU's user-mode network.
  virtualisation.vmVariant = {
    networking.nameservers = [
      "10.0.2.3"
      "1.1.1.1"
    ];
    services.getty.autologinUser = "root";
  };
}
