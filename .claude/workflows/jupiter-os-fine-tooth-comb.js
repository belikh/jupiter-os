
export const meta = {
  name: 'jupiter-os-fine-tooth-comb',
  description: 'Comprehensive multi-dimension audit of the jupiter-os NixOS monorepo',
  phases: [
    { title: 'Review' },
    { title: 'Verify' },
    { title: 'Synthesize' },
  ],
}

const CONTEXT = `
jupiter-os is a declarative, ZFS-backed NixOS monorepo, currently being rebuilt from scratch
one machine at a time (previous full tree lives on archive/full-fleet-reference and was never
fully buildable -- do not treat patterns copied from it as automatically correct).

Registered hosts (in flake.nix nixosConfigurations): amalthea, thebe, metis, adrastea (4 TCx Wave
kiosks sharing modules/desktop/tcxwave-kiosk.nix), europa (ZFS NAS + PXE server, live, full
bdver4-tuned closure), callisto (shared Nix remote builder + MQTT broker, live with persistent
iSCSI root on europa's zvol, i5-8500T, 64GB RAM), pallene (ephemeral BinaryLane build-server ISO
host, phase 2 only). NOT yet registered in flake.nix despite having .sops.yaml age keys: ganymede,
himalia (roadmap hosts only -- this is intentional per CLAUDE.md, not a bug, but flag if any
module assumes they exist).

Known current state facts (treat as ground truth, flag any code/docs that contradicts them):
- adrastea is registered/CI-green but still has a placeholder disko diskId ('REPLACE-ME') and a
  placeholder (non-SSH-derived) sops age key -- not yet physically installed.
- metis has a real disk and real age key (fixed 2026-07-24).
- callisto is live at 10.1.1.3, ext4 root over iSCSI, jupiter.build.microarch = 'skylake' is a
  ROADMAP-ONLY setting -- pallene must build+push the skylake closure to attic before callisto's
  next nixos-rebuild takes effect. The running closure is stale relative to git HEAD.
- europa Stage 4 (bdver4 tuned closure, substituting from its own Attic) is done; stages 2 and 5
  remain, are independent cleanup, not blockers.
- MQTT broker lives on callisto (modules/services/mqtt.nix), moved from amalthea 2026-07-24.
  Kiosks address it via a static 10.1.1.3 IP literal (no DNS/mDNS yet) -- this is intentional,
  not a bug, but any OTHER hardcoded-IP pattern should be scrutinized.
- PXE serving for callisto's netboot lives on europa (modules/network/pxe-server.nix), wired via
  flake.nix's pxeModule extraModules mechanism -- ganymede's role in the old design, deliberately
  moved since ganymede isn't registered yet.

Buildability rules (the reason this rebuild exists -- violations are high-severity findings):
1. No custom kernels on ZFS hosts -- must use stock linuxPackages default (the one ZFS always
   supports and cache.nixos.org always has built).
2. A new flake input must be justified by a registered host that actually uses it -- flag any
   flake input that no current nixosConfigurations host references.
3. No cross-host closure wiring (PXE, backup-hub scans, etc.) until BOTH ends of the wire are
   registered in flake.nix's nixosConfigurations and building.
4. Must keep building from cache.nixos.org with 'nix flake check' (europa's own btver2 Attic
   substituter is a documented, intentional exception -- not a violation).
5. sops secrets must be read at activation time, not build time -- nix build / CI / nix flake
   check must work without the age key. Flag anything that reads a secret path at eval/build time.

Module style conventions (flag violations):
- Explicit lib.mkOption / lib.mkIf / lib.types -- never 'with lib;'.
- Module function argument order: { config, lib, pkgs, ... }.
- Structure: options.jupiter.<...> = { ... }; then config = lib.mkIf cfg.enable { ... }; with
  cfg = config.jupiter.<...> bound in a let.
- New cross-host functionality belongs in modules/<category>/ gated by a jupiter.* option;
  hosts opt in via toggles, not inlined config.
- Secrets: current canonical mechanism must be used, not hand-rolled workarounds (e.g. the wifi
  PSK precedent: networking.networkmanager.ensureProfiles.secrets via the nm-file-secret-agent
  D-Bus secret agent, NOT an envsubst/systemd-hack pipeline). Flag any hand-rolled secret
  injection (custom envsubst services, plaintext fallback paths, secrets baked into the Nix store).

Your job: read the actual files named in your assignment (use Read/Grep/Bash -- this is a real
git checkout at the cwd, paths are relative to repo root), find concrete, file-and-line-anchored
defects or inconsistencies against the rules/facts above. Do NOT report stylistic nitpicks with
no functional or correctness impact. Do NOT flag the callisto-microarch-not-deployed-yet or
mqtt-hardcoded-IP or ganymede/himalia-unregistered facts above as bugs -- those are confirmed
intentional/known states. For each finding give a concrete failure scenario (what breaks, for
whom, under what condition) not just an abstract style complaint.
`

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'number' },
          category: { type: 'string' },
          severity: { type: 'string', enum: ['low', 'medium', 'high'] },
          summary: { type: 'string' },
          failure_scenario: { type: 'string' },
        },
        required: ['file', 'summary', 'failure_scenario', 'severity'],
      },
    },
  },
  required: ['findings'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    verified: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'number' },
          category: { type: 'string' },
          severity: { type: 'string', enum: ['low', 'medium', 'high'] },
          summary: { type: 'string' },
          failure_scenario: { type: 'string' },
          verdict: { type: 'string', enum: ['CONFIRMED', 'REFUTED'] },
          rationale: { type: 'string' },
        },
        required: ['file', 'summary', 'verdict', 'rationale'],
      },
    },
  },
  required: ['verified'],
}

