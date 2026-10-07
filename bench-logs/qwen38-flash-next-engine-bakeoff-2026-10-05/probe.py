#!/usr/bin/env python3
"""One engine configuration for Qwen3.8-Flash-Next, measured end to end over HTTP.

Subcommands:
  wait-load   wait for 1-min loadavg < 2 (or --max-load-wait seconds), print the load flag
  corpus      build the shared text corpus + agent-replay conversation into --cache
  llama       start one llama-server (stock or HIP fork), run --do groups, print one JSON row
  gufo        start one Gufo container, run --do groups, print one JSON row
  strata      start one Strata server (python serve/server.py + the strata engine), run --do groups, print one JSON row
  exec        run the argv after `--` behind the gate under a memory watchdog, print one JSON row (output in --child-log)
  gufo-help   print `gufo serve llm --help` from the image
  analyze     compare the correctness rows of a JSONL file against reference rows

Every engine gets identical text over /v1/completions (speed groups) and /v1/chat/completions
(replay, toolcall, correctness); timing is client-side so engines are comparable. Speed prompts are
a unique nonce line plus a corpus slice. Strata has no /v1/completions and no ignore_eos: its speed
groups go over /v1/chat/completions (the chat template wraps the prompt, so prompt_tokens includes
template tokens) and ask for a long essay so generation reaches max_tokens. Groups (--do, comma
list): prefill4k decode512 decode32k decode128k replay toolcall correctness concurrency vision tasks soak longsoak bigimage quirks.
vision (strata only, needs --vision-bin and --mmproj) sends a generated red|blue PNG and passes iff
the answer names both colours.
tasks (the 16-task agent/code/long-context quality set of ../qwen38-flash-next-iq3-quality-2026-10-06/tasks.py; --quick runs one task per category).
soak, longsoak, bigimage (strata only; ../qwen38-flash-next-strata-quality-2026-10-07/soak.py): three agent replays plus 2 and 4 concurrent
requests; --soak-minutes of continuous mixed requests with thinking on; a screenshot (SCREENSHOT_PNG, needs --vision-max-tokens 1024)
through the CPU encoder with a concurrent text request.

Exit: 0 ok, 1 row error, 2 foreign benchmark running, 3 memory gate, 4 strict load wait expired,
7 usage error (argparse; no JSON row), 143 signalled. Other failures still print one JSON line with "error",
"label" and "server_tail".
"""
import argparse
import base64
import collections
import concurrent.futures
import contextlib
import grp
import importlib.util
import json
import os
import re
import shlex
import signal
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import types
import urllib.error
import urllib.request
import uuid
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "grid", os.path.join(HERE, "..", "qwen38-flash-next-mtp-tuning-2026-10-04", "grid.py"))
grid = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grid)
grid.WATCHED.update({"gufo", "strata"})
grid.WATCHED.add("llama-perplexity")  # comm is truncated to 15 chars; preflight_busy matches argv[0]'s basename

DEFER = None


def _on_signal(sig, _frame):
    if isinstance(DEFER, list):
        DEFER.append(sig)
    elif sig == signal.SIGINT:
        raise KeyboardInterrupt
    else:
        sys.exit(143)

GROUPS = ["toolcall", "prefill4k", "decode512", "decode32k", "decode128k", "replay", "correctness", "concurrency", "vision", "tasks",
          "soak", "longsoak", "bigimage", "quirks"]
SLICE_TOKENS = (512, 4096, 32768, 130000)
DECODE_SLICE = {"decode512": "512", "decode32k": "32768", "decode128k": "130000"}
CONC_OFFSETS = (40000, 60000, 80000, 100000)
GEN = 128
REPLAY_GEN = 300
SYSTEM_TOKENS = 6000
DOC_FILES = ["AGENTS.md", "CLAUDE.md", "README.md"]
TURN_FILES = ["flake.nix", "modules/amd-npu.nix", "pkgs/lemonade/default.nix",
              "bench-logs/qwen38-flash-next-mtp-tuning-2026-10-04/grid.py", "pkgs/fastflowlm/default.nix",
              "docs/rocm-gfx1151-numerics.md", "docs/halo-bringup-checklist.md", "pkgs/xrt/default.nix"]
TURN_TOKENS = [2000, 3000, 4000, 5000, 6000, 7000, 8000, 2500]
SYSTEM_INTRO = ("You are a coding agent working in the repository whose conventions and documentation "
                "follow. Use the tools to inspect files before changing anything.\n\n")
USER_TASK = ("I want to understand how this repository packages and benchmarks local LLM inference on an "
             "AMD Strix Halo machine. Read the Nix expressions and docs you think matter, then explain which "
             "parts of the NPU, ROCm and llama.cpp stack are built here, which numbers in the docs are "
             "hardware-gated, and what you would check first before changing the benchmark harness.")
