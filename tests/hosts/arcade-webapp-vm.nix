{
  config,
  lib,
  pkgs,
  ...
}:

# arcade-webapp-vm — the minimal test host for the jupiterOS Arcade
# pipeline webapp (gauntlet plan §4: `make test-arcade-webapp`).
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
# -> complete. P3 adds the verify flow against the REAL igir
# (pkgs.igir from the pinned nixpkgs): the games trees/DAT dir are
# materialized as WRITABLE copies (igir COPY-promotes into them, the DAT
# manager fetches into the DAT dir), the ROM corpus is staged under
# incoming/ (the .zip scanner shapes stay games-tree-only — staged zips
# would be input-side junk), and the stub server doubles as the
# Fresh1G1R DAT host (the DAT fetch URL is overridden — tests never
# touch GitHub). The nes verify is asserted in two real-igir steps:
# amber "extra" while the tree holds non-DAT zips (the provenance
# split), then green "verified" after the tree is aligned to the DAT
# and emptied — a REAL COPY promotion (the files on disk afterwards
# come from igir, not the fixture materializer).
#
# The in-VM assertions live in jupiter-arcade-webapp-smoke.service: wait
# for /healthz, wait for the startup scan to land, assert the dashboard
# renders the expected per-system counts/coverage, exercise /rescan and
# the partials, then run the P2 download cycle and the P3 verify cycle
# (DAT refresh via stub -> .aria2 skip -> real igir verify (amber
# extra -> clean -> green) -> promote-unchecked -> verify-all ->
# stage-torrent/stage-uri), print the PASS marker and power off. The
# driver (scripts/test-arcade-webapp.sh) greps the serial log for the
# marker.
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
  # mid-flight, short enough to keep the VM run under budget.
  #
  # NOTE darkhttpd (not python http.server): pause/resume needs HTTP
  # Range support on the webseed — verified locally; python's simple
  # server ignores Range and the resumed download stalls forever. P3
  # reuses the same server as the Fresh1G1R DAT stub (darkhttpd
  # percent-decodes paths — verified locally before wiring).
  #
  # aria2Secret is an INVENTED test value (not from secrets.yaml — house
  # rule: no real secret ever enters this repo). It lives in the store
  # like every other fixture datum; what is under test is the WIRING:
  # the webapp reads the path at runtime and sends it as the RPC token
  # without ever logging it (asserted via the journal grep below).
  aria2Secret = pkgs.writeText "arcade-aria2-rpc-secret" "vm-test-invented-secret-not-from-sops";

  # The static-server root in one derivation: the torrent payload at
  # payload/ (webseed URL /payload/…) and the stubbed Fresh1G1R DAT
  # tree at dats/ (the module's datFetchBaseUrl points at
  # http://127.0.0.1:8099/dats — tests never touch GitHub). The stubbed
  # nes DAT carries a NEWER date (2026-08-22) than the committed fixture
  # DATs (2026-08-21) so the refresh is observable in the UI.
  stubRoot = pkgs.stdenv.mkDerivation {
    name = "arcade-webapp-vm-stub-root";
    buildCommand = ''
      set -euo pipefail
      mkdir -p $out/payload $out/dats/no-intro
      head -c 2097152 /dev/zero | tr '\0' 'P' > $out/payload/vm-fixture-payload.bin
      sed 's/2026-08-21/2026-08-22/' ${dats}/nes.dat \
        > "$out/dats/no-intro/Nintendo - Nintendo Entertainment System (Headerless) (No-Intro - Fresh1G1R - McLean).dat"
    '';
  };

  # The torrent over the stub payload, named EXACTLY as the fleet
  # catalogue TSV's nes row expects (the smoke fails loudly on drift).
  torrentFixture = pkgs.stdenv.mkDerivation {
    name = "arcade-webapp-vm-torrent-fixture";
    nativeBuildInputs = [ pkgs.mktorrent ];
    buildCommand = ''
      set -euo pipefail
      mkdir -p $out/minerva-torrents
      mktorrent -l 18 -p \
        -w 'http://127.0.0.1:8099/payload/vm-fixture-payload.bin' \
        -o "$out/minerva-torrents/Minerva_Myrient - No-Intro - Nintendo - Nintendo Entertainment System (Headerless).torrent" \
        ${stubRoot}/payload/vm-fixture-payload.bin
    '';
  };

  incoming = "/var/lib/arcade-incoming";
  gamesRoot = "/var/lib/arcade-games";
  datDir = "/var/lib/arcade-dats";
  scratch = "/var/lib/arcade-scratch";
  torrents = "/var/lib/arcade-torrents";

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

    # Bound EVERY curl in the smoke: a request against a wedged endpoint
    # must fail fast and visibly, never hang the service until the
    # driver's QEMU timeout (a silent full-budget burn with no FAIL
    # marker — the ADV-P1-04 lesson in a new costume, seen once during
    # P3 bring-up when the daemon stalled mid-startup).
    curl() { command curl --max-time 10 "$@"; }

    echo "smoke: waiting for the webapp to reach the aria2 daemon"
    ok=0
    misses=0
    for _ in $(seq 1 60); do
      frag=$(curl -sf "$base/partials/downloads-summary" || true)
      if grep -q 'data-aria2="ok"' <<<"$frag"; then ok=1; break; fi
      misses=$((misses + 1))
      if [ $((misses % 20)) = 0 ]; then
        echo "smoke: DEBUG aria2 still unreachable after ''${misses} polls:"
        systemctl is-active arcade-aria2 arcade-payload-server || true
        journalctl -u arcade-aria2 --no-pager -n 10 || true
        journalctl -u jupiter-arcade-webapp --no-pager -n 10 || true
      fi
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
    # journal (runtime file read, token only on the wire). The check has
    # TWO guards against a vacuous pass (ADV-P2-01): journalctl must
    # succeed, and the journal must contain the unit's stable startup
    # line ("listening on", emitted right before ListenAndServe in
    # cmd/arcade-webapp/main.go) — a dead/redirected journal fails
    # loudly instead of grepping nothing and reporting 0 matches.
    journal=$(journalctl -u jupiter-arcade-webapp --no-pager) \
      || fail "journalctl could not read the webapp journal (secret grep would be vacuous)"
    grep -q 'arcade-webapp: listening on' <<<"$journal" \
      || fail "webapp journal lacks its startup line — journal capture broken (secret grep would be vacuous)"
    n=$(grep -c 'vm-test-invented-secret-not-from-sops' <<<"$journal" || true)
    [ "$n" = "0" ] || fail "RPC secret value leaked into the webapp journal"
    echo "smoke: RPC secret never logged (journal alive: startup line present, grep clean)"

    # ---- P3: verify & organize (REAL igir) + DAT currency (stubbed) ----
    #
    # The P2 payload was a DOWNLOAD fixture, not ROM staging — remove it
    # so nes's staged set is exactly the corpus the DAT describes
    # (leftover, it would surface as 1 UNUSED = red, not green). The
    # infohash .torrent aria2 dropped next to it stays DELIBERATELY: it
    # exercises the runner's --input-exclude **/*.torrent against the
    # real igir (aria2 writes these into every download dir even via
    # addTorrent — D-P3e; the run must still reach green with it
    # present).
    rm -f ${incoming}/nes/vm-fixture-payload.bin

    # The verify worklist renders with pills still unknown (nothing
    # verified yet) and every action present.
    page=$(curl -sf "$base/verify" || fail "GET /verify")
    grep -q 'id="verify-panel"' <<<"$page" || fail "verify page missing its panel"
    grep -q 'data-system="nes" data-verify="unknown"' <<<"$page" \
      || fail "nes must start unverified on the worklist"
    grep -q 'hx-post="/verify"' <<<"$page" || fail "verify-all action missing"
    grep -q 'hx-post="/dats/refresh"' <<<"$page" || fail "DAT refresh action missing"
    frag=$(curl -sf "$base/partials/verify" || fail "GET /partials/verify")
    grep -q '<html' <<<"$frag" && fail "verify partial rendered the full layout"
    echo "smoke: verify worklist renders (fragment-shaped, actions present)"

    # CSRF posture on every new mutating endpoint.
    for ep in /verify /systems/nes/verify /dats/refresh /systems/nes/dat-refresh /systems/snes/stage-torrent; do
      code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base$ep")
      [ "$code" = 403 ] || fail "POST $ep without X-HX-Request -> $code, want 403"
    done
    echo "smoke: P3 mutating endpoints are htmx-only"

    # DAT refresh via the stub host: nes's DAT date moves 2026-08-21 ->
    # 2026-08-22 (the stub serves a re-dated copy of the same committed
    # DAT), proving the fetch + header re-parse landed — without GitHub.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/systems/nes/dat-refresh")
    [ "$code" = 200 ] || fail "POST /systems/nes/dat-refresh -> $code, want 200"
    ok=0
    for _ in $(seq 1 30); do
      page=$(curl -sf "$base/partials/verify" || true)
      if grep -q '2026-08-22' <<<"$page"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "stubbed DAT refresh never updated the nes currency date"
    echo "smoke: DAT refresh via stub host worked (date 2026-08-22 rendered)"

    # The audit trail for dat-fetch is asserted HERE, at the step that
    # records it: the status partial renders only the newest 8 runs, and
    # the verify steps below (5 runs + post-verify rescans) would push
    # this row out of the window before a later grep could see it.
    status=$(curl -sf "$base/partials/status" || true)
    grep -q '<td>dat-fetch</td>' <<<"$status" || fail "dat-fetch run not in the audit trail"
    echo "smoke: dat-fetch run recorded"

    # Unmapped system (wiiu: deliberately absent from the McLean table):
    # the mapping error surfaces on the fragment — a state, not a 5xx.
    code=$(curl -s -o /tmp/wiiu.out -w '%{http_code}' -H "$HX" -X POST "$base/systems/wiiu/dat-refresh")
    [ "$code" = 200 ] || fail "POST /systems/wiiu/dat-refresh -> $code, want 200 (state, not 5xx)"
    grep -q 'no McLean DAT mapping' /tmp/wiiu.out \
      || fail "unmapped DAT refresh must surface the mapping error"
    echo "smoke: unmapped system surfaces its mapping error"

    # .aria2 skip: stage a control file for gb — the whole system skips
    # (partial files cannot DAT-match), gb stays unknown, no report.
    touch "${incoming}/gb/inflight.aria2"
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/systems/gb/verify")
    [ "$code" = 202 ] || fail "POST /systems/gb/verify (in-flight) -> $code, want 202"
    ok=0
    for _ in $(seq 1 30); do
      status=$(curl -sf "$base/partials/status" || true)
      if grep -q 'gb: skipped-downloading' <<<"$status"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "gb in-flight skip never recorded in the run detail"
    page=$(curl -sf "$base/partials/verify" || true)
    grep -q 'data-system="gb" data-verify="unknown"' <<<"$page" \
      || fail "in-flight gb must stay unverified"
    [ ! -f "${scratch}/reports/gb.csv" ] || fail "in-flight skip must not write a report"
    rm -f "${incoming}/gb/inflight.aria2"
    echo "smoke: .aria2 in-flight skip works (gb untouched, run detail says why)"

    # REAL igir verify of nes, in two honest steps (shapes proven against
    # the real igir 5.3.0 locally before wiring):
    #
    # 1. The games tree still holds the 2 fixture .zips (P1's scanner
    #    shapes) that the DAT does not claim. igir scans the OUTPUT tree
    #    too, so those surface as output-side UNUSED = Extra (amber, the
    #    provenance split — all 5 DAT games found, 0 unmatched). This is
    #    the designed operator signal, asserted as amber, not green.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/systems/nes/verify")
    [ "$code" = 202 ] || fail "POST /systems/nes/verify -> $code, want 202"
    ok=0
    for _ in $(seq 1 60); do
      frag=$(curl -sf "$base/partials/verify" || true)
      if grep -q 'data-system="nes" data-verify="extra"' <<<"$frag"; then ok=1; break; fi
      sleep 1
    done
    if [ "$ok" != 1 ]; then
      echo "smoke: DEBUG nes verify poll failed — verify fragment rows:"
      grep -o 'data-system="[a-z0-9]*" data-verify="[a-z]*"' <<<"$frag" | head -8 || true
      echo "smoke: DEBUG incoming/nes:"; ls -la ${incoming}/nes || true
      echo "smoke: DEBUG games/cartridge/nes:"; ls -la ${gamesRoot}/cartridge/nes || true
      echo "smoke: DEBUG report:"; head -30 ${scratch}/reports/nes.csv || true
      echo "smoke: DEBUG last run detail (verify error text):"
      curl -sf "$base/partials/status" | grep -A6 '<td>verify</td>' | head -20 || true
      echo "smoke: DEBUG live igir processes (hang check):"
      ps aux | grep -v grep | grep igir || echo "(none — igir not running)"
      echo "smoke: DEBUG webapp journal tail:"
      journalctl -u jupiter-arcade-webapp --no-pager -n 40 || true
      fail "real-igir nes verify never reached amber extra (zips in the tree)"
    fi
    grep -q '>2 extra</span>' <<<"$frag" || fail "nes extra pill must count 2"
    echo "smoke: REAL igir saw the tree extras (amber, provenance split live)"
    rep=$(curl -sf "$base/verify/reports/nes.csv" || fail "GET /verify/reports/nes.csv")
    grep -q ',FOUND,' <<<"$rep" || fail "nes report CSV lacks FOUND rows"

    # 2. Operator aligns the tree with the DAT (drops the non-DAT zips)
    #    AND empties the output — so the next verify's COPY promotion is
    #    REAL (files must appear via igir's copy, not the fixture
    #    materializer). Staged corpus vs refreshed DAT -> every game
    #    FOUND, zero unmatched, zero extra -> GREEN.
    rm -f "${gamesRoot}/cartridge/nes/"*
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/systems/nes/verify")
    [ "$code" = 202 ] || fail "POST /systems/nes/verify (2nd) -> $code, want 202"
    ok=0
    for _ in $(seq 1 60); do
      frag=$(curl -sf "$base/partials/verify" || true)
      if grep -q 'data-system="nes" data-verify="verified"' <<<"$frag"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "real-igir nes verify never reached green (zero unmatched)"
    echo "smoke: REAL igir verified nes (zero unmatched, green)"
    [ -f "${gamesRoot}/cartridge/nes/Starlit Vault (USA).nes" ] \
      || fail "igir COPY-promoted ROM missing in the games tree (fresh output — this was a REAL promotion)"
    ok=0
    for _ in $(seq 1 30); do
      page=$(curl -sf "$base/" || true)
      if grep -q 'data-system="nes" data-games="5" data-coverage="60" data-verify="verified"' <<<"$page"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "dashboard nes card never flipped to 5 games / 60% / verified"
    echo "smoke: promotion on disk (fresh output), dashboard pill live"

    # Promote-unchecked degradation: a2600 has staged input but NO DAT in
    # the VM — everything copies as-is, the pill reads 'unchecked' (grey,
    # not red), and the promoted file lands in the games tree.
    mkdir -p "${incoming}/a2600"
    head -c 512 /dev/zero | tr '\0' 'A' > "${incoming}/a2600/Fake Game (USA).a26"
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/systems/a2600/verify")
    [ "$code" = 202 ] || fail "POST /systems/a2600/verify -> $code, want 202"
    ok=0
    for _ in $(seq 1 30); do
      frag=$(curl -sf "$base/partials/verify" || true)
      if grep -q 'data-system="a2600" data-verify="unchecked"' <<<"$frag"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "a2600 never reached the unchecked state"
    [ -f "${gamesRoot}/cartridge/a2600/Fake Game (USA).a26" ] \
      || fail "promote-unchecked did not copy the staged file"
    echo "smoke: missing-DAT degradation promotes unchecked (grey)"

    # Verify-all: the whole catalogue in one batch — the empty systems
    # skip instantly, snes+gb run igir, nes re-verifies idempotently.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/verify")
    [ "$code" = 202 ] || fail "POST /verify -> $code, want 202"
    ok=0
    for _ in $(seq 1 90); do
      frag=$(curl -sf "$base/partials/verify" || true)
      if grep -q 'data-system="snes" data-verify="verified"' <<<"$frag" \
         && grep -q 'data-system="gb" data-verify="verified"' <<<"$frag"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "verify-all never turned snes+gb green"
    echo "smoke: verify-all green across the staged corpus"

    # The runs table carries the verify kind with human detail (the
    # dat-fetch kind is asserted at its own step above — see the
    # RecentRuns(8) window note there).
    status=$(curl -sf "$base/partials/status" || true)
    grep -q '<td>verify</td>' <<<"$status" || fail "verify run not in the audit trail"
    echo "smoke: verify runs recorded"

    # ---- P3 carry-in: torrent staging (the P2 critic's named gap) ----
    #
    # Upload a .torrent for snes (its catalogue torrent is NOT staged in
    # the fixture): stored under the (writable) torrentDir with the
    # CATALOGUE-expected name, after which the snes acquire affordance
    # goes live.
    printf 'd4:infod4:name4:snes' > /tmp/vm-staged.torrent
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" \
      -F 'torrent=@/tmp/vm-staged.torrent;filename=my snes set.torrent' \
      "$base/systems/snes/stage-torrent")
    [ "$code" = 200 ] || fail "stage-torrent upload -> $code, want 200"
    [ -f "${torrents}/Minerva_Myrient - No-Intro - Nintendo - Super Nintendo Entertainment System.torrent" ] \
      || fail "uploaded torrent not stored under the catalogue-expected name"
    page=$(curl -sf "$base/downloads" || true)
    grep -q 'hx-post="/systems/snes/acquire"' <<<"$page" \
      || fail "staged snes torrent did not enable its acquire button"
    echo "smoke: stage-torrent stored under the catalogue name, acquire enabled"

    # Validation: non-.torrent rejected; unknown system 404.
    printf 'not a torrent' > /tmp/evil.sh
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -F 'torrent=@/tmp/evil.sh' \
      "$base/systems/snes/stage-torrent")
    [ "$code" = 400 ] || fail "stage-torrent with .sh -> $code, want 400"
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -F 'torrent=@/tmp/vm-staged.torrent' \
      "$base/systems/nope/stage-torrent")
    [ "$code" = 404 ] || fail "stage-torrent unknown system -> $code, want 404"

    # stage-uri: a magnet accepted by the real daemon (dir-routed into
    # incoming/gb); a bad scheme rejected.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" \
      --data-urlencode 'uri=magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567' \
      "$base/systems/gb/stage-uri")
    [ "$code" = 200 ] || fail "stage-uri magnet -> $code, want 200"
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" \
      --data-urlencode 'uri=ftp://example.com/x.torrent' \
      "$base/systems/gb/stage-uri")
    [ "$code" = 400 ] || fail "stage-uri ftp -> $code, want 400"
    echo "smoke: stage-uri magnet queued, bad scheme rejected"

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
    # P3: the games trees/DAT dir are WRITABLE copies of the fixture (the
    # arcade-fixture-materialize service below) — igir COPY-promotes
    # into them and the DAT manager fetches into the DAT dir, exactly
    # like europa's on-pool datasets. Read-only store paths would fail
    # the unit's ReadWritePaths at step NAMESPACE (D-P1f) AND the
    # promotions themselves.
    cartridgeRoot = "${gamesRoot}/cartridge";
    opticalRoot = "${gamesRoot}/optical";
    modernRoot = "${gamesRoot}/modern";
    datDir = datDir;
    skyscraperCacheDir = "${fixture}/metadata/skyscraper-cache";
    # Writable incoming root (NOT the read-only store fixture): the aria2
    # daemon writes real downloads here, and the webapp's P2 attribution
    # reads them. The scanner's "incoming" stat counts live staging
    # bytes; materialize also stages the ROM corpus under it so verify
    # has real input.
    incomingDir = incoming;
    # Writable torrent dir with the nes fixture torrent pre-staged (the
    # P3 stage-torrent upload writes the snes one through the webapp).
    torrentDir = torrents;
    # igirPackage keeps its default (pkgs.igir from the pinned nixpkgs —
    # 5.3.0, the same binary the fixture gate pins): the REAL igir runs
    # in-VM against the REAL fixture tree.
    # DAT manager against the in-VM stub host — tests never touch
    # GitHub (the stub serves a re-dated nes DAT so the refresh is
    # observable). Scheduled refresh stays OFF for determinism; the
    # on-demand endpoints are what the smoke drives.
    datFetchBaseUrl = "http://127.0.0.1:8099/dats";
    datRefreshIntervalHours = null;
    scratchDir = scratch;
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
  # pre-creating keeps ReadOnlyPaths on the webapp side exact too). P3
  # widens this to every writable tree the unit mounts.
  systemd.tmpfiles.rules = [
    "d ${incoming} 0755 root root -"
    "d ${torrents} 0755 root root -"
  ];

  # P3 fixture materialization: writable copies of the read-only store
  # fixture (games tree + DATs) plus the staged ROM corpus under
  # incoming. MUST complete before the webapp unit starts — its
  # ReadWritePaths entries have to exist at namespace-build time
  # (D-P1f), and the startup scan walks these trees.
  systemd.services.arcade-fixture-materialize = {
    description = "arcade-webapp VM fixture: writable trees + staged corpus";
    wantedBy = [ "multi-user.target" ];
    before = [ "jupiter-arcade-webapp.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      mkdir -p ${gamesRoot} ${datDir} ${scratch}/reports ${torrents}
      cp -r ${fixture}/games/. ${gamesRoot}/
      cp ${fixture}/metadata/no-intro-dats/*.dat ${datDir}/
      cp ${torrentFixture}/minerva-torrents/*.torrent ${torrents}/
      # Stage the DAT corpus under incoming — the verify runner's input
      # (the same deterministic bytes the committed DATs describe). The
      # nes .zip shapes are GAMES-TREE scanner coverage (ADV-P1-01),
      # NOT staged corpus: staging them would model junk-arrived-in-
      # staging (input-side UNUSED = red), a signal the smoke exercises
      # deliberately further down instead (the amber extra → green
      # verified sequence). Proven against the real igir 5.3.0.
      for sys in nes snes gb; do
        mkdir -p "${incoming}/$sys"
        for f in "${fixture}/games/cartridge/$sys"/*; do
          case "$f" in *.zip) continue ;; esac
          cp "$f" "${incoming}/$sys/"
        done
      done
    '';
  };
  systemd.services.jupiter-arcade-webapp = {
    wants = [ "arcade-fixture-materialize.service" ];
    after = [ "arcade-fixture-materialize.service" ];
  };

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

  # Webseed source for the fixture torrent AND the stubbed Fresh1G1R
  # DAT tree. darkhttpd: tiny, its Range support is load-bearing for
  # pause/resume (see the fixture note), and it percent-decodes paths
  # (verified locally before wiring — load-bearing for the DAT URLs).
  systemd.services.arcade-payload-server = {
    description = "static webseed + DAT-stub server for the VM fixtures";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "exec";
      ExecStart = "${pkgs.darkhttpd}/bin/darkhttpd ${stubRoot} --port 8099 --addr 127.0.0.1 --no-listing";
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
      procps # ps: the P3 verify DEBUG hang-check
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
