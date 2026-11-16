#!/usr/bin/env python3
"""Markdown tables for the README from footprint.py summaries and the probe's reload rows.

    tables.py footprint --dir D [--sizes 20000,10000,5000]   footprint per --expert-cache, and what a smaller cache frees
    tables.py reload --dir D --rows rows.jsonl [--sizes ...]  cold and warm reload rows per --expert-cache

D holds `foot-base-foot<N>.json` (footprint rows) and `foot-base-reload<N>-<cold|warm>.json` (reload rows), the summaries
footprint.py writes; rows.jsonl rows are labelled `base-reload<N>-<cold|warm>`. Every missing or null value prints
`unmeasured`; `active_file_loaded_delta_gib` and `inactive_file_loaded_delta_gib` are absent from older series, so they
print `unmeasured` there. Deltas are printed with a sign and negative numbers are legitimate. The reload table takes
`load_s` and the first-token times from rows.jsonl and the memory figures from the summaries.

The first size is the reference. Freed GTT is GTT(reference) - GTT(S), positive when the cache shrinks. Every host-side
delta (dRssFile, dVmLck, dRssAnon, d system Mlocked, dActive(file), dInactive(file), d MemAvailable drop) is the other
way round, value(S) - value(reference): what the smaller cache added on the host. The split of the freed GTT is derived,
not measured: it asks where the freed amount reappeared. locked = dVmLck, reclaimable file = dRssFile - dVmLck, anon =
dRssAnon, rest = freed - (locked + reclaimable + anon); a negative rest means the host gained more than the GPU freed.
It assumes strata-host's VmLck pages are file-backed (so RssFile contains them). The raw deltas are printed beside it so
a reader can redo it under another assumption. The sum check adds the four parts back up and must equal the freed GTT.
"""

import argparse
import json
import os

KB_PER_GIB = 2**20
UNMEASURED = "unmeasured"
# (column, summary key, signed) of the footprint columns that read one summary value; GTT loaded, RSS and GTT + RSS are composed
FOOT_COLUMNS = [
    ("GTT loaded", "gtt_loaded_delta_gib", False),
    ("RSS peak", "rss_peak_gib", False),
    ("VmLck", "vm_lck_loaded_gib", False),
    ("system Mlocked delta", "mlocked_loaded_delta_gib", True),
    ("Active(file) delta", "active_file_loaded_delta_gib", True),
    ("Inactive(file) delta", "inactive_file_loaded_delta_gib", True),
    ("MemAvailable baseline", "mem_available_baseline_gib", False),
    ("MemAvailable drop, loaded", "mem_available_loaded_drop_gib", False),
    ("MemAvailable drop, lowest", "mem_available_min_drop_gib", False),
]
# (split key, summary key) of the raw deltas of a smaller size against the reference
RAW_DELTAS = [
    ("d_rss_file", "rss_file_loaded_gib"),
    ("d_vm_lck", "vm_lck_loaded_gib"),
    ("d_rss_anon", "rss_anon_loaded_gib"),
    ("d_mlocked", "mlocked_loaded_delta_gib"),
    ("d_active_file", "active_file_loaded_delta_gib"),
    ("d_inactive_file", "inactive_file_loaded_delta_gib"),
    ("d_mem_available_drop", "mem_available_loaded_drop_gib"),
]


def num(value, signed=False):
    if value is None:
        return UNMEASURED
    return f"{value:+.1f}" if signed else f"{value:.1f}"


def diff(a, b):
    return None if a is None or b is None else round(a - b, 1)


def total(*values):
    return None if None in values else round(sum(values), 1)


def freed_split(ref, small):
    """Freed GTT (ref - small), the host-side deltas (small - ref) and the derived split; None when unmeasured."""
    out = {"freed_gtt": diff(ref.get("gtt_loaded_delta_gib"), small.get("gtt_loaded_delta_gib"))}
    for name, key in RAW_DELTAS:
        out[name] = diff(small.get(key), ref.get(key))
    out["locked"] = out["d_vm_lck"]
    out["reclaimable"] = diff(out["d_rss_file"], out["d_vm_lck"])
    out["anon"] = out["d_rss_anon"]
    parts = (out["locked"], out["reclaimable"], out["anon"])
    out["rest"] = diff(out["freed_gtt"], total(*parts))
    out["check"] = total(*parts, out["rest"])
    return out


def load_json(path):
    if not os.path.exists(path):
        return {}
    with open(path) as fh:
        return json.load(fh)


