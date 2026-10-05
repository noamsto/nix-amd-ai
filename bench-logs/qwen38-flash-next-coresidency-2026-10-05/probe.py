#!/usr/bin/env python3
"""Flash-Next residency probes for halo (gfx1151): long context, and beside Qwen3.5-4B.

Each invocation runs one row against fresh standalone llama-server processes
(Vulkan, the #240 MTP preset: n-max 3, no p-min, --jinja, flash attention on),
prints exactly one JSON line to stdout and stops the servers it started. It
reuses the load gate pieces, foreign-process refusal, corpus builder and GTT/RSS
readers of ../qwen38-flash-next-mtp-tuning-2026-10-04/grid.py.

  probe.py context    --server BIN --target T.gguf --draft D.gguf --ctx 65536 --kv q8_0
  probe.py coresident --server BIN --target T.gguf --draft D.gguf --small S.gguf

Exit 2: foreign benchmark process or lemond has a model loaded. 3: low memory.
4: host not quiet after 30 min. 1: any other error.
"""
import argparse
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "grid", os.path.join(HERE, "..", "qwen38-flash-next-mtp-tuning-2026-10-04", "grid.py"))
grid = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grid)

GIB = 1 << 30
FN_MIN_AVAIL = 95 * GIB
LIMIT_AVAIL = 8 * GIB
GEN = 128
PROMPT_FILE = "flake.nix"


class HostNotQuiet(grid.RowError):
    pass


def lemond_idle():
    try:
        with urllib.request.urlopen("http://localhost:13305/api/v1/health", timeout=5) as r:
            return not json.load(r).get("all_models_loaded")
    except Exception as e:
        raise grid.RowError(f"lemond health check failed: {e!r}") from e


def gate():
    """Return the loadavg gate used: '<2', or '<4 after 10 min' when <2 never held."""
    t0 = time.time()
    while True:
        load = os.getloadavg()[0]
        if load < 2:
            return "<2"
        if load < 4 and time.time() - t0 > 600:
            return "<4 after 10 min"
        if time.time() - t0 > 1800:
            raise HostNotQuiet(f"loadavg {load:.2f} after 30 min")
        time.sleep(15)


def preflight(need_bytes):
    if grid.preflight_busy():
        raise grid.BusyError(f"other benchmark processes running: {grid.preflight_busy()}")
    if not lemond_idle():
        raise grid.BusyError("system lemond has a model loaded")
    g = gate()
    if not lemond_idle():
        raise grid.BusyError("system lemond has a model loaded")
    if grid.preflight_busy():
        raise grid.BusyError(f"other benchmark processes running: {grid.preflight_busy()}")
    avail = grid.mem_available_kb() * 1024
    if avail < need_bytes:
        raise grid.MemError(f"MemAvailable {avail / GIB:.1f} GiB < {need_bytes / GIB:.1f} GiB")
    return g


def fn_argv(a, port, ctx, kv):
    return [a.server, "--model", a.target, "--model-draft", a.draft, "--port", str(port),
            "--host", "127.0.0.1", "--device", "Vulkan0", "-ngl", "99", "-c", str(ctx),
            "-ctk", kv, "-ctv", kv, "-fa", "on", "-t", "8", "-np", "1",
            "--spec-type", "draft-mtp", "--spec-draft-n-max", "3", "--jinja"]


def small_argv(a, port):
    return [a.server, "--model", a.small, "--port", str(port), "--host", "127.0.0.1",
            "--device", "Vulkan0", "-ngl", "99", "-c", str(a.small_ctx),
            "-ctk", "q8_0", "-ctv", "q8_0", "-fa", "on", "-t", "8", "-np", "1", "--jinja"]


def start(argv, port, log):
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=log)
    try:
        ready = grid.wait_ready(proc, port)
    except BaseException:
        stop(proc)
        raise
    if not ready:
        stop(proc)
        raise grid.RowError("server not ready")
    return proc


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def snap(procs, gtt0, vram0):
    gtt, vram = grid.gpu_mem()
    return {"gtt_delta_gib": round((gtt - gtt0) / GIB, 2), "vram_delta_gib": round((vram - vram0) / GIB, 2),
            "gtt_used_gib": round(gtt / GIB, 2),
            "rss_gib": {k: round(grid.proc_status_kb(p.pid, "VmRSS") / (1 << 20), 2) for k, p in procs.items()},
            "mem_available_gib": round(grid.mem_available_kb() / (1 << 20), 2)}


def prompt_text(root):
    with open(os.path.join(root, PROMPT_FILE), encoding="utf-8") as f:
        return f.read()[:3000]


def text_completion(port, text):
    t = grid.http(port, "/completion", {"prompt": text, "n_predict": GEN, "temperature": 0,
                                        "ignore_eos": True, "cache_prompt": False})["timings"]
    if t.get("predicted_n") != GEN:
        raise grid.RowError(f"generation stopped short: predicted_n={t.get('predicted_n')}")
    return round(t["predicted_per_second"], 3)


def decode_runs(port, text, n=3):
    text_completion(port, text)
    return [text_completion(port, text) for _ in range(n)]