TOOLS = [
    {"type": "function", "function": {
        "name": "read_file", "description": "Read a file from the repository.",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "grep", "description": "Search files in the repository for a regular expression.",
        "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}, "path": {"type": "string"}},
                       "required": ["pattern", "path"]}}},
    {"type": "function", "function": {
        "name": "run_tests", "description": "Run the test target and return its output.",
        "parameters": {"type": "object", "properties": {"target": {"type": "string"}}, "required": ["target"]}}},
]
TOOLCALL_BODY = {
    "messages": [{"role": "user", "content": "What is the weather in Paris right now? Use the tool."}],
    "tools": [{"type": "function", "function": {
        "name": "get_weather", "description": "Get the current weather for a city.",
        "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}],
    "max_tokens": 2048, "temperature": 0,
}

PROMPTS = [
    ("code1", "Write a Python function `fib(n)` that returns the n-th Fibonacci number iteratively "
              "(fib(0) = 0, fib(1) = 1). Reply with only the code."),
    ("code2", "Write a Python function `is_palindrome(s)` that ignores case and non-alphanumeric characters. "
              "Reply with only the code."),
    ("code3", "Write a Python function `merge_sorted(a, b)` that merges two sorted lists into one sorted list "
              "in linear time. Reply with only the code."),
    ("code4", "Write a bash one-liner that prints the ten most frequent words in the file `words.txt`, one per "
              "line with its count. Reply with only the command."),
    ("code5", "Write a Go function `Reverse(s string) string` that reverses a string correctly for multi-byte "
              "UTF-8 characters. Reply with only the code."),
    ("code6", "Write a SQL query that returns the second highest salary from a table `employees(id, name, "
              "salary)`, or NULL if there is none. Reply with only the query."),
    ("code7", "Write a Python function `parse_kv(line)` that parses a string like `a=1;b=2;c=3` into a dict "
              "mapping str to int. Reply with only the code."),
    ("code8", "Write a C function `int gcd(int a, int b)` using Euclid's algorithm. Reply with only the code."),
    ("math1", "A train travels 180 km in 2.5 hours. At the same speed, how far does it travel in 4 hours? "
              "Show brief reasoning, then the answer."),
    ("math2", "What is the sum of the first 50 positive odd numbers? Show brief reasoning."),
    ("math3", "Solve for x: 3x + 7 = 2x - 5. Show the steps."),
    ("math4", "How many distinct ways can the letters of the word LEVEL be arranged? Explain briefly."),
    ("math5", "A rectangle has perimeter 36 and area 80. What are its side lengths? Explain briefly."),
    ("math6", "What is the remainder when 7^100 is divided by 5? Explain briefly."),
    ("prose1", "Summarize the plot of Romeo and Juliet in three sentences."),
    ("prose2", "Explain in one paragraph why the sky is blue."),
    ("prose3", "Write a four-line poem about the sea at dawn."),
    ("prose4", "Describe the difference between a compiler and an interpreter in two short paragraphs."),
    ("prose5", "Give three practical tips for keeping a houseplant alive, as a short list."),
    ("prose6", "Continue this public-domain opening in one paragraph: \"It was the best of times, it was "
               "the worst of times,\""),
]
SANITY = [
    ("What is 347 * 29? Reply with only the number.", "10063"),
    ("What is 1234 + 8766? Reply with only the number.", "10000"),
    ("What is 15% of 240? Reply with only the number.", "36"),
    ("What is 2 to the power of 16? Reply with only the number.", "65536"),
    ("What is 9999 - 1234? Reply with only the number.", "8765"),
    ("What does this Python print? Reply with only the output.\n\nprint(sum(range(10)))", "45"),
    ("What does this Python print? Reply with only the output.\n\nprint('abc'[::-1])", "cba"),
    ("What does this Python print? Reply with only the output.\n\n"
     "print(len([x for x in range(20) if x % 3 == 0]))", "7"),
    ("What does this Python print? Reply with only the output.\n\nprint(7 // 2, 7 % 2)", "3 1"),
    ("What does this Python print? Reply with only the output.\n\nprint('-'.join(['a', 'b', 'c']))", "a-b-c"),
]


class LoadError(grid.RowError):
    pass


class EnginePid(int):
    """The strata engine's pid; pgid is the server's process group, which holds the whole tree."""
    pgid = None


def group_members(pgid):
    """Live (non-zombie) pids in a process group; a zombie has already released its files and GPU memory."""
    out = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/stat") as f:
                state, _, pgrp = f.read().rsplit(")", 1)[1].split()[:3]
        except (OSError, ValueError):
            continue
        if int(pgrp) == pgid and state not in ("Z", "X"):
            out.append(int(d))
    return out


def tree_status_kb(pgid, key):
    total = 0
    for pid in group_members(pgid):
        try:
            total += grid.proc_status_kb(pid, key) or 0
        except OSError:
            pass  # exited between the listing and the read
    return total


def mem_snapshot(pid, gtt0, vram0):
    gtt, vram = grid.gpu_mem()
    swap = {}
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith(("SwapTotal:", "SwapFree:")):
                swap[line.split(":")[0]] = int(line.split()[1])
    snap = {
        "rss_kb": grid.proc_status_kb(pid, "VmRSS"),
        "rss_anon_kb": grid.proc_status_kb(pid, "RssAnon"),
        "rss_file_kb": grid.proc_status_kb(pid, "RssFile"),
        "gtt_delta_bytes": None if gtt0 is None else gtt - gtt0,
        "vram_delta_bytes": None if vram0 is None else vram - vram0,
        "mem_available_kb": grid.mem_available_kb(),
        "swap_used_kb": swap["SwapTotal"] - swap["SwapFree"],
    }
    if getattr(pid, "pgid", None):
        snap["tree_rss_kb"] = tree_status_kb(pid.pgid, "VmRSS")
    return snap


@contextlib.contextmanager
def loadavg_peak():
    """Max 1-min loadavg over the block, sampled every 5 s; "max" is None if sampling failed."""
    peak = {"max": os.getloadavg()[0]}
    stop = threading.Event()

    def sample():
        try:
            while not stop.wait(5):
                peak["max"] = max(peak["max"], os.getloadavg()[0])
        except OSError:
            peak["max"] = None  # a dead sampler must not leave a partial max that reads as a measurement

    t = threading.Thread(target=sample, daemon=True)
    t.start()
    try:
        yield peak
    finally:
        stop.set()
        t.join(timeout=2)


@contextlib.contextmanager
def gtt_peak(gtt0):
    """Max GTT delta over the block, sampled every 0.5 s (shorter spikes are missed); "bytes" is None without a reading or if sampling failed."""
    peak = {"bytes": None}
    stop = threading.Event()

    def sample():
        try:
            while not stop.is_set():
                gtt, _ = grid.gpu_mem()
                if gtt is not None and gtt0 is not None:
                    peak["bytes"] = max(peak["bytes"] or 0, gtt - gtt0)
                stop.wait(0.5)
        except (OSError, ValueError):
            peak["bytes"] = None  # a dead sampler must not leave a partial peak that reads as a measurement

    t = threading.Thread(target=sample, daemon=True)
    t.start()
    try:
        yield peak
    finally:
        stop.set()
        t.join(timeout=2)  # a sysfs read stuck on a wedged GPU must not hang the exit path


def stats(xs):
    return {"mean": round(statistics.mean(xs), 3),
            "stdev": round(statistics.stdev(xs), 3) if len(xs) > 1 else 0.0,
            "runs": [round(x, 3) for x in xs]}


def gate(a, draft):
    """Foreign-process, load and memory gates; returns load_flag."""
    def no_foreign():
        busy = grid.preflight_busy()
        if busy:
            raise grid.BusyError(f"other benchmark processes running: {busy}")

    no_foreign()
    os.environ["GRID_LOAD_WAIT_S"] = str(a.max_load_wait)
    load_flag = grid.wait_for_quiet_load()
    if load_flag and a.strict_load:
        raise LoadError(f"host load stayed >= 2 for {a.max_load_wait}s")
    no_foreign()
    if a.need_gib is None:
        grid.check_memory(a.target, draft)
    else:
        have = grid.mem_available_kb() * 1024
        if have < a.need_gib * (1 << 30):
            raise grid.MemError(f"insufficient memory: need {a.need_gib} GiB, MemAvailable {have / (1 << 30):.1f} GiB")
    return load_flag


# ---- HTTP -------------------------------------------------------------------------------------

def sse(port, path, body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=3600) as r:
            for raw in r:
                line = raw.decode().strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    return
                yield json.loads(payload)
    except urllib.error.HTTPError as e:
        raise grid.RowError(f"HTTP {e.code} on {path}: {e.read().decode()[:500]}") from e
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise grid.RowError(f"request to {path} failed: {e!r}") from e


def stream(e, path, body):
    """POST a streaming request. A chunk counts as output when it carries text or tool-call deltas."""
    body = {**body, "model": e.model, "stream": True, "stream_options": {"include_usage": True}}
    t_send = time.perf_counter()
    t_first = t_last = None
    text, usage, timings, finish = [], {}, {}, None
    for chunk in sse(e.port, path, body):
        now = time.perf_counter()
        usage = chunk.get("usage") or usage
        timings = chunk.get("timings") or timings
        for c in chunk.get("choices") or []:
            d = c.get("delta", c)
            if d.get("reasoning_content"):
                raise grid.RowError("reasoning_content returned with thinking disabled")
            piece = d.get("text") or d.get("content") or ""
            if piece or d.get("tool_calls"):
                t_first = t_first or now
                t_last = now
                text.append(piece)
            finish = c.get("finish_reason") or finish
    t_end = time.perf_counter()
    if t_first is None:
        raise grid.RowError(f"{path} stream produced no output")
    if not usage:
        raise grid.RowError(f"{path} stream ended without a usage chunk")
    cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens", timings.get("cache_n"))
    return {"ttft_s": t_first - t_send, "gen_s": t_last - t_first, "wall_s": t_end - t_send,
            "text": "".join(text), "finish_reason": finish, "prompt_tokens": usage["prompt_tokens"],
            "completion_tokens": usage["completion_tokens"], "cached_tokens": cached,
            "timings": timings, "gufo": usage.get("gufo")}


def stream_complete(e, prompt_text, max_tokens, temperature, seed, ignore_eos=True, cache_prompt=False):
    if e.engine == "strata":
        # Strata has no /v1/completions and no ignore_eos: ask for an essay far longer than any max_tokens used
        # here, so the completion_tokens == max_tokens check below still catches an early stop.
        body = {"messages": [{"role": "user", "content": (
                    f"# run {uuid.uuid4()}\n{prompt_text}\n\nWrite a very long, detailed, multi-section essay "
                    "about the documents above, at least 1500 words.")}],
                "max_tokens": max_tokens, "temperature": temperature, "seed": seed, **thinking_off(e)}
        r = stream(e, "/v1/chat/completions", body)
        if ignore_eos and r["completion_tokens"] != max_tokens:
            raise grid.RowError(f"generation stopped short: {r['completion_tokens']} != {max_tokens}")
        return r
    body = {"prompt": f"# run {uuid.uuid4()}\n{prompt_text}", "max_tokens": max_tokens,
            "temperature": temperature, "seed": seed, "ignore_eos": ignore_eos}
    if e.engine == "llama":  # Gufo documents cache_prompt only for chat/responses and rejects unknown fields
        body["cache_prompt"] = cache_prompt
    r = stream(e, "/v1/completions", body)
    if ignore_eos and r["completion_tokens"] != max_tokens:
        raise grid.RowError(f"generation stopped short: {r['completion_tokens']} != {max_tokens}")
    return r


def prefill_tps(r):
    return r["prompt_tokens"] / r["ttft_s"]


def decode_tps(r):
    if r["completion_tokens"] < 2 or r["gen_s"] <= 0:
        return None
    return (r["completion_tokens"] - 1) / r["gen_s"]


def require_decode_tps(r):
    tps = decode_tps(r)
    if tps is None:
        raise grid.RowError("no decode timing: all tokens in one chunk")
    return tps


def thinking_off(e):
    if e.engine == "gufo":
        return {"reasoning_effort": "none"}
    return {"chat_template_kwargs": {"enable_thinking": False}}


def scrape_metrics(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=30) as r:
        lines = r.read().decode().splitlines()
    out = {}
    for line in lines:
        if line.startswith("#") or not line.strip():
            continue
        name, _, value = line.rpartition(" ")
        if re.search(r"spec|draft|accept|verif|mtp", name.split("{")[0], re.I):
            out[name] = float(value)
    return out


# ---- groups -----------------------------------------------------------------------------------

def check_uncached(rs):
    for r in rs:
        if (r["cached_tokens"] or 0) > 0.05 * r["prompt_tokens"]:
            raise grid.RowError(f"prompt cache hit on a speed run: {r['cached_tokens']} of {r['prompt_tokens']}")


def speed_fields(rs):
    out = {"prompt_tokens": rs[0]["prompt_tokens"], "prefill_tps": stats([prefill_tps(r) for r in rs]),
           "cached_tokens": [r["cached_tokens"] for r in rs]}
    if any(r["timings"] for r in rs):
        out["server_prompt_tps"] = [r["timings"].get("prompt_per_second") for r in rs]
        out["server_decode_tps"] = [r["timings"].get("predicted_per_second") for r in rs]
    if any(r["gufo"] for r in rs):
        out["gufo_usage"] = [r["gufo"] for r in rs]
    return out


def g_prefill4k(e, c, quick):
    rs = [stream_complete(e, c["slices"]["4096"], 1, 0.0, 0) for _ in range(3)]
    check_uncached(rs)
    return speed_fields(rs)


def g_decode(e, c, quick, group):
    text = c["slices"][DECODE_SLICE[group]]
    seeds = (1,) if quick else (1, 2, 3)
    before = scrape_metrics(e.port) if e.engine == "gufo" else None
    rs = [stream_complete(e, text, GEN, 0.7, s) for s in seeds] + [stream_complete(e, text, GEN, 0.0, 0)]
    check_uncached(rs)
    out = speed_fields(rs)
    out["decode_tps"] = stats([require_decode_tps(r) for r in rs[:-1]])
    out["decode_tps_t0"] = round(require_decode_tps(rs[-1]), 3)
    drafted = sum(r["timings"].get("draft_n") or 0 for r in rs)
    accepted = sum(r["timings"].get("draft_n_accepted") or 0 for r in rs)
    out["acceptance"] = round(accepted / drafted, 4) if drafted else None
    if before is not None:
        after = scrape_metrics(e.port)
        out["metrics_delta"] = {k: round(v - before.get(k, 0), 6) for k, v in after.items()}
        d = {k.split("{")[0].split(":")[-1]: v for k, v in out["metrics_delta"].items()}
        proposed = d.get("spec_decode_num_draft_tokens_total")
        accepted_m = d.get("spec_decode_num_accepted_tokens_total")
        if out["acceptance"] is None and proposed and accepted_m is not None:
            out["acceptance"] = round(accepted_m / proposed, 4)
    return out


def png(width, height, pixel):
    """Deterministic RGB PNG; pixel(x) is the (r, g, b) of column x."""
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    row = b"\x00" + b"".join(bytes(pixel(x)) for x in range(width))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * height, 9)) + chunk(b"IEND", b""))


