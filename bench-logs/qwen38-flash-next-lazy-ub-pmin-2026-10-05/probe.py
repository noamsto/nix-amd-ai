#!/usr/bin/env python3
"""One llama-server configuration for Qwen3.8-Flash-Next on stock llama.cpp, measured end to end.

Starts one fresh llama-server (halo's production preset as a standalone process, plus
whatever --lazy-mode / --pmin / --ub / --batch the row varies), measures, prints exactly
one JSON line to stdout, and stops the server. It reuses grid.py's load gate, foreign
process check, memory/GTT readers and corpus builder from the mtp-tuning run.

Measurements, in order (--do picks a subset):
  cold512    one 512-deep decode straight after load, before anything else has touched the
             weights ("as it is after load"); memory is read before and after it
  decode512  3 more 512-deep decodes (the cold one acts as the warmup)
  prefill4k  3 completions of a 4096-token prompt with n_predict 1, prompt t/s
  decode32k  3 decodes at 32768 depth; their prompt t/s is the 32K prefill figure
  prose      1 warmup + 3 prose continuations at temperature 0.7, seeds 1..3

Decodes are 128 tokens, temperature 0, ignore_eos, prompt cache off. Prose is 512 tokens.
"""
import argparse
import importlib.util
import json
import os
import signal
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "grid", os.path.join(HERE, "..", "qwen38-flash-next-mtp-tuning-2026-10-04", "grid.py"))
grid = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grid)

CTX = 131072


def mem_snapshot(pid, gtt0, vram0):
    gtt, vram = grid.gpu_mem()
    swap = {}
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith(("SwapTotal:", "SwapFree:")):
                swap[line.split(":")[0]] = int(line.split()[1])
    return {
        "rss_kb": grid.proc_status_kb(pid, "VmRSS"),
        "rss_anon_kb": grid.proc_status_kb(pid, "RssAnon"),
        "rss_file_kb": grid.proc_status_kb(pid, "RssFile"),
        "gtt_delta_bytes": None if gtt0 is None else gtt - gtt0,
        "vram_delta_bytes": None if vram0 is None else vram - vram0,
        "mem_available_kb": grid.mem_available_kb(),
        "swap_used_kb": swap["SwapTotal"] - swap["SwapFree"],
    }


def stats(xs):
    return {"mean": round(statistics.mean(xs), 3),
            "stdev": round(statistics.stdev(xs), 3) if len(xs) > 1 else 0.0,
            "runs": [round(x, 3) for x in xs]}


def decode(port, ids, gen, temperature=0.0, seed=None):
    body = {"prompt": ids, "n_predict": gen, "temperature": temperature,
            "ignore_eos": True, "cache_prompt": False}
    if seed is not None:
        body["seed"] = seed
    t = grid.http(port, "/completion", body)["timings"]
    if t.get("predicted_n") != gen:
        raise grid.RowError(f"generation stopped short: predicted_n={t.get('predicted_n')} != {gen}")
    return t


def summarize(runs, with_prefill):
    drafted = sum(r.get("draft_n") or 0 for r in runs)
    accepted = sum(r.get("draft_n_accepted") or 0 for r in runs)
    out = {"decode_tps": stats([r["predicted_per_second"] for r in runs]),
           "acceptance": round(accepted / drafted, 4) if drafted else None,
           "prompt_n": runs[0]["prompt_n"]}
    if with_prefill:
        out["prefill_tps"] = stats([r["prompt_per_second"] for r in runs])
    return out


