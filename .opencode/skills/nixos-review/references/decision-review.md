# Decision review

Defects are objective; decisions are judgement. Review a decision by stating
it, finding its context, listing the alternatives (considered or not), and
naming the consequences — then judge whether the context still holds.

## How to critique a decision

1. **Find the record.** Check CLAUDE.md/AGENTS.md, ADRs (`docs/adr/`), README,
   commit messages, and inline comments. A decision with a written rationale
   gets a *decision review*; one with none gets a finding: "undocumented
   decision, context unknown".
2. **Apply Chesterton's fence.** You may not remove a decision you do not
   understand. Reconstruct why it exists before judging it; if the reason is
   discoverable but unwritten, that is the finding (document it), not the
   choice.
3. **Steelman first.** Write the strongest case for the current decision, then
   attack that. If the steelman survives, the decision stands.
4. **Classify reversibility.** One-way doors (disk layout, identity, encryption
   keys, data migrations, host naming) earn the hardest scrutiny and a written
   rationale. Two-way doors (module layout, CI shape, option naming) should be
   made quickly and cheaply — do not demand ceremony for them.
5. **Check consequences and fit.** Does the consequence list include the
   negative ones? Does the decision still match the current context (host
   count, team size, release pin)? Context drift is a legitimate "revisit".
6. **Verdict per decision:** `sound` (rationally defensible in context),
   `revisit` (context or alternatives changed, or consequences unmanaged), or
   `undocumented` (cannot be reviewed — record it as a decision risk).

## Catalogue

Review each decision that applies; skip with a one-line reason if not present.
"Reversibility" is one-way (1W) or two-way (2W).

### 1. Flakes at all — 2W
- **Alternatives:** channels, `system.nix` (NixOS 26.05+), npins/`fetchTarball`
  pins, flake-compat.
- **Probe:** is there a consumer-facing output or a composition problem that
  needs a flake? Upstream still calls flakes experimental; Lix froze them by
  design.
- **Review questions:** what does the flake buy here that pinning tools do
  not? Are consumers told about the lock/update discipline?

### 2. One monorepo flake vs split flakes — 2W
- **Alternatives:** one flake per host, per-package flakes, flake-parts /
  dendritic split within one lock.
- **Probe:** a giant `flake.nix` (hundreds of lines of logic) mixes entry
  point with implementation; per-package flakes multiply locks and evaluation.
- **Review questions:** is the entry point thin? Are host/package definitions
  imported from ordinary files? Does one change force a fleet-wide relock?

### 3. Single nixpkgs pin vs multiple/mixed — 2W
- **Alternatives:** one nixpkgs with `follows` everywhere; deliberate second
  nixpkgs for a specific need.
- **Probe:** `nix flake metadata --json | jq '[.locks.nodes[] | select(.locked.repo?=="nixpkgs")]'`
  — every extra instance costs eval memory and closure duplication.
- **Review questions:** is each extra instance justified in writing? Does
  unstable+stable mixing have a documented exit plan? Are `follows` complete
  or "spooky action at a distance"? Is over-following breaking a dependency?

### 4. Ref strategy — 2W
- **Alternatives:** branch ref + committed lock; tag; explicit `rev`.
- **Probe:** tags and branches can move; the lock is what actually pins.
- **Review questions:** is `flake.lock` committed and reviewed on every bump?
  Do deploy commands use mutable refs (`--refresh` / branch URL) where the
  lock is ignored? Is any CI/deploy using `--override-input` (which implies
  `--no-write-lock-file`)?

### 5. Config placement: module vs host file vs overlay — 2W
- **Alternatives:** enable-gated module with options; host-local config;
  overlay.
- **Probe:** copy-pasted host blocks drift; overlays change package sets
  globally and bypass option semantics.
- **Review questions:** is cross-host behaviour behind an option? Do host
  files contain shared logic? Is anything patched by overlay that should be
  an option or an `overrideAttrs` on the one package?

### 6. Package customisation: overlay vs option — 2W
- **Alternatives:** `mkPackageOption`, per-service package option, targeted
  `overrideAttrs`, overlay.
- **Probe:** a stdenv-level or widely-consumed overlay cascades rebuilds and
  makes caches miss; `doCheck = false` blankets do the same.
- **Review questions:** does the overlay touch a widely consumed package?
  Could the consumer take a package option instead? Is the override scoped to
  one package with a comment?

### 7. Microarch tuning vs cache substitution — 1W per host
- **Alternatives:** stock packages (substitutable); `gccarch-*` tuned builds
  (need matching builders + private cache).
- **Probe:** tuned derivations are absent from `cache.nixos.org`; a host that
  cannot advertise the feature cannot even fallback-build its closure.
- **Review questions:** is the tuning documented per host? Is there a builder
  and cache path that actually serves those features? Is the gain measured,
  or assumed?

### 8. Secrets: sops-nix vs agenix (+ recovery) — 1W
- **Alternatives:** sops-nix (multi-secret files, templates, rotation);
  agenix (one file per secret, minimal, SSH-native).
