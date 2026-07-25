# Gaming mode — handover (open issues & how to finish)

> **Historical note (2026-07-25).** Since this handover, the `jupiter-gaming`
> session was renamed **`jupiter-steam`** and joined by **`jupiter-heroic`** and
> **`jupiter-lutris`** modes (data-driven `modes` catalogue in
> `modules/desktop/dashboard-gaming.nix`). Every reference to `jupiter-gaming.service`
> below is historical — it is now `jupiter-steam.service` with the same Steam
> Deck-UI command. The `capsh --noamb` fix documented here is unchanged and now
> also covers Heroic/Lutris (verified live on amalthea).

This doc hands off the **gaming-mode port** to the TCx Wave kiosks. The
architecture is built, committed, and proven end-to-end on **metis**,
**including** the Steam bootstrap blocker (see "OPEN ISSUE 1" below — now
**RESOLVED**, root cause was an ambient capability leak, fixed with
`capsh --noamb`). amalthea/thebe are still pending deployment (not yet
attempted this round — see "OPEN ISSUE 2").

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
| Code | committed on top of `3ce5226` — the `capsh --noamb` fix to `dashboard-gaming.nix` |
| `make check` + `make fmt-check` (touched files) | ✅ clean |
| metis | ✅ deployed; dashboard + mode-switch work both directions |
| metis gaming *session* (Steam) | ✅ **FIXED** — bwrap bootstraps, Steam UI (`steamwebhelper`) comes up and stays up |
| attic | gaming closure was pushed pre-fix; **not yet re-pushed** with this fix — amalthea/thebe would build, not substitute, until it is |
| amalthea / thebe | ⏸ **not yet deployed this round** — dashboard is unaffected, gaming session needs this fix |
| adrastea | not physically installed — will pick up the config at install time |

**The Steam `bwrap` bug is fixed.** Root cause: `pam_systemd` puts
`CAP_WAKE_ALARM` in the *ambient* capability set for any seat/VT session on
this system (confirmed on both `cage-tty1` and `jupiter-gaming` — systemic,
not something our unit config requests). Ambient capabilities survive every
fork/exec, so both the outer nixpkgs FHS-sandbox bwrap **and** Steam's own
bundled pressure-vessel bwrap inherited it and refused to start (bwrap
treats "has caps, isn't setuid" as a sandbox-escape risk). Fix: the gaming
launcher script now runs everything under `capsh --noamb --`, clearing the
ambient set before gamescope/Steam ever exec. See `dashboard-gaming.nix`'s
`gamingLauncher` for the full comment and commit history for the diagnostic
trail (verified via live capability inspection — `/proc/<pid>/status` on the
gamescope process showed the same `CapAmb` bit as cage's compositor process,
which ruled out the cap_sys_nice wrapper theory from the prior handover).

**Remaining work:** push the fixed closure to attic, then deploy
amalthea/thebe (see OPEN ISSUE 2 below — unchanged, still gated on this fix
which is now in place).

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

## ✅ OPEN ISSUE 1 — Steam won't bootstrap (RESOLVED)

**Root cause & fix:** `pam_systemd` ambient-capability leak (`CAP_WAKE_ALARM`)
into every process in the session tree, which bubblewrap treats as an unsafe
config when the process isn't setuid. Fixed by clearing the ambient set with
`capsh --noamb` before exec'ing gamescope/Steam in `dashboard-gaming.nix`'s
`gamingLauncher`. Full diagnosis below (kept for the trail — the "How to
debug" / "Likely fixes" sections describe the investigation that led here,
not remaining work).

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

### Root cause (confirmed — the prior "best understanding" below was wrong)

The previous handover guessed this was a **file-capabilities** problem
(bwrap binary with `setcap` caps but not setuid). That turned out to be a
dead end: `getcap` on every bwrap-adjacent binary on metis — the nixpkgs
`bubblewrap` package, the FHS-wrapper's hardcoded bwrap path, everything
under `/run/wrappers/bin` — came back clean. No file caps anywhere.

The actual mechanism is **ambient capabilities**, not file caps. Live
inspection (`cat /proc/<pid>/status | grep Cap`) on the running `gamescope`
process during a gaming-mode flip showed:

```
CapInh: 0000000800000000   CapPrm: 0000000800000000
CapEff: 0000000800000000   CapAmb: 0000000800000000
```

Bit 35 = `CAP_WAKE_ALARM`. The systemd unit's own `AmbientCapabilities=` is
empty (checked via `systemctl show jupiter-gaming.service -p
AmbientCapabilities`), so this isn't something our config requests. Checking
`cage-tty1`'s compositor process for comparison showed **the identical
ambient `CAP_WAKE_ALARM` bit** — proving it's `pam_systemd` doing this for
*any* seat/VT session on this system (both `cage` and `jupiter-gaming` use
the same `PAMName` + `session ... pam_systemd.so` pattern), not something
specific to gaming. Chromium (cage's payload) never notices because it
doesn't sandbox with bwrap; Steam's bundled bubblewrap does, and refuses to
run non-setuid with any inherited capability — hence "Unexpected
capabilities but not setuid, old file caps config?".

Ambient capabilities survive every fork/exec down the process tree, so this
one `CAP_WAKE_ALARM` bit reached **both** bwrap invocations in the chain:
the outer nixpkgs FHS-sandbox bwrap (`.../bubblewrap-0.11.2/bin/bwrap`,
wraps the whole Steam FHS env) and, once that layer was passed, Steam's own
bundled `srt-bwrap` (pressure-vessel, extracted from its runtime tarball at
first launch) — which is why dropping the cap_sys_nice gamescope wrapper
(commit `3ce5226`) didn't fix it: that wrapper was never the source.

### The fix

Clear the process's own ambient capability set before it execs
gamescope/Steam, so nothing downstream inherits anything. `libcap`'s `capsh
--noamb` does exactly this (verified standalone first: `sudo -u gamer capsh
--noamb -- -c 'cat /proc/self/status'` shows all-zero Cap* lines). Wired into
`dashboard-gaming.nix`'s `gamingLauncher`:

```
exec ${pkgs.libcap}/bin/capsh --noamb -- -c 'exec ${cfg.gaming.command}'
```

Verified on metis: no `bwrap: Unexpected capabilities` in the journal for
the post-fix service invocation; `srt-bwrap` (pressure-vessel) and
`steamwebhelper` (Steam's actual UI, several CEF child processes) came up
and stayed up; `~/.local/share/Steam` populated (bootstrap.tar.xz downloaded
and extracted, ~430MB). Flipped dashboard→gaming→dashboard twice, both
directions clean, cage recovered fine after the switch-triggered restart
(gotcha #3 below, unrelated to this fix).

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

1. ~~Reproduce the bwrap error on metis, diagnose, land a fix.~~ **Done** —
   `capsh --noamb` fix, see OPEN ISSUE 1 above.
2. ~~Verify on metis: gamescope stable, Steam bootstraps, flip
   dashboard↔gaming twice.~~ **Done** — verified both directions, Steam UI
   stayed up, cage recovered.
3. **Next:** push the fixed gaming closure to attic (LAN endpoint,
   `http://10.1.1.2:8080/jupiter-os` — see gotcha #4 for the one-pusher-at-a-
   time / retry-on-InternalServerError caveats), then deploy amalthea,
   verify; deploy thebe, verify (should substitute, not build, once attic has
   the new closure).
4. Consider the follow-up: drop the self-build feedback from
   `modules/core/build-machines.nix` (gotcha #1) — still open, unrelated to
   this fix.
5. Commit each fix, `git push origin main` immediately (repo convention).
