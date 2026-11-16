"""Memory footprint of one bench row: a sampler that runs beside a gated run.sh row, and its summariser.

    python3 footprint.py watch --root-pid P --out summary.json [--raw raw.jsonl] [--interval 0.2]
    python3 footprint.py summarise --raw raw.jsonl [--out summary.json]

Every tick records GTT in use (amdgpu), /proc/meminfo MemAvailable, Mlocked, Mapped and Cached, and the memory of each
process under P whose comm starts with `strata`. Only descendants of P count, so lemond's resident Strata engine (a
sibling tree) is never included. The sampler stops on SIGTERM or SIGINT or once P is gone, then writes the summary.
`summarise` re-reads a raw series and gives the same summary without re-running the row.

The idle baseline is the first sample with a watched process: run.sh has unloaded lemond's model by then, so GTT and
MemAvailable are the host's floor (the GTT baseline is the first watched sample with a readable GTT). Samples before it
(the lemond phase) are ignored. The probe tears the engine down at the end of the watched window, so the tail is not the
loaded state. The loaded window is the watched samples whose GTT delta vs the baseline is at least LOADED_FRACTION of
the peak GTT delta; every `*_loaded_*` figure is the median over that window. The window is empty, and every
`*_loaded_*` figure, `load_s`, `loaded_s` and `loaded_samples` null, when GTT is unreadable or never rises above its
baseline. All summary values are GiB rounded to 0.1 (seconds to 0.1, `loaded_samples` a count), and null when
unmeasured. Drops are baseline minus value, so a positive drop means memory was taken. `load_s` is the time from the
first watched sample to the first loaded one, `loaded_s` the span of the loaded window, `loaded_samples` its length.
"""

import argparse
import glob
import json
import os
import signal
import statistics
import sys
import time

GIB = 2**30
LOADED_FRACTION = 0.9
MEMINFO_KEYS = {
    "MemAvailable": "mem_available",
    "Mlocked": "mlocked",
    "Mapped": "mapped",
    "Cached": "cached",
}
STATUS_KEYS = {
    "VmRSS": "vm_rss",
    "RssAnon": "rss_anon",
    "RssFile": "rss_file",
    "VmLck": "vm_lck",
}
PROC_FIELDS = tuple(STATUS_KEYS.values())
SUMMARY_KEYS = [
    "gtt_baseline_gib",
    "gtt_peak_delta_gib",
    "gtt_loaded_delta_gib",
    "mem_available_baseline_gib",
    "mem_available_min_drop_gib",
    "mem_available_loaded_drop_gib",
    "mlocked_loaded_delta_gib",
    "mapped_loaded_delta_gib",
    "cached_loaded_delta_gib",
    "rss_peak_gib",
    "rss_loaded_gib",
    "rss_anon_loaded_gib",
    "rss_file_loaded_gib",
    "vm_lck_loaded_gib",
    "load_s",
    "loaded_s",
    "loaded_samples",
]


def read_proc_table(proc="/proc"):
    """{pid: (ppid, comm)} for every readable process."""
    table = {}
    for name in os.listdir(proc):
        if not name.isdigit():
            continue
        try:
            with open(f"{proc}/{name}/stat") as fh:
                data = fh.read()
        except OSError:
            continue
        # comm sits in parentheses and may contain spaces or parentheses itself
        lp, rp = data.find("("), data.rfind(")")
        if lp < 0 or rp < lp:
            continue
        table[int(name)] = (int(data[rp + 2 :].split()[1]), data[lp + 1 : rp])
    return table