def rss_cell(summary):
    keys = ("rss_loaded_gib", "rss_file_loaded_gib", "rss_anon_loaded_gib")
    total_, file_, anon = (summary.get(k) for k in keys)
    if total_ is file_ is anon is None:
        return UNMEASURED
    return f"{num(total_)} ({num(file_)} / {num(anon)})"


def print_table(header, rows):
    print("| " + " | ".join(header) + " |")
    print("| " + " | ".join(["---"] + ["---:"] * (len(header) - 1)) + " |")
    for row in rows:
        print("| " + " | ".join(row) + " |")
    print()


def footprint(args):
    sizes = args.sizes.split(",")
    series = {s: load_json(os.path.join(args.dir, f"foot-base-foot{s}.json")) for s in sizes}
    header = ["--expert-cache", "GTT loaded", "process RSS loaded (file / anon)", "GTT + RSS"]
    header += [name for name, _, _ in FOOT_COLUMNS[1:]]
    rows = []
    for size, summary in series.items():
        gtt = summary.get("gtt_loaded_delta_gib")
        rows.append(
            [size, num(gtt), rss_cell(summary), num(total(gtt, summary.get("rss_loaded_gib")))]
            + [num(summary.get(key), signed) for _, key, signed in FOOT_COLUMNS[1:]]
        )
    print_table(header, rows)

    ref_size, ref = sizes[0], series[sizes[0]]
    splits = {s: freed_split(ref, series[s]) for s in sizes[1:]}
    added = f"added on host (S - {ref_size})"
    raw_header = [f"freed against the {ref_size}-cache row (GiB)", f"freed GTT ({ref_size} - S)"]
    raw_header += [f"{n} {added}" for n in ("dRssFile", "dVmLck", "dRssAnon", "d system Mlocked")]
    raw_header += [f"{n} {added}" for n in ("dActive(file)", "dInactive(file)", "d MemAvailable drop")]
    raw_keys = ["freed_gtt"] + [name for name, _ in RAW_DELTAS]
    print_table(raw_header, [[s] + [num(sp[k], True) for k in raw_keys] for s, sp in splits.items()])
    split_header = ["split of freed GTT (GiB)", "freed GTT", "reappeared as locked (dVmLck)"]
    split_header += ["reappeared as reclaimable file (dRssFile - dVmLck)", "reappeared as anon (dRssAnon)"]
    split_header += ["rest = freed - (locked + file + anon)", "sum check"]
    split_keys = ["freed_gtt", "locked", "reclaimable", "anon", "rest", "check"]
    print_table(split_header, [[s] + [num(sp[k], True) for k in split_keys] for s, sp in splits.items()])


def read_rows(path):
    with open(path) as fh:
        return {r["label"]: r for r in map(json.loads, filter(str.strip, fh))}


def kb_to_gib(kb):
    return None if kb is None else kb / KB_PER_GIB


def reload_rows(args):
    sizes = args.sizes.split(",")
    rows = read_rows(args.rows)
    header = ["--expert-cache", "reload", "since spawn (s)", "load_s", "ttft_s", "GTT peak", "RSS peak"]
    header += ["MemAvailable drop, lowest", "Cached at start", "Cached before pre-eviction", "Cached after pre-eviction"]
    table = []
    for size in sizes:
        for kind in ("cold", "warm"):
            summary = load_json(os.path.join(args.dir, f"foot-base-reload{size}-{kind}.json"))
            row = rows.get(f"base-reload{size}-{kind}", {})
            first = row.get("firsttoken") or {}
            cached = [kb_to_gib(row.get(k)) for k in ("cached_kb_at_start", "cached_kb_before_evict_pre", "cached_kb_after_evict_pre")]
            evict = [num(c) for c in cached[1:]] if kind == "cold" else ["-", "-"]
            table.append(
                [size, kind, num(first.get("since_spawn_s")), num(row.get("load_s")), num(first.get("ttft_s"))]
                + [num(summary.get(k)) for k in ("gtt_peak_delta_gib", "rss_peak_gib", "mem_available_min_drop_gib")]
                + [num(cached[0])]
                + evict
            )
    print_table(header, table)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("footprint")
    f.add_argument("--dir", required=True)
    f.add_argument("--sizes", default="20000,10000,5000")
    f.set_defaults(run=footprint)
    r = sub.add_parser("reload")
    r.add_argument("--dir", required=True)
    r.add_argument("--rows", required=True)
    r.add_argument("--sizes", default="20000,10000,5000")
    r.set_defaults(run=reload_rows)
    args = p.parse_args(argv)
    args.run(args)


if __name__ == "__main__":
    main()
