---
name: nixos-review
description: Critically audit a NixOS flake and its design decisions — defects and risks across structure, inputs, modules, security, reproducibility, and operations — then produce a prioritised remediation plan. Use when asked to review, audit, or criticise a NixOS flake or configuration, or to plan fixes for an existing fleet.
---

# NixOS flake review

A critic's audit: find what is wrong or unjustified, prove it, attack the
proof, and plan the fixes. Not a linter run, and not a rewrite. The output
keeps **findings** (verified defects, risks, and questioned decisions) separate
from the **remediation plan** (ordered, atomic, verifiable fixes).

## Stance

- **Evidence over assertion.** A finding without `file:line`, a quoted value,
  or command output is an opinion — label it, or drop it.
- **Decisions are reviewed as decisions.** A choice is not a defect. State the
  decision, its context, the alternatives considered (or not), and the
  consequences; flag *undocumented decisions* and *unconsidered alternatives*,
  never taste. Apply Chesterton's fence, then steelman before criticising.
- **The target repo's own docs are the first authority** (`CLAUDE.md`/
  `AGENTS.md`, README, ADRs, inline rationale). A documented, intentional
  trade-off is not a finding; a stale one is.
- **Read-only by default.** The review changes nothing and runs nothing
  destructive. Remediation is a plan; executing it is a later, separately
  approved phase.
- **Calibrate, or the report is noise.** NixOS defaults (`PasswordAuthentication`
  allowed, `openFirewall` on an opted-in service) are not mistakes; a high
  `systemd-analyze security` score is not a vulnerability; a microarch-tuned
  host may accept non-substitutable builds deliberately. Severity inflation
  is a defect of the review itself.

## Workflow

1. **Scope and authority.** Agree the target: the whole flake fleet, one
   flake, or the diff since a fixed point (commit/branch/merge-base). Read the
   repo's governing docs and note any constraints on evidence (can you build?
   Is a cache reachable? Is the target live?). Done when the scope, the
   authority documents, and the evidence limits are written down.
2. **Evidence baseline.** Inventory before judging:
   `nix flake metadata --json`, `nix flake show --all-systems --json`,
   `git ls-files flake.lock`, `nix flake check --no-build` (eval), the host
   list vs `nixosConfigurations`, CI/workflow files, and the mechanical greps
   from the audit references. Record exact outputs — these are the review's
   primary evidence. Done when every claim later made can cite this baseline
   or a fresh command.
3. **Dimension audits in parallel sub-agents.** Four independent audits, each
   carrying its own reference and returning findings only:
   - **Flake, inputs, purity, reproducibility, cacheability** —
     `references/flake-audit.md`
   - **Modules, hosts, option/priority hygiene, state** —
     `references/module-audit.md`
   - **Security: secrets, privilege, exposure, hardening, CI supply chain** —
     `references/security-audit.md`
   - **Operations: deployment, rollback, backup, CI, observability, boot** —
     `references/ops-audit.md`

   Dispatch with the `task` tool (general sub-agent) so contexts stay separate;
   paste the finding schema and calibration rules into each brief. If
   sub-agents are unavailable, wear the four hats sequentially in one context
   but keep the findings in separate lists. Done when all four audits returned
   findings (or an explicit "no findings").
4. **Adversarial verification.** For every finding, a fresh verifier re-reads
   the named file/line (and re-runs the named command where cheap) and returns
   `CONFIRMED`, `REFUTED`, or `AMBIGUOUS` with a one-sentence rationale.
   Default to REFUTED when the claim cannot be independently re-derived.
   Refuted findings move to a "considered and dismissed" appendix — never
   silently deleted, never reported as findings. Ambiguity is labelled, not
   smoothed over. Done when every finding carries a verdict.
5. **Decision review.** Walk the load-bearing decisions against
   `references/decision-review.md`: which are one-way doors (disk layout,
   identity, encryption) and which are two-way; which are documented and
   which happened by default; which alternatives were never considered. Done
   when every decision in the catalogue is reviewed or explicitly out of scope.
6. **Synthesise.** Deduplicate to root causes: **one finding per root cause**,
   with all its symptom sites attached. Sort into defects (objective,
   reproducible), decisions (judgement, linked to context), and risks
   (conditional on a stated trigger). Name the fleet-wide themes. Done when
   no two findings share a root cause and every symptom site is attached.
7. **Remediate on paper.** Build the plan per
   `references/remediation-plan.md`: stop-the-bleeding first, then SSVC-style
   buckets, dependency-ordered, each fix atomic with a verification criterion
   and a rollback note. Accepted risks get a rationale, an owner, and a review
   date. Done when every finding maps to exactly one remediation entry.
8. **Report.** Use the template in `references/remediation-plan.md`. Lead with
   the verdict and counts, state plainly what was **not** verified, and keep
   the dismissed appendix.

## Finding schema

Every finding, from every dimension:

```md
- ID: <DIM-NN>
  TYPE: defect | decision | risk
  SEVERITY: blocker | critical | major | minor
  CONFIDENCE: high (reproduced) | medium (read) | low (inferred)
  EVIDENCE: <file:line, quoted text and/or command output>
  FAILURE SCENARIO: <what breaks, for whom, under what condition>
  REMEDIATION SKETCH: <smallest safe fix>
```

## Gates

- **G1** No finding without evidence (`file:line` or command output) and a
  concrete failure scenario — or it is labelled opinion and excluded.
- **G2** No `blocker`/`critical` without a reproduction command and high or
  medium confidence; otherwise downgrade.
- **G3** No remediation bundles a refactor, reformat, or unrelated fix; one
  purpose per change.
- **G4** No write, no deploy, no `nix-collect-garbage`, no destructive command
  against the target during review.
- **G5** Every remediation entry has a verification criterion and a rollback
  note; accepted risks have an owner and a revisit date.
- **G6** Refuted findings and documented trade-offs appear only in the
  dismissed appendix, with the reason.

## Calibration table (the review's own fraud bar)

| Fraud | Symptom |
|---|---|
| Severity inflation | a style nit rated major "for emphasis"; no exploitation/reachability path |
| Finding without failure | "this is bad practice" with no scenario of what breaks |
| Taste as defect | flagging a documented, intentional trade-off the repo explains |
| Rewrite reflex | remediation proposes replacing the architecture instead of the smallest fix |
| Eval-as-proof | calling a flake healthy because `nix flake check` passed (it may evaluate only) |
| Scanner-as-verdict | repeating a linter/tool hit without re-deriving it from source |
| Missing the stated rule | failing to read the repo's own documented rules before judging against generic taste |
| Silent dismissal | dropping a finding without recording why, so the next reviewer re-litigates it |

## References

- `references/flake-audit.md` — flake structure, inputs, purity, lock, tests,
  CI signals, reproducibility and cache substitutability criteria.
- `references/module-audit.md` — module interface and implementation,
  priorities, host composition, state and documentation drift criteria.
- `references/security-audit.md` — secrets, accounts/privilege, network
  exposure, systemd hardening, CI supply-chain, update posture criteria.
- `references/ops-audit.md` — deployment topology, generations/rollback,
  backup/recovery, CI verification, observability, boot-chain criteria.
- `references/decision-review.md` — the recurring NixOS decisions with
  alternatives, reversibility classes, failure probes, and review questions.
- `references/remediation-plan.md` — severity/confidence taxonomy, SSVC-style
  buckets, ordering and atomicity rules, report template, dismissed appendix.

## Sources

Methodology sources are itemised in `references/remediation-plan.md`. Domain
criteria sources are itemised per audit reference (all accessed 2026-09-30).
