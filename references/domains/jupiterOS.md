# jupiterOS (NixOS Infrastructure)

**Scope:** NixOS/jupiterOS infrastructure changes. Covers new modules, flake inputs, secrets handling, cross-host wiring, and deployment verification. Detects violations of the 5 buildability rules (no custom ZFS kernels, justified flake inputs, no cross-host wiring until both ends registered, plain `nix flake check` cache-buildability, activation-time-only secrets).

## Evidence (open every time)

- `CLAUDE.md` (buildability rules §1-5, module conventions §6-7)
- `flake.nix` (inputs block, mkHost, nixosConfigurations keys, extraModules mechanism)
- `Makefile` (targets: make check, make build-all, make pallene-iso)
- `.sops.yaml` (registered vs unregistered hosts, real vs placeholder age keys)
- `git log --oneline` (commit history for pattern reference)
- `modules/core/build-machines.nix` (house style skeleton)
- `modules/services/mqtt.nix` (options.jupiter.*, cfg binding, lib.mkIf guard, sops secrets)
- `memory/` directory (field-tested traps: pallene attic failure modes, kiosk OOM, thebe wifi, nmcli autoconnect bypass, deployment vs assertion)

## Authority

- **sops-nix activation-time secrets:** https://github.com/Mic92/sops-nix/blob/master/README.md — secrets decrypted only in nixos-rebuild switch activation phase, not at build/eval time
- **NetworkManager WiFi/PSK via nm-file-secret-agent:** nixpkgs option `networking.networkmanager.ensureProfiles.secrets` (https://search.nixos.org/options) — modern method avoids baking secrets in store
- **ZFS kernel compatibility:** https://wiki.nixos.org/wiki/ZFS — must use stock linuxPackages default or explicitly pin; unsupported kernels fail evaluation
- **disko/impermanence:** https://wiki.nixos.org/wiki/Impermanence — declarative disk layouts + erase-on-reboot; integration requires both modules in nixosSystem
- **attic binary cache:** https://docs.attic.rs/tutorial.html — self-hosted Nix binary cache; verify substitutability on target host, not just push exit-code
- **nixpkgs option docs:** https://search.nixos.org/options — authoritative for all `jupiter.*` and system options; always prefer documented nixpkgs options over hand-rolled patterns

## Workflow

### Step 1: Classify and scope the change
- Read the git diff or proposed code/doc change
- Name: is this a new module, modification, doc fix, or configuration override?
- Scope: which registered hosts does this affect?
- Consequence: will this affect host startup, package closure, secrets handling, or physical hardware access?

### Step 2: Establish host state empirically
- For each affected host, check physical/live status: `ping`, `ssh root@hostname`, static IP assignments
- Check CLAUDE.md "Current state" section but verify against reality (see memory: `jupiter_os_not_deployed.md`)
- For kiosks (amalthea, thebe, metis, adrastea): mDNS hostname + dynamic DHCP
- For europa/callisto: static IP (10.1.1.2 and 10.1.1.3 respectively) + no DNS yet
- Check if a host's sops key in `.sops.yaml` is real or placeholder (adrastea, metis pre-2026-07-24 had placeholders)
- **GATE:** FAIL if a host is assumed live when sops key is placeholder, or assumed placeholder when actually live

### Step 3: SEARCH the internet for the modern canonical method ← CRITICAL STEP
- If adding a new service/daemon: web-search for accepted NixOS module pattern in 2026 (not archive/old-tree patterns)
- If adding secrets: SEARCH `sops-nix activation time secrets` + `networking.networkmanager.ensureProfiles.secrets` (do NOT hand-roll envsubst/environmentFile hacks)
- If adding networking: SEARCH `NetworkManager configuration NixOS` + specific subsystem (WiFi PSK, wireguard, static IP)
- If adding ZFS-related config: SEARCH `ZFS kernel compatibility nixpkgs` (do NOT assume linuxPackages_latest is safe)
- If adding disko/impermanence: SEARCH `disko impermanence NixOS root configuration` (understand erase-on-reboot layout)
- Record the source URL and exact option name/nixpkgs location for your authority section
- **GATE:** FAIL if module tries hand-rolled secret injection, custom kernel on ZFS, or violates CLAUDE.md buildability rules 1 or 5

### Step 4: Locate module extension point and read house style
- If new service module: check `modules/services/`, `modules/desktop/`, `modules/gaming/`, `modules/network/`, `modules/core/` for category
- Read one existing module in that category (e.g. `mqtt.nix`, `build-machines.nix`) for skeleton: `options.jupiter.*` → cfg binding → `config = lib.mkIf cfg.enable`
- Verify module uses explicit `lib.mkOption`/`lib.mkIf`/`lib.types`, NOT `with lib;`
- Check function signature: `{ config, lib, pkgs, ... }` in that order
- **GATE:** FAIL if module style does not match skeleton

### Step 5: Check cross-host wiring gates
- If wiring to another host (PXE on europa, MQTT on callisto, build delegation): `grep hosts/*/configuration.nix` for consumption
- Verify BOTH ends registered in `flake.nix` nixosConfigurations (not just `.sops.yaml`, which includes ganymede/himalia)
- Verify BOTH ends physically live or documented as intentional placeholders
- Example: callisto's iSCSI root target on europa's zfs-nas module; both registered and live ✓
- **GATE:** FAIL if cross-host wiring reaches unregistered host or assumes placeholder is live

### Step 6: Write module in house style and test flake evaluation
- If new flake input: `grep` entire `hosts/` + `modules/` tree for actual usage
- Verify usage appears in at least one nixosConfigurations host (not just a URL comment)
- Run `make fmt` (nix fmt) to normalize style
- Run `make check` (`nix flake check --no-build`) to verify all registered hosts still eval
- **GATE:** FAIL if `make check` fails, or new flake input has no consumer host, or large closure lands on kiosk

### Step 7: Verify secrets are activation-time only and gated by real host age key
- If using sops secrets: every `sops.secrets.*` declaration gated inside `config = lib.mkIf cfg.enable { ... }`
- Grep for `builtins.readFile` / environment variable expansion of secret paths at build time (forbidden)
- If module applies to specific host (e.g. thebe WiFi PSK): check host's `.sops.yaml` recipient age key is real, not placeholder
- Verify secret's owner/permissions match consumer service
- **GATE:** FAIL if secret read at build/eval time, or host's sops key is placeholder but config assumes live

### Step 8: Deploy and verify by observation
- If daemon/service: restart service and check `systemctl status` / logs on live host (not VM)
- If WiFi/network: do NOT use `nmcli connection up` to verify autoconnect (bypasses actual check); restart NetworkManager and passively poll `nmcli device status`
- If build machine: verify it receives work via nix build logs for `delegation to X` messages
- If pushing closure to attic: check host can actually substitute from attic (not just push exit-code — atticd can wedge silently)
- If large build on kiosk: route off-kiosk via callisto or skip kiosk entirely
- **GATE:** FAIL if observed behavior does not match expected

### Step 9: Commit, push, and report outcome-first
- Verify `git status` is clean and all changes staged
- Commit with clear message (describe WHY, not just WHAT)
- `git push` to remote immediately (repo convention: every commit pushed)
- Report: what changed, which hosts/subsystems affected, what was verified empirically (separate from assumed)

## Workflow Flowchart

```
Classify → Empirically establish host state
  ↓ (Placeholder key?)
  FAIL: host not live
  ↓ (Live confirmed)
SEARCH for canonical method
  ↓ (Blessed nixpkgs option exists?)
  FAIL: hand-rolled pattern
  ↓ (Yes)
Read house-style module skeleton
  ↓
Locate extension point
  ↓ (Cross-host wiring?)
  Yes → Both ends registered + live?
    ↓ (No)
    FAIL: unregistered/placeholder
    ↓ (Yes)
    Write module in style
  No → Write module in style
  ↓
make fmt && make check
  ↓ (Fails)
  FAIL: eval error
  ↓ (Passes)
New flake input?
  ↓ (Yes)
  Grep consumer in nixosConfigurations
    ↓ (No consumer)
    FAIL: unjustified input
    ↓ (Found)
  No ↓
Verify secrets activation-time only
  ↓ (Reads at build time)
  FAIL: secret at eval
  ↓ (Activation-time only)
Deploy to live host
  ↓
Verify by observation
  ↓ (Tests pass)
  Commit + push + report
    ↓
    PASS: Outcome-first report
  (Tests fail)
  ↓
  FAIL: unverified behavior
```

## Fraud Table (Prevention)

| Fraud | Rule Violated | Scenario 0 (Trap) | Scenario 1 (Partial) | Scenario 2 (Correct) |
|-------|---------------|-------------------|----------------------|----------------------|
| **Unjustified flake input** | Rule 2 | New input added, no host uses it. Build succeeds locally but fails fleet-wide. **Catch:** grep flake.nix inputs + grep nixosConfigurations for reference. | Input added, but old violation unfixed in sibling. Option description says "for readability" without constraint. | Input used in at least one host (confirmed grep). Comment explains why. `make check` verifies. |
| **Custom kernel on ZFS host** | Rule 1 | `boot.kernelPackages = pkgs.linuxPackages_latest` on europa. Build fails: ZFS eval error "unsupported kernel version". **Catch:** grep hosts/ for kernelPackages on ZFS hosts. | Kernel pinned, but option description omits ZFS constraint; future dev re-introduces trap. | Stock linuxPackages default or explicit compatible pin. Comment cites ZFS docs. |
| **Secret read at build time** | Rule 5 | `builtins.readFile` on sops path during eval. `nix flake check` fails immediately: secret not materialized. **Catch:** `make check` error names secret file. | Secret gated, but racy EnvironmentFile + ExecStartPre instead of native `.secretFile` option. | Uses modern NixOS method (e.g. `ensureProfiles.secrets` for NetworkManager). Cites upstream option docs. |
| **Placeholder age key implies live** | CLAUDE.md Current state | Developer assumes himalia is registered (has .sops.yaml key) → adds himalia to config. Later `nix build .#himalia` fails. **Catch:** grep .sops.yaml keys vs flake.nix nixosConfigurations. | Developer sees adrastea has age key but .sops.yaml warns "placeholder" — realizes before deploy. | Real SSH-derived age key captured. `.sops.yaml` comment + physical host status verify. |
| **Deployment verified by assertion** | Memory: test-dont-assert | Developer commits WiFi with wrong key-mgmt, tests via `nmcli connection up` (bypasses autoconnect matching). Reports verified. Clean reboot: never autoconnects. **Catch:** restart NetworkManager + passively poll, not forced activation. | Build succeeds, asserts verified based on `nix flake check` (eval-only). Later delegation times out (ssh key missing). | Actual deployment observed: service logs, attic substitutability check, network autoconnect via passive polling. |
| **attic push exit-0 ≠ cached** | Memory: pallene-push-path | Developer runs `attic push` on pallene, sees exit 0. Later: host hangs on substitution (mesh TCP drop or atticd wedge). **Catch:** verify substitutability by running `nix build` on LAN host pointing at `10.1.1.2:8080`. | Push from thebe (LAN) uses `attic.jupiter.au` endpoint (tunnel 524 timeout on large NARs). Retries with correct IP. | Push + status query + successful retrieval. Push endpoint matches network location (LAN uses `10.1.1.2:8080`). |
| **Heavy build routed to kiosk** | Memory: kiosk-build-oom | Developer adds uncached private Rust workspace. Kiosks attempt build locally via `nixos-rebuild switch`. metis OOM-kills mid-rebuild. **Catch:** check if local build would be forced; if so, build once off-kiosk + attic push. | Developer uses `--build-host root@10.1.1.3` on metis. Fails (uses user's SSH key, not nix daemon key). Falls back to local build, OOM. | Routes build to callisto via `nix.buildMachines`. callisto builds, kiosk substitutes. Deployment succeeds. |

## Sources

- CLAUDE.md (repo root) — buildability rules, module conventions, git push discipline
- flake.nix (repo root) — registered hosts, inputs, mkHost lexical closure
- memory/ directory — concrete incidents: attic wedge, kiosk OOM, thebe WiFi multi-fix, nmcli autoconnect bypass, documentation staleness
- git log --oneline (repo history) — d6a7642, cb68618, 061bdb9 (thebe WiFi fix chain); c994493 (hashedPasswordFile pattern); ba62703 (revert analysis)
- nixpkgs documentation (https://search.nixos.org/options) — authoritative option names, canonical service patterns
- Modern NixOS guides (2025-2026) — sops-nix activation-time secrets, NetworkManager ensureProfiles.secrets, ZFS kernel support, disko/impermanence integration