def red_blue_png():
    return png(128, 128, lambda x: (255, 0, 0) if x < 64 else (0, 0, 255))


def g_vision(e, c, quick):
    if e.engine != "strata":
        raise grid.RowError("the vision group is only wired for the strata subcommand")
    url = "data:image/png;base64," + base64.b64encode(red_blue_png()).decode()
    r = stream(e, "/v1/chat/completions", {
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": url}},
            {"type": "text", "text": "Which two colors does this image show? Answer with the color names only."}]}],
        "max_tokens": 64, "temperature": 0, **thinking_off(e)})
    answer = r["text"]
    return {"ok": {"red", "blue"} <= set(re.findall(r"[a-z]+", answer.lower())), "answer": answer[:200],
            "ttft_s": round(r["ttft_s"], 3), "wall_s": round(r["wall_s"], 3), "prompt_tokens": r["prompt_tokens"]}


def g_replay(e, c, quick, decode32k):
    rp = c["replay"]
    rate = decode32k["decode_tps"]["mean"] if decode32k else None
    turns = []
    for k in range(1, len(rp["turns"]) + 1):
        msgs = [{"role": "system", "content": rp["system"]}, {"role": "user", "content": rp["user"]}]
        for t in rp["turns"][:k]:
            msgs += [t["assistant"], t["tool"]]
        r = stream(e, "/v1/chat/completions", {
            "messages": msgs, "tools": rp["tools"], "max_tokens": REPLAY_GEN, "temperature": 0, "seed": 0,
            "cache_prompt": True, **thinking_off(e)})
        if "<think>" in r["text"]:
            raise grid.RowError(f"<think> in replay turn {k} output")
        own = decode_tps(r)
        fallback = r["completion_tokens"] < 32 or own is None
        use = rate if fallback else own
        turns.append({"turn": k, "ttft_s": round(r["ttft_s"], 4), "prompt_tokens": r["prompt_tokens"],
                      "completion_tokens": r["completion_tokens"],
                      "decode_tps": None if own is None else round(own, 3),
                      "cached_tokens": r["cached_tokens"], "wall_s": round(r["wall_s"], 4),
                      "server_timings": {k: r["timings"].get(k) for k in (
                          "prompt_n", "prompt_ms", "predicted_n", "predicted_ms", "predicted_per_second")}
                      if r["timings"] else None,
                      "finish_reason": r["finish_reason"], "rate_fallback": fallback,
                      "normalized_s": None if use is None else round(r["ttft_s"] + REPLAY_GEN / use, 4)})
    complete = all(t["normalized_s"] is not None for t in turns)
    return {"turns": turns, "wall_total_s": round(sum(t["wall_s"] for t in turns), 3),
            "ttft_total_s": round(sum(t["ttft_s"] for t in turns), 3),
            "normalized_total_s": round(sum(t["normalized_s"] for t in turns), 3) if complete else None,
            "normalized_incomplete": not complete, "fallback_decode_tps": rate}


