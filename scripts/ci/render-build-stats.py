#!/usr/bin/env python3
"""Aggregate per-builder stats from ci-distributed.yml into a job summary.

Reads builder-stats-<idx>/stats.json artifacts (one per builder, produced by
the `builder` matrix jobs) and writes a Markdown report to stdout, intended
for $GITHUB_STEP_SUMMARY.

Deliberately stdlib-only and chart-library-free: GitHub renders Markdown in
step summaries, and Unicode block bars render identically everywhere without
depending on which Mermaid version the runner happens to ship.
"""

import json
import pathlib
import sys

BAR_W = 22
BLOCKS = "▏▎▍▌▋▊▉█"


def bar(value, maximum, width=BAR_W):
    """Horizontal bar with 1/8-cell resolution, so small values stay visible."""
    if maximum <= 0:
        return ""
    eighths = round((value / maximum) * width * 8)
    full, rem = divmod(eighths, 8)
    return "█" * full + (BLOCKS[rem - 1] if rem else "")


def load(stats_dir):
    out = []
    for p in sorted(pathlib.Path(stats_dir).glob("builder-stats-*/stats.json")):
        try:
            out.append(json.loads(p.read_text()))
        except (json.JSONDecodeError, OSError) as e:
            print(f"<!-- skipped {p}: {e} -->")
    return sorted(out, key=lambda s: s.get("idx", 0))


def main():
    stats_dir = sys.argv[1] if len(sys.argv) > 1 else "stats"
    rows = load(stats_dir)

    print("## Distributed build stats\n")
    if not rows:
        print("No builder stats were collected — every builder job failed "
              "before its collection step, or artifact upload failed.")
        return

    total_drvs = sum(r.get("drvs_built", 0) for r in rows)
    workers = [r for r in rows if r.get("drvs_built", 0) > 0]
    idle = [r for r in rows if r.get("drvs_built", 0) == 0]
    cores = sum(r.get("cores", 0) for r in rows)
    # Mean over builders that actually reported samples; a builder whose
    # sampler never ran would otherwise drag the fleet average toward zero
    # and read as "underutilised" rather than "not measured".
    sampled = [r for r in rows if r.get("samples", 0) > 0]
    mean_cpu = (sum(r["cpu_mean"] for r in sampled) / len(sampled)) if sampled else 0.0

    print(f"- **{total_drvs}** derivations built across **{len(workers)}/{len(rows)}** "
          f"builders ({cores} vCPU total)")
    print(f"- Fleet mean CPU while the coordinator was active: **{mean_cpu:.1f}%**")
    if idle:
        print(f"- **{len(idle)}** builder(s) built nothing: "
              f"{', '.join('#' + str(r.get('idx', '?')) for r in idle)}")
    print()

    max_drvs = max((r.get("drvs_built", 0) for r in rows), default=0)

    print("| Builder | Derivations | | CPU mean | | Saturated |")
    print("|--:|--:|:--|--:|:--|--:|")
    for r in rows:
        idx = r.get("idx", "?")
        d = r.get("drvs_built", 0)
        cpu = r.get("cpu_mean", 0.0)
        sat = r.get("cpu_pct_saturated", 0.0)
        note = "" if r.get("samples", 0) else " ⚠︎"
        print(f"| {idx} | {d} | `{bar(d, max_drvs)}` | {cpu:.0f}%{note} | "
              f"`{bar(cpu, 100)}` | {sat:.0f}% |")

    print()
    print("<sub>“Saturated” = share of 5s samples at ≥90% CPU. "
          "⚠︎ = no CPU samples collected for that builder. "
          "Derivations are counted from each builder's own "
          "<code>/nix/var/log/nix/drvs</code> delta, so they reflect work that "
          "machine actually performed, not work dispatched to it.</sub>")


if __name__ == "__main__":
    main()
