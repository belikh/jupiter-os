#!/usr/bin/env python3
"""arcade-webapp L3 browser lane (arcade remediation plan §6.E / W3).

Chromium-in-VM Playwright drive of the REAL dashboard served by the REAL
module inside the arcade-webapp VM harness (tests/hosts/
arcade-webapp-vm.nix). This is the only lane whose client sends exactly
what a real browser sends: htmx's native `HX-Request: true` header, real
fragment swaps, real poll timers. The lifetime-403 class (every
browser-originated mutation silently rejected because the server checked
a header htmx never sends) was invisible to every other gate BY
CONSTRUCTION — unit tests and the VM smoke replay the server's own
assumption about the browser. This lane does not assume; it drives.

Contracts asserted (task W3 / gate matrix L3):
  1. NO 4xx/5xx on ANY resource across EVERY page visit — document,
     stylesheet, script, htmx poll, /art image, click-triggered XHR.
  2. Every htmx poll panel id appears EXACTLY ONCE in the live DOM
     after at least one poll swap has landed (the swap-contract bug
     class: morph/outerHTML mistakes nest a copy of the panel inside
     itself, duplicating ids and self-amplifying triggers).
  3. At least one MUTATING button click succeeds: a real click on the
     dashboard's Rescan button whose POST /rescan response is not an
     error, and whose request provably carried the native htmx header.
  4. The library page renders at least one game card with a loaded
     image (the /art route, content-checked via naturalWidth).

Verdict: ALWAYS writes PASS or FAIL to $ARCADE_BROWSER_VERDICT
(/run/arcade-browser-verdict in the VM) and exits nonzero on FAIL — the
runNixOSTest driver asserts the file, the serial console and journal
carry the markers for humans. The wrapper service guarantees a verdict
exists even if this process dies before writing one (ADV-P1-04: a FAIL
that races its own teardown burns the driver's whole timeout
undiagnosed).

Bring-up note (run 1): never use time.sleep() while counting events —
Playwright's sync API only dispatches response/request callbacks while
the main thread is inside a Playwright call. Every wait below goes
through page.wait_for_timeout()/wait_for_* so the event queue pumps.
"""

import os
import sys

from playwright.sync_api import expect, sync_playwright

BASE = os.environ.get("ARCADE_BASE_URL", "http://127.0.0.1:8094")
VERDICT_PATH = os.environ.get("ARCADE_BROWSER_VERDICT", "/run/arcade-browser-verdict")

# Poll cadences from the templates (layout.html footer documents them):
# status-panel/system-cards every 10s, downloads-summary every 5s,
# verify-panel/downloads-panel every 2s. Waits are event-driven with
# generous caps (a 2-core VM can jitter a tick), and each polled page
# must see its swaps BEFORE the duplicate-id scan — a scan of a
# never-swapped DOM would be vacuous.
POLL_WAIT_CAP_S = 60

failures = []
bad_responses = []  # (status, method, url) for everything >= 400
poll_counts = {}  # path -> times its panel fragment was fetched
mutation_requests = {}  # path -> request headers of click-triggered POSTs


def fail(msg):
    failures.append(msg)
    print(f"ARCADE-WEBAPP-BROWSER: FAIL: {msg}")


def write_verdict(v):
    try:
        with open(VERDICT_PATH, "w") as f:
            f.write(v)
    except OSError as e:  # never hide the real failure behind the verdict write
        print(f"ARCADE-WEBAPP-BROWSER: could not write verdict: {e}")


def track_response(resp):
    url = resp.url
    path = url[len(BASE):] if url.startswith(BASE) else url
    if resp.status >= 400:
        bad_responses.append((resp.status, resp.request.method, url))
    if path.startswith("/partials/"):
        poll_counts[path] = poll_counts.get(path, 0) + 1


def track_request(req):
    if req.method == "POST" and req.url.startswith(BASE):
        path = req.url[len(BASE):]
        try:
            mutation_requests[path] = req.all_headers()
        except Exception:  # pragma: no cover - header capture is best-effort
            pass


def scan_duplicate_ids(page, where):
    """Every id in the live document must be unique. Returns the dup list."""
    dups = page.evaluate(
        """() => {
            const seen = new Map();
            for (const el of document.querySelectorAll('[id]'))
                seen.set(el.id, (seen.get(el.id) || 0) + 1);
            return [...seen.entries()].filter(([, n]) => n > 1).map(([id, n]) => id + ' x' + n);
        }"""
    )
    if dups:
        fail(f"{where}: duplicate element ids in live DOM: {', '.join(dups)}")
    return dups


def wait_for_polls(page, wanted, where):
    """Event-driven wait until every named partial has been fetched at
    least `n` times. Returns False on timeout (recorded as a failure:
    the duplicate-id scan that follows would otherwise be vacuous)."""
    deadline = POLL_WAIT_CAP_S * 1000
    waited = 0
    while waited < deadline:
        if all(poll_counts.get(p, 0) >= n for p, n in wanted.items()):
            return True
        page.wait_for_timeout(250)  # pumps the event queue
        waited += 250
    for p, n in wanted.items():
        got = poll_counts.get(p, 0)
        if got < n:
            fail(f"{where}: {p} polled {got} times, want >= {n} (scan would be vacuous)")
    return False


