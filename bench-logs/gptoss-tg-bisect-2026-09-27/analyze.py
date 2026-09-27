#!/usr/bin/env python3
"""Summarize the interleaved b10964-vs-b11207 tg128 runs for #162.

Reads every arm's llama-bench `-o json` output under the run directories and
prints the per-round table plus the paired statistics quoted in README.md.
Paths resolve relative to this script, so it can be run from anywhere:
    python3 analyze.py
"""
import json
import os
import statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))

# Run directory -> round numbers. Order of phases is the order they were run.
PHASES = [
    ("interleaved", range(1, 5)),           # AB rounds 1-4
    ("interleaved-reversed", range(5, 7)),  # BA rounds 5-6
    ("interleaved-balanced", range(7, 11)),  # mixed rounds 7-10
    ("interleaved-quiet", range(11, 15)),   # mixed rounds 11-14, host load lower
]

# Rounds taken while sibling dispatcher workers saturated the host
# (load average ~72 observed at 18:58; wall time ~2x the rest).
LOAD_SPIKE_ROUNDS = {7, 8}

# Two-sided 95% t multipliers, indexed by degrees of freedom.
T95 = {1: 12.71, 2: 4.30, 3: 3.18, 4: 2.78, 5: 2.57, 6: 2.45, 7: 2.36,
       8: 2.31, 9: 2.26, 10: 2.23, 11: 2.20, 12: 2.18, 13: 2.16, 14: 2.14,
       15: 2.13, 16: 2.12, 17: 2.11, 18: 2.10, 19: 2.09, 20: 2.09}


def load_run(path):
    with open(path) as f:
        rec = json.load(f)[0]
    return rec["avg_ts"], rec["stddev_ts"], f"{rec['build_commit']} ({rec['build_number']})"


def main():
    runs = {}
    build = {}
    for d, rounds in PHASES:
        for r in rounds:
            for arm in ("old", "new"):
                p = os.path.join(HERE, d, f"r{r}-{arm}.json")
                if not os.path.exists(p):
                    raise SystemExit(f"missing expected run file: {p}")
                avg, sd, b = load_run(p)
                runs[(r, arm)] = (avg, sd)
                build[arm] = b
    rounds = sorted({r for r, _ in runs})

    print(f"old = {build.get('old')}   new = {build.get('new')}\n")
    print(f"{'round':>5} {'old t/s':>9} {'old sd':>7} {'new t/s':>9} {'new sd':>7} {'old-new':>9}  load")
    for r in rounds:
        o, osd = runs[(r, "old")]
        n, nsd = runs[(r, "new")]
        tag = "spike" if r in LOAD_SPIKE_ROUNDS else ""
        print(f"{r:>5} {o:>9.3f} {osd:>7.3f} {n:>9.3f} {nsd:>7.3f} {o - n:>+9.3f}  {tag}")

    def report(label, sel):
        old = [runs[(r, "old")][0] for r in sel]
        new = [runs[(r, "new")][0] for r in sel]
        d = [o - n for o, n in zip(old, new)]
        m, s = st.mean(d), st.stdev(d)
        se = s / len(d) ** 0.5
        t = m / se if se else 0.0
        dm = st.mean(old) - st.mean(new)
        print(f"\n[{label}] n={len(d)} pairs")
        print(f"  old mean {st.mean(old):.3f} sd {st.stdev(old):.3f}   new mean {st.mean(new):.3f} sd {st.stdev(new):.3f}")
        print(f"  unpaired delta old-new {dm:+.3f} t/s ({100 * dm / st.mean(old):+.2f}%)")
        print(f"  paired diff mean {m:+.3f} sd {s:.3f} se {se:.3f} t={t:.3f} df={len(d) - 1}")
        tc = T95.get(len(d) - 1, 2.0)
        print(f"  paired 95% CI ~ {m - tc * se:+.3f} .. {m + tc * se:+.3f} t/s (df={len(d) - 1}, t95={tc})")

    report("all rounds", rounds)
    report("excluding load-spike rounds 7-8", [r for r in rounds if r not in LOAD_SPIKE_ROUNDS])
    report("quiet rounds 9-14", [r for r in rounds if r >= 9])


if __name__ == "__main__":
    main()
