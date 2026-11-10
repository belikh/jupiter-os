# Remediation planning and report

Findings are only half the review; the plan is the deliverable that changes
anything. This file defines the vocabulary, the prioritisation, the change
discipline, and the report shape.

## Severity and confidence

**Severity** — how bad if true (impact × exploitability/blast radius):

| Band | Meaning |
|---|---|
| blocker | breaks build/boot/reproducibility, exposes secrets, or makes rollback impossible; fix before merge/adoption |
| critical | direct, reachable exposure or data-loss path with no mitigation; urgent |
| major | real damage or latent incident: composability destroyed, a service that cannot start, an unrecoverable state |
| minor | hygiene, drift, polish — fix opportunistically |

**Confidence** — how sure you are, kept separate from severity:

- **high (reproduced):** you ran the command or observed the failure.
- **medium (read):** derived from source, not executed.
- **low (inferred):** reasoning only; must be labelled as such.

**Urgency** is a third axis: exploitability, network reachability, known
exploitation. A critical with no reachable attacker is not automatically the
first item; a minor that is internet-facing and exploited is.

Rules: no band inflation for emphasis (CVSS v4's Threat metrics exist to
counter this); a `blocker`/`critical` needs a reproduction and a failure
scenario; judgement calls are marked, not dressed as sourced facts; severity
is about the finding, not about who wrote it.

## Buckets

| Bucket | Contents | Timing |
|---|---|---|
| Stop the bleeding | exposed secrets, reachable unauthenticated services, a boot/rollback path already broken | immediately, before the rest of the plan |
| Act | verified blockers/criticals and high-confidence bad states | before adoption/merge, in the same effort |
| Attend | majors and supported risks that will bite during operation | scheduled, dated |
| Track | minors, staleness, hygiene, documentation drift | backlog, no date pressure |
| Accept | risks deliberately not fixed | rationale + owner + revisit date recorded |

Every finding lands in exactly one bucket. Accept is a decision, not a bin:
write why, who owns it, and when it gets revisited.

## Ordering

1. **Stop the bleeding** items first, independently of everything else.
2. Then order by **risk reduction per unit effort**, not by severity alone:
   one line change that closes a critical beats a rewrite that closes another.
3. Respect **dependency edges**: a module/option change that other fixes
   depend on lands first; nothing in the plan may leave the tree in a
   non-building or un-deployable state between steps.
4. Prefer fixes on **two-way doors** early (cheap, reversible); schedule
   one-way-door changes with their migration and verification plan attached.
5. One purpose per change. A fix never bundles a refactor, a reformat, or an
   unrelated cleanup; those become their own entries.

## Verification and rollback per fix

Define both **before** applying the fix:

- **Verification criterion:** the observable that proves the fix
  (`nix flake check` plus build the host; VM boot; the unit is `active`;
  `nix store verify`; the secret is absent from the store; the port is
  closed). "The change was applied" is not verification.
- **Rollback note:** what reverts it (a generation rollback, reverting the
  commit, re-encrypting the secret). On NixOS the generation is the natural
  mechanism — keep it available (no `nix-collect-garbage -d` before
  verification).
- For fleet changes: canary one host, observe, then the rest. Boot-chain,
  kernel, and storage changes use `boot` + reboot, not `switch` alone.

## Report template

```md
# NixOS review — <target> (<scope: whole flake | diff since X>)

## Verdict
<one paragraph: overall health, the worst finding, whether adoption/merge is
blocked>

## Summary
- Findings: <n> (blockers <n> / critical <n> / majors <n> / minors <n>)
- By type: defects <n> | decisions <n> | risks <n>
- Refuted/dismissed: <n> (appendix)
- Not verified: <what the review could not check: builds, boots, live state>

## Themes
<fleet-wide patterns, each with the findings it explains>

## Findings
<per finding: the schema from SKILL.md, grouped by dimension>

## Decision reviews
<per decision: verdict, context, alternatives, consequences>

## Remediation plan
### Stop the bleeding
### Act
### Attend
### Track
### Accept (rationale + owner + revisit date)
<each fix: finding IDs, scope, verification criterion, rollback note>

## Dismissed and intentional
<refuted findings and documented trade-offs, with the reason; prevents
re-litigation>
```

## Mapping to tracking

Give every remediation entry a stable ID and map it to exactly one issue or
task (one finding per issue, or a documented bundle when the root cause is
shared). The issue carries: finding IDs, severity, confidence, dependency
edges, verification criterion, rollback note. Untracked fixes evaporate.

## Calibration checklist before publishing

- Every finding has evidence and a failure scenario (G1).
- Every critical/blocker has a reproduction and confidence ≥ medium (G2).
- Every fix is atomic (G3).
- Nothing was run destructively during review (G4).
- Every remediation has verification + rollback; every accept has owner + date (G5).
- Refuted findings and intentional trade-offs are in the dismissed appendix (G6).
- The "not verified" section is honest: eval-only evidence is labelled as such.

## Sources

- CVSS v4.0 severity bands and the severity/risk distinction: https://www.first.org/cvss/v4.0/specification-document and .../user-guide (accessed 2026-09-30)
- OWASP Risk Rating (likelihood × impact, worst case, not all risks are fixed): https://owasp.org/www-community/OWASP_Risk_Rating_Methodology (accessed 2026-09-30)
- CISA SSVC decision buckets (Track/Track*/Attend/Act): https://www.cisa.gov/stakeholder-specific-vulnerability-categorization-ssvc (accessed 2026-09-30)
- CISA BOD 26-04 (risk-based prioritisation; exposure, KEV, automation, impact): https://www.cisa.gov/news-events/directives/bod-26-04-prioritizing-security-updates-based-risk (accessed 2026-09-30)
- NIST SP 800-40r4 (patch: identify → prioritise → apply → verify): https://csrc.nist.gov/pubs/sp/800/40/r4/final (accessed 2026-09-30)
- NIST SP 800-30r1 (risk assessment process): https://csrc.nist.gov/pubs/sp/800/30/r1/final (accessed 2026-09-30)
- Google eng-practices (code health, facts over opinion, small self-contained changes, nit prefix): https://google.github.io/eng-practices/review/ (accessed 2026-09-30)
- Fagan inspection (preparation, follow-up verification): https://en.wikipedia.org/wiki/Fagan_inspection (accessed 2026-09-30)
