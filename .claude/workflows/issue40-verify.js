export const meta = {
  name: 'issue40-verify',
  description: 'Adversarial verification of the issue-#40 arcade fix before deploy',
  phases: [{ title: 'Verify', detail: '5 parallel adversarial reviewers' }],
}

const SCHEMA = {
  type: 'object',
  required: ['verdict', 'findings'],
  properties: {
    verdict: { type: 'string', enum: ['PASS', 'PASS_WITH_CAVEATS', 'FAIL'] },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['severity', 'claim', 'evidence'],
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor', 'note'] },
          claim: { type: 'string' },
          evidence: { type: 'string', description: 'command + output proving it' },
          fix: { type: 'string' },
        },
      },
    },
  },
}

const COMMON = `You are an ADVERSARIAL reviewer of an uncommitted fix for jupiter-os issue #40 (Pegasus arcade broken end-to-end), repo /home/io/Projects/jupiter-os, branch arcade-pegasus-architecture. The working tree holds the fix (see 'git status'/'git diff'). Your job is to REFUTE the fix — find concrete failure scenarios, not style nits. Only report findings you can back with evidence (a command you ran, a line you quote, a spec you verified). If you cannot refute an aspect, say so. DO NOT modify the repo, europa (ssh root@10.1.1.2), or amalthea (ssh root@amalthea) — read-only. Architecture you are reviewing: each kiosk NFS-mounts europa's per-collection datasets /tank/archive/retro/games/curated/{exo-dos,exo-win3x,exo-win9x} at /mnt/europa-games/<n>, overlays each at /mnt/exo-games/<n> (upper /var/lib/exo-overlay/<n>/), Pegasus (jupiter-arcade.service, gamescope) reads game_dirs.txt written by arcade.nix's pegasus-config-seed from jupiter.arcade.gameDirs (contributed by exodos.nix), each collection root has a europa-generated metadata.pegasus.txt with 'launch: exo-launch <emu> "{file.path}"', and scripts/exo-launch.sh extracts the game zip on first run via sudo exo-extract-helper then execs dosbox/dosbox-x from the eXo/ CWD.`

phase('Verify')

