#!/usr/bin/env python3
"""parse-results.py — aggregate and compare openshift-runtime-bench run directories.

Every run directory (results/<label>-<runtime>-<stamp>/) contains one .jsonl
file per suite, where each line is a RESULT_JSON envelope:

    {"suite": ..., "test": ..., "runtime": ..., "node": ..., "timestamp": ...,
     "iteration": N, "parameters": {...}, "metrics": {...}, "units": {...}}

Usage:
    # summarize a single run
    parse-results.py results/gcp-crun-20260704-101500

    # compare two runs (FIRST dir is the baseline, e.g. crun)
    parse-results.py results/gcp-crun-<ts> results/gcp-kata-<ts>

    # three or more runs: wide table, first dir is still the baseline
    parse-results.py results/gcp-crun-<ts> results/gcp-kata-<ts> results/aws-kata-<ts>

Options:
    --csv PATH    where to write the comparison CSV (default: comparison.csv
                  in the current directory when 2+ dirs are given)
    --json PATH   also dump the aggregated data as JSON

Only the Python standard library is used.
"""

import argparse
import csv
import json
import re
import statistics
import sys
from pathlib import Path

# --- direction: is a bigger number better or worse? ---------------------------------
# Latencies, jitter, loss, retransmits, startup/deletion seconds, and memory
# overhead deltas are lower-is-better; throughput/IOPS/rate metrics are
# higher-is-better; the env suite is informational (no direction).
_LOWER_BETTER = re.compile(
    r"lat|jitter|loss|retransmit|delta|rss|_time|deletion", re.IGNORECASE
)
_LOWER_BETTER_EXACT = {
    "scheduled_s",
    "running_s",
    "ready_s",
    "wallclock_ready_s",
    "deletion_s",
}

# Regression threshold for the warning flag in comparison tables.
_REGRESSION_RATIO = 0.10


def direction_of(suite, metric):
    if suite == "env":
        return "info"
    if metric in _LOWER_BETTER_EXACT or _LOWER_BETTER.search(metric):
        return "lower-better"
    return "higher-better"


# --- loading -------------------------------------------------------------------------