def watched_pids(table, root, prefix="strata"):
    """Sorted pids below `root` (not root itself) whose comm starts with `prefix`."""
    children = {}
    for pid, (ppid, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    found, stack = [], [root]
    while stack:
        for pid in children.get(stack.pop(), ()):
            stack.append(pid)
            if table[pid][1].startswith(prefix):
                found.append(pid)
    return sorted(found)


def read_status(proc, pid):
    """The watched memory fields of one process in bytes (None when the kernel omits one), None if it is gone."""
    out = dict.fromkeys(PROC_FIELDS)
    try:
        with open(f"{proc}/{pid}/status") as fh:
            for line in fh:
                key, _, rest = line.partition(":")
                if key in STATUS_KEYS:
                    out[STATUS_KEYS[key]] = int(rest.split()[0]) * 1024
    except OSError:
        return None
    return out


def read_meminfo():
    out = dict.fromkeys(MEMINFO_KEYS.values())
    with open("/proc/meminfo") as fh:
        for line in fh:
            key, _, rest = line.partition(":")
            if key in MEMINFO_KEYS:
                out[MEMINFO_KEYS[key]] = int(rest.split()[0]) * 1024
    return out


def gtt_used_path():
    for path in sorted(glob.glob("/sys/class/drm/card[0-9]*/device/mem_info_gtt_used")):
        return path
    return None


def read_gtt(path):
    if path is None:
        return None
    try:
        with open(path) as fh:
            return int(fh.read())
    except (OSError, ValueError):
        return None


def take_sample(root, gtt_path, proc="/proc"):
    procs = [
        s
        for s in (
            read_status(proc, p) for p in watched_pids(read_proc_table(proc), root)
        )
        if s
    ]
    return {
        "t": time.monotonic(),
        "gtt": read_gtt(gtt_path),
        **read_meminfo(),
        "procs": procs,
    }


def gib(value):
    return None if value is None else round(value / GIB, 1)


def known(values):
    return [v for v in values if v is not None]


def median(values):
    values = known(values)
    return statistics.median(values) if values else None


def delta(value, base):
    return None if value is None or base is None else value - base


def proc_sum(sample, field):
    values = known(p[field] for p in sample["procs"])
    return sum(values) if values else None


def first_gtt(live):
    return next((s["gtt"] for s in live if s["gtt"] is not None), None)


def loaded_window(live):
    """The live samples whose GTT delta vs the first known one is at least LOADED_FRACTION of the peak delta.

    Empty when GTT never rose: a row whose weights never reached GTT has no loaded window."""
    gtt_base = first_gtt(live)
    deltas = [delta(s["gtt"], gtt_base) for s in live]
    peak = max(known(deltas), default=None)
    if peak is None or peak <= 0:
        return []
    return [
        s for s, d in zip(live, deltas) if d is not None and d >= LOADED_FRACTION * peak
    ]


def summarise(samples):
    """Summary dict (GiB, 0.1) of a sample series; see the module docstring for the definitions."""
    live = [s for s in samples if s["procs"]]
    out = dict.fromkeys(SUMMARY_KEYS)
    out.update(samples=len(samples), watched_s=None)
    if not live:
        return out
    base = live[0]
    window = loaded_window(live)
    gtt_base = first_gtt(live)
    gtts = known(s["gtt"] for s in live)
    mems = known(s["mem_available"] for s in live)
    out.update(
        watched_s=round(live[-1]["t"] - base["t"], 1),
        gtt_baseline_gib=gib(gtt_base),
        gtt_peak_delta_gib=gib(delta(max(gtts), gtt_base)) if gtts else None,
        mem_available_baseline_gib=gib(base["mem_available"]),
        mem_available_min_drop_gib=gib(delta(base["mem_available"], min(mems)))
        if mems
        else None,
        rss_peak_gib=gib(max(known(proc_sum(s, "vm_rss") for s in live), default=None)),
    )
    if not window:
        return out
    out.update(
        load_s=round(window[0]["t"] - base["t"], 1),
        loaded_s=round(window[-1]["t"] - window[0]["t"], 1),
        loaded_samples=len(window),
        gtt_loaded_delta_gib=gib(delta(median(s["gtt"] for s in window), gtt_base)),
        mem_available_loaded_drop_gib=gib(
            delta(base["mem_available"], median(s["mem_available"] for s in window))
        ),
    )
    for name, field in (
        ("mlocked_loaded_delta_gib", "mlocked"),
        ("mapped_loaded_delta_gib", "mapped"),
        ("cached_loaded_delta_gib", "cached"),
    ):
        out[name] = gib(delta(median(s[field] for s in window), base[field]))
    for name, field in (
        ("rss_loaded_gib", "vm_rss"),
        ("rss_anon_loaded_gib", "rss_anon"),
        ("rss_file_loaded_gib", "rss_file"),
        ("vm_lck_loaded_gib", "vm_lck"),
    ):
        out[name] = gib(median(proc_sum(s, field) for s in window))
    return out


def write_summary(path, samples):
    tmp = f"{path}.tmp"
    with open(tmp, "w") as fh:
        json.dump(summarise(samples), fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


def read_raw(path):
    with open(path) as fh:
        return [json.loads(line) for line in fh if line.strip()]


def summarise_raw(args):
    samples = read_raw(args.raw)
    if args.out:
        write_summary(args.out, samples)
        return
    json.dump(summarise(samples), sys.stdout, indent=2)
    sys.stdout.write("\n")


def watch(args):
    stop = []
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.append(True))
    gtt_path = gtt_used_path()
    samples = []
    with open(args.raw or os.devnull, "w", buffering=1) as raw:
        try:
            while not stop and os.path.exists(f"/proc/{args.root_pid}"):
                started = time.monotonic()
                sample = take_sample(args.root_pid, gtt_path)
                samples.append(sample)
                if args.raw:
                    raw.write(json.dumps(sample) + "\n")
                time.sleep(max(0.0, args.interval - (time.monotonic() - started)))
        finally:
            write_summary(args.out, samples)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("watch")
    w.add_argument("--root-pid", type=int, required=True)
    w.add_argument("--out", required=True)
    w.add_argument("--raw")
    w.add_argument("--interval", type=float, default=0.2)
    w.set_defaults(run=watch)
    r = sub.add_parser("summarise")
    r.add_argument("--raw", required=True)
    r.add_argument("--out")
    r.set_defaults(run=summarise_raw)
    args = p.parse_args(argv)
    args.run(args)


if __name__ == "__main__":
    main()
