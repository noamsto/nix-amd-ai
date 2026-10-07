#!/usr/bin/env python3
"""Markdown tables for the #260 README from a rows.jsonl: tables.py tasks <rows.jsonl> | kl <log>..."""
import json
import re
import sys


def rows(path):
    with open(path, encoding="utf-8") as f:
        return {r["label"]: r for r in map(json.loads, f) if r.get("label") and "error" not in r}


def count(passes, n, errors):
    return f"{passes}/{n}" + (f" err={errors}" if errors else "")


def cell(modes, mode):
    p = modes[mode]["pass"]
    return count(sum(p), len(p), modes[mode].get("errors", 0))


def tasks(path):
    r = rows(path)
    iq4, iq3 = r["tasks-iq4"]["tasks"], r["tasks-iq3"]["tasks"]
    print("| task | IQ4_XS greedy | IQ3_XXS greedy | IQ4_XS sampled | IQ3_XXS sampled |")
    print("| --- | ---: | ---: | ---: | ---: |")
    for tid, t4 in iq4["tasks"].items():
        t3 = iq3["tasks"][tid]
        print(f"| {tid} | {cell(t4['modes'], 'greedy')} | {cell(t3['modes'], 'greedy')} | "
              f"{cell(t4['modes'], 'sampled')} | {cell(t3['modes'], 'sampled')} |")
    print()
    print("Intervals are Wilson 95 % per run, pooled over seeds (runs are not independent). err = runs that "
          "failed on a request error rather than a wrong answer.")
    print()
    print("| category / mode | IQ4_XS | IQ3_XXS |")
    print("| --- | ---: | ---: |")
    for cat in ("tool", "code", "lc", "all"):
        for mode in ("greedy", "sampled"):
            a4, a3 = iq4["aggregate"][cat][mode], iq3["aggregate"][cat][mode]
            fmt = lambda a: (f"{count(a['passes'], a['n'], a.get('errors', 0))} "
                             f"({a['wilson95'][0]:.2f}-{a['wilson95'][1]:.2f})")
            print(f"| {cat} {mode} | {fmt(a4)} | {fmt(a3)} |")
    print()
    for label in ("tasks-iq4", "tasks-iq3"):
        print(f"{label}: loadavg_start {r[label]['loadavg_start']}, load_flag {r[label]['load_flag']}, "
              f"GTT after load / peak {r[label]['mem_after_load']['gtt_delta_bytes'] / 2**30:.1f} / "
              f"{r[label]['gtt_peak_delta_bytes'] / 2**30:.1f} GiB")


def kl(paths):
    keys = ("Mean PPL", "Mean KLD", "Median KLD", "99.0% KLD", "Maximum KLD", "RMS Δp", "Same top p")
    for path in paths:
        text = open(path, encoding="utf-8", errors="replace").read()
        print(f"== {path.rsplit('/', 1)[-1]}")
        for line in text.splitlines():
            if any(k in line for k in keys):
                print(re.sub(r"^\S+ I ", "", line).strip())


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("tasks", "kl"):
        sys.exit(__doc__)
    tasks(sys.argv[2]) if sys.argv[1] == "tasks" else kl(sys.argv[2:])