def context_row(a, log):
    ctx = a.ctx
    g = preflight(FN_MIN_AVAIL)
    row = {"row": f"context-{ctx}-{a.kv}", "ctx": ctx, "kv": a.kv, "load_gate": g,
           "loadavg_start": round(os.getloadavg()[0], 2), "build": grid.server_build(a.server),
           "mem_available_before_gib": round(grid.mem_available_kb() / (1 << 20), 2)}
    gtt0, vram0 = grid.gpu_mem()
    proc = start(fn_argv(a, a.port, ctx, a.kv), a.port, log)
    try:
        row["after_load"] = snap({"flash_next": proc}, gtt0, vram0)
        depth = ctx - GEN - 1024
        ids, files, sha = grid.build_corpus(a.port, a.corpus_root, depth, a.corpus_rev)
        row.update(depth=depth, corpus_files=files, corpus_sha256=sha)
        t = grid.completion(a.port, ids, GEN)
        if not t.get("draft_n"):
            raise grid.RowError("no drafts recorded")
        row.update(prompt_n=t["prompt_n"], prefill_tps=round(t["prompt_per_second"], 2),
                   decode_tps=round(t["predicted_per_second"], 3),
                   draft_n=t.get("draft_n"), draft_n_accepted=t.get("draft_n_accepted"))
        row["after_decode"] = snap({"flash_next": proc}, gtt0, vram0)
        row["hwm_gib"] = round(grid.proc_status_kb(proc.pid, "VmHWM") / (1 << 20), 2)
        row["below_limit"] = grid.mem_available_kb() * 1024 < LIMIT_AVAIL
        return row
    finally:
        stop(proc)


def coresident_row(a, log):
    small_bytes = os.path.getsize(a.small)
    g = preflight(FN_MIN_AVAIL)
    text = prompt_text(a.corpus_root)
    row = {"row": "coresident", "fn_ctx": a.ctx, "fn_kv": "q8_0", "small_ctx": a.small_ctx,
           "load_gate": g, "loadavg_start": round(os.getloadavg()[0], 2),
           "build": grid.server_build(a.server), "gen": GEN,
           "mem_available_before_gib": round(grid.mem_available_kb() / (1 << 20), 2)}
    gtt0, vram0 = grid.gpu_mem()
    fn = small = None
    try:
        fn = start(fn_argv(a, a.port, a.ctx, "q8_0"), a.port, log)
        row["fn_loaded"] = snap({"flash_next": fn}, gtt0, vram0)
        row["fn_alone_tps"] = decode_runs(a.port, text)
        row["fn_alone_tool_call"] = grid.tool_call(a.port)
        if grid.mem_available_kb() * 1024 < small_bytes + 6 * GIB:
            raise grid.MemError("not enough MemAvailable for the 4B beside Flash-Next")
        small = start(small_argv(a, a.port + 1), a.port + 1, log)
        row["both_loaded"] = snap({"flash_next": fn, "qwen35_4b": small}, gtt0, vram0)
        row["fn_with_4b_tps"] = decode_runs(a.port, text)
        row["small_tps"] = decode_runs(a.port + 1, text)

        pair = []
        for _ in range(3):
            out, errs = {}, []
            barrier = threading.Barrier(2)

            def go(name, port):
                try:
                    barrier.wait()
                    out[name] = text_completion(port, text)
                except Exception as e:
                    errs.append(repr(e))
            ts = [threading.Thread(target=go, args=("fn", a.port)),
                  threading.Thread(target=go, args=("small", a.port + 1))]
            [t.start() for t in ts]
            [t.join() for t in ts]
            if errs or len(out) != 2:
                raise grid.RowError(f"concurrent decode failed: {errs}")
            pair.append(out)
        row["concurrent_tps"] = pair
        row["after_decodes"] = snap({"flash_next": fn, "qwen35_4b": small}, gtt0, vram0)
        row["tool_call_with_4b"] = grid.tool_call(a.port)
        return row
    finally:
        for p in (small, fn):
            if p:
                try:
                    stop(p)
                except BaseException:
                    stop(p)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("context", "coresident"):
        p = sub.add_parser(name)
        p.add_argument("--server", required=True)
        p.add_argument("--target", required=True)
        p.add_argument("--draft", required=True)
        p.add_argument("--port", type=int, default=18130)
        p.add_argument("--corpus-root", default=".")
        p.add_argument("--corpus-rev", default=None)
        if name == "context":
            p.add_argument("--ctx", type=int, required=True)
            p.add_argument("--kv", choices=["q8_0", "f16"], required=True)
        else:
            p.add_argument("--small", required=True)
            p.add_argument("--ctx", type=int, default=65536)
            p.add_argument("--small-ctx", type=int, default=32768)
    a = ap.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(143))
    fn = context_row if a.cmd == "context" else coresident_row
    with tempfile.TemporaryFile(mode="w+", errors="replace") as log:
        try:
            row = fn(a, log)
        except Exception as e:
            code = {grid.BusyError: 2, grid.MemError: 3, HostNotQuiet: 4}.get(type(e), 1)
            log.seek(0)
            print(json.dumps({"error": str(e) if isinstance(e, grid.RowError) else repr(e),
                              "cmd": a.cmd, "server_tail": log.read()[-1500:]}))
            return code
    print(json.dumps(row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
