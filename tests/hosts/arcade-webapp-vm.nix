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
# stage-torrent/stage-uri), print the PASS marker and power off. P6 adds
# the launcher-DB block: Regenerate renders each populated system dir's
# metadata.pegasus.txt from the store — launch lines, relative paths,
# byte stability across two runs, hidden exclusion both directions
# (through the REAL hide/show endpoint since P7), and a zeroed .chd
# landing in the "(Pending)" not-launchable collection. P7 adds the
# curation block: endpoint-driven hide/unhide both directions, the bulk
# show-all-hidden, and a cross-system custom collection whose block
# lands in BOTH member systems' generated files (hidden members
# excluded), plus the P6-critic carry-in: the stubbed Skyscraper cache
# now carries real description TEXT, so scrape → generate must emit
# description: lines into the served file.
# The driver (scripts/test-arcade-webapp.sh) greps the serial log for
# the marker.
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
  skyCache = "/var/lib/arcade-skycache";

  # ---- P5: metadata-engine fixture ----------------------------------
  #
  # A stubbed Skyscraper: deterministic, no network. Every invocation
  # rewrites <cachedir>/db.xml with description+cover resources keyed by
  # the sha1 of each ROM file under the input dir — exactly the id shape
  # CacheID/ReadCacheCoverage key on — so a scrape moves REAL coverage
  # numbers through the real driver→store→ApplyCacheFlags→template stack.
  # When ARCADE_SKYSCRAPER_STUB_LOG is set it journals its argv, giving
  # the smoke a direct probe that the game-detail re-scrape windowed its
  # gather passes to ONE ROM (--startat/--endat).
  skyscraperStub = pkgs.writeShellScriptBin "skyscraper" ''
    set -eu
    export PATH="${pkgs.coreutils}/bin:${pkgs.findutils}/bin:$PATH"
    # Journal the RAW argv FIRST — the parse loop below shifts $@ away,
    # and a journal taken after it would be empty (run-1 root cause).
    if [ -n "''${ARCADE_SKYSCRAPER_STUB_LOG:-}" ]; then
      { echo '---'; printf '%s\n' "$@"; } >> "''${ARCADE_SKYSCRAPER_STUB_LOG}"
    fi
    p=""; i=""; d=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -p) p="$2"; shift 2 ;;
        -i) i="$2"; shift 2 ;;
        -d) d="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$d" ] || exit 1
    mkdir -p "$d"
    {
      echo '<?xml version="1.0" encoding="UTF-8"?>'
      echo '<db>'
      find "$i" -type f 2>/dev/null | LC_ALL=C sort | while read -r f; do
        case "''${f##*.}" in
          nes|sfc|smc|gb|gbc|gba|n64|zip|cue|bin|chd|iso) ;;
          *) continue ;;
        esac
        id="$(sha1sum "$f" | cut -d' ' -f1)"
        # The description resource carries REAL per-game text (not a fixed
        # token): the P7 enrichment assertion greps the SERVED launcher-DB
        # file for this exact prose, so the ingest path must carry the
        # cache's actual payload end to end.
        base="$(basename "$f")"
        echo "  <resource id=\"$id\" type=\"description\" source=\"stub\" timestamp=\"1\">stubbed description of ''${base%.*}</resource>"
        echo "  <resource id=\"$id\" type=\"cover\" source=\"stub\" timestamp=\"1\">covers/stub.png</resource>"
      done
      echo '</db>'
    } > "$d/db.xml"
  '';

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

    # POST-and-wait-for-a-pill with bounded retry. Since P6, every
    # SUCCESSFUL verify triggers a launcher-DB regeneration that claims
    # the shared pipeline slot right after the runner releases it — a
    # verify POST landing inside that window is rejected ErrBusy and
    # swallowed by design (P3 semantics: the page already shows state),
    # so the action must be RETRIED — exactly what an operator's second
    # click does. Three attempts, 30s poll each; the callers fail loudly
    # with their DEBUG blocks when even that never lands.
    verify_until() { # $1 endpoint $2 system $3 expected state
      local ep="$1" sys="$2" want="$3" attempt frag
      for attempt in 1 2 3; do
        curl -s -o /dev/null -H "$HX" -X POST "$base$ep"
        for _ in $(seq 1 30); do
          frag=$(curl -sf "$base/partials/verify" || true)
          if grep -q "data-system=\"$sys\" data-verify=\"$want\"" <<<"$frag"; then return 0; fi
          sleep 1
        done
        echo "smoke: $sys never reached '$want' (attempt $attempt) — retrying"
      done
      return 1
    }

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

    # ADV-P3-01: the P3 verify steps below depend on the infohash-named
    # .torrent companion aria2 just dropped into incoming/nes — it is
    # what exercises the runner's --input-exclude against the REAL igir
    # (D-P3e). No later step can notice it never arrived: green would
    # still pass with the exclude never having mattered, i.e. vacuous
    # coverage. Assert it exists HERE, at the step that produces it.
    # The natural idiom here is `compgen -G`, but nixpkgs' bash 5.3 is
    # built WITHOUT programmable completion ("compgen: command not
    # found", rc=127) — use a POSIX glob loop instead, which any shell
    # handles.
    torrent_seen=""
    for f in ${incoming}/nes/*.torrent; do
      if [ -e "$f" ]; then torrent_seen=1; break; fi
    done
    [ -n "$torrent_seen" ] \
      || fail "aria2 metadata companion missing — --input-exclude coverage is vacuous"
    echo "smoke: aria2 .torrent metadata companion present in incoming/nes (--input-exclude coverage is real)"

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
    # present; its presence is asserted right after the resume step —
    # ADV-P3-01, so the coverage can never silently go vacuous).
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
    if ! verify_until /systems/nes/verify nes verified; then
      echo "smoke: DEBUG webapp journal tail:"
      journalctl -u jupiter-arcade-webapp --no-pager -n 40 || true
      fail "real-igir nes verify never reached green (zero unmatched)"
    fi
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
    if ! verify_until /systems/a2600/verify a2600 unchecked; then
      echo "smoke: DEBUG webapp journal tail:"
      journalctl -u jupiter-arcade-webapp --no-pager -n 40 || true
      fail "a2600 never reached the unchecked state"
    fi
    [ -f "${gamesRoot}/cartridge/a2600/Fake Game (USA).a26" ] \
      || fail "promote-unchecked did not copy the staged file"
    echo "smoke: missing-DAT degradation promotes unchecked (grey)"

    # Verify-all: the whole catalogue in one batch — the empty systems
    # skip instantly, snes+gb run igir, nes re-verifies idempotently.
    # Bounded retry: the POST can land inside the previous verify's
    # post-promotion regeneration window (P6 trigger + shared slot) and
    # be swallowed ErrBusy — retrying is the operator semantics.
    ok=0
    for attempt in 1 2 3; do
      curl -s -o /dev/null -H "$HX" -X POST "$base/verify"
      for _ in $(seq 1 40); do
        frag=$(curl -sf "$base/partials/verify" || true)
        if grep -q 'data-system="snes" data-verify="verified"' <<<"$frag" \
           && grep -q 'data-system="gb" data-verify="verified"' <<<"$frag"; then ok=1; break; fi
        sleep 1
      done
      [ "$ok" = 1 ] && break
      echo "smoke: verify-all gate not reached (attempt $attempt) — retrying"
    done
    if [ "$ok" != 1 ]; then
      echo "smoke: DEBUG verify fragment rows:"
      grep -o 'data-system="[a-z0-9]*" data-verify="[a-z]*"' <<<"$frag" | head -8 || true
      echo "smoke: DEBUG webapp journal tail:"
      journalctl -u jupiter-arcade-webapp --no-pager -n 40 || true
      fail "verify-all never turned snes+gb green"
    fi
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

    # ---- P4: library gallery + detail + art fallback ----
    #
    # artDir stays UNSET on this host: the /art route must serve its
    # deterministic SVG posters (content-type image/svg+xml) when no
    # cover root is wired — the scraped-cover path is unit-covered.
    echo "smoke: P4 library renders fixture titles"
    # Page size is 10 (libPageSize); the 16-game corpus spans two pages,
    # so page 1 carries the alphabetically-early titles + the next link.
    page=$(curl -sf "$base/library" || fail "GET /library")
    grep -q 'Mecha Garden' <<<"$page" || fail "library page 1 missing a fixture card"
    grep -q 'rel="next"' <<<"$page" || fail "library pager missing (16 games must paginate)"
    grep -q 'src="/art/' <<<"$page" || fail "library cards not wired to the /art route"

    echo "smoke: library filter ?q= narrows the grid"
    page=$(curl -sf "$base/library?q=Starlit" || fail "GET /library?q=Starlit")
    grep -q 'Starlit Vault' <<<"$page" || fail "?q=Starlit lost its match"
    grep -q 'Mecha Garden' <<<"$page" && fail "?q=Starlit must exclude Mecha Garden"

    # Detail page via the card's OWN href (ids are autoincrement — never
    # assumed); the page must carry the rel_path file fact.
    href=$(awk '
      /class="gcard" href="/ { match($0, /href="[^"]*"/); h = substr($0, RSTART + 6, RLENGTH - 7) }
      /gcard-title" title="Starlit Vault/ { print h; exit }
    ' <<<"$page")
    [ -n "$href" ] || fail "no Starlit Vault card link in the filtered grid"
    case "$href" in /systems/nes/games/*) ;; *) fail "card href '$href' is not a detail-route link" ;; esac
    code=$(curl -s -o /tmp/detail.out -w '%{http_code}' "$base$href")
    [ "$code" = 200 ] || fail "GET $href -> $code, want 200"
    grep -q '<code>Starlit Vault (USA).nes</code>' /tmp/detail.out \
      || fail "detail page missing the rel_path fact"

    # Art route: SVG fallback content-type for a real scanned game id.
    gid=$(sed -n 's|.*/games/\([0-9]*\).*|\1|p' <<<"$href")
    [ -n "$gid" ] || fail "could not parse game id from href '$href'"
    ctype=$(curl -s -o /dev/null -w '%{content_type}' "$base/art/nes/$gid")
    [ "$ctype" = "image/svg+xml" ] \
      || fail "/art/nes/$gid content-type '$ctype', want image/svg+xml (SVG fallback)"
    curl -sf "$base/art/nes/$gid" | grep -q '<svg' || fail "/art body is not SVG"
    echo "smoke: P4 library + filtered grid + detail rel_path + svg art ok"

    # ---- P5: metadata engine control (stubbed Skyscraper) ----
    #
    # Coverage must CHANGE after a scrape through the REAL driver →
    # store → ApplyCacheFlags → template stack, driven by a stub binary
    # that keys canned resources off each ROM's actual sha1 — fully
    # deterministic, no network. nes's games tree holds exactly the 5
    # DAT-promoted ROMs at this point (P3 removed the zips), so a scrape
    # must move its description/cover coverage 0% → 100%.
    echo "smoke: P5 metadata page renders the worklist"
    page=$(curl -sf "$base/metadata" || fail "GET /metadata")
    grep -q 'id="metadata-panel"' <<<"$page" || fail "metadata page missing its panel"
    grep -q 'hx-post="/metadata/scrape"' <<<"$page" || fail "scrape-all action missing"
    grep -q 'hx-post="/systems/nes/scrape"' <<<"$page" || fail "per-system scrape action missing"
    frag=$(curl -sf "$base/partials/metadata" || fail "GET /partials/metadata")
    grep -q '<html' <<<"$frag" && fail "metadata partial rendered the full layout"
    # Pre-scrape truth: nothing flagged yet (the fixture db.xml carries
    # synthetic ids that never match real sha1s — flags all zero).
    grep -q 'data-system="nes" data-games="5" data-desc-pct="0" data-cover-pct="0"' <<<"$frag" \
      || fail "nes row must start unflagged (desc/cover 0%)"
    echo "smoke: metadata worklist renders fragment-shaped with unscraped rows"

    # CSRF posture on every new mutating endpoint (game route needs the
    # id the P4 step parsed from its card href).
    [ -n "$gid" ] || fail "P5 lost the game id from the P4 detail step"
    for ep in "/metadata/scrape" "/systems/nes/scrape" "/systems/nes/games/$gid/scrape"; do
      code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base$ep")
      [ "$code" = 403 ] || fail "POST $ep without X-HX-Request -> $code, want 403"
    done
    echo "smoke: P5 mutating endpoints are htmx-only"

    # Per-system scrape: coverage flips 0 → 100 on BOTH columns once the
    # stub's sha1-keyed db.xml lands and the driver refreshes flags.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/systems/nes/scrape")
    [ "$code" = 202 ] || fail "POST /systems/nes/scrape -> $code, want 202"
    ok=0
    for _ in $(seq 1 60); do
      frag=$(curl -sf "$base/partials/metadata" || true)
      if grep -q 'data-system="nes" data-games="5" data-desc-pct="100" data-cover-pct="100"' <<<"$frag"; then ok=1; break; fi
      sleep 1
    done
    if [ "$ok" != 1 ]; then
      echo "smoke: DEBUG nes scrape poll failed — metadata fragment rows:"
      grep -o 'data-system="[a-z0-9]*"[^>]*' <<<"$frag" | head -6 || true
      echo "smoke: DEBUG sky cache:"; ls -la ${skyCache}/nes 2>/dev/null || true
      echo "smoke: DEBUG webapp journal tail:"
      journalctl -u jupiter-arcade-webapp --no-pager -n 30 || true
      fail "stubbed nes scrape never moved coverage 0->100%"
    fi
    echo "smoke: stubbed scrape flipped nes coverage to desc=100 cover=100"

    # Audit trail: assert the scrape run HERE — the status partial shows
    # only the newest 8 runs and later steps would push it out (the
    # dat-fetch lesson from P3).
    status=$(curl -sf "$base/partials/status" || true)
    grep -q '<td>scrape</td>' <<<"$status" || fail "scrape run not recorded in the runs table"
    echo "smoke: scrape run recorded in the audit trail"

    # Second run → the history drill-down renders two points with a delta.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/systems/nes/scrape")
    [ "$code" = 202 ] || fail "second nes scrape -> $code, want 202"
    ok=0
    for _ in $(seq 1 60); do
      frag=$(curl -sf "$base/partials/metadata" || true)
      if grep -q 'run history (2)' <<<"$frag"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "run-history drill-down never showed two points"
    echo "smoke: run history drill-down live"

    # Scrape all: gb sat at 0% forever — flipping it proves the batch
    # reached systems beyond the one clicked. GATE ON COMPLETION, not on
    # the gb flip alone: catalogue order puts segacd AFTER gb, whose
    # flags flip mid-batch — gating there raced the next POST into the
    # driver's serialized slot (409; run-3 flake). In-flight-only
    # markers: the 3s poll trigger + the running pill both render ONLY
    # while a batch holds the driver (the bare word "scraping" is NOT a
    # marker — the page heading carries it always; run-4 lesson).
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/metadata/scrape")
    [ "$code" = 202 ] || fail "POST /metadata/scrape -> $code, want 202"
    ok=0
    for _ in $(seq 1 90); do
      frag=$(curl -sf "$base/partials/metadata" || true)
      if ! grep -q 'every 3s' <<<"$frag" && ! grep -q '>scraping' <<<"$frag" \
         && grep -q 'data-system="gb" data-games="4" data-desc-pct="100"' <<<"$frag"; then ok=1; break; fi
      sleep 1
    done
    if [ "$ok" != 1 ]; then
      echo "smoke: DEBUG scrape-all gate failed — metadata fragment rows:"
      grep -o 'data-system="[a-z0-9]*"[^>]*' <<<"$frag" | head -6 || true
      grep -o 'class="pill[^"]*">[a-z ]*' <<<"$frag" | head -4 || true
      journalctl -u jupiter-arcade-webapp --no-pager -n 20 || true
      fail "scrape-all never completed (gb unflipped or batch still in flight)"
    fi
    echo "smoke: scrape-all green across the corpus"

    # Cross-page consistency: the dashboard card wall reads the SAME
    # scrape_coverage aggregate the driver just refreshed.
    ok=0
    for _ in $(seq 1 30); do
      page=$(curl -sf "$base/" || true)
      if grep -q 'data-system="nes" data-games="5" data-coverage="100"' <<<"$page"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "dashboard nes card never flipped to coverage=100 after the scrape"
    echo "smoke: dashboard card agrees with the metadata engine (60->100)"

    # Belt-and-braces before the game POST: the slot must be FREE (same
    # in-flight-only markers as the gate above) — a 409 here would mean
    # the smoke, not the serialization, misbehaved.
    for _ in $(seq 1 60); do
      frag=$(curl -sf "$base/partials/metadata" || true)
      if ! grep -q 'every 3s' <<<"$frag" && ! grep -q '>scraping' <<<"$frag"; then break; fi
      sleep 1
    done

    # Game-detail re-scrape: windowed to ONE rom (--startat/--endat),
    # proven via the stub's argv journal (cleared first so earlier
    # scrapes cannot satisfy the grep).
    rm -f "${scratch}/skyscraper-stub.log"
    code=$(curl -s -o /tmp/gscrape.out -w '%{http_code}' -H "$HX" \
      -X POST "$base/systems/nes/games/$gid/scrape")
    [ "$code" = 202 ] || fail "game re-scrape -> $code, want 202"
    grep -q 'id="game-actions"' /tmp/gscrape.out \
      || fail "game re-scrape did not answer with the actions region"
    ok=0
    for _ in $(seq 1 60); do
      if [ -f "${scratch}/skyscraper-stub.log" ] && grep -q -e '--startat' "${scratch}/skyscraper-stub.log"; then ok=1; break; fi
      sleep 1
    done
    if [ "$ok" != 1 ]; then
      journalctl -u jupiter-arcade-webapp --no-pager -n 20 || true
      fail "game re-scrape never invoked the stub windowed (--startat missing)"
    fi
    grep -q 'Starlit Vault (USA).nes' "${scratch}/skyscraper-stub.log" \
      || fail "game re-scrape windowed to the wrong ROM"
    echo "smoke: game re-scrape wired (--startat/--endat at the one ROM)"

    # ---- P6: launcher-DB generation ----
    #
    # The store becomes the source of truth and Regenerate renders each
    # populated system dir's metadata.pegasus.txt. Deterministic: the
    # corpus is fixed bytes, the DB state at this point is known (nes =
    # the 5 DAT-promoted ROMs), and generation itself is byte-stable by
    # construction (asserted below by hashing two consecutive runs).
    echo "smoke: P6 launcher-database section renders"
    page=$(curl -sf "$base/metadata" || fail "GET /metadata")
    grep -q 'hx-post="/generate"' <<<"$page" || fail "Regenerate action missing"
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/generate")
    [ "$code" = 403 ] || fail "POST /generate without X-HX-Request -> $code, want 403"

    # The shared pipeline slot must be FREE before generating: the P5
    # game re-scrape above can still be finishing (its stub-log marker
    # lands mid-batch), and a busy Regenerate is an honest 409 by design.
    # Wait on the fragment's in-flight-only markers (run-4 lesson).
    for _ in $(seq 1 60); do
      frag=$(curl -sf "$base/partials/metadata" || true)
      if ! grep -q 'every 3s' <<<"$frag" && ! grep -q '>scraping' <<<"$frag"; then break; fi
      sleep 1
    done

    # First generation answers 200 synchronously (bounded local job).
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/generate")
    [ "$code" = 200 ] || fail "POST /generate -> $code, want 200"
    md="${gamesRoot}/cartridge/nes/metadata.pegasus.txt"
    [ -f "$md" ] || fail "generation wrote nothing into the served tree"
    grep -q '^collection: Nintendo Entertainment System$' "$md" \
      || fail "nes metadata lacks the catalogue collection title"
    grep -q '^shortname: nes$' "$md" || fail "nes metadata lacks its shortname"
    grep -q '^launch: jupiter-retroarch -L fceumm "{file.path}"$' "$md" \
      || fail "nes metadata lacks the catalogue launch line"
    grep -q '^file: Starlit Vault (USA).nes$' "$md" \
      || fail "nes metadata lacks an explicit game file entry"
    if grep -q '/var/lib/' "$md"; then fail "absolute path leaked into the launcher DB"; fi
    echo "smoke: generated nes metadata carries catalogue launch line + relative files"

    # P6-critic carry-in (P7): enrichment demonstrated END TO END. The
    # stubbed Skyscraper cache carries description TEXT keyed by ROM
    # sha1; the scrape ingest landed it in games.description and this
    # generation must have emitted it verbatim into the served file.
    grep -q '^description: stubbed description of Starlit Vault \(USA\)$' "$md" \
      || fail "served metadata lacks the ingested description — enrichment is not wired end to end"
    echo "smoke: scraped cache description reached the served launcher DB (enrichment e2e)"

    # Byte stability: regenerating over unchanged state must reproduce
    # identical bytes (kiosk re-reads stay cheap; AC-5).
    h1=$(sha256sum "$md" | cut -d' ' -f1)
    curl -s -o /dev/null -H "$HX" -X POST "$base/generate"
    h2=$(sha256sum "$md" | cut -d' ' -f1)
    [ -n "$h1" ] && [ "$h1" = "$h2" ] || fail "generation not byte-stable ($h1 vs $h2)"
    echo "smoke: regeneration byte-stable (sha256 unchanged)"

    # The run is recorded and self-validated (the strict parser gate ran
    # before anything was renamed).
    status=$(curl -sf "$base/partials/status" || true)
    grep -q '<td>generate</td>' <<<"$status" || fail "generate run not recorded in the audit trail"
    # A run row spans six template lines; the detail cell is the sixth
    # (-A6 reaches it from the kind cell).
    grep -A6 '<td>generate</td>' <<<"$status" | grep -q 'validated' \
      || fail "generate run detail does not show the validation verdict"
    echo "smoke: generate run recorded + strict-parser validated"

    # ---- P7: curation ----
    #
    # Hide/show through the REAL toggle endpoint (the affordance an
    # operator clicks), replacing the P6 smoke's direct sqlite seeding.
    # The regeneration each mutation triggers runs asynchronously through
    # the shared pipeline slot, so an immediate Regenerate may honestly
    # 409 — gen_now retries exactly like an operator's second click.
    gen_now() {
      local attempt code
      for attempt in 1 2 3 4 5; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/generate")
        case "$code" in
          200) return 0 ;;
          409) sleep 2 ;; # the async curation regen still holds the slot
          *) fail "POST /generate -> $code, want 200" ;;
        esac
      done
      fail "POST /generate kept answering $code (async regen never freed the slot)"
    }

    echo "smoke: P7 hide/show via the toggle endpoint"
    page=$(curl -sf "$base/library?q=Mecha&system=nes" || fail "GET /library?q=Mecha")
    mhref=$(awk '
      /class="gcard" href="/ { match($0, /href="[^"]*"/); h = substr($0, RSTART + 6, RLENGTH - 7) }
      /gcard-title" title="Mecha Garden/ { print h; exit }
    ' <<<"$page")
    [ -n "$mhref" ] || fail "no Mecha Garden card link found for the hide step"
    case "$mhref" in /systems/nes/games/*) ;; *) fail "hide target href '$mhref' is not a detail-route link" ;; esac
    mid=$(sed -n 's|.*/games/\([0-9]*\).*|\1|p' <<<"$mhref")
    [ -n "$mid" ] || fail "could not parse Mecha Garden id from '$mhref'"
    code=$(curl -s -o /tmp/hide.out -w '%{http_code}' -H "$HX" \
      -X POST "$base/systems/nes/games/$mid/hide")
    [ "$code" = 200 ] || fail "POST hide -> $code, want 200"
    grep -q 'Show</button>' /tmp/hide.out \
      || fail "hide response did not re-render its button flipped to Show"
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/systems/nes/games/$mid/hide")
    [ "$code" = 403 ] || fail "bare POST hide -> $code, want 403 (CSRF posture)"
    gen_now
    grep -q 'Mecha Garden' "$md" && fail "hidden game leaked into the generated file"
    curl -s -o /dev/null -H "$HX" -X POST "$base/systems/nes/games/$mid/hide"
    gen_now
    grep -q '^file: Mecha Garden (Japan).nes$' "$md" \
      || fail "unhidden game never returned to the generated file"
    echo "smoke: hide/show toggles both directions through the endpoint"

    echo "smoke: P7 custom collections CRUD + launcher surfacing"
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/collections/create")
    [ "$code" = 403 ] || fail "bare POST /collections/create -> $code, want 403"
    resp=$(curl -sf -H "$HX" --data-urlencode 'name=Kitchen quick-play' \
      --data-urlencode 'summary=pick up and play' -X POST "$base/collections/create") \
      || fail "collection create failed"
    cid=$(sed -n 's|.*href="/collections/\([0-9]*\)".*|\1|p' <<<"$resp" | head -1)
    [ -n "$cid" ] || fail "created collection id not found in the refreshed panel"

    # Members: the nes game ($gid from the P4 step) + a snes game — one
    # collection spanning TWO systems.
    page=$(curl -sf "$base/library?system=snes&q=Astral" || fail "GET snes library search")
    shref=$(awk '
      /class="gcard" href="/ { match($0, /href="[^"]*"/); h = substr($0, RSTART + 6, RLENGTH - 7) }
      /gcard-title" title="Astral Almari/ { print h; exit }
    ' <<<"$page")
    [ -n "$shref" ] || fail "no Astral Almari card link for the collection step"
    sid=$(sed -n 's|.*/games/\([0-9]*\).*|\1|p' <<<"$shref")
    [ -n "$sid" ] || fail "could not parse Astral Almari id from '$shref'"
    curl -s -o /dev/null -H "$HX" -X POST "$base/collections/$cid/add?system=nes&game=$gid"
    resp=$(curl -sf -H "$HX" -X POST "$base/collections/$cid/add?system=snes&game=$sid") \
      || fail "collection add (snes) failed"
    grep -q 'Astral Almari' <<<"$resp" || fail "added member missing from the editor panel"

    gen_now
    grep -q '^# jupiter-custom-collection' "$md" || fail "custom-collection marker missing from nes file"
    grep -q '^collection: Kitchen quick-play$' "$md" || fail "custom collection title missing from nes file"
    grep -q '^shortname: kitchen-quick-play$' "$md" || fail "custom shortname missing from nes file"
    n=$(grep -c '^launch: jupiter-retroarch -L fceumm "{file.path}"$' "$md")
    [ "$n" = "2" ] || fail "nes launch lines = $n, want 2 (main + custom block)"
    n=$(grep -c '^file: Starlit Vault (USA).nes$' "$md")
    [ "$n" = "2" ] || fail "starlit entries = $n, want 2 (main + custom membership)"
    awk '/^shortname: kitchen-quick-play$/{k=NR}
         /^file: Starlit Vault \(USA\).nes$/{s=NR}
         END { exit !(k && s && s > k) }' "$md" \
      || fail "member block not listed INSIDE the custom collection section"
    smd="${gamesRoot}/cartridge/snes/metadata.pegasus.txt"
    grep -q '^collection: Kitchen quick-play$' "$smd" \
      || fail "same collection name must recur in the SNES file (cross-file merge)"
    n=$(grep -c '^file: Astral Almari (USA).sfc$' "$smd")
    [ "$n" = "2" ] || fail "snes astral entries = $n, want 2 (main + custom membership)"
    status=$(curl -sf "$base/partials/status" || true)
    grep -A6 '<td>generate</td>' <<<"$status" | grep -q 'collections' \
      || fail "generate run detail does not report collection counts"
    echo "smoke: cross-system collection live in BOTH system files (+ counts in run detail)"

    # Hidden members are excluded from the custom block too; the bulk
    # show-all-hidden then restores everything in one action.
    curl -s -o /dev/null -H "$HX" -X POST "$base/systems/nes/games/$gid/hide"
    gen_now
    n=$(grep -c 'Starlit Vault' "$md")
    [ "$n" = "0" ] || fail "hidden member still listed $n time(s), want 0"
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/systems/nes/unhide-all")
    [ "$code" = 403 ] || fail "bare POST unhide-all -> $code, want 403"
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "$HX" -X POST "$base/systems/nes/unhide-all")
    [ "$code" = 200 ] || fail "unhide-all -> $code, want 200"
    gen_now
    n=$(grep -c '^file: Starlit Vault (USA).nes$' "$md")
    [ "$n" = "2" ] || fail "starlit entries after unhide-all = $n, want 2 (restored everywhere)"
    echo "smoke: hidden member excluded from collections; bulk unhide restores both surfaces"

    # Pending split: a zeroed .chd models aria2's preallocated in-flight
    # download (the rom_complete sniff's whole reason). It must scan as a
    # game, then land in a trailing "(Pending)" collection — listed but
    # NOT launchable — while the complete cue stays playable.
    head -c 1048576 /dev/zero > "${gamesRoot}/optical/segacd/Pending Planet (USA).chd"
    curl -s -o /dev/null -H "$HX" -X POST "$base/rescan"
    ok=0
    for _ in $(seq 1 60); do
      page=$(curl -sf "$base/" || true)
      if grep -q 'data-system="segacd" data-games="2"' <<<"$page"; then ok=1; break; fi
      sleep 1
    done
    [ "$ok" = 1 ] || fail "rescan never picked up the zeroed .chd as a segacd game"
    gen_now
    sd="${gamesRoot}/optical/segacd/metadata.pegasus.txt"
    [ -f "$sd" ] || fail "segacd metadata missing after regeneration"
    grep -q '^launch: jupiter-retroarch -L genesis-plus-gx "{file.path}"$' "$sd" \
      || fail "segacd metadata lacks its launch line"
    n=$(grep -c '^launch: ' "$sd")
    [ "$n" = "1" ] || fail "pending collection must carry NO launch line (found $n)"
    grep -q '# jupiter-pending-section' "$sd" || fail "pending marker missing"
    grep -q '^collection: Sega Mega CD & Sega CD (Pending)$' "$sd" \
      || fail "(Pending) collection title missing"
    grep -q '^shortname: segacd-pending$' "$sd" || fail "pending shortname missing"
    awk '/# jupiter-pending-section/{m=NR}
         /^file: Pending Planet \(USA\).chd$/{c=NR}
         END { exit !(m && c && c > m) }' "$sd" \
      || fail "zeroed .chd not listed INSIDE the pending section"
    awk '/# jupiter-pending-section/{m=NR}
         /^file: Turbo Disc \(USA\).cue$/{t=NR}
         END { exit !(m && t && t < m) }' "$sd" \
      || fail "complete cue must stay OUTSIDE (before) the pending section"
    echo "smoke: pending split live (zeroed .chd listed-not-launchable, cue still playable)"

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
    # P5: a WRITABLE copy of the fixture cache (materialized below) —
    # the stubbed Skyscraper writes db.xml into it, so a read-only store
    # path would fail exactly like D-P1f's ReadWritePaths lesson.
    skyscraperCacheDir = skyCache;
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
    #
    # P5: skyscraperPackage is the STUB (deterministic coverage flips,
    # no network — see the fixture note above); the scheduled scrape
    # stays OFF for determinism, the on-demand endpoints are what the
    # smoke drives. Screenscraper/TGDB point at /dev/null: the driver
    # reads empty creds and runs every pass, exercising the full
    # three-pass flow.
    skyscraperPackage = skyscraperStub;
    scrapeIntervalHours = null;
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
    # Screenscraper/TGDB: /dev/null = empty creds read at scrape call
    # time (paths-only discipline intact; the stub ignores them anyway).
    screenscraperCredsFile = "/dev/null";
    tgdbApikeyFile = "/dev/null";
  };

  # P5 probe: the stub journals its argv here, and the smoke greps it
  # for the game-scrape windowing proof. scratch/ exists via the
  # module's tmpfiles rule + materialize's mkdir.
  systemd.services.jupiter-arcade-webapp.environment.ARCADE_SKYSCRAPER_STUB_LOG =
    "${scratch}/skyscraper-stub.log";

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
      mkdir -p ${gamesRoot} ${datDir} ${scratch}/reports ${torrents} ${skyCache}
      cp -r ${fixture}/games/. ${gamesRoot}/
      cp ${fixture}/metadata/no-intro-dats/*.dat ${datDir}/
      # P5: the Skyscraper cache starts as a copy of the fixture's
      # synthetic db.xml files (nes 60% / snes 100% / gb 0% — the P1
      # dashboard assertions hold), then the stubbed Skyscraper rewrites
      # nes/gb/etc. with REAL sha1-keyed resources during the smoke.
      cp -r ${fixture}/metadata/skyscraper-cache/. ${skyCache}/
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
      gawk # P4: pair each library card's href with its title; P6/P7: pending-section + collection line-order checks
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
