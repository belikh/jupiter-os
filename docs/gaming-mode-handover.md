# Gaming mode — handover (open issues & how to finish)

This doc hands off the **gaming-mode port** to the TCx Wave kiosks. The
architecture is built, committed, and proven end-to-end on **metis** except
for **one blocker**: Steam can't bootstrap inside the gaming session (a
Steam-on-NixOS `bwrap` issue, orthogonal to the switching design). amalthea/
thebe are deployed-pending that fix.

Read this whole doc before touching anything. It captures hard-won
operational lessons (build hangs, attic flakiness, cage-stops-on-switch) that
will cost you time if you rediscover them.

Parent context: read `CLAUDE.md` first (buildability rules, module style, the
fleet's distributed-build model). The original task brief lives in the
session that kicked this off; the design rationale and deviations are
summarised below.

---

## TL;DR — state at a glance

| Thing | State |
|---|---|
| Code | **committed + pushed** (`e63f6b2..3ce5226`, 6 commits on `origin/main`) |
| `make check` + `make fmt-check` (touched files) | ✅ clean |
| metis | ✅ deployed; dashboard + mode-switch work both directions |
| metis gaming *session* (Steam) | ❌ **blocked** — `bwrap: Unexpected capabilities but not setuid` |
| attic | ✅ metis gaming closure pushed ( substitutes fast ) |
| amalthea / thebe | ⏸ **held** — deploy after the bwrap fix (their dashboard is unaffected) |
| adrastea | not physically installed — will pick up the config at install time |

**Single biggest open issue = the Steam `bwrap` bug.** Fix that, redeploy
metis to verify, then push amalthea/thebe. Everything else is done.

---

## What was built (design summary)

Goal: a TCx Wave kiosk normally shows the Cage + Chromium dashboard; Home
Assistant can flip it to a gamescope/Steam gaming session and back.

### Architecture (deliberately NOT the archived dual-VT design)

The archived `dashboard-gaming.nix` (on `archive/full-fleet-reference`) ran
kiosk + gaming simultaneously on separate VTs (VT6/VT7) with a bespoke
`jupiter-mode` chvt tool, polkit rules, and two VT-pinned services. **The user
explicitly rejected that.** The shipped design instead uses ha-linux-agent's
existing launcher mutual-exclusion group (already implemented in
`ha-linux-agent`'s `backend-launcher`):

- `cage-tty1.service` (the dashboard) and a new `jupiter-gaming.service`
  share launcher **group `"session"`**.
- Turning either profile ON first best-effort-stops its group-mate, then
  starts the target unit. One HA switch tap flips modes.
- **No chvt, no second VT, no polkit-for-chvt.** The session is on a *shared*
  tty1 — only one of cage/jupiter-gaming is active at a time.

### Key files

- `modules/gaming/console.nix` (new, ~400 lines) — the Bazzite-style software
  stack (Steam, Proton, gamescope, gamemode, app catalogue, controllers),
  gated behind `jupiter.gaming.console.enable`. Ported from the archive;
  stock kernel + stock Mesa (ZFS/buildability). `gamingMode.enable` gates
  `jovian.steam.enable`; `gamingMode.autoStart` gates Jovian's SDDM autologin.
- `modules/desktop/dashboard-gaming.nix` (new, ~225 lines) — the integration:
  - `jupiter.gaming.console` enabled with `gpu="intel"`, `cachyOsKernel=false`,
    `mesaGit=false`, `gamingMode.enable=true`, **`gamingMode.autoStart=false`**.
  - `jupiter-gaming.service` — the gaming session as a start/stoppable
    **system** service on tty1 (PAM/logind seat via `sessionOnTty1`,
    modelled on nixpkgs' `services.cage`).
  - `gamer` user (uid 1002) + impermanence for `.steam`,
    `.local/share/Steam`, `.config/Steam`, `.config/gamescope`.
  - polkit rule granting `io` start+stop on `cage-tty1.service` and
    `jupiter-gaming.service` (the agent runs unprivileged).
  - `systemd.services.cage-tty1.conflicts = [ "jupiter-gaming.service" ]`
    backstop.
- `modules/desktop/tcxwave-kiosk.nix` — `jupiter.dashboardGaming.enable = true`
  added (all 4 kiosks, once).
- `flake.nix` — `jovian` flake input; jovian nixos module imported fleet-wide
  (inert); jovian overlay applied **only** on hosts with
  `jupiter.gaming.console.enable` (guarded with `or` for non-gaming hosts).

### Unit names (both verified, don't re-guess)

- Dashboard: **`cage-tty1.service`** — confirmed in nixpkgs'
  `modules/services/wayland/cage.nix` (`systemd.services."cage-tty1"`) at the
  pinned rev `567a49d`.
- Gaming: **`jupiter-gaming.service`** — defined in `dashboard-gaming.nix:152`.

### Deviations from the original brief (all evidence-based — read before reverting)

1. **chaotic-nyx was DROPPED.** The brief asked for both jovian + chaotic.
   Forcing chaotic to `follows = "nixpkgs"` (repo convention) caused **patch
   skew**: chaotic's mangohud override reapplied a patch nixpkgs had already
   merged → "Reversed or previously applied patch" → broke the whole closure
   (mangohud → bottles → gamescope-session → goverlay). Jovian alone covers
   the stack; chaotic's only ungated extras (`proton-cachyos`,
   `gamescope_git`) are dispensable (Steam ships Proton; jovian provides
   gamescope). The `_git` emulators/openrgb in the catalogue were switched to
   stock nixpkgs. See commit `5c70088`.
2. **Jovian mangohud fixup overlay.** Same skew class — jovian's
   `pkgs/mangohud/default.nix` backports patches (`0805396`, `2c1dc528`)
   nixpkgs has since merged. `flake.nix` restores stock nixpkgs mangohud on
   gaming hosts after applying jovian's overlay. **Drop this fixup once jovian
   upstream removes the redundant backports** (check jovian's `pkgs/mangohud`).
   See commit `ff91a50`.
3. **`gamingMode.autoStart = false` + custom `jupiter-gaming.service`.** The
   brief assumed Jovian's `gamescope-session.service` is "a real
   start/stoppable systemd unit." **It is not.** It's a *systemd user unit*
   that boots via an **SDDM autologin** into `gamescope-wayland`
   (`jovian/modules/steam/autostart.nix`). SDDM + cage both want tty1/the
   seat, so `autoStart=true` would conflict with cage and boot into gaming.
   So we keep jovian's software stack but run the session ourselves as a
   system service. This honours the user's explicit intent ("ha-agent manages
   the sessions; stop cage in gaming mode").
4. **polkit rule added** (commit `2d7aebb`) — without it the launcher switch
   silently no-ops (agent runs as unprivileged `io`).
5. **gamescope launcher uses the plain system gamescope**, NOT jovian's
   `cap_sys_nice` wrapper at `/run/wrappers/bin/gamescope` (commit `3ce5226`).

---

## ✅ Verified working on metis (commit `3ce5226`)

- `make check` passes for every registered host; touched files pass
  `nixfmt-rfc-style --check`.
- metis closure builds and `nixos-rebuild switch` succeeds.
- **Mode switch, dashboard → gaming**: publish `ON` to
  `ha-linux-agent/metis/cmd/launcher_gaming` → cage-tty1 stops,
  `jupiter-gaming` starts, **gamescope + Xwayland launch and render**
  (confirmed live processes + the gamer's PAM session).
- **Mode switch, gaming → dashboard**: publish `ON` to
  `ha-linux-agent/metis/cmd/launcher_dashboard` → jupiter-gaming stops,
  cage-tty1 restarts, chromium renders.
- HA discovery entities appear on the broker (`callisto:1883`):
  `homeassistant/switch/metis_launcher_dashboard/config`,
  `homeassistant/switch/metis_launcher_gaming/config`, + paired `_active`
  binary_sensors, alongside the pre-existing `launcher_screen-power`.
- `gamer` user exists (uid 1002, groups video/render/input/audio); Steam
  impermanence mounts present (`home-gamer-.steam.mount`, etc.).
- Closure pushed to attic (`http://10.1.1.2:8080/jupiter-os`).

---

## ❌ OPEN ISSUE 1 — Steam won't bootstrap (THE BLOCKER)

### Symptom

Flip metis to gaming. `jupiter-gaming.service` starts fine, gamescope + Xwayland
come up and render, then ~2-3s later the service exits and `Restart=always`
flaps it. The **only** non-lifecycle line in the journal is:

```
bwrap: Unexpected capabilities but not setuid, old file caps config?
```

Steam's bundled `bubblewrap` (pressure-vessel/scout runtime sandbox) refuses
to start → Steam exits with no other output → gamescope has no client → exits.
`~/.local/share/Steam` never populates (Steam never gets past its own
sandbox). NRestarts climbs indefinitely.

This is a **Steam-on-NixOS runtime issue**. It is **not** caused by the
mode-switch design, the cage handoff, or DRM master (gamescope *does* get DRM
master and renders). It would hit any Steam launch in this environment.

### What I already tried (don't redo)

| Attempt | Result | Commit |
|---|---|---|
| jovian's `cap_sys_nice` gamescope wrapper (`/run/wrappers/bin/gamescope`) | bwrap error + SIGSEGV in `.gamescope-wrapped` | — |
| Set `XDG_RUNTIME_DIR` + `DBUS_SESSION_BUS_ADDRESS` in the launcher | Stopped the segfault; gamescope stable; **bwrap error persists** | `36f45f5` |
| Use **plain** system gamescope (drop the cap_sys_nice wrapper) | bwrap error **still** persists → caps aren't coming from gamescope | `3ce5226` |

So: the capabilities bubblewrap complains about are **not** inherited from
the gamescope wrapper.

### Root cause (best understanding)

bubblewrap prints *"Unexpected capabilities but not setuid, old file caps
config?"* when **the bwrap binary it's running has file capabilities set
(via `setcap`) but is NOT setuid root** — bubblewrap treats that as an unsafe
config and exits. NixOS's own `/run/wrappers/bin/bwrap` **is** setuid (via
`security.wrappers`), so if that were the bwrap in use, there'd be no error.
→ Steam is almost certainly invoking a **bundled bwrap** (from its own
runtime tarball) that carries file caps but isn't setuid.

### How to debug (ranked)

Reproduce first, then isolate. SSH to metis, flip to gaming, then read the
journal:

```bash
# from a machine with the mqtt pw (sops secret mqtt_homeassistant)
mosquitto_pub -h 10.1.1.3 -u homeassistant -P "$PW" \
  -t 'ha-linux-agent/metis/cmd/launcher_gaming' -m ON
ssh root@metis.localdomain 'journalctl -u jupiter-gaming.service -o cat --since "30s ago" | grep -vE "session opened|Started|Deactivat|Scheduled"'
```

Then rank these hypotheses:

1. **Which bwrap is failing?** It's almost certainly Steam's bundled one, but
   confirm. As `gamer`, trace a launch:
   ```bash
   ssh root@metis.localdomain 'sudo -u gamer -i XDG_RUNTIME_DIR=/run/user/1002 \
     strace -f -e execve -o /tmp/bwrap.trace steam -gamepadui' 2>&1 | tail
   grep -i bwrap /tmp/bwrap.trace
   ```
   Find the exact bwrap path + check `getcap <path>` and `ls -la <path>`.
2. **System bwrap setuid sanity**: `ls -la /run/wrappers/bin/bwrap` (should
   be setuid root), `getcap $(readlink -f $(which bwrap))`. Confirm
   `security.wrappers.bwrap`/bubblewrap is in the closure.
3. **unprivileged user namespaces**: `sysctl kernel.unprivileged_userns_clone`
   (expect 1). If 0, bwrap falls back to needing setuid.
4. **Can Steam run at all outside gamescope?** Quick isolation: temporarily
   run steam directly (not via the jupiter-gaming service / gamescope), e.g.
   `sudo -u gamer -i steam` inside an existing Cage session or a `machinectl
   shell`. If it fails the same way, the bug is Steam-on-NixOS, not our
   service.
5. **Check the steam wrapper for caps**: `getcap` on the `programs.steam`
   wrapper binary. Steam's own wrapper could be the caps source.
6. **Search upstream**: nixpkgs issues + NixOS discourse for
   `"bwrap: Unexpected capabilities"` + steam/pressure-vessel. This is a
   known friction area; there may be a `programs.steam` option or a
   recommended `security.wrappers`/bubblewrap fix.

### Likely fixes to try (in order)

a. **Force Steam to use the system setuid bwrap** — e.g. via
   `security.wrappers.bwrap` (ensure it exists) and/or a Steam env var
   (`STEAM_RUNTIME`/pressure-vessel config) that points at the system bwrap.
b. **Strip file caps from Steam's bundled bwrap** at install (a
   `programs.steam`/steam derivation overlay) — heavier.
c. If it turns out to be the **steam wrapper** carrying caps, rebuild the
   wrapper without them.
d. As a last resort, disable Steam's sandbox
   (`pressure-vessel`/`STEAM_RUNTIME`) — loses containerisation but proves
   the path; not a real fix.

**When you fix it:** verify the full flow on metis (gamescope stable, Steam
bootstraps — `~/.local/share/Steam` populates, a steam UI process stays up),
flip to dashboard and back, **then** proceed to amalthea/thebe.

---

## ⏸ OPEN ISSUE 2 — amalthea & thebe deployment (held)

Held per the brief's gate ("don't touch them until metis has proven the
design works end-to-end") **and** because their gaming session would hit the
same bwrap bug. Their **dashboard is unaffected** by the change.

### To deploy them (after the bwrap fix)

The closure is already in attic, so they'll **substitute, not build** (fast,
low memory risk). For each host:

```bash
HOST=amalthea   # then thebe
ssh root@$HOST.localdomain \
  'rm -rf /root/jupiter-os && \
   git clone --depth 1 https://github.com/belikh/jupiter-os.git /root/jupiter-os && \
   cd /root/jupiter-os && git log --oneline -1'
```

Then run the rebuild with the **single-callisto dispatch** (see "build hang"
gotcha below — the default multi-builder dispatch hangs):

```bash
ssh root@$HOST.localdomain 'cd /root/jupiter-os && \
  systemd-run --unit=jupiter-rebuild --working-directory=/root/jupiter-os \
  --setenv=NIX_CONFIG="max-jobs = 0
builders = ssh-ng://root@10.1.1.3 x86_64-linux /run/secrets/nix_build_ssh_key 6 2 gccarch-btver2,gccarch-skylake,big-parallel - -
builders-use-substitutes = true" \
  -- bash -lc "nixos-rebuild switch --flake .#'"$HOST"'"'
```

Poll:
```bash
ssh root@$HOST.localdomain 'systemctl is-active jupiter-rebuild.service; \
  journalctl -u jupiter-rebuild.service --no-pager -n 2 | tail -c 200'
```

After switch, **verify cage is up** (see gotcha) and run the same HA flip test
as metis (the MQTT topics use the host name, e.g.
`ha-linux-agent/amalthea/cmd/launcher_gaming`).

`adrastea` is not physically installed; it will pick up the gaming config
automatically whenever it's installed (its sops key/disk are still
placeholders).

