#!/usr/bin/env python3
"""Markdown tables for the README from halogen.py row files: tables.py <work dir> (reads halogen-<arm>-<stage>.row.json)."""
import glob
import json
import os
import sys

GIB = 1 << 30


def load(w, arm, stage):
    """The newest row file of a stage (rows.sh appends a short hash of the image and settings to its label)."""
    found = sorted(glob.glob(os.path.join(w, f"halogen-{arm}-{stage}*.row.json")), key=os.path.getmtime)
    for path in reversed(found):
        with open(path) as f:
            row = json.load(f)
        if "error" not in row:
            return row
    raise SystemExit(f"no successful {arm} {stage} row in {w}")


def cell(fn, row):
    """One table cell; a field the harness could not measure (None or absent) prints as n/a."""
    try:
        return fn(row)
    except (KeyError, TypeError):
        return "n/a"


def main(w):
    rows = {a: load(w, a, "rows") for a in ("v2", "byo")}
    print("| | v2 checkpoint | BYO UD-IQ4_XS |\n| --- | ---: | ---: |")

    def line(name, fn):
        print(f"| {name} | " + " | ".join(cell(fn, rows[a]) for a in ("v2", "byo")) + " |")

    line("Prefill 4K (t/s)", lambda r: f"{r['prefill4k']['prefill_tps']['mean']:.0f}")
    for g, n in (("decode512", "512"), ("decode32k", "32K"), ("decode128k", "128K")):
        line(f"Prefill at the {n} decode prompt (t/s)", lambda r, g=g: f"{r[g]['prefill_tps']['mean']:.0f}")
    for g, n in (("decode512", "512"), ("decode32k", "32K"), ("decode128k", "128K")):
        line(f"Decode {n}, T=0.7 mean of 3 (t/s)", lambda r, g=g: f"{r[g]['decode_tps']['mean']:.1f} (runs {', '.join(f'{x:.0f}' for x in r[g]['decode_tps']['runs'])})")
        line(f"Decode {n}, T=0 (t/s)", lambda r, g=g: f"{r[g]['decode_tps_t0']:.1f}")
        line(f"Draft acceptance {n}", lambda r, g=g: f"{r[g]['acceptance']:.2f}")
    line("Replay, normalized (s)", lambda r: f"{r['replay']['normalized_total_s']:.1f}")
    line("Replay, wall (s)", lambda r: f"{r['replay']['wall_total_s']:.1f}")
    line("Replay, TTFT summed (s)", lambda r: f"{r['replay']['ttft_total_s']:.1f}")
    line("Tool call / vision / sanity", lambda r: f"{r['toolcall']['tool_call_ok']} / {r['vision']['ok']} / {r['correctness']['sanity_score']}/10")
    line("Load time (s)", lambda r: f"{r['load_s']:.0f}")
    print()
    print("| memory | v2 | BYO |\n| --- | ---: | ---: |")

    def mline(name, fn):
        print(f"| {name} | " + " | ".join(cell(fn, rows[a]) for a in ("v2", "byo")) + " |")

    mline("GTT peak delta (GiB)", lambda r: f"{r['gtt_peak_delta_bytes'] / GIB:.1f}")
    mline("Container cgroup after load / end (GiB)", lambda r: f"{r['mem_after_load']['cgroup']['current_bytes'] / GIB:.1f} / {r['mem_end']['cgroup']['current_bytes'] / GIB:.1f}")
    mline("cgroup anon / file at end (GiB)", lambda r: f"{r['mem_end']['cgroup']['anon_bytes'] / GIB:.1f} / {r['mem_end']['cgroup']['file_bytes'] / GIB:.1f}")
    mline("Lowest MemAvailable during rows (GiB)", lambda r: f"{r['min_mem_available_kb'] / (1 << 20):.1f}")
    mline("Swap used at end (GiB)", lambda r: f"{r['mem_end']['swap_used_kb'] / (1 << 20):.2f}")
    mline("Peak 1-min loadavg", lambda r: f"{r['loadavg_max']}")
    print()
    print("| tasks (#260 set) | v2 | BYO |\n| --- | ---: | ---: |")
    t = {a: load(w, a, "tasks")["tasks"]["aggregate"] for a in ("v2", "byo")}
    for cat in ("tool", "code", "lc", "all"):
        for mode in ("greedy", "sampled"):
            cells = []
            for a in ("v2", "byo"):
                x = t[a][cat][mode]
                cells.append(f"{x['passes']}/{x['n']}" + (f" err={x['errors']}" if x.get("errors") else ""))
            print(f"| {cat} {mode} | {cells[0]} | {cells[1]} |")


if __name__ == "__main__":
    main(sys.argv[1])