def g_toolcall(e, c, quick):
    resp = grid.http(e.port, "/v1/chat/completions", {**TOOLCALL_BODY, "model": e.model, **thinking_off(e)})
    choice = resp["choices"][0]
    msg = choice["message"]
    calls = msg.get("tool_calls")
    ok = False
    if isinstance(calls, list) and calls:
        try:
            args = json.loads(calls[0]["function"]["arguments"])
            ok = isinstance(args, dict) and "city" in args
        except (json.JSONDecodeError, KeyError, TypeError):
            pass
    finish = choice.get("finish_reason")
    return {"tool_call_ok": ok and finish == "tool_calls", "finish_reason": finish,
            "content_head": (msg.get("content") or "")[:200]}


def chat_once(e, content):
    resp = grid.http(e.port, "/v1/chat/completions", {
        "model": e.model, "messages": [{"role": "user", "content": content}],
        "max_tokens": 256, "temperature": 0, "seed": 0, **thinking_off(e)})
    choice = resp["choices"][0]
    if choice["message"].get("reasoning_content"):
        raise grid.RowError("reasoning_content returned with thinking disabled")
    return choice["message"].get("content") or "", choice.get("finish_reason")


def normalize_answer(s):
    s = re.sub(r"\s+", " ", s.strip())
    return s.strip("`").strip().rstrip(".").strip()


def g_correctness(e, c, quick):
    outputs = []
    for pid, prompt in PROMPTS:
        text, finish = chat_once(e, prompt)
        outputs.append({"id": pid, "text": text, "finish_reason": finish})
    sanity = []
    for q, expected in SANITY:
        text, finish = chat_once(e, q)
        sanity.append({"q": q, "expected": expected, "text": text, "finish_reason": finish,
                       "ok": normalize_answer(text) == expected})
    return {"outputs": outputs, "sanity": sanity, "sanity_score": sum(s["ok"] for s in sanity)}


def g_tasks(e, c, quick):
    path = os.path.join(HERE, "..", "qwen38-flash-next-iq3-quality-2026-10-06", "tasks.py")
    tasks_spec = importlib.util.spec_from_file_location("tasks", path)
    tasks = importlib.util.module_from_spec(tasks_spec)
    tasks_spec.loader.exec_module(tasks)
    return tasks.run(e, c, quick)


def g_soak(group, e, c, quick, minutes=None):
    path = os.path.join(HERE, "..", "qwen38-flash-next-strata-quality-2026-10-07", "soak.py")
    soak_spec = importlib.util.spec_from_file_location("soak", path)
    soak = importlib.util.module_from_spec(soak_spec)
    soak_spec.loader.exec_module(soak)
    me = sys.modules[__name__]
    if group == "soak":
        return soak.run_short(e, c, me)
    if group == "longsoak":
        return soak.run_long(e, c, me, minutes)
    if group == "quirks":
        return soak.run_quirks(e, c, me)
    return soak.run_image(e, c, me)


def g_concurrency(e, c, quick):
    out = {}
    for users in (2, 4):
        t0 = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(users) as pool:
            futs = [pool.submit(stream_complete, e, c["conc_slices"][i], GEN, 0.7, i + 1) for i in range(users)]
            rs = [f.result() for f in futs]
        wall = time.perf_counter() - t0
        total = sum(r["completion_tokens"] for r in rs)
        rates = [require_decode_tps(r) for r in rs]
        out[str(users)] = {"per_request_decode_tps": [round(x, 3) for x in rates],
                           "sum_decode_tps": round(sum(rates), 3), "completion_tokens": total,
                           "wall_s": round(wall, 3), "aggregate_tps": round(total / wall, 3),
                           "decode_aggregate_tps": round(total / (wall - max(r["ttft_s"] for r in rs)), 3),
                           "ttft_s": [round(r["ttft_s"], 3) for r in rs],
                           "prompt_tokens": [r["prompt_tokens"] for r in rs]}
    return out


# ---- servers ----------------------------------------------------------------------------------

def stop(proc, timeout=30):
    proc.terminate()
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


@contextlib.contextmanager
def llama_server(a, log):
    argv = [a.server, "--model", a.target, "--port", str(a.port), "--host", "127.0.0.1", "-c", str(a.ctx),
            "-fa", "on", "-ctk", "q8_0", "-ctv", "q8_0", "--jinja", "--metrics"]
    if a.draft:
        argv += ["--model-draft", a.draft, "--spec-type", "draft-mtp", "--spec-draft-n-max", "3"]
    argv += ["-np", str(a.slots), "--no-kv-unified"] if a.slots > 1 else ["--parallel", "1"]
    argv += shlex.split(a.extra)
    env = {**os.environ, **dict(kv.split("=", 1) for kv in a.env)}
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=log, env=env)
    try:
        if not grid.wait_ready(proc, a.port):
            raise grid.RowError("server not ready")
        yield proc.pid
    finally:
        stop(proc)


STRATA_READY_S = 1800  # loading the pack (and the vision encoder) takes minutes


def strata_config(a, tmp):
    vision = bool(a.vision_bin and a.mmproj)
    args = ["--pack", a.pack, "--native", a.target] + (["--mtp", a.mtp_rt] if a.mtp_rt else []) \
        + ["--max-context", str(a.ctx)] + (["--vision"] if vision else []) + shlex.split(a.extra)
    cfg = {"exe": a.engine_bin, "args": args, "cwd": a.repo, "tokenizer": os.path.join(a.pack, "tokenizer"),
           "model_name": "strata", "backend": "hip", "env": dict(kv.split("=", 1) for kv in a.env),
           "lib_dirs": a.lib_dir, "log": os.path.join(tmp, "engine.log"), "host": "127.0.0.1"}
    if vision:
        cfg["vision"] = {"exe": a.vision_bin, "mmproj": a.mmproj, "model": a.target, "max_tokens": a.vision_max_tokens}
    return cfg