---

## ⚠️ Known operational gotchas (each cost real time this session)

### 1. The distributed build HANGS with the default config (use the workaround)

The fleet's `modules/core/build-machines.nix` lists **every kiosk including
the building host itself** in `/etc/nix/machines`, and `nix.conf` has
`max-jobs = auto`. On a 7.6 GB kiosk this creates a **self-build feedback
loop** (`nix __build-remote` SSHes back to `metis.localdomain`) that
intermittently **deadlocks** — the build freezes, all builders go idle, the
nix process blocks on `anon_pipe_read`. Happened twice here.

**Workaround** (used for all successful builds): override dispatch to
**callisto only** + `max-jobs=0` via `NIX_CONFIG` (see the deploy command
above). This both avoids the self-build deadlock AND keeps the 7.6 GB kiosk
out of the compilation path (the kiosk coordinates; callisto's 64 GB does the
work).

**Real fix to consider separately** (out of scope for the gaming task): either
drop the building host from its own `/etc/nix/machines`, or set
`nix.settings.max-jobs = 0` on the kiosks (they should distribute, not build
locally), or both. File a follow-up.

### 2. Background SSH builds hang the SSH channel — use `systemd-run`

`nohup nixos-rebuild ... &` over SSH does **not** detach cleanly (the
backgrounded process's fds keep the channel open; the SSH call hangs until
timeout). Use a transient unit instead — it returns immediately and you can
poll via `systemctl`/`journalctl`:

