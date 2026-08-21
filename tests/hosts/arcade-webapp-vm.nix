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
# Phase 0 corpus uses: fixturegen's dummy ROMs plus zipped cartridge ROMs
# and a cue/bin optical rip (ADV-P1-01's real-tree shapes), the committed
# Logiqx DATs (pkgs/arcade-webapp/testdata/dats), the REAL fleet catalogue
# TSV (the module's own store copy — 61 systems, so the scan also proves
# empty systems collapse out of the card wall), and synthetic Skyscraper
# db.xml caches to exercise the coverage heuristic. P2 adds a REAL aria2
# daemon (local invented secret) + a webseed static server so the
# downloads UI is driven end-to-end: acquire -> queue -> pause -> resume
# -> complete (see the P2 fixture block below).
#
# The in-VM assertions live in jupiter-arcade-webapp-smoke.service: wait
# for /healthz, wait for the startup scan to land, assert the dashboard
# renders the expected per-system counts/coverage, exercise /rescan and
# the partials, then run the P2 download cycle and the journal secret
# grep, print the PASS marker and power off. The driver
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
        $out/metadata/skyscraper-cache/snes

      # Deterministic dummy ROM tree: nes (5), snes (4), gb (4) — the
      # committed DATs' hashes match these bytes (internal/fixture).
      fixturegen --roms $out/games/cartridge

      # ADV-P1-01 shape coverage — real promoted trees the plain corpus
      # lacks: No-Intro .zip archives beside loose cartridge ROMs (igir
      # COPY has no extract), and a cue/bin optical rip whose track files
      # are companions, not games. Zero bytes = deterministic store path.
      head -c 1024 /dev/zero > "$out/games/cartridge/nes/Bonza Box (USA).zip"
      head -c 2048 /dev/zero > "$out/games/cartridge/nes/Zip Zapper (Europe).zip"
      mkdir -p "$out/games/optical/segacd"
      head -c  128 /dev/zero > "$out/games/optical/segacd/Turbo Disc (USA).cue"
      head -c 4096 /dev/zero > "$out/games/optical/segacd/Turbo Disc (USA) (Track 1).bin"
      head -c 2048 /dev/zero > "$out/games/optical/segacd/Turbo Disc (USA) (Track 2).bin"

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

  # ---- P2: download-control fixture --------------------------------
  #
  # A REAL aria2 daemon driven through the webapp's acquire action, with
  # a self-authored torrent (zero copyrighted material — same posture as
  # the fixture corpus) whose payload arrives over HTTP from an in-VM
  # static server: mktorrent's webseed (-w) makes the "torrent" download
  # from darkhttpd. No trackers, no DHT (private flag) — deterministic.
  #
  # The payload is 2 MiB and the daemon throttles at 256 KiB/s, so the
  # download takes ~8s: long enough to observe it active and PAUSE it
  # mid-flight, short enough to keep the VM run under ~90s.
  #
  # NOTE darkhttpd (not python http.server): pause/resume needs HTTP
  # Range support on the webseed — verified locally; python's simple
  # server ignores Range and the resumed download stalls forever.
  #
  # aria2Secret is an INVENTED test value (not from secrets.yaml — house
  # rule: no real secret ever enters this repo). It lives in the store
  # like every other fixture datum; what is under test is the WIRING:
  # the webapp reads the path at runtime and sends it as the RPC token
  # without ever logging it (asserted via the journal grep below).
  aria2Secret = pkgs.writeText "arcade-aria2-rpc-secret" "vm-test-invented-secret-not-from-sops";

  # 2 MiB deterministic payload + its torrent in one derivation so the
  # hashed bytes can never drift. The torrent basename must equal the
  # fleet catalogue TSV's nes row (scripts/cartridge-catalogue.tsv,
  # torrent column) — the smoke fails loudly if it drifts.
  torrentFixture = pkgs.stdenv.mkDerivation {
    name = "arcade-webapp-vm-torrent-fixture";
    nativeBuildInputs = [ pkgs.mktorrent ];
    buildCommand = ''
      set -euo pipefail
      mkdir -p $out/payload $out/minerva-torrents
      head -c 2097152 /dev/zero | tr '\0' 'P' > $out/payload/vm-fixture-payload.bin
      mktorrent -l 18 -p \
        -w 'http://127.0.0.1:8099/vm-fixture-payload.bin' \
        -o "$out/minerva-torrents/Minerva_Myrient - No-Intro - Nintendo - Nintendo Entertainment System (Headerless).torrent" \
        $out/payload/vm-fixture-payload.bin
    '';
  };

  incoming = "/var/lib/arcade-incoming";

  # In-VM assertions. Failures print FAIL lines (the driver shows the log
  # tail); success prints the marker and powers the VM off. All output is
  # forced onto /dev/ttyS0 — NOT /dev/console: the QEMU runner appends its
  # own "console=ttyS0 … console=tty0", so /dev/console lands on the
  # headless VGA device and journal/console plumbing never reaches the
  # serial line the driver greps. The verdict is flushed (sync + settle
  # sleep) BEFORE poweroff so the marker is on the wire before the machine
  # dies — a FAIL that races its own shutdown burns the driver's whole
  # timeout undiagnosed (ADV-P1-04).
  smoke = pkgs.writeShellScript "arcade-webapp-vm-smoke" ''
    exec > /dev/ttyS0 2>&1
    set -uo pipefail
    poweroff_drained() {
      sync
      sleep 1
      systemctl poweroff || true
    }
    fail() {
      echo "ARCADE-WEBAPP-VM: FAIL: $*" >&2
      poweroff_drained
      exit 1
    }
    pass() {
      echo "ARCADE-WEBAPP-VM: PASS"
      poweroff_drained
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
    # scan: nes 5 loose + 2 zips = 7 games at 3/7 = 42% cache coverage,
    # snes 4/100%, gb 4/0%, segacd 1 game (the .cue; its track .bins are
    # companion bytes — 128+4096+2048 = 6272 B = 6.1 KiB on the card).
    echo "smoke: waiting for the startup scan to render fixture cards"
    page=""
    for _ in $(seq 1 60); do
      page=$(curl -sf "http://127.0.0.1:${toString port}/" || true)
      if grep -q 'data-system="nes" data-games="7" data-coverage="42"' <<<"$page"; then break; fi
      sleep 1
    done
    grep -q 'data-system="nes" data-games="7" data-coverage="42"' <<<"$page" \
      || fail "dashboard never rendered nes 7/42% (zips must count as games)"
    grep -q 'data-system="snes" data-games="4" data-coverage="100"' <<<"$page" \
      || fail "snes card missing/wrong (want 4 games, 100%)"
    grep -q 'data-system="gb" data-games="4" data-coverage="0"' <<<"$page" \
      || fail "gb card missing/wrong (want 4 games, 0%)"
    grep -q 'data-system="segacd" data-games="1"' <<<"$page" \
      || fail "segacd card missing/wrong (want 1 game — the cue, not the bins)"
    grep -q '6.1 KiB' <<<"$page" \
      || fail "segacd card size wrong (want 6.1 KiB = cue + track companions)"
    grep -q '2026-08-21' <<<"$page" || fail "fixture DAT date not rendered"
    grep -q '57 catalogue systems empty' <<<"$page" \
      || fail "empty-systems footer missing (61 catalogue rows - 4 active = 57)"
    echo "smoke: dashboard renders fixture counts + DAT currency + coverage"

    # Partials are fragment-shaped (htmx targets).
    frag=$(curl -sf "http://127.0.0.1:${toString port}/partials/systems" || fail "GET /partials/systems")
    grep -q '<html' <<<"$frag" && fail "systems partial rendered the full layout"
    frag2=$(curl -sf "http://127.0.0.1:${toString port}/partials/status" || fail "GET /partials/status")
    grep -q 'id="status-panel"' <<<"$frag2" || fail "status partial missing its panel id"

    # Rescan endpoint: 202 + the status fragment, then a second scan run
    # must appear in the runs table. Mutating endpoints are htmx-only
    # (CSRF posture) — the header is mandatory since P2.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-HX-Request: true' -X POST "http://127.0.0.1:${toString port}/rescan")
    [ "$code" = 202 ] || [ "$code" = 200 ] || fail "POST /rescan -> $code, want 202/200"
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${toString port}/rescan")
    [ "$code" = 403 ] || fail "POST /rescan without X-HX-Request -> $code, want 403 (CSRF posture)"
    echo "smoke: rescan accepted (HTTP 202, htmx-only)"
    for _ in $(seq 1 60); do
      status=$(curl -sf "http://127.0.0.1:${toString port}/partials/status" || true)
      n=$(grep -o '<td>scan</td>' <<<"$status" | wc -l)
      [ "$n" -ge 2 ] && break
      sleep 1
    done
    [ "''${n:-0}" -ge 2 ] || fail "rescan did not record a second run"
    echo "smoke: rescan recorded in runs table"

    # ---- P2: download control against the REAL in-VM aria2 daemon ----
    HX='X-HX-Request: true'
    base="http://127.0.0.1:${toString port}"

    echo "smoke: waiting for the webapp to reach the aria2 daemon"
    ok=0
    for _ in $(seq 1 60); do
      frag=$(curl -sf "$base/partials/downloads-summary" || true)
      if grep -q 'data-aria2="ok"' <<<"$frag"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "aria2 never became reachable through the webapp"
    echo "smoke: aria2 reachable (version chip rendered)"

    # Acquire nes: submits the staged fixture torrent (webseed -> the
    # in-VM static server) into incoming/nes with aria2-rpc.sh semantics.
    code=$(curl -s -o /tmp/acq.out -w '%{http_code}' -H "$HX" -X POST "$base/systems/nes/acquire")
    [ "$code" = 202 ] || fail "POST /systems/nes/acquire -> $code, want 202"
    grep -q 'id="downloads-panel"' /tmp/acq.out || fail "acquire did not answer the queue fragment"
    echo "smoke: acquire accepted (HTTP 202)"

    # The download appears in the queue fragment, attributed to nes.
    gid=""
    for _ in $(seq 1 30); do
      frag=$(curl -sf "$base/partials/downloads" || true)
      gid=$(sed -n 's/.*data-gid="\([0-9a-f]*\)" data-status="active" data-system="nes".*/\1/p' <<<"$frag" | head -1)
      [ -n "$gid" ] && break
      sleep 1
    done
    [ -n "$gid" ] || fail "acquired download never appeared active+attributed in the queue"
    echo "smoke: nes download live in queue (gid=$gid)"

    # Pause -> paused (throttled to 256 KiB/s, still mid-flight).
    curl -s -o /dev/null -H "$HX" -X POST "$base/downloads/$gid/pause"
    paused=0
    for _ in $(seq 1 15); do
      frag=$(curl -sf "$base/partials/downloads" || true)
      if grep -q "data-gid=\"$gid\" data-status=\"paused\"" <<<"$frag"; then paused=1; break; fi
      sleep 1
    done
    [ "$paused" = 1 ] || fail "pause never took effect for gid=$gid"
    echo "smoke: pause works"

    # Resume -> completes; payload lands in incoming/nes at full size.
    echo "smoke: sending resume for $gid"
    code=$(curl -s -o /tmp/resume.out -w '%{http_code}' -H "$HX" -X POST "$base/downloads/$gid/resume")
    echo "smoke: resume POST -> $code"
    [ "$code" = 200 ] || fail "resume POST -> $code, want 200"
    done=0
    i=0
    for _ in $(seq 1 45); do
      i=$((i + 1))
      frag=$(curl -sf "$base/partials/downloads" || true)
      if grep -q "data-gid=\"$gid\" data-status=\"complete\"" <<<"$frag"; then done=1; break; fi
      if [ $((i % 10)) = 0 ]; then
        st=$(grep -o "data-gid=\"$gid\" data-status=\"[a-z]*\"" <<<"$frag" | head -1)
        echo "smoke: waiting for complete... ($i: $st)"
      fi
      sleep 1
    done
    [ "$done" = 1 ] || fail "download never completed after resume (gid=$gid)"
    test -f ${incoming}/nes/vm-fixture-payload.bin || fail "payload file missing after complete"
    size=$(stat -c %s ${incoming}/nes/vm-fixture-payload.bin)
    [ "$size" = 2097152 ] || fail "payload size $size, want 2097152"
    echo "smoke: resume works; download completed (2.0 MiB into incoming/nes)"

    # The acquire submission is recorded in the runs table (audit trail).
    for _ in $(seq 1 10); do
      status=$(curl -sf "$base/partials/status" || true)
      grep -q '<td>acquire</td>' <<<"$status" && break
      sleep 1
    done
    grep -q '<td>acquire</td>' <<<"$status" || fail "acquire run not recorded in runs table"

    # House-critical: the RPC secret VALUE never appears in the webapp's
    # journal (runtime file read, token only on the wire).
    n=$(journalctl -u jupiter-arcade-webapp --no-pager | grep -c 'vm-test-invented-secret-not-from-sops' || true)
    [ "$n" = "0" ] || fail "RPC secret value leaked into the webapp journal"
    echo "smoke: RPC secret never logged (journal grep clean)"

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
    # Writable incoming root (NOT the read-only store fixture): the aria2
    # daemon writes real downloads here, and the webapp's P2 attribution
    # reads them. The scanner's "incoming" stat counts live staging bytes.
    incomingDir = incoming;
    torrentDir = "${torrentFixture}/minerva-torrents";
    # Download control against the in-VM daemon (default RPC URL
    # http://127.0.0.1:6800/jsonrpc). INVENTED test secret — see the
    # torrentFixture note above.
    aria2SecretFile = "${aria2Secret}";
    # VM state dir — deliberately NOT /tmp: the service hardening includes
    # PrivateTmp, so a /tmp state dir would exist only in the unit's
    # private tmpfs namespace and fail ReadWritePaths at step NAMESPACE.
    # /var/lib is unaffected; tmpfiles (module) creates it before start.
    # ADR-0002 D3's on-pool rule is a europa concern; the schema + WAL
    # behaviour are what's under test here.
    stateDir = "/var/lib/arcade-webapp-state";
    # No legacy inventory in the fixture — absence is tolerated by design.
    inventoryFile = null;
    # Screenscraper/TGDB stay unconfigured (P5's consumers).
    screenscraperCredsFile = "/dev/null";
    tgdbApikeyFile = "/dev/null";
  };

  # The incoming dir must exist before the webapp unit's mount namespace
  # is built (D-P1f lesson applies to ReadWritePaths on the aria2 side;
  # pre-creating keeps ReadOnlyPaths on the webapp side exact too).
  systemd.tmpfiles.rules = [ "d ${incoming} 0755 root root -" ];

  # Minimal aria2 daemon (NOT jupiter.services.aria2: that module pulls
  # nginx + AriaNg + the sops secret the VM deliberately doesn't have).
  # Throttled to 256 KiB/s so the 2 MiB fixture download stays in flight
  # long enough to pause/resume deterministically.
  systemd.services.arcade-aria2 = {
    description = "aria2 JSON-RPC daemon (VM test fixture, local secret)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    preStart = ''
      mkdir -p ${incoming}
    '';
    serviceConfig = {
      Type = "exec";
      ExecStart = pkgs.writeShellScript "arcade-aria2-exec" ''
        exec ${pkgs.aria2}/bin/aria2c \
          --enable-rpc \
          --rpc-listen-port=6800 \
          --rpc-secret="$(cat ${aria2Secret})" \
          --dir=${incoming} \
          --max-download-limit=256K \
          --split=1 \
          --max-connection-per-server=1 \
          --file-allocation=none \
          --allow-overwrite=true \
          --auto-file-renaming=false \
          --continue=true \
          --quiet=true
      '';
      Restart = "on-failure";
      RestartSec = "5s";
      ReadWritePaths = [ incoming ];
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectHome = true;
    };
  };

  # Webseed source for the fixture torrent. darkhttpd: tiny, and its
  # Range support is load-bearing for pause/resume (see the fixture note).
  systemd.services.arcade-payload-server = {
    description = "static webseed server for the VM download fixture";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "exec";
      ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${torrentFixture}/payload --port 8099 --addr 127.0.0.1 --no-listing";
      Restart = "on-failure";
      RestartSec = "5s";
    };
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

  # Minimal VM shape for `nixos-rebuild build-vm` / the driver script.
  # Deliberately NO autologin getty (ADV-P1-04): an autologin root shell
  # races the smoke service for /dev/ttyS0 — its prompt/escape output can
  # swallow the FAIL verdict, and failures then burn the driver's whole
  # timeout undiagnosed. P2 goes further and masks the serial getty
  # entirely: the smoke is a systemd service needing no shell, and the
  # getty's terminal-reset escape sequences on ttyS0 interleaved with
  # smoke output during P2 bring-up. DNS via QEMU user-net.
  virtualisation.vmVariant = {
    systemd.services."serial-getty@ttyS0".enable = false;
    networking.nameservers = [
      "10.0.2.3"
      "1.1.1.1"
    ];
  };
}