- **Probe:** age ciphertext is not the secret; the identity key must exist
  somewhere recoverable. Activation-time-only is non-negotiable.
- **Review questions:** where do host age keys live and are they escrowed?
  Are recipients current (placeholder keys? departed hosts?)? Is any secret
  read at eval/build time? Is rotation accompanied by `updatekeys`/`rotate`?

### 9. Disk layout and impermanence — 1W
- **Alternatives:** generated `fileSystems`; disko declarative layout;
  tmpfs/rollback roots with persistence lists.
- **Probe:** erase-on-reboot loses anything omitted; a wrong disk id wipes
  the wrong device; `neededForBoot` omissions hang stage 1.
- **Review questions:** is the persisted set complete and tested by reboot?
  Are devices by-id? Is the layout documented as intentional? Is persistence
  distinguished from backup?

### 10. Boot strategy — 1W
- **Alternatives:** systemd-boot vs GRUB; `configurationLimit` values; boot
  assessment (systemd-boot boot counting on 26.11+).
- **Probe:** unbounded entries on a small ESP; too-low limits deleting the
  rollback target; no fallback entry on a console-less host.
- **Review questions:** can the host boot the previous generation? Is the ESP
  sized for the retention? Is the boot chain tested in a VM?

### 11. Deployment topology — 2W (the rollback guarantee is 1W)
- **Alternatives:** on-host pull (host evaluates the flake); control-machine
  push (`--target-host`, deploy-rs, colmena); CI-built closure deployed by
  substitution (`--store-path`-style).
- **Probe:** each assumes something different (outbound network on the host;
  SSH + sudo; cache reachability). Mutable refs in the deploy path silently
  deploy unreviewed revisions.
- **Review questions:** does the deployed revision equal the reviewed commit?
  What is the rollback path and who can trigger it? Does any tool's
  auto-rollback get disabled without a replacement guard?

### 12. CI verification level — 2W (claims made by CI are 1W)
- **Alternatives:** eval only (`nix flake check --no-build`); build every
  host; VM boot tests; deploy from CI.
- **Probe:** eval-only green proves neither build nor boot; caches make builds
  cheap, so "expensive" rarely justifies eval-only.
- **Review questions:** what does each job actually prove? Are all hosts in
  the matrix? Are actions pinned to SHAs, permissions minimal, and privileged
  triggers (`pull_request_target`, `workflow_run`) safe?

### 13. Upgrade and rollout policy — 1W (stateful migrations)
- **Alternatives:** manual flake bumps; `system.autoUpgrade` (with
  `allowReboot`, `rebootWindow`); channel upgrades.
- **Probe:** timing and staging; kernel changes need reboot; stateful services
  migrate on package majors gated by `stateVersion`.
- **Review questions:** is `stateVersion` pinned and untouched? Is there a
  canary host? Are auto-upgrades observed, or blind? Is GC configured to
  preserve rollback targets?

### 14. Home Manager integration — 2W
- **Alternatives:** HM as a NixOS module (`useGlobalPkgs`, `useUserPackages`);
  standalone HM with its own pkgs; no HM.
- **Probe:** branch mismatch vs nixpkgs; private pkgs ignoring system
  overlays; two writers for the same files or accounts.
- **Review questions:** one owner per file/account? Branch matched to
  nixpkgs? Session variables sourced for managed shells?

## Output

For each decision: the verdict, the evidence (where it is documented or that
it is not), the alternatives and why they were or were not viable, and — for
`revisit`/`undocumented` — a remediation entry that records a decision
(document, replace, or accept with date), never a silent rewrite.

## Sources

- Nygard, "Documenting Architecture Decisions" (title/context/decision/status/
  consequences; superseded records kept): https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions (accessed 2026-09-30)
- ADR concept ("a justified design choice", trade-offs, decision log): https://adr.github.io/ (accessed 2026-09-30)
- Bezos 2015 shareholder letter (one-way vs two-way doors): https://www.sec.gov/Archives/edgar/data/1018724/000119312516530910/d168744dex991.htm (accessed 2026-09-30)
- Chesterton's fence: https://en.wikipedia.org/wiki/G._K._Chesterton#Chesterton's_Fence (accessed 2026-09-30)
- Flakes status and alternatives: https://nix.dev/concepts/flakes; Lix freeze: https://wiki.lix.systems/books/lix-contributors/page/flakes-feature-freeze (accessed 2026-09-30)
- Microarch/cache tension: nixpkgs `make-derivation.nix`; NixOS wiki, Binary Cache (accessed 2026-09-30)
- sops-nix and agenix READMEs (trade-offs, recovery): https://github.com/Mic92/sops-nix and https://github.com/ryantm/agenix (accessed 2026-09-30)
- Deployment tool semantics: https://github.com/serokell/deploy-rs, https://github.com/nix-community/colmena (accessed 2026-09-30)
- Upgrades and `stateVersion`: https://nixos.org/manual/nixos/stable/#sec-upgrading (accessed 2026-09-30)