def load_run_dir(path):
    """Return (aggregates, metadata) for one run directory.

    aggregates: {(suite, test, metric): {"values": [...], "unit": str}}
    The suite key is the .jsonl file stem (so disk-emptydir / disk-pvc /
    disk-block stay separate), except env records, which every suite emits and
    which are merged under the single suite key 'env'.
    """
    path = Path(path)
    if not path.is_dir():
        sys.exit(f"error: not a directory: {path}")

    agg = {}
    jsonl_files = sorted(path.glob("*.jsonl"))
    if not jsonl_files:
        sys.exit(f"error: no .jsonl files in {path} — is this a run directory?")

    for jf in jsonl_files:
        stem = jf.stem
        with jf.open(encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError as exc:
                    print(
                        f"warning: {jf}:{lineno}: skipping unparseable line ({exc})",
                        file=sys.stderr,
                    )
                    continue
                suite = "env" if rec.get("suite") == "env" else stem
                test = rec.get("test", "?")
                units = rec.get("units", {})
                for metric, value in rec.get("metrics", {}).items():
                    if not isinstance(value, (int, float)):
                        continue
                    key = (suite, test, metric)
                    entry = agg.setdefault(
                        key, {"values": [], "unit": units.get(metric, "")}
                    )
                    entry["values"].append(float(value))

    metadata = {}
    meta_file = path / "metadata.json"
    if meta_file.is_file():
        try:
            metadata = json.loads(meta_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print(f"warning: could not parse {meta_file}", file=sys.stderr)
    return agg, metadata


def stats_of(values):
    mean = statistics.mean(values)
    stdev = statistics.pstdev(values) if len(values) > 1 else 0.0
    return mean, stdev, len(values)


# --- formatting helpers ----------------------------------------------------------------


def fmt_num(value):
    if value is None:
        return "-"
    if value == 0:
        return "0"
    if abs(value) >= 1000:
        return f"{value:,.0f}"
    if abs(value) >= 10:
        return f"{value:.1f}"
    return f"{value:.3f}"


def fmt_mean_sd(mean, sd, n):
    return f"{fmt_num(mean)} ±{fmt_num(sd)} (n={n})"


def print_metadata_header(dirs, metas):
    print()
    for d, meta in zip(dirs, metas):
        if meta:
            print(
                f"  {Path(d).name}: runtime={meta.get('runtime', '?')}"
                f" node={meta.get('node', '?')}"
                f" instance={meta.get('instance_type', '?')}"
                f" zone={meta.get('zone', '?')}"
                f" kernel={meta.get('kernelVersion', '?')}"
            )
        else:
            print(f"  {Path(d).name}: (no metadata.json)")
    print()


def print_markdown_table(headers, rows):
    print("| " + " | ".join(headers) + " |")
    print("|" + "|".join("---" for _ in headers) + "|")
    for row in rows:
        print("| " + " | ".join(str(c) for c in row) + " |")


# --- single-run summary -------------------------------------------------------------------


def summarize_single(run_dir, agg, meta):
    print_metadata_header([run_dir], [meta])
    current_suite = None
    for (suite, test, metric), entry in sorted(agg.items()):
        if suite != current_suite:
            print(f"\n## {suite}\n")
            current_suite = suite
        mean, sd, n = stats_of(entry["values"])
        unit = entry["unit"] or "-"
        print(f"  {test:<24} {metric:<28} {fmt_mean_sd(mean, sd, n):>26}  {unit}")
    print()


# --- comparison ---------------------------------------------------------------------------


def compare(dirs, aggs, metas, csv_path, threshold=_REGRESSION_RATIO):
    baseline_agg = aggs[0]
    all_keys = sorted(set().union(*(a.keys() for a in aggs)))
    candidate_names = [Path(d).name for d in dirs[1:]]

    print_metadata_header(dirs, metas)
    print(
        f"Baseline: {Path(dirs[0]).name} — ratio = candidate/baseline; "
        f"⚠ marks a >{threshold:.0%} regression in the metric's worse direction.\n"
    )

    headers = ["suite", "test", "metric", "unit", "baseline"]
    for name in candidate_names:
        headers += [name, "ratio", "delta%"]
    headers.append("direction")

    rows = []
    csv_rows = []
    for key in all_keys:
        suite, test, metric = key
        direction = direction_of(suite, metric)
        base_entry = baseline_agg.get(key)
        base_stats = stats_of(base_entry["values"]) if base_entry else None
        unit = ""
        for a in aggs:
            if key in a and a[key]["unit"]:
                unit = a[key]["unit"]
                break

        row = [
            suite,
            test,
            metric,
            unit or "-",
            fmt_mean_sd(*base_stats) if base_stats else "-",
        ]
        csv_row = {
            "suite": suite,
            "test": test,
            "metric": metric,
            "unit": unit,
            "direction": direction,
            "baseline_mean": base_stats[0] if base_stats else "",
            "baseline_stdev": base_stats[1] if base_stats else "",
            "baseline_n": base_stats[2] if base_stats else "",
        }

        for name, agg in zip(candidate_names, aggs[1:]):
            entry = agg.get(key)
            if not entry:
                row += ["-", "-", "-"]
                csv_row[f"{name}_mean"] = ""
                csv_row[f"{name}_ratio"] = ""
                continue
            mean, sd, n = stats_of(entry["values"])
            cell = fmt_mean_sd(mean, sd, n)
            if base_stats and base_stats[0] != 0:
                ratio = mean / base_stats[0]
                delta_pct = (ratio - 1.0) * 100.0
                flag = ""
                if direction == "lower-better" and ratio > 1 + threshold:
                    flag = " ⚠"
                elif direction == "higher-better" and ratio < 1 - threshold:
                    flag = " ⚠"
                row += [cell, f"{ratio:.3f}{flag}", f"{delta_pct:+.1f}%"]
                csv_row[f"{name}_mean"] = mean
                csv_row[f"{name}_ratio"] = round(ratio, 4)
            else:
                row += [cell, "-", "-"]
                csv_row[f"{name}_mean"] = mean
                csv_row[f"{name}_ratio"] = ""
        row.append(direction)
        rows.append(row)
        csv_rows.append(csv_row)

    print_markdown_table(headers, rows)
    print()

    if csv_path:
        fieldnames = list(csv_rows[0].keys()) if csv_rows else []
        with open(csv_path, "w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(csv_rows)
        print(f"CSV written to {csv_path}", file=sys.stderr)


# --- main ------------------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Aggregate and compare openshift-runtime-bench run directories. "
        "With one directory: per-suite summary. With two or more: comparison "
        "table where the FIRST directory is the baseline (typically crun).",
    )
    parser.add_argument(
        "run_dirs",
        nargs="+",
        metavar="RUN_DIR",
        help="run directories under results/ (baseline first)",
    )
    parser.add_argument(
        "--csv",
        metavar="PATH",
        default=None,
        help="comparison CSV output path (default: comparison.csv when "
        "comparing 2+ run dirs; ignored for a single dir)",
    )
    parser.add_argument(
        "--json",
        metavar="PATH",
        default=None,
        help="also dump the aggregated per-dir statistics as JSON",
    )
    args = parser.parse_args()

    aggs = []
    metas = []
    for d in args.run_dirs:
        agg, meta = load_run_dir(d)
        aggs.append(agg)
        metas.append(meta)

    if args.json:
        dump = {}
        for d, agg in zip(args.run_dirs, aggs):
            dump[str(d)] = {
                "/".join(key): dict(
                    zip(("mean", "stdev", "n"), stats_of(entry["values"])),
                    unit=entry["unit"],
                )
                for key, entry in sorted(agg.items())
            }
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(dump, fh, indent=2)
        print(f"JSON written to {args.json}", file=sys.stderr)

    if len(args.run_dirs) == 1:
        summarize_single(args.run_dirs[0], aggs[0], metas[0])
    else:
        csv_path = args.csv if args.csv is not None else "comparison.csv"
        compare(args.run_dirs, aggs, metas, csv_path)


if __name__ == "__main__":
    main()
