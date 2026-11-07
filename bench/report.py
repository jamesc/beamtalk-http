#!/usr/bin/env python3
# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
"""Render bench/run.sh raw samples into REPORT.md (BT-4546).

Usage: report.py <raw-dir> <report-md>
Reads <raw-dir>/<row>.<impl>.r<round>/{meta.json,samples-w*} and writes
per-round figures plus per-(row, impl) medians with min-max spread, and
gun/mint ratios where both impls ran the row.
"""
import json
import os
import statistics
import subprocess
import sys
from datetime import datetime, timezone


def pct(sorted_xs, p):
    if not sorted_xs:
        return 0.0
    i = min(len(sorted_xs) - 1, int(p / 100 * len(sorted_xs)))
    return float(sorted_xs[i])


def main():
    raw, report = sys.argv[1], sys.argv[2]
    rounds = {}  # (row, impl, round) -> dict
    for d in sorted(os.listdir(raw)):
        meta_p = os.path.join(raw, d, "meta.json")
        if not os.path.isfile(meta_p):
            continue
        with open(meta_p) as f:
            meta = json.load(f)
        lat = []
        for fn in sorted(os.listdir(os.path.join(raw, d))):
            if not fn.startswith("samples-w"):
                continue
            with open(os.path.join(raw, d, fn)) as f:
                lat.extend(float(line) for line in f if line.strip())
        lat.sort()
        dur_s = meta["duration_ms"] / 1000
        rounds[(meta["row"], meta["impl"], meta["round"])] = {
            "n": len(lat),
            "rps": len(lat) / dur_s if dur_s else 0.0,
            "min": lat[0] if lat else 0.0,
            "p50": pct(lat, 50),
            "p99": pct(lat, 99),
            "max": lat[-1] if lat else 0.0,
        }

    def rows_for(row, impl):
        return [v for (r, i, _), v in rounds.items() if r == row and i == impl]

    summary = {}
    for row, impl, _ in rounds:
        rs = rows_for(row, impl)
        med = lambda k: statistics.median([v[k] for v in rs])  # noqa: E731
        summary[(row, impl)] = {
            "rounds": len(rs),
            "rps": med("rps"),
            "rps_spread": (min(v["rps"] for v in rs), max(v["rps"] for v in rs)),
            "p50": med("p50"),
            "p99": med("p99"),
            "p99_spread": (min(v["p99"] for v in rs), max(v["p99"] for v in rs)),
        }

    def rev(cwd):
        try:
            out = subprocess.run(
                ["git", "-C", cwd, "rev-parse", "--short", "HEAD"],
                capture_output=True, text=True, check=True)
            dirty = subprocess.run(
                ["git", "-C", cwd, "diff", "--quiet", "HEAD", "--", "src", "bench"],
                capture_output=True).returncode != 0
            return out.stdout.strip() + ("+dirty" if dirty else "")
        except Exception:
            return "?"

    root = os.path.dirname(os.path.dirname(os.path.abspath(report)))
    lines = [
        "# Client load bench report",
        "",
        f"Recorded {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC} by bench/run.sh (BT-4546).",
        f"http rev {rev(root)}; beamtalk {os.popen('beamtalk --version 2>/dev/null').read().strip()}.",
        "Fresh local server per measurement; loopback; medians over rounds.",
        "",
        "| row | impl | rounds | req/s (spread) | p50 ms | p99 ms (spread) | gun/mint req/s |",
        "|---|---|---|---|---|---|---|",
    ]
    for (row, impl) in sorted(summary):
        s = summary[(row, impl)]
        ratio = ""
        if impl == "gun" and (row, "mint") in summary:
            m = summary[(row, "mint")]["rps"]
            ratio = f"{s['rps'] / m:.2f}" if m else ""
        lines.append(
            f"| {row} | {impl} | {s['rounds']} "
            f"| {s['rps']:.0f} ({s['rps_spread'][0]:.0f}-{s['rps_spread'][1]:.0f}) "
            f"| {s['p50']:.2f} | {s['p99']:.2f} "
            f"({s['p99_spread'][0]:.2f}-{s['p99_spread'][1]:.2f}) | {ratio} |")
    lines += ["", "## Per-round figures", ""]
    lines.append("| row | impl | round | n | req/s | min | p50 | p99 | max |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for (row, impl, rnd) in sorted(rounds):
        v = rounds[(row, impl, rnd)]
        lines.append(
            f"| {row} | {impl} | {rnd} | {v['n']} | {v['rps']:.0f} "
            f"| {v['min']:.2f} | {v['p50']:.2f} | {v['p99']:.2f} | {v['max']:.2f} |")
    lines.append("")
    with open(report, "w") as f:
        f.write("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