def load_page(page, path, selector, where):
    page.goto(BASE + path, wait_until="domcontentloaded", timeout=30_000)
    page.wait_for_selector(selector, state="attached", timeout=15_000)
    scan_duplicate_ids(page, where)


def run() -> int:
    with sync_playwright() as p:
        # Launch kwargs mirror nixpkgs' own nixos/tests/playwright-python.nix
        # at the pinned rev — channel="chromium" resolves the browser from
        # PLAYWRIGHT_BROWSERS_PATH (the in-tree playwright-driver browsers
        # linkFarm), never from a CDN download.
        browser = p.chromium.launch(channel="chromium", args=["--headless", "--disable-gpu"])
        try:
            context = browser.new_context()
            page = context.new_page()
            page.on("response", track_response)
            page.on("request", track_request)
            page.set_default_timeout(15_000)

            # ---- Dashboard: polls, panel ids, the mutating click -------
            load_page(page, "/", "#status-panel", "dashboard")
            h1 = page.locator("h1").inner_text()
            if "jupiterOS" not in h1:
                fail(f"dashboard h1 unexpected: {h1!r}")
            # >= one full 10s poll cycle on every dashboard panel before
            # the post-swap scan (status-panel, system-cards: every 10s;
            # downloads-summary: load + every 5s).
            wait_for_polls(
                page,
                {
                    "/partials/status": 1,
                    "/partials/systems": 1,
                    "/partials/downloads-summary": 1,
                },
                "dashboard",
            )
            scan_duplicate_ids(page, "dashboard after polls")

            for panel in ("#status-panel", "#downloads-summary", "#system-cards"):
                if page.locator(panel).count() != 1:
                    fail(f"dashboard: {panel} present {page.locator(panel).count()} times, want exactly 1")

            # The mutating click — THE 403 probe. A real browser click on
            # the real htmx button; the response must not be an error.
            # (If a scan happens to be running the button is disabled;
            # post-smoke it is idle, but wait for enabled anyway.)
            rescan = page.locator('button[hx-post="/rescan"]')
            rescan.wait_for(state="visible")
            expect(rescan).to_be_enabled()
            with page.expect_response(
                lambda r: r.url.startswith(BASE + "/rescan") and r.request.method == "POST",
                timeout=15_000,
            ) as resp_info:
                rescan.click()
            status = resp_info.value.status
            if status >= 400:
                fail(
                    f"mutating click POST /rescan -> {status} "
                    "(the lifetime-403 class: browser-originated mutation rejected)"
                )
            else:
                print(f"browser: Rescan click accepted (POST /rescan -> {status})")

            # Prove the click used the REAL browser contract: htmx's
            # native header. If htmx (or our bundling of it) ever stops
            # sending it, this lane must say so — the server accepting it
            # is only half the contract.
            hdrs = mutation_requests.get("/rescan", {})
            if hdrs.get("hx-request") != "true":
                fail(
                    f"POST /rescan did not carry the native htmx header "
                    f"(hx-request: {hdrs.get('hx-request')!r}) — lane is no longer proving the browser contract"
                )

            # Post-click: the swap re-rendered the panel exactly once.
            scan_duplicate_ids(page, "dashboard after rescan swap")

            # ---- Library: >= 1 game card with a loaded image ----------
            load_page(page, "/library", "a.gcard", "library")
            cards = page.locator("a.gcard")
            n = cards.count()
            if n < 1:
                fail("library renders no game cards")
            first = cards.first.locator("img.gcard-art")
            if first.count() < 1:
                fail("first library card has no /art image")
            else:
                src = first.get_attribute("src") or ""
                if not src.startswith("/art/"):
                    fail(f"library card image src {src!r} is not the /art route")
                loaded = first.evaluate("el => el.complete && el.naturalWidth > 0")
                if not loaded:
                    fail("library card image did not decode (naturalWidth 0)")
            print(f"browser: library renders {n} game card(s), art loaded")

            # ---- Remaining surfaces: panels + no-4xx + polls ----------
            load_page(page, "/verify", "#verify-panel", "verify")
            wait_for_polls(page, {"/partials/verify": 2}, "verify")
            scan_duplicate_ids(page, "verify after polls")

            load_page(page, "/downloads", "#downloads-panel", "downloads")
            wait_for_polls(page, {"/partials/downloads": 2}, "downloads")
            scan_duplicate_ids(page, "downloads after polls")

            # metadata-panel only polls while a batch runs (hx-trigger is
            # conditional); presence + uniqueness + no-4xx still hold.
            load_page(page, "/metadata", "#metadata-panel", "metadata")

            load_page(page, "/collections", "#collections-panel", "collections")
            # Let any straggler events (late polls, lazy images) flush
            # into the trackers before the final 4xx sweep.
            page.wait_for_timeout(1_000)
        finally:
            browser.close()

    if bad_responses:
        for status, method, url in bad_responses:
            fail(f"HTTP {status} on {method} {url}")
    else:
        print("browser: zero 4xx/5xx responses across every page, poll and click")

    if failures:
        write_verdict("FAIL")
        print(f"ARCADE-WEBAPP-BROWSER: FAIL: {len(failures)} assertion(s)")
        return 1
    write_verdict("PASS")
    print("ARCADE-WEBAPP-BROWSER: PASS")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run())
    except Exception as e:
        fail(f"unhandled exception: {type(e).__name__}: {e}")
        write_verdict("FAIL")
        sys.exit(1)