def find_engine(root, proc, timeout=30):
    """Pid of the descendant of root whose comm is `strata`; polls because /health can precede the spawn."""
    deadline = time.time() + timeout
    while True:
        children = {}
        for d in os.listdir("/proc"):
            info = grid.proc_info(int(d)) if d.isdigit() else None
            if info:
                children.setdefault(info[2], []).append((int(d), info[0]))
        todo = [root]
        while todo:
            for pid, comm in children.get(todo.pop(), []):
                if comm == "strata":
                    return pid
                todo.append(pid)
        if proc.poll() is not None or time.time() > deadline:
            raise grid.RowError("no strata engine process under the server")
        time.sleep(0.5)


def stop_group(proc):
    """SIGTERM the server's process group, SIGKILL after 30 s, then wait for every member to be gone with no
    timeout: a group stuck in the kernel (a wedged GPU) must hang the probe rather than return, so the caller
    never reloads another model over it."""
    pgid = proc.pid

    def signal_group(sig):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pgid, sig)

    signal_group(signal.SIGTERM)
    deadline = time.time() + 30
    while time.time() < deadline and (proc.poll() is None or group_members(pgid)):
        time.sleep(0.2)
    signal_group(signal.SIGKILL)
    proc.wait()
    while group_members(pgid):
        time.sleep(0.5)


def cpu_ticks(pid=None):
    """Busy CPU ticks, system-wide from /proc/stat or one process (utime + stime); None if unreadable."""
    try:
        if pid is None:
            with open("/proc/stat") as f:
                v = [int(x) for x in f.readline().split()[1:]]
            return sum(v[:3]) + sum(v[5:8])  # user nice system, irq softirq steal: everything but idle and iowait
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return int(fields[11]) + int(fields[12])
    except (OSError, ValueError, IndexError):
        return None


def meminfo_kb(key):
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith(key + ":"):
                return int(line.split()[1])


def evict_files(paths):
    """Drop the page cache of the model files (no privilege needed): the engine reads its experts through it, and a
    large cache is what the lemond reload after the row would otherwise start from."""
    for path in paths:
        with contextlib.suppress(OSError), open(path, "rb") as f:
            os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)


def gguf_shards(first):
    m = re.match(r"^(.*)-\d{5}-of-(\d{5})\.gguf$", first)
    if not m:
        return [first]
    return [f"{m.group(1)}-{i:05d}-of-{m.group(2)}.gguf" for i in range(1, int(m.group(2)) + 1)]


@contextlib.contextmanager
def strata_server(a, log):
    with tempfile.TemporaryDirectory() as tmp:
        cfg_path = os.path.join(tmp, "config.json")
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(strata_config(a, tmp), f)
        argv = [a.python, "-m", "serve.server", "--engine", "strata", "--config", cfg_path,
                "--host", "127.0.0.1", "--port", str(a.port)]
        proc = subprocess.Popen(argv, cwd=a.repo, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                start_new_session=True)
        try:
            if not grid.wait_ready(proc, a.port, STRATA_READY_S):
                if proc.poll() is not None:
                    raise grid.RowError(f"strata server exited with code {proc.returncode} before becoming ready")
                raise grid.RowError(f"strata server not ready after {STRATA_READY_S}s")
            pid = EnginePid(find_engine(proc.pid, proc))
            pid.pgid = proc.pid
            yield pid
        except BaseException:
            with contextlib.suppress(OSError), open(os.path.join(tmp, "engine.log"), "rb") as f:
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - 3000))
                log.write("\n--- engine log tail ---\n" + f.read().decode(errors="replace"))
                log.flush()
            raise
        finally:
            # A second signal (run.sh forwards its own TERM to this process) must not cut the teardown short:
            # the engine is in its own session and only this wait keeps lemond from reloading over it.
            global DEFER
            DEFER = got = []
            try:
                stop_group(proc)
                if a.evict_after:
                    a.cached_kb_before_evict = meminfo_kb("Cached")
                    evict_files([os.path.realpath(p) for p in gguf_shards(a.target)])
                    a.cached_kb_after_evict = meminfo_kb("Cached")
            finally:
                DEFER = None
            if got:
                sys.exit(143)


def docker(*args, **kw):
    return subprocess.run(["docker", *args], capture_output=True, text=True, **kw)


def device_flags():
    return ["--device", "/dev/kfd", "--device", "/dev/dri",
            "--group-add", str(grp.getgrnam("video").gr_gid), "--group-add", str(grp.getgrnam("render").gr_gid)]


def hf_hub_root(*paths):
    p = os.path.commonpath(paths)
    while os.path.basename(p) not in ("hub", ""):
        p = os.path.dirname(p)
    if not p or p == "/":
        raise grid.RowError("model files are not under an HF hub directory")
    return p


@contextlib.contextmanager
def gufo_server(a, log):
    name = f"bakeoff-gufo-{re.sub(r'[^A-Za-z0-9_.-]', '-', a.label)}-{os.getpid()}"
    hub = hf_hub_root(a.target, a.draft)
    context, sessions = (131072, 1) if a.slots == 1 else (32768, a.slots)
    cmd = ["run", "-d", "--name", name, "--network", "host", *device_flags(),
           "--user", f"{os.getuid()}:{os.getgid()}", "--ulimit", "memlock=-1", "-v", f"{hub}:{hub}:ro",
           a.image, "gufo", "serve", "--host", "127.0.0.1", "--port", str(a.port), "llm", "--model", a.target,
           "--speculative", "mtp", "--mtp-model", a.draft, "--context", str(context), "--sessions", str(sessions)]
    started = docker(*cmd)
    if started.returncode:
        raise grid.RowError(f"docker run failed: {started.stderr.strip()[:500]}")
    try:
        pid = int(docker("inspect", "-f", "{{.State.Pid}}", name).stdout)
        deadline = time.time() + 900
        while True:
            if docker("inspect", "-f", "{{.State.Running}}", name).stdout.strip() != "true":
                raise grid.RowError("gufo container exited before becoming ready")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{a.port}/v1/models", timeout=5) as r:
                    if r.status == 200:
                        break
            except OSError:
                pass
            if time.time() > deadline:
                raise grid.RowError("gufo not ready after 15 min")
            time.sleep(2)
        yield pid
    except BaseException:
        tail = docker("logs", "--tail", "80", name)
        log.write(tail.stdout + tail.stderr)
        raise
    finally:
        docker("rm", "-f", name)


# ---- subcommands ------------------------------------------------------------------------------