def run(a, log):
    argv = [a.server, "--model", a.target, "--port", str(a.port), "--host", "127.0.0.1",
            "-c", str(CTX), "-ctk", a.kv, "-ctv", a.kv, "-fa", "on", "--parallel", "1",
            "--jinja", "--model-draft", a.draft, "--spec-type", "draft-mtp",
            "--spec-draft-n-max", "3"]
    if a.pmin > 0:
        argv += ["--spec-draft-p-min", str(a.pmin)]
    if a.lazy != "auto":
        argv += ["--lazy-mode", a.lazy]
    if a.ub:
        argv += ["-ub", str(a.ub)]
    if a.batch:
        argv += ["-b", str(a.batch)]

    busy = grid.preflight_busy()
    if busy:
        raise grid.BusyError(f"other benchmark processes running: {busy}")
    load_flag = grid.wait_for_quiet_load()
    busy = grid.preflight_busy()
    if busy:
        raise grid.BusyError(f"other benchmark processes running: {busy}")
    grid.check_memory(a.target, a.draft)
    row = {"label": a.label, "build": grid.server_build(a.server), "lazy": a.lazy, "kv": a.kv, "pmin": a.pmin,
           "ub": a.ub or "default", "batch": a.batch or "default",
           "loadavg_start": round(os.getloadavg()[0], 2), "load_flag": load_flag}
    do = set(a.do.split(","))

    gtt0, vram0 = grid.gpu_mem()
    t0 = time.time()
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=log)
    try:
        if not grid.wait_ready(proc, a.port):
            raise grid.RowError("server not ready")
        row["load_s"] = round(time.time() - t0, 1)
        row["mem_after_load"] = mem_snapshot(proc.pid, gtt0, vram0)

        ids_32k = None
        if do & {"cold512", "decode512", "prefill4k", "decode32k"}:
            ids_32k, files, sha = grid.build_corpus(a.port, a.corpus_root, 32768, a.corpus_rev)
            row.update(corpus_files=files, corpus_sha256=sha)
        if "cold512" in do:
            t = decode(a.port, ids_32k[:512], 128)
            row["cold512"] = summarize([t], False)
            row["mem_after_decode"] = mem_snapshot(proc.pid, gtt0, vram0)
        if "decode512" in do:
            row["decode512"] = summarize([decode(a.port, ids_32k[:512], 128) for _ in range(3)], False)
        if "prefill4k" in do:
            runs = [grid.http(a.port, "/completion", {"prompt": ids_32k[:4096], "n_predict": 1,
                                                      "temperature": 0, "cache_prompt": False})["timings"]
                    for _ in range(3)]
            row["prefill4k"] = {"prefill_tps": stats([r["prompt_per_second"] for r in runs]),
                                "prompt_n": runs[0]["prompt_n"]}
        if "decode32k" in do:
            row["decode32k"] = summarize([decode(a.port, ids_32k, 128) for _ in range(3)], True)
        if "prose" in do:
            with open(os.path.join(HERE, "prose.txt"), encoding="utf-8") as f:
                ids = grid.http(a.port, "/tokenize", {"content": f.read()})["tokens"]
            decode(a.port, ids, 512, 0.7, seed=0)
            row["prose"] = summarize([decode(a.port, ids, 512, 0.7, seed=s) for s in (1, 2, 3)], False)
            row["prose"]["prompt_tokens"] = len(ids)
        row["mem_end"] = mem_snapshot(proc.pid, gtt0, vram0)
        row["hwm_kb"] = grid.proc_status_kb(proc.pid, "VmHWM")
        return row
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        log.seek(0)
        row["server_lazy_lines"] = [l.strip()[:200] for l in log.read().splitlines()
                                    if "lazy" in l.lower()][:6]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--server", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--draft", required=True)
    ap.add_argument("--lazy", choices=["auto", "on", "off"], default="auto",
                    help="auto passes no flag (llama-server's default)")
    ap.add_argument("--kv", default="q8_0", help="K and V cache type")
    ap.add_argument("--pmin", type=float, default=0.0)
    ap.add_argument("--ub", type=int, default=0, help="0 = server default")
    ap.add_argument("--batch", type=int, default=0, help="0 = server default")
    ap.add_argument("--do", default="cold512,decode512,prefill4k,decode32k")
    ap.add_argument("--corpus-root", default=".")
    ap.add_argument("--corpus-rev", default=None)
    ap.add_argument("--label", default="")
    ap.add_argument("--port", type=int, default=18130)
    a = ap.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(143))
    with tempfile.TemporaryFile(mode="w+", errors="replace") as log:
        try:
            row = run(a, log)
        except (grid.RowError, OSError) as e:
            log.seek(0)
            print(json.dumps({"error": str(e), "label": a.label, "server_tail": log.read()[-1500:]}))
            return {grid.BusyError: 2, grid.MemError: 3}.get(type(e), 1)
    print(json.dumps(row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