const DIMENSIONS = [
  {
    key: 'module-style',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit module style/convention compliance across the ENTIRE modules/ tree (find modules/ -name "*.nix"; there are ~38 files across boot/, core/, desktop/, gaming/, network/, services/, storage/, plus modules/common.nix). Grep for "with lib;" (must be zero hits), check function argument order, check that each module follows the options.jupiter.<x> / config = lib.mkIf cfg.enable pattern with cfg bound in a let. Flag any module that inlines cross-host wiring instead of using a jupiter.* toggle. Flag any hand-rolled secret injection.',
  },
  {
    key: 'buildability-rules',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit the 5 buildability rules across the whole repo. Read flake.nix in full. Check every host boot.kernelPackages / any custom kernel refs (grep -r "kernelPackages\\|linuxPackages" hosts/ modules/). Check every flake input in flake.nix inputs block is actually referenced by at least one nixosConfigurations host (grep for disko/impermanence/sops-nix/ha-linux-agent/jovian/nixpkgs-unstable usage). Check for any cross-host wiring (PXE, backup scans, build delegation) where one side is a host NOT in nixosConfigurations. Check modules/core/build-tuning.nix, build-machines.nix, attic-substituter.nix for anything that would break a plain "nix flake check --no-build" without an age key or private substituter (aside from europa documented Attic-substituter exception).',
  },
  {
    key: 'secrets-sops',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit secrets/sops handling. Read .sops.yaml, and grep the whole repo for "sops." option usage (grep -rn "sops\\." modules/ hosts/) and for any hardcoded credential-shaped strings (grep -riE "password|secret|token|api[_-]?key" modules/ hosts/ --include=*.nix, excluding option names/comments -- flag only things that look like literal values, not option declarations). Cross-check .sops.yaml key list (admin_io, ganymede, europa, himalia, callisto, metis, adrastea, amalthea, thebe) against flake.nix registered nixosConfigurations -- ganymede/himalia having keys but no flake registration is EXPECTED, do not flag it. Flag: any secret read via config path that is not gated for activation-time-only, any module that would fail nix build/eval without decrypting a secret, any sops.secrets declaration whose owner/permissions look wrong for its consumer service.',
  },
  {
    key: 'storage-zfs',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit modules/storage/*.nix (nas-nfs.nix, sanoid.nix, zfs-nas.nix, zfs-profiles.nix, zfs-tuning.nix) and modules/core/impermanence.nix, plus how hosts/europa/configuration.nix, hosts/callisto/configuration.nix, and hosts/pallene/disk-configuration.nix consume them (disko layouts, zfs pool/dataset definitions, impermanence erase-your-darlings root config). Check for: impermanence + ZFS dataset interactions that could lose data on boot, zfs-profiles options that do not match what a given host actually sets, sanoid snapshot policy gaps, disko config that does not match the diskId/hostId documented for that host in CLAUDE.md.',
  },
  {
    key: 'networking',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit modules/network/*.nix (nas-bond.nix, pxe-server.nix, wireguard.nix) and modules/services/mqtt.nix. Check static IP / hostId consistency across hosts (grep -rn "10\\.1\\.1\\." modules/ hosts/), check the PXE server wiring in flake.nix (the pxeModule extraModules mechanism for europa/callisto) actually matches what modules/network/pxe-server.nix expects, check wireguard.nix key/peer handling does not bake secrets into the store. Flag any inconsistency between a host declared static IP/hostname and what other modules assume for it.',
  },
  {
    key: 'build-tuning-attic',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit the build-farm/tuning stack: modules/core/build-machines.nix, modules/core/build-tuning.nix, modules/core/attic-substituter.nix, modules/services/attic-server.nix, modules/services/harmonia-server.nix, modules/services/build-server.nix, modules/services/pallene-watchdog.nix. Cross-check against CLAUDE.md claims: callisto is tuned cores=6/max-jobs=1 (opposite of pallene cores=1/max-jobs=auto), callisto jupiter.build.microarch="skylake" is committed but the running closure is STALE (not yet deployed) -- code should reflect this is a future-effective setting, not something already substituting. europa btver2 Attic substituter should be europa-specific, not accidentally applied fleet-wide. Flag any config that would silently apply microarch tuning to a host whose actual deployed hardware does not match (would break its build).',
  },
  {
    key: 'desktop-kiosk-profile',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit modules/desktop/tcxwave-kiosk.nix, dashboard-kiosk.nix, dashboard-gaming.nix, exodos.nix, arcade.nix. These are shared by amalthea/thebe/metis/adrastea. Check the profile module correctly parameterizes per-kiosk hostName/hostId/dashboard URL/disk (no hardcoded single-host values leaking into the shared module), check dashboard-gaming.nix gamescope/Jovian integration does not assume packages not gated behind jupiter.gaming.console, check exodos.nix mergeMountBase and collection paths are consistent with docs/arcade-collection-archival.md and docs/arcade-metadata-deployment.md claims.',
  },
  {
    key: 'gaming-console',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit modules/gaming/console.nix and its flake.nix wiring (the jovian input, the "jovian nixos module is inert unless jupiter.gaming.console enabled, but the overlay is gated" claim). Read docs/gaming-mode-handover.md for the intended behavior and cross-check the module actually implements it. Known past bug: pam_systemd ambient CAP_WAKE_ALARM leak was fixed via capsh --noamb -- check that fix is actually present and not reverted/dangling. Check the overlay really is gated per-host and does not leak jovian/chaotic packages into europa/callisto closures.',
  },
  {
    key: 'services-batch-a',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit these service modules: modules/services/arcade-api.nix, cloudflare-tunnel.nix, console-screensaver.nix, customer-display.nix, customer-msr.nix, dmt-console.nix, ha-agent.nix. Check each follows the jupiter.* option-gated pattern, check ha-agent.nix MQTT broker connection correctly points at callisto (10.1.1.3) per the documented move, check cloudflare-tunnel.nix does not bake a tunnel credential into the Nix store, check customer-msr.nix (likely a card-reader / point-of-sale peripheral) for any hardware-access permission issues (udev rules, group membership).',
  },
  {
    key: 'services-batch-b',
    prompt: CONTEXT + '\n\nASSIGNMENT: Audit these service modules: modules/services/iscsi-target.nix, mqtt.nix, smart-monitoring.nix, syncthing.nix, tcxwave-power-tuning.nix, tcxwave-touch-wake.nix, vps-image-server.nix. iscsi-target.nix backs callisto persistent root (europa side) -- check LUN/IQN config matches docs/callisto-iscsi-root-provisioning.md and hosts/callisto/configuration.nix initiator side. Check mqtt.nix broker config matches what modules/desktop/tcxwave-kiosk.nix mqttHost default expects. Check smart-monitoring.nix disk-health thresholds are sane for the actual drives per CLAUDE.md/docs.',
  },
  {
    key: 'flake-outputs',
    prompt: CONTEXT + '\n\nASSIGNMENT: Deeply audit flake.nix outputs block: the mkHost function, its lexical-closure module injection (vs specialArgs -- check specialArgs is genuinely NOT used anywhere as a shortcut), the extraModules mechanism (europa pxeModule, callisto iSCSI/build wiring, any other extraModules usage), and that every host in hosts/ has a corresponding nixosConfigurations entry (or a documented reason it does not, e.g. pallene being ISO-only). Check the jovian/chaotic overlay gating described in flake.nix own comments is actually implemented as claimed (overlay only applied to hosts with jupiter.gaming.console enabled).',
  },
  {
    key: 'kiosk-hosts',
    prompt: CONTEXT + '\n\nASSIGNMENT: Read hosts/amalthea/configuration.nix, hosts/thebe/configuration.nix, hosts/metis/configuration.nix, hosts/adrastea/configuration.nix in full and diff them mentally against each other. They should all consume modules/desktop/tcxwave-kiosk.nix with per-host hostName/hostId/dashboard URL/disk overrides only -- flag any host that duplicates logic instead of using the shared profile, any drift where one kiosk config diverges in a way that looks accidental rather than intentional (e.g. thebe wifi/mt76x2u fix (see commits 061bdb9, cb68618, d6a7642) -- check it is genuinely present and consistent, not partially applied). Flag adrastea known placeholder diskId/age-key state if the code does not clearly gate/guard for it (e.g. would nixos-rebuild switch on adrastea silently brick a real disk if run today with the placeholder?).',
  },
  {
    key: 'europa-host',
    prompt: CONTEXT + '\n\nASSIGNMENT: Read hosts/europa/configuration.nix in full, plus modules/network/pxe-server.nix and any modules it imports for ZFS NAS + PXE + Attic substituter duties. Cross-check against docs/europa-bringup-stages.md, docs/europa-stage4-progress.md, and docs/europa-case-insensitive-migration.md -- does the current configuration.nix actually match what those docs claim is "done" (Stage 4 btver2 tuned closure, its own Attic substituter)? Flag any mismatch between doc claims and actual config, and any config that would only work if callisto/ganymede were already live in ways they are not yet.',
  },
  {
    key: 'callisto-host',
    prompt: CONTEXT + '\n\nASSIGNMENT: Read hosts/callisto/configuration.nix in full. Cross-check against docs/callisto-iscsi-root-provisioning.md and CLAUDE.md claims: persistent iSCSI root on europa zvol, i5-8500T/64GB RAM, cores=6/max-jobs=1 build tuning, jupiter.build.microarch="skylake" as a NOT-YET-DEPLOYED roadmap setting, MQTT broker hosting via modules/services/mqtt.nix. Flag anything where the committed config would, if deployed today via nixos-rebuild, break the live iSCSI-root machine (e.g. a microarch flag that is already active rather than staged, a disko/filesystem change that does not account for the persistent root already existing).',
  },
  {
    key: 'pallene-host',
    prompt: CONTEXT + '\n\nASSIGNMENT: Read hosts/pallene/configuration.nix and hosts/pallene/disk-configuration.nix in full, plus modules/services/build-server.nix, pallene-watchdog.nix, vps-image-server.nix which it likely uses. Pallene is described as an EPHEMERAL BinaryLane ISO host for phase-2 full-fleet rebuilds (ISO -> R2 -> BinaryLane -> attic, per "make rebuild-world"). Check the disk-configuration.nix is genuinely ephemeral/disposable (not accidentally declaring a persistent layout), check build-server.nix tuning (cores=1/max-jobs=auto, full-closure rebuild workload) matches CLAUDE.md claim, check pallene-watchdog.nix failure-recovery logic against the known push-path failure modes (mesh TCP drops, tunnel 524s on big NARs, atticd wedging -- keep ONE pusher).',
  },
  {
    key: 'docs-vs-reality',
    prompt: CONTEXT + '\n\nASSIGNMENT: Read CLAUDE.md in full (already summarized above, but re-read the actual file at repo root for exact wording) and every file under docs/ (arcade-collection-archival.md, arcade-metadata-deployment.md, callisto-iscsi-root-provisioning.md, europa-bringup-stages.md, europa-case-insensitive-migration.md, europa-stage4-progress.md, gaming-mode-handover.md, and anything under docs/plans/). For each doc, spot-check its concrete factual claims (a stage being "done", a host being "live", a specific config value) against the actual current file contents in flake.nix / hosts/ / modules/. Flag stale documentation -- claims that no longer match the code -- as findings, citing both the doc location and the contradicting code location. Also check the Makefile and .github/workflows/ci.yml for any target/step that references a host or path that no longer exists.',
  },
]

phase('Review')
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: 'find:' + d.key, phase: 'Review', schema: FINDINGS_SCHEMA }),
  (findResult, d) => {
    const findings = (findResult && findResult.findings) || []
    if (findings.length === 0) return { key: d.key, verified: [] }
    return agent(
      CONTEXT + '\n\nA prior reviewer audited "' + d.key + '" and reported these findings:\n\n' + JSON.stringify(findings, null, 2) + '\n\nYour job: adversarially verify EACH finding. Re-read the actual file(s) named, at the exact line if given. For each finding, decide CONFIRMED (the defect is real and matches the failure scenario as described) or REFUTED (the file does not say what was claimed, the "defect" is actually one of the explicitly-intentional states listed in the context above, the line/file does not exist, or the failure scenario does not actually follow). Be skeptical by default -- default to REFUTED if you cannot independently confirm the claim by reading the file yourself. Return one verified entry per input finding, preserving file/summary/failure_scenario, with your verdict and a one-sentence rationale.',
      { label: 'verify:' + d.key, phase: 'Verify', schema: VERIFY_SCHEMA }
    ).then(v => ({ key: d.key, verified: ((v && v.verified) || []) }))
  }
)

phase('Synthesize')
const confirmed = results
  .filter(Boolean)
  .flatMap(r => r.verified.filter(f => f.verdict === 'CONFIRMED').map(f => Object.assign({}, f, { dimension: r.key })))

const refutedCount = results.filter(Boolean).flatMap(r => r.verified).filter(f => f.verdict === 'REFUTED').length
log(confirmed.length + ' confirmed findings across ' + DIMENSIONS.length + ' dimensions (' + refutedCount + ' refuted by adversarial verification)')

return { confirmed, refutedCount, dimensionsRun: DIMENSIONS.length }