const results = await parallel([
  () => agent(`${COMMON}

Dimension: NIX EVAL AND UNIT GENERATION. Verify the modules produce correct systems.
1. Run: cd /home/io/Projects/jupiter-os && make check — must pass for all hosts.
2. nix eval the amalthea config to inspect what's actually generated (use --apply; do NOT build the full system):
   - fileSystems attr names + the options/device/depends of /mnt/europa-games/exo-dos and /mnt/exo-games/exo-dos (verify lowerdir/upperdir/workdir strings, automount opts).
   - config.systemd.services."jupiter-exodos-metadata".script (or serviceConfig) — confirm all 3 exo-to-pegasus.py invocations with correct --xml/--root/--conf-name/--rewrite args and quoting (the win3x XML has a space in its name).
   - config.systemd.services."jupiter-arcade" — requires/after include jupiter-exodos-metadata.service; unitConfig.RequiresMountsFor lists the 3 merge mounts.
   - config.systemd.services."pegasus-config-seed" — wantedBy multi-user.target, script writes game_dirs.txt with the 3 /mnt/exo-games entries; check the generated game_dirs file content renders one path per line.
   - config.security.sudo.extraRules — the exo-extract-helper NOPASSWD rule exists and points at a store path ending in /bin/exo-extract-helper.
   - environment.systemPackages includes exo-launch, dosbox-staging, dosbox-x, pegasus-frontend on amalthea; pegasus-rom-launch/bubbletea absent everywhere (grep the eval'd systemPackages names).
3. Adversarial: look for eval-order traps — exodos.nix defines jupiter.arcade.gameDirs while arcade.nix has default []; does the final gameDirs eval to exactly the 3 merge mounts on amalthea? Does the overlay fileSystems 'depends' produce valid x-systemd.requires-mounts-for behavior with automounts (check the generated mount unit config via config.systemd... if reachable, else reason from nixpkgs module source)?
4. Check thebe/metis/adrastea also eval (make check covered it) and that nothing in their configs conflicts with the new exodos defaults.`,
    { label: 'verify:nix-eval', phase: 'Verify', schema: SCHEMA }),

  () => agent(`${COMMON}

Dimension: GENERATED METADATA CORRECTNESS (the files now live on europa at /tank/archive/retro/games/curated/<c>/metadata.pegasus.txt).
1. Pegasus syntax: verify no game entry contains keys Pegasus won't parse. Valid game keys: file(s), launch/command, workdir/cwd, developer(s), publisher(s), genre(s), tag(s), players, summary, description, release, rating, sort*, plus assets.<type> where <type> ∈ {boxfront/box_front, screenshot, titlescreen, logo, background, marquee, ...} and x-* custom keys. Extract the set of all keys used in each file (awk -F: over lines matching '^[a-zA-Z_.-]+:' minus continuation lines) and flag anything invalid.
2. Entry integrity: every 'game:' must be followed by exactly one 'file:' before the next 'game:'; descriptions must be single-line (no entry field bleeding). Verify counts: dos 7199 / win3x 1139 / win9x 635 games. Spot-check 3 specific games per collection (pick ones with punctuation in titles, e.g. "Ultima IV: Quest of the Avatar") — verify their file: path exists on disk AND their assets.box_front (if any) exists.
3. FALSE-POSITIVE artwork hunt: pick 10 random games with assets.box_front across collections; for each, eyeball whether the image filename plausibly corresponds to the game title (the matcher sanitizes : ' ? / to _ — a wrong match would show a different title's name). Report any mismatches.
4. COVERAGE honesty: for exo-dos count distinct sanitized stems in 'Images/MS-DOS/Box - Front' (root + region subdirs, minus -NN suffix and extension) vs games matched (3950). If >300 on-disk stems match NO game title, sample 10 unmatched stems and diagnose why (alternate titles? different sanitization? region variants?). Same quick check for win9x (505 matched vs 691 files).
5. Launch lines: exactly 'launch: exo-launch dosbox "{file.path}"' (dos) / 'exo-launch dosbox-x "{file.path}"' (win3x, win9x); confirm collection/shortname headers.
6. The win3x metadata previously had 1062 broken eXoWin3X paths — verify ZERO file: lines now contain 'eXoWin3X' (capital X) in the new files, and dos file: lines that were case-corrected (e.g. Ultima1) point at dirs that exist.`,
    { label: 'verify:metadata', phase: 'Verify', schema: SCHEMA }),

  () => agent(`${COMMON}

Dimension: LAUNCH FLOW (scripts/exo-launch.sh in the working tree + helpers in modules/desktop/exodos.nix).
1. Read scripts/exo-launch.sh fully. Trace it BY HAND for three concrete conf paths (all under a hypothetical merge mount /mnt/exo-games):
   a) /mnt/exo-games/exo-dos/eXo/eXoDOS/!dos/Ultima1/dosbox.conf
   b) '/mnt/exo-games/exo-win3x/eXo/eXoWin3x/!win3x/CasWind/dosbox.conf'
   c) '/mnt/exo-games/exo-win9x/eXo/eXoWin9x/!win9x/1994/Hyperoid (1994)/Play.conf'
   For each: what are GAMEDIR/PLATFORM_DIR/TARGET/ZIP/EXO_DIR? Verify against the REAL layout on europa (ssh root@10.1.1.2, ls the corresponding /tank/archive/retro/games/curated paths) that the derived ZIP actually exists and TARGET parent exists. Hunt for quoting bugs with spaces/parens/apostrophes in names (e.g. \"Amy's First Primer\"-style dirs, win9x GAMEDIR with spaces).
2. Extraction contract: exo-extract-helper does 'unzip -q -o \$ZIP -d \$TARGET_PARENT' then 'chown -R ... \$TARGET_PARENT/\$TARGET_NAME'. Verify for one real zip per platform (stream-list the zip's top-level entry over ssh — python zipfile via 'nix shell nixpkgs#python3' on europa or parse locally) that the zip's top-level dir EXACTLY equals TARGET_NAME derived by the script (case included!). Pay special attention: for DOS the script derives FULL_NAME from the launcher .bat but TARGET_NAME=GAMEDIR (8.3 name) — confirm zip top-level == GAMEDIR case-exactly for e.g. Ultima1 ('Ultima I - The First Age of Darkness (1986).zip') and 2 others. Flag any zip whose inner dir case differs from the !dos dir name.
3. Win9x runtime deps: verify on europa that eXo/emulators/dosbox/options9x.conf and eXo/emulators/dosbox/x98/ exist and contain the Win98 base VHD(s) referenced by a sample Play.conf's [autoexec] (read '/tank/.../exo-win9x/eXo/eXoWin9x/!win9x/1994/Hyperoid (1994)/Play.conf' [autoexec] section; resolve each .\\-relative path it mentions against eXo/ and report which exist). Check the nixpkgs dosbox-x version (nix eval nixpkgs#dosbox-x.version) vs the conf's '0.83.19' — flag if older. Check whether the autoexec uses commands (VHDMAKE, IMGMOUNT -t vhd differencing) that Linux dosbox-x supports — search dosbox-x upstream docs/source via WebSearch/WebFetch if needed.
4. PATH: the arcade session PATH is /run/current-system/sw/bin — confirm exo-launch/exo-extract-helper/dosbox/dosbox-x will all resolve there given the new module (systemPackages). Confirm the sudo NOPASSWD rule path matches what 'readlink -f \$(command -v exo-extract-helper)' would return.
5. The metadata service runs as root writing into /mnt/exo-games/<n> (overlay upper): will the generated metadata.pegasus.txt be readable by the gamer user (umask, dir modes)? And if europa's lower already has metadata.pegasus.txt (it does now), does the mtime-skip prevent a pointless upper copy?`,
    { label: 'verify:launch-flow', phase: 'Verify', schema: SCHEMA }),

  () => agent(`${COMMON}

Dimension: REGRESSIONS AND LEFTOVERS in the working tree.
1. git status + git diff --stat: enumerate every changed/deleted/renamed file. For each DELETED or MOVED file, grep the remaining tree (excluding scripts/deprecated and docs/) for references that would now dangle — nix path literals especially (a ../../scripts/<gone> in any module = eval failure; make check may not exercise every path if gated by disabled options).
2. modules/desktop/arcade.nix lost: the NFS mount of /tank/archive/retro, tmpfiles for /tmp/pegasus-cache + /var/cache/pegasus-roms, impermanence entries, emulator packages (pcem, ppsspp, pcsx2, dolphin-emu, ryubing, dosbox trio moved to exodos.nix), bubbletea build, /usr/local/bin symlinks. Hunt for anything still expecting those: grep for pegasus-cache, pegasus-roms, pegasus-torrents, /usr/local/bin, pcem, ryubing across modules/ hosts/ scripts/ (excluding deprecated). Does anything on the LIVE amalthea depend on /tank/archive/retro being mounted (ssh root@amalthea: check ha-agent config, other units referencing that path) that would break when the next deploy removes the mount?
3. dashboard-gaming.nix + gaming/console.nix: does the jupiter.gaming.console stack (enabled by dashboardGaming) install anything that referenced the removed bits? Also confirm modeSpecs 'arcade' persist entries still make sense.
4. docs/: docs/arcade-metadata-deployment.md, docs/arcade-collection-archival.md, issues/30-arcade-management-plan.md, .claude/domains/pegasus-metadata-transformation.md and GROUND-TRUTH docs reference the old architecture — confirm nothing in .claude/ or Makefile EXECUTES them (docs are fine to leave; executable hooks are not).
5. europa: hosts/europa/configuration.nix no longer imports arcade-metadata-generator.nix (file deleted). Confirm europa still evals (make check covers it) and that jupiter.services.arcadeApi doesn't reference the deleted module or scripts. Confirm nothing else in the repo references modules/services/arcade-metadata-generator.nix.
6. The gamer user: arcade.nix defines users.users.gamer with initialHashedPassword and groups; dashboard-gaming.nix also defines it (isNormalUser). Verify the merged user definition is still valid on amalthea eval (no conflicting attrs).`,
    { label: 'verify:regressions', phase: 'Verify', schema: SCHEMA }),

  () => agent(`${COMMON}

Dimension: ISSUE #40 ACCEPTANCE CRITERIA — grade the fix against the issue's own 'What done looks like' list (gh issue view 40 for full text). For each of the 6 criteria, state MET / PARTIALLY MET / NOT MET with evidence:
1. One generator (exo-to-pegasus.py) single source of truth; generate-arcade-metadata.py + pegasus-rom-launch removed or quarantined (check scripts/deprecated/, check no .nix references them).
2. Regenerated metadata for exo-dos/exo-win3x/exo-win9x: all games from platform XML, description from Notes, genre/developer/publisher/release(/players — note the XMLs have NO MaxPlayers field, only PlayMode mapped to tag: — judge whether that satisfies the spirit), resolving assets (verify a sample on europa yourself: ssh root@10.1.1.2, pick 5 random assets.* lines per collection from /tank/archive/retro/games/curated/<c>/metadata.pegasus.txt and stat them).
3. launch: lines use exo-launch <emulator> with file: = per-game conf; win9x verified as dosbox-x-based (its own flow — the 29 86Box games are SKIPPED; judge whether that's acceptable given the issue says 'verify before assuming dosbox').
4. modules/desktop/exodos.nix imported by kiosk hosts (check tcxwave-kiosk.nix imports + jupiter.exodos.enable) — deployment to amalthea is scheduled AFTER this review; grade the config readiness.
5. arcade.nix gameDirs matches what exists (now: merge mounts backed by europa datasets — the europa collections/ dir was emptied into _deprecated-issue40-20260730; verify that move happened and nothing references the old collections/ paths anymore, including the LIVE amalthea game_dirs.txt which will be overwritten by the seed on deploy).
6. On-device verification plan: not yet run (deploy pending) — list exactly what must be checked on amalthea post-deploy for criterion 6 (3 games per collection, boxart renders, boots to playable).
Also: re-read the issue's §1-§5 problem statements and check none of them still holds in the new design (e.g. §4's 'exo-launch not installed' → now in systemPackages; §1's path-contract mismatch → gone).`,
    { label: 'verify:acceptance', phase: 'Verify', schema: SCHEMA }),
])

const [nixEval, metadata, launchFlow, regressions, acceptance] = results
return {
  nixEval: nixEval ?? 'AGENT FAILED',
  metadata: metadata ?? 'AGENT FAILED',
  launchFlow: launchFlow ?? 'AGENT FAILED',
  regressions: regressions ?? 'AGENT FAILED',
  acceptance: acceptance ?? 'AGENT FAILED',
}