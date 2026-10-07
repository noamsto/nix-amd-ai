#!/usr/bin/env python3
"""Markdown tables for the README from kl_strata.py compare JSON, llama-perplexity logs and probe rows.

    tables.py kl <compare.json>              top-256 KL table and the paired differences
    tables.py llama <llama-perplexity log>...  full-vocabulary KL / PPL / top-1 of each log (label = file name)
    tables.py rows <rows.jsonl> <label>...   soak and image tables of the labelled rows
"""
import json
import re
import sys


def kl(path):
    rows = json.load(open(path))
    print("| row | chunks | positions | mean KLD | median | p99 | same top token | PPL (ratio to ref) |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for r in rows:
        if "kl_mean" not in r:
            continue
        print(f"| {r['row']} | {r['chunks']} | {r['positions']} | {r['kl_mean']:.4f} ± {r['kl_se']:.4f} | "
              f"{r['kl_median']:.4f} | {r['kl_p99']:.2f} | {100 * r['top1_same']:.2f} ± {100 * r['top1_se']:.2f} % | "
              f"{r['ppl']:.4f} ({r['ppl_ratio']:.4f} ± {r['ppl_ratio_se']:.4f}) |")
    pairs = [r for r in rows if "dkl_mean" in r]
    if pairs:
        print("\n| paired | positions | ΔKLD | ΔNLL per token | top-1 differs |")
        print("| --- | ---: | ---: | ---: | ---: |")
        for r in pairs:
            print(f"| {r['row']} | {r['positions']} | {r['dkl_mean']:+.4f} ± {r['dkl_se']:.4f} | "
                  f"{r['dnll_mean']:+.4f} ± {r['dnll_se']:.4f} | {100 * r['top1_flips']:.1f} % |")


def llama(paths):
    print("| row | PPL (ratio to ref) | mean KLD | median | 99 % | same top token |")
    print("| --- | ---: | ---: | ---: | ---: | ---: |")
    for p in paths:
        t = open(p, errors="replace").read()

        def f(pat):
            m = re.search(pat, t)
            return m.groups() if m else None

        ppl, ratio = f(r"Mean PPL\(Q\)\s*:\s*([\d.]+)"), f(r"Mean PPL\(Q\)/PPL\(base\)\s*:\s*([\d.]+)\s*±\s*([\d.]+)")
        mean, med, p99 = (f(r"Mean\s+KLD:\s*([\d.]+)\s*±\s*([\d.]+)"), f(r"Median\s+KLD:\s*(-?[\d.]+)"),
                          f(r"99\.0%\s+KLD:\s*([\d.]+)"))
        top = f(r"Same top p:\s*([\d.]+)\s*±\s*([\d.]+)")
        if not (ppl and ratio and mean and med and p99 and top):
            print(f"| {p} | incomplete | | | | |")
            continue
        print(f"| {p.split('/')[-1].removesuffix('.log')} | {ppl[0]} ({ratio[0]} ± {ratio[1]}) | "
              f"{mean[0]} ± {mean[1]} | {med[0]} | {p99[0]} | {top[0]} ± {top[1]} % |")


def mb(kb):
    return f"{kb / 1048576:.1f}"


def rows(path, labels):
    data = {}
    for line in open(path):
        d = json.loads(line)
        data[d.get("label")] = d
    for lab in labels:
        d = data[lab]
        print(f"\n### {lab}\n")
        if "soak" in d:
            s = d["soak"]
            print("| replay repeat | errors | TTFT sum (s) | wall (s) | decode t/s median |")
            print("| --- | ---: | ---: | ---: | ---: |")
            for i, r in enumerate(s["replay"], 1):
                print(f"| {i} | {r['errors']} | {r['ttft_total_s']} | {r['wall_total_s']} | {r['decode_tps_median']} |")
            print("\n| concurrent requests | errors | wall (s) | aggregate t/s | per-request TTFT (s) | per-request decode t/s |")
            print("| --- | ---: | ---: | ---: | --- | --- |")
            for n, r in s["concurrency"].items():
                print(f"| {n} | {r['errors']} | {r['wall_s']} | {r['aggregate_tps']} | "
                      f"{' / '.join(str(x.get('ttft_s')) for x in r['requests'])} | "
                      f"{' / '.join(str(x.get('decode_tps')) for x in r['requests'])} |")
            tc = [x for r in s["concurrency"].values() for x in r["requests"] if x["kind"] == "toolcall"]
            print(f"\nTool calls under concurrency: {sum(1 for x in tc if x.get('tool_call_ok'))}/{len(tc)} valid; "
                  f"engine pid {s['engine_pid_start']} -> {s['engine_pid_end']}")
        if "longsoak" in d:
            s = d["longsoak"]
            print(f"{s['wall_s'] / 60:.0f} min, {s['requests']} requests, {s['errors']} errors, "
                  f"{s['engine_restarts']} engine restarts (pids {s['engine_pids']})\n")
            print("| kind | n | errors | TTFT median (s) | decode t/s median |")
            print("| --- | ---: | ---: | ---: | ---: |")
            for k, v in s["kinds"].items():
                print(f"| {k} | {v['n']} | {v['errors']} | {v['ttft_median_s']} | {v['decode_tps_median']} |")
            print("\n| minutes | requests | decode t/s median |")
            print("| --- | ---: | ---: |")
            for w in s["windows"]:
                print(f"| {w['from_min']}-{w['from_min'] + 10} | {w['requests']} | {w['decode_tps_median']} |")
            print("\n| canary at (min) | decode t/s (T=0, 128 tokens) | prefill t/s (4K) | errors |")
            print("| ---: | ---: | ---: | ---: |")
            for c in s["canaries"]:
                print(f"| {c['t_s'] / 60:.0f} | {c['decode_tps']} | {c['prefill_tps']} | {len(c['errors'])} |")
            g, r, a, v = s["gtt_delta_bytes"], s["rss_kb"], s["rss_anon_kb"], s["mem_available_kb"]
            print(f"\nGTT delta first / last / max: {g['first'] / 2**30:.2f} / {g['last'] / 2**30:.2f} / {g['max'] / 2**30:.2f} GiB; "
                  f"engine RSS {mb(r['first'])} / {mb(r['last'])} / {mb(r['max'])} GiB (anon {mb(a['first'])} / {mb(a['last'])} / "
                  f"{mb(a['max'])}); MemAvailable {mb(v['first'])} / {mb(v['last'])} / min {mb(v['min'])} GiB")
        if "bigimage" in d:
            s = d["bigimage"]
            a = s["image_alone"]
            print(f"Image tokens {a['image_tokens']} (prompt {a['prompt_tokens']}), file {s['image_bytes']} bytes\n")
            print("| image alone | TTFT (s) | wall (s) | encoder window | decode t/s |")
            print("| --- | ---: | ---: | --- | ---: |")
            for k in ("cold", "repeat"):
                print(f"| {k} | {a[k]['ttft_s']} | {a[k]['wall_s']} | {a[k]['encode_window']} | {a[k]['decode_tps']} |")
            print(f"\nencode cache hit on the repeat: {a['encode_cache_hit']}; cold - repeat TTFT {a['ttft_cold_minus_repeat_s']} s\n")
            print("| text alone | decode t/s | first 8 s t/s |")
            print("| --- | ---: | ---: |")
            for r in s["text_alone"]:
                print(f"| | {r['decode_tps']} | {r['first_8s_tps']} |")
            print("\n| concurrent | image TTFT (s) | encode (s) | CPU (s) | text t/s before | during encode | after | text t/s whole |")
            print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
            for r in s["concurrent"]:
                e = r["encode"] or {}
                print(f"| | {r['image_ttft_s']} | {e.get('encode_s')} | {e.get('cpu_s')} | {e.get('text_tps_before')} | "
                      f"{e.get('text_tps_during_encode')} | {e.get('text_tps_after')} | {r['text_decode_tps']} |")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "kl" and len(sys.argv) == 3:
        kl(sys.argv[2])
    elif cmd == "llama" and len(sys.argv) > 2:
        llama(sys.argv[2:])
    elif cmd == "rows" and len(sys.argv) > 3:
        rows(sys.argv[2], sys.argv[3:])
    else:
        sys.exit(__doc__)