def run_row(a, log):
    load_flag = gate(a, a.draft)
    with open(a.cache, encoding="utf-8") as f:
        cache = json.load(f)
    configurable = a.cmd in ("llama", "strata")  # extra, env and ctx come from the arguments
    row = {"host": socket.gethostname(), "engine": a.cmd, "label": a.label,
           "build": {"llama": lambda: grid.server_build(a.server), "gufo": lambda: a.image,
                     "strata": lambda: strata_build(a)}[a.cmd](),
           "extra": a.extra if configurable else None,
           "env": dict(kv.split("=", 1) for kv in a.env) if configurable else {},
           "slots": a.slots, "ctx": a.ctx if configurable else (131072 if a.slots == 1 else 32768),
           "loadavg_start": round(os.getloadavg()[0], 2), "load_flag": load_flag,
           "corpus_sha256": cache["corpus_sha256"]}
    do = set(a.do.split(","))
    gtt0, vram0 = grid.gpu_mem()
    t0 = time.time()
    cpu0 = {}
    server = {"llama": llama_server, "gufo": gufo_server, "strata": strata_server}[a.cmd]
    with gtt_peak(gtt0) as peak, loadavg_peak() as load, server(a, log) as pid:
        row["load_s"] = round(time.time() - t0, 1)
        e = types.SimpleNamespace(
            port=a.port, engine=a.cmd, model=grid.http(a.port, "/v1/models", timeout=30)["data"][0]["id"],
            pid=pid, gtt0=gtt0, vram0=vram0, args=a)
        row["mem_after_load"] = mem_snapshot(pid, gtt0, vram0)
        cpu0 = {"t": time.time(), "sys": cpu_ticks(), "eng": cpu_ticks(pid)}
        if "toolcall" in do:
            row["toolcall"] = g_toolcall(e, cache, a.quick)
        if "prefill4k" in do:
            row["prefill4k"] = g_prefill4k(e, cache, a.quick)
        for group in DECODE_SLICE:
            if group in do:
                row[group] = g_decode(e, cache, a.quick, group)
        if "replay" in do:
            row["replay"] = g_replay(e, cache, a.quick, row.get("decode32k"))
            row["mem_after_replay"] = mem_snapshot(pid, gtt0, vram0)
        if "correctness" in do:
            row["correctness"] = g_correctness(e, cache, a.quick)
        if "concurrency" in do:
            row["concurrency"] = g_concurrency(e, cache, a.quick)
        if "vision" in do:
            row["vision"] = g_vision(e, cache, a.quick)
        if "tasks" in do:
            row["tasks"] = g_tasks(e, cache, a.quick)
        for group in ("soak", "longsoak", "bigimage", "quirks"):
            if group in do:
                row[group] = g_soak(group, e, cache, a.quick, a.soak_minutes)
        row["mem_end"] = mem_snapshot(pid, gtt0, vram0)
        row["gtt_peak_delta_bytes"] = peak["bytes"]
        row["hwm_kb"] = grid.proc_status_kb(pid, "VmHWM")
        if a.cmd == "strata":
            row["tree_hwm_kb"] = tree_status_kb(pid.pgid, "VmHWM")  # sum of per-process peaks, not a joint peak
        if a.cmd == "strata" and None not in cpu0.values():
            # The engine's own CPU worker pool raises the 1-min loadavg by itself; the foreign share is what a
            # load rule can act on. Average busy cores over the requests, system-wide vs the engine process.
            wall, hz = time.time() - cpu0["t"], os.sysconf("SC_CLK_TCK")
            sys1, eng1 = cpu_ticks(), cpu_ticks(pid)
            if sys1 is not None and eng1 is not None and wall > 0:
                row["cpu_cores_system"] = round((sys1 - cpu0["sys"]) / hz / wall, 2)
                row["cpu_cores_engine"] = round((eng1 - cpu0["eng"]) / hz / wall, 2)
        row["loadavg_end"] = round(os.getloadavg()[0], 2)
        row["loadavg_max"] = None if load["max"] is None else round(load["max"], 2)
    if a.cmd == "strata":
        gtt, _ = grid.gpu_mem()
        row["gtt_after_stop_delta_bytes"] = None if gtt0 is None or gtt is None else gtt - gtt0
        row["cached_kb_before_evict"] = getattr(a, "cached_kb_before_evict", None)
        row["cached_kb_after_evict"] = getattr(a, "cached_kb_after_evict", None)
    return row