```bash
systemd-run --unit=<name> --working-directory=/root/jupiter-os -- bash -lc '...'
```

### 3. cage-tty1.service STOPS on `nixos-rebuild switch` and doesn't come back

cage's upstream unit has `restartIfChanged = false`. When a switch changes
cage-tty1's unit file (e.g. adding the `Conflicts=jupiter-gaming.service`
here), the activation **stops** cage but does **not** restart it → the
dashboard goes dark until you `systemctl start cage-tty1.service`. This bit
the first metis switch. **Always check `systemctl is-active cage-tty1.service`
after every switch on a kiosk and restart it if down.** (Not every switch
triggers it — only ones that change cage's unit file — but check regardless.)

### 4. atticd on europa returns InternalServerError under memory pressure

europa is a 8 GB MicroServer. Pushing the large gaming closure (≈700 MB) can
trip atticd into `InternalServerError: The server encountered an internal
error or misconfiguration` (saw europa at ~5.8/7.7 Gi used). `attic push` is
**idempotent** — just re-run the same command; it skips everything already
uploaded and sweeps up the remainder (the re-push here was near-instant and
exit 0). Keep pushers to **one at a time** (concurrent pushes have wedged
atticd before). And **always clean up the push token** from the kiosk
afterward (`rm -rf /root/.config/attic`).

### 5. Don't trust a piped command's exit code

`cmd | tail -N` masks the real exit code. Verify by checking live state
(`systemctl is-active`, `readlink -f /run/current-system`, `journalctl`)
rather than `$?` alone.

### 6. MQTT topic wildcards over nested SSH break

`mosquitto_sub -t 'homeassistant/+/metis_launcher_+/config'` errors over SSH
(the `+` gets mangled). Use `-t 'homeassistant/#'` and grep the output.

---

## 🔑 Credentials / endpoints (all already wired)

- **MQTT broker**: `10.1.1.3:1883` (callisto). Users: `homeassistant`
  (`readwrite #`) and `ha-linux-agent` (scoped). Passwords are sops secrets
  `mqtt_homeassistant` / `mqtt_ha_linux_agent` in `secrets/secrets.yaml`.
  Decrypt locally:
  ```bash
  SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
    nix run --inputs-from . nixpkgs#sops -- -d \
    --extract '["mqtt_homeassistant"]' secrets/secrets.yaml
  ```
- **mosquitto_cli on callisto**: `/nix/store/p80jdv378jxpxd5xn36i6rirzcl5n4z9-mosquitto-2.1.2/bin/mosquitto_{pub,sub}`
  (path may change with nixpkgs; `find /nix/store -maxdepth 1 -iname '*mosquitto*' -type d`).
- **attic (LAN)**: `http://10.1.1.2:8080/jupiter-os` (europa). Push token is
  in the admin's `~/.config/attic/config.toml` (`[servers.jupiter]`). The
  Cloudflare endpoint (`attic.jupiter.au`) **524-times-out** on large NARs —
  always use the LAN endpoint for pushes.
- **SSH**: `root@{amalthea,thebe,metis}.localdomain` (mDNS) and
  `root@10.1.1.3` (callisto, no DNS), all passwordless. `adrastea.localdomain`
  does not resolve.

---

## Repo state

- Branch `main`, HEAD `3ce5226`, in sync with `origin/main`.
- 6 commits for this feature: `a7410e1` (initial port) → `5c70088` (drop
  chaotic) → `ff91a50` (mangohud fixup) → `2d7aebb` (polkit) → `36f45f5`
  (XDG_RUNTIME_DIR) → `3ce5226` (plain gamescope).
- Working tree has **pre-existing untracked files you must NOT touch**:
  `intel-amt-linux` (submodule), `.claude/`, `audit.log`,
  `docs/recap_20260713.html`, `modules/services/dmt-console.nix`,
  `scripts/fleet-build-status.sh`. Don't stage these.
- `modules/common.nix` has a **pre-existing** `nixfmt` nit (untouched, out of
  scope). All gaming files pass `nixfmt-rfc-style --check`.

---

## Suggested finish line

1. Reproduce the bwrap error on metis, run the ranked diagnostics, land a
   fix (system setuid bwrap / force system bwrap on Steam is the prime
   suspect).
2. Verify on metis: gamescope stable, Steam bootstraps (`~/.local/share/Steam`
   populates, a steam UI process persists), flip dashboard↔gaming twice.
3. Deploy amalthea, verify; deploy thebe, verify (substitutes from attic).
4. Consider the follow-up: drop the self-build feedback from
   `modules/core/build-machines.nix` (gotcha #1).
5. Commit each fix, `git push origin main` immediately (repo convention).