def strata_build(a):
    r = subprocess.run(["git", "-C", a.repo, "rev-parse", "HEAD"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else os.path.basename(a.engine_bin)


def detok(port, ids):
    # slicing can cut a multi-byte character; the server renders the fragment as U+FFFD
    return grid.http(port, "/detokenize", {"tokens": ids})["content"].strip("�")


def n_tokens(port, text):
    return len(grid.http(port, "/tokenize", {"content": text})["tokens"])


def git_out(root, *args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, check=True).stdout.decode("utf-8", "replace")


def build_replay(port, root, rev):
    tree = git_out(root, "ls-tree", "-r", "--name-only", rev).split("\n")
    docs = DOC_FILES + sorted(f for f in tree if re.fullmatch(r"docs/[^/]+\.md", f))
    doc_text = SYSTEM_INTRO + "".join(f"# {p}\n\n{git_out(root, 'show', f'{rev}:{p}')}\n\n" for p in docs)
    ids = grid.http(port, "/tokenize", {"content": doc_text})["tokens"]
    if len(ids) < SYSTEM_TOKENS:
        raise grid.RowError(f"repo docs yield only {len(ids)} tokens < {SYSTEM_TOKENS}")
    system = detok(port, ids[:SYSTEM_TOKENS])

    turns, turn_tokens = [], []
    for k, (path, target) in enumerate(zip(TURN_FILES, TURN_TOKENS), 1):
        text = git_out(root, "show", f"{rev}:{path}")
        following = iter(f for f in tree[tree.index(path) + 1:] if f.endswith(grid.EXTS))
        while True:
            ids = grid.http(port, "/tokenize", {"content": text})["tokens"]
            if len(ids) >= target:
                break
            nxt = next(following, None)
            if nxt is None:
                raise grid.RowError(f"no more files to reach {target} tokens for {path}")
            text += f"\n\n# {nxt}\n\n{git_out(root, 'show', f'{rev}:{nxt}')}"
        text = detok(port, ids[:target])
        turn_tokens.append(n_tokens(port, text))
        call = {"id": f"call_{k}", "type": "function",
                "function": {"name": "read_file", "arguments": json.dumps({"path": path})}}
        turns.append({"path": path,
                      "assistant": {"role": "assistant", "content": f"I'll read {path} next.", "tool_calls": [call]},
                      "tool": {"role": "tool", "tool_call_id": call["id"], "content": text}})
    return ({"system": system, "tools": TOOLS, "user": USER_TASK, "turns": turns},
            {"system": n_tokens(port, system), "turns": turn_tokens})


def build_cache(a, port):
    ids, files, sha = grid.build_corpus(port, a.corpus_root, max(SLICE_TOKENS), a.corpus_rev)
    slices = {str(n): detok(port, ids[:n]) for n in SLICE_TOKENS}
    conc = [detok(port, ids[o:o + 512]) for o in CONC_OFFSETS]
    replay, replay_tokens = build_replay(port, a.corpus_root, a.corpus_rev)
    return {"corpus_rev": a.corpus_rev, "corpus_sha256": sha, "corpus_files": files, "slices": slices,
            "slice_tokens": {k: n_tokens(port, v) for k, v in slices.items()},
            "conc_slices": conc, "conc_slice_tokens": [n_tokens(port, t) for t in conc],
            "replay": replay, "replay_tokens": replay_tokens, "tokenizer_target": os.path.basename(a.target)}


def run_corpus(a, log):
    gate(a, "")
    argv = [a.server, "--model", a.target, "--port", str(a.port), "--host", "127.0.0.1", "-c", str(a.ctx),
            "--parallel", "1", "--no-warmup"]
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=log)
    try:
        if not grid.wait_ready(proc, a.port):
            raise grid.RowError("server not ready")
        cache = build_cache(a, a.port)
    finally:
        stop(proc)
    with open(a.cache, "w", encoding="utf-8") as f:
        json.dump(cache, f)
    return {"cache": a.cache, "corpus_rev": cache["corpus_rev"], "corpus_sha256": cache["corpus_sha256"],
            "corpus_files": cache["corpus_files"], "slice_tokens": cache["slice_tokens"],
            "conc_slice_tokens": cache["conc_slice_tokens"], "replay_tokens": cache["replay_tokens"],
            "tokenizer_target": cache["tokenizer_target"]}


EXEC_CPU_GTT_LIMIT = 1 << 30


def swap_used_kb():
    swap = {}
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith(("SwapTotal:", "SwapFree:")):
                swap[line.split(":")[0]] = int(line.split()[1])
    return swap["SwapTotal"] - swap["SwapFree"]


def run_exec(a, log):
    """Run argv after `--` behind the memory gate; a watchdog kills it on host-memory trouble.

    Child stdout and stderr go to --child-log only: stdout here is one JSON row that run.sh appends to the row file.
    """
    load_flag = gate(a, a.draft)
    row = {"host": socket.gethostname(), "label": a.label, "engine": "exec", "dev": a.dev,
           "loadavg_start": round(os.getloadavg()[0], 2), "load_flag": load_flag, "argv": a.child,
           "child_log": a.child_log}
    gtt0, _ = grid.gpu_mem()
    swap0 = swap_used_kb()
    killed_by = None
    peak_anon_kb = peak_swap_kb = None
    t0 = time.time()
    with open(a.child_log, "wb") as out, gtt_peak(gtt0) as peak:
        proc = subprocess.Popen(a.child, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT)
        try:
            while True:
                try:
                    proc.wait(timeout=0.5)
                    break
                except subprocess.TimeoutExpired:
                    pass
                try:
                    anon_kb = grid.proc_status_kb(proc.pid, "RssAnon")
                except OSError:  # exited since the wait timed out
                    continue
                swap_kb = swap_used_kb() - swap0
                peak_anon_kb = max(peak_anon_kb or 0, anon_kb or 0)
                peak_swap_kb = max(peak_swap_kb or 0, swap_kb)
                if a.dev == "cpu" and (peak["bytes"] or 0) > EXEC_CPU_GTT_LIMIT:
                    killed_by = "gtt_on_cpu"
                elif swap_kb > a.swap_limit_gib << 20:
                    killed_by = "swap_growth"
                elif (anon_kb or 0) > a.anon_limit_gib << 20:
                    killed_by = "anon_limit"
                if killed_by:
                    break
        finally:
            stop(proc, 5)
    row.update({"rc": proc.returncode, "killed_by": killed_by, "gtt_peak_delta_bytes": peak["bytes"],
                "rss_anon_peak_bytes": None if peak_anon_kb is None else peak_anon_kb * 1024,
                "swap_growth_peak_bytes": None if peak_swap_kb is None else peak_swap_kb * 1024,
                "wall_s": round(time.time() - t0, 1)})
    if killed_by:
        row["error"] = f"child killed by watchdog: {killed_by}"
    elif proc.returncode:
        row["error"] = f"child exited {proc.returncode}"
    return row


def run_wait_load(a):
    t0 = time.time()
    os.environ["GRID_LOAD_WAIT_S"] = str(a.max_load_wait)
    flag = grid.wait_for_quiet_load()
    return {"load_flag": flag, "waited_s": round(time.time() - t0), "loadavg": round(os.getloadavg()[0], 2)}


def run_gufo_help(a):
    r = docker("run", "--rm", *device_flags(), a.image, "gufo", "serve", "llm", "--help")
    print(r.stdout + r.stderr)
    return r.returncode


def diverge(x, y):
    if x == y:
        return -1
    n = 0
    while n < min(len(x), len(y)) and x[n] == y[n]:
        n += 1
    return n


def looping(ids, n=8, share=0.4):
    if len(ids) < n:
        return False
    grams = [tuple(ids[i:i + n]) for i in range(len(ids) - n + 1)]
    top = collections.Counter(grams).most_common(1)[0][0]
    covered = set()
    for i, g in enumerate(grams):
        if g == top:
            covered.update(range(i, i + n))
    return len(covered) >= share * len(ids)


def run_analyze(a):
    rows = {}
    with open(a.rows, encoding="utf-8") as f:
        for line in f:
            r = json.loads(line)
            if "correctness" in r:
                rows[r["label"]] = r
    for ref in filter(None, (a.ref, a.ref2)):
        if ref not in rows:
            raise grid.RowError(f"no correctness row labelled {ref}")
    tok_s = 0.0
    memo = {}

    def ids_of(text):
        nonlocal tok_s
        if text not in memo:
            t = time.time()
            r = subprocess.run([a.tokenizer_bin, "-m", a.vocab, "--ids", "--log-disable", "--stdin"],
                               input=text, capture_output=True, text=True, check=True)
            memo[text] = json.loads(r.stdout)
            tok_s += time.time() - t
        return memo[text]

    def per_prompt(row):
        return {o["id"]: {"text": o["text"], "ids": ids_of(o["text"])} for o in row["correctness"]["outputs"]}

    def degenerate(p):
        return "�" in p["text"] or looping(p["ids"])

    def compare(row, ref):
        mine, theirs = per_prompt(row), per_prompt(ref)
        div = {i: diverge(mine[i]["ids"], theirs[i]["ids"]) for i in mine}
        diverged = [d for d in div.values() if d >= 0]
        exact = sum(d < 0 for d in div.values())
        median = statistics.median(diverged) if diverged else None
        bad = sorted(i for i in mine if degenerate(mine[i]) and not degenerate(theirs[i]))
        sanity, ref_sanity = row["correctness"]["sanity_score"], ref["correctness"]["sanity_score"]
        reasons = []
        if sanity < ref_sanity - 1:
            reasons.append(f"sanity {sanity} < reference {ref_sanity} - 1")
        if bad:
            reasons.append(f"degenerate outputs the reference does not have: {bad}")
        early = exact == 0 and median is not None and median < 10
        return {"reference": ref["label"], "exact_match": exact, "prompts": len(div),
                "median_first_divergence": median, "first_divergence": div, "sanity_score": sanity,
                "reference_sanity_score": ref_sanity, "degenerate": bad,
                "verdict": "fail" if reasons else "suspect" if early else "pass",
                "reasons": reasons + (["systematic early drift: manual review required"] if early else [])}

    out = []
    for label, row in rows.items():
        if label in (a.ref, a.ref2):
            continue
        item = {"label": label, "build": row.get("build"), "vs_ref": compare(row, rows[a.ref])}
        if a.ref2:
            item["vs_ref2"] = compare(row, rows[a.ref2])
        out.append(item)
    return {"ref": a.ref, "ref2": a.ref2, "tokenize_s": round(tok_s, 2), "rows": out}


def gate_args(p):
    p.add_argument("--need-gib", type=int, default=None, help="override the memory gate's need")
    p.add_argument("--max-load-wait", type=int, default=1800)
    p.add_argument("--strict-load", action="store_true", help="exit 4 instead of running when load never settles")
    p.add_argument("--port", type=int, default=18140)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(7, f"{self.prog}: error: {message}\n")  # 2 means a foreign benchmark is busy


def main():
    ap = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("wait-load")
    p.add_argument("--max-load-wait", type=int, default=1800)

    p = sub.add_parser("corpus")
    p.add_argument("--server", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--cache", required=True)
    p.add_argument("--corpus-rev", required=True)
    p.add_argument("--corpus-root", default=".")
    p.add_argument("--ctx", type=int, default=8192)
    gate_args(p)

    for name in ("llama", "gufo", "strata"):
        p = sub.add_parser(name)
        p.add_argument("--target", required=True, help="GGUF shard 1" if name == "strata" else None)
        if name == "strata":
            p.set_defaults(draft="")
        else:
            p.add_argument("--draft", default="" if name == "llama" else None, required=name == "gufo")
        p.add_argument("--slots", type=int, default=1)
        p.add_argument("--cache", required=True)
        p.add_argument("--label", required=True)
        p.add_argument("--do", required=True)
        gate_args(p)
        if name == "gufo":
            p.add_argument("--image", required=True)
            p.set_defaults(quick=False)
            continue
        if name == "llama":
            p.add_argument("--server", required=True)
        p.add_argument("--extra", default="", help="engine arguments, appended last" if name == "strata" else None)
        p.add_argument("--env", action="append", default=[], metavar="K=V",
                       help="engine environment, repeatable" if name == "strata" else None)
        p.add_argument("--ctx", type=int, default=131072)
        p.add_argument("--quick", action="store_true", help="smoke: 1 temperature-0.7 decode run per group")
        if name == "strata":
            p.add_argument("--repo", required=True, help="Strata checkout: server working directory")
            p.add_argument("--python", default=sys.executable, help="interpreter that runs serve/server.py")
            p.add_argument("--engine-bin", required=True, help="the strata engine binary")
            p.add_argument("--pack", required=True, help="model pack directory (holds tokenizer/)")
            p.add_argument("--mtp-rt", help="MTP runtime directory; adds --mtp DIR to the engine arguments")
            p.add_argument("--lib-dir", action="append", default=[], metavar="DIR",
                           help="LD_LIBRARY_PATH entry for the engine, repeatable")
            p.add_argument("--vision-bin", help="strata-vision binary; with --mmproj turns images on")
            p.add_argument("--vision-max-tokens", type=int, default=300,
                           help="most tokens one picture becomes (Strata's own maximum is 1024)")
            p.add_argument("--soak-minutes", type=float, default=60, help="longsoak duration")
            p.add_argument("--mmproj", help="vision projector file; with --vision-bin turns images on")
            p.add_argument("--evict-after", action="store_true",
                           help="after teardown, drop the page cache of the GGUF shards (last row of a stage)")

    p = sub.add_parser("exec", usage="%(prog)s [options] -- cmd [args...]")
    p.add_argument("--target", required=True)
    p.add_argument("--draft", default="")
    p.add_argument("--label", required=True)
    p.add_argument("--dev", choices=("gpu", "cpu"), required=True, help="cpu: the child must not grow GTT")
    p.add_argument("--anon-limit-gib", type=int, required=True, help="kill the child above this RssAnon")
    p.add_argument("--swap-limit-gib", type=int, default=4,
                   help="kill the child when system swap use grows by more than this (the kernel may swap other processes' cold pages out for the page cache of an mmap'd model)")
    p.add_argument("--child-log", required=True, help="the child's stdout and stderr")
    gate_args(p)

    p = sub.add_parser("gufo-help")
    p.add_argument("--image", required=True)

    p = sub.add_parser("analyze")
    p.add_argument("--rows", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--ref2")
    p.add_argument("--tokenizer-bin", required=True)
    p.add_argument("--vocab", required=True)

    argv, child = sys.argv[1:], []
    if "--" in argv:
        i = argv.index("--")
        argv, child = argv[:i], argv[i + 1:]
    a = ap.parse_args(argv)
    if a.cmd == "exec":
        if not child:
            ap.error("exec needs a command after --")
        if a.need_gib is None:
            ap.error("exec needs --need-gib")
        a.child = child
    elif child:
        ap.error("unexpected arguments after --")
    if a.cmd in ("llama", "gufo", "strata"):
        unknown = set(a.do.split(",")) - set(GROUPS)
        if unknown:
            ap.error(f"unknown groups: {sorted(unknown)}")
        if "concurrency" in a.do.split(",") and a.slots < 4:
            ap.error("concurrency needs --slots 4")
    if a.cmd == "strata":
        if bool(a.vision_bin) != bool(a.mmproj):
            ap.error("--vision-bin and --mmproj go together")
        if "vision" in a.do.split(",") and not a.vision_bin:
            ap.error("the vision group needs --vision-bin and --mmproj")
        if "concurrency" in a.do.split(","):
            ap.error("concurrency is not wired for strata")
        if "bigimage" in a.do.split(",") and not a.vision_bin:
            ap.error("the bigimage group needs --vision-bin and --mmproj")
    elif {"vision", "soak", "longsoak", "bigimage", "quirks"} & set(getattr(a, "do", "").split(",")):
        ap.error("the vision and soak groups are only for the strata subcommand")
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, _on_signal)

    if a.cmd == "wait-load":
        print(json.dumps(run_wait_load(a)))
        return 0
    if a.cmd == "gufo-help":
        return run_gufo_help(a)
    if a.cmd == "analyze":
        try:
            print(json.dumps(run_analyze(a)))
        except grid.RowError as e:
            print(json.dumps({"error": str(e)}))
            return 1
        return 0
    with tempfile.TemporaryFile(mode="w+", errors="replace") as log:
        try:
            result = {"corpus": run_corpus, "exec": run_exec}.get(a.cmd, run_row)(a, log)
        except (grid.RowError, OSError) as e:
            log.seek(0)
            print(json.dumps({"error": str(e), "label": getattr(a, "label", a.cmd), "server_tail": log.read()[-4000:]}))
            return {grid.BusyError: 2, grid.MemError: 3, LoadError: 4}.get(type(e), 1)
        except Exception as e:
            traceback.print_exc()
            log.seek(0)
            print(json.dumps({"error": repr(e), "label": getattr(a, "label", a.cmd), "server_tail": log.read()[-4000:]}))
            return 1
    print(json.dumps(result))
    return 1 if "error" in result else 0


if __name__ == "__main__":
    sys.exit(main())
