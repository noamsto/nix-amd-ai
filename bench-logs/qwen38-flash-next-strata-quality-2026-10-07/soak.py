"""Soak and image groups for probe.py's strata subcommand (#276), loaded like tasks.py: `run_*(e, c, P, ...)` where `e` is
probe's engine namespace (port, model, pid with .pgid, args, gtt0, vram0), `c` the corpus cache and `P` probe's module.

  run_short   the 8-turn agent replay three times, 2 and 4 concurrent requests (long-context decode and tool calls)
  run_long    continuous mixed requests with thinking on for SOAK_MINUTES (default 60), a canary every 5 minutes, and a
              30 s sampler of GTT, engine RSS and the engine pid
  run_quirks  the literal tool-call start token in prose and code, tools on and off; the sampling defaults a request that
              omits them gets
  run_image   one realistic screenshot through the CPU encoder: encode window, time to first token cold and repeated,
              and the decode rate of a concurrent text request with and without the encode running

Requests that fail are counted, not fatal: a soak that stops at its first error says nothing about the second hour.
"""
import base64
import concurrent.futures
import contextlib
import json
import os
import statistics
import threading
import time
import urllib.request
import uuid

CANARY_EVERY_S = 300
SAMPLE_EVERY_S = 30
WINDOW_S = 600
THINK_MAX = 1024


# ---- requests ---------------------------------------------------------------------------------------------------

def post(P, e, body):
    """One streamed chat completion with thinking left as the server's default. Returns timings and chunk times."""
    body = {**body, "model": e.model, "stream": True, "stream_options": {"include_usage": True}}
    t_send = time.perf_counter()
    t_first = t_last = None
    stamps, usage, text, reasoning, finish, calls = [], {}, [], [], None, 0
    for chunk in P.sse(e.port, "/v1/chat/completions", body):
        now = time.perf_counter()
        usage = chunk.get("usage") or usage
        for ch in chunk.get("choices") or []:
            d = ch.get("delta", {})
            piece = (d.get("content") or "") + (d.get("reasoning_content") or "")
            if piece or d.get("tool_calls"):
                t_first = t_first or now
                t_last = now
                stamps.append(now - t_send)
                calls += bool(d.get("tool_calls"))
            text.append(d.get("content") or "")
            reasoning.append(d.get("reasoning_content") or "")
            finish = ch.get("finish_reason") or finish
    t_end = time.perf_counter()
    if t_first is None:
        raise P.grid.RowError("stream produced no output")
    if not usage:
        raise P.grid.RowError("stream ended without a usage chunk")
    gen = max(t_last - t_first, 1e-9)
    n = usage["completion_tokens"]
    return {"ttft_s": t_first - t_send, "wall_s": t_end - t_send, "gen_s": gen, "completion_tokens": n,
            "prompt_tokens": usage["prompt_tokens"], "decode_tps": (n - 1) / gen if n > 1 else None,
            "finish": finish, "text": "".join(text), "reasoning_chars": len("".join(reasoning)), "stamps": stamps,
            "tool_chunks": calls}


def guarded(fn, *a, **kw):
    """(result, None) or (None, error string): a failed request is data."""
    try:
        return fn(*a, **kw), None
    except Exception as exc:  # noqa: BLE001 - the soak records every failure kind
        return None, f"{type(exc).__name__}: {str(exc)[:200]}"


def replay_messages(c, k):
    rp = c["replay"]
    msgs = [{"role": "system", "content": rp["system"]}, {"role": "user", "content": rp["user"]}]
    for t in rp["turns"][:k]:
        msgs += [t["assistant"], t["tool"]]
    return msgs


def tool_ok(r):
    return r["finish"] == "tool_calls" or r["tool_chunks"] > 0


def engine_pid(P, e):
    """Current pid of the `strata` engine in the server's process group (changes when the server restarts it)."""
    for pid in P.group_members(e.pid.pgid):
        with contextlib.suppress(OSError), open(f"/proc/{pid}/comm") as f:
            if f.read().strip() == "strata":
                return pid
    return None


def snapshot(P, e):
    pid = engine_pid(P, e)
    out = {"engine_pid": pid, "loadavg": round(os.getloadavg()[0], 2)}
    if pid:
        with contextlib.suppress(OSError):
            gtt, _ = P.grid.gpu_mem()
            out.update({"gtt_delta_bytes": None if e.gtt0 is None or gtt is None else gtt - e.gtt0,
                        "rss_kb": P.grid.proc_status_kb(pid, "VmRSS"), "rss_anon_kb": P.grid.proc_status_kb(pid, "RssAnon"),
                        "rss_file_kb": P.grid.proc_status_kb(pid, "RssFile"),
                        "mem_available_kb": P.grid.mem_available_kb()})
    return out


def pctl(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else None


def med(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs), 3) if xs else None


# ---- short soak -------------------------------------------------------------------------------------------------

def run_short(e, c, P):
    out = {"engine_pid_start": engine_pid(P, e)}
    reps = []
    for _ in range(3):
        turns, errors = [], 0
        for k in range(1, len(c["replay"]["turns"]) + 1):
            r, err = guarded(post, P, e, {"messages": replay_messages(c, k), "tools": c["replay"]["tools"],
                                          "max_tokens": P.REPLAY_GEN, "temperature": 0, "seed": 0,
                                          "chat_template_kwargs": {"enable_thinking": False}})
            if err:
                errors += 1
                turns.append({"turn": k, "error": err})
                continue
            turns.append({"turn": k, "ttft_s": round(r["ttft_s"], 4), "wall_s": round(r["wall_s"], 3),
                          "prompt_tokens": r["prompt_tokens"], "completion_tokens": r["completion_tokens"],
                          "decode_tps": None if r["decode_tps"] is None else round(r["decode_tps"], 2),
                          "finish": r["finish"]})
        good = [t for t in turns if "error" not in t]
        rates = [t["decode_tps"] for t in good if t["decode_tps"] and t["completion_tokens"] >= 32]
        reps.append({"errors": errors, "ttft_total_s": round(sum(t["ttft_s"] for t in good), 2),
                     "wall_total_s": round(sum(t["wall_s"] for t in good), 2),
                     "decode_tps_median": med(rates), "turns": turns})
    out["replay"] = reps
    out["concurrency"] = {}
    slices = c["conc_slices"]
    for users in (2, 4):
        t0 = time.perf_counter()
        results = []

        def one(i):
            started = time.perf_counter() - t0
            if i % 2 == 0:  # long-context decode
                body = {"messages": [{"role": "user", "content": f"# run {uuid.uuid4()}\n{slices[i % len(slices)]}\n\n"
                                      "Write a very long, detailed essay about the documents above."}],
                        "max_tokens": 128, "temperature": 0.7, "seed": i + 1,
                        "chat_template_kwargs": {"enable_thinking": False}}
                kind = "decode"
            else:  # tool call
                body = {**P.TOOLCALL_BODY, "chat_template_kwargs": {"enable_thinking": False}}
                kind = "toolcall"
            r, err = guarded(post, P, e, body)
            res = {"kind": kind, "start_s": round(started, 2), "error": err}
            if r:
                res.update({"ttft_s": round(r["ttft_s"], 2), "wall_s": round(r["wall_s"], 2),
                            "prompt_tokens": r["prompt_tokens"], "completion_tokens": r["completion_tokens"],
                            "decode_tps": None if r["decode_tps"] is None else round(r["decode_tps"], 2),
                            "tool_call_ok": tool_ok(r) if kind == "toolcall" else None})
            return res

        with concurrent.futures.ThreadPoolExecutor(users) as pool:
            results = list(pool.map(one, range(users)))
        wall = time.perf_counter() - t0
        done = [r for r in results if not r["error"]]
        out["concurrency"][str(users)] = {
            "requests": results, "wall_s": round(wall, 2), "errors": len(results) - len(done),
            "aggregate_tps": round(sum(r["completion_tokens"] for r in done) / wall, 2)}
    out["engine_pid_end"] = engine_pid(P, e)
    out["mem_end"] = snapshot(P, e)
    return out


# ---- long soak --------------------------------------------------------------------------------------------------

MATH = ["A bag holds 3 red, 4 blue and 5 green marbles. Two are drawn without replacement. What is the probability "
        "that both are the same color? Think it through, then give the fraction.",
        "Find the number of ways to tile a 2x8 strip with 1x2 dominoes, and explain the recurrence.",
        "Write a Python function that returns the longest palindromic substring of a string, and say why its running "
        "time is what it is."]


def run_long(e, c, P, minutes=None):
    minutes = float(minutes or os.environ.get("SOAK_MINUTES", "60"))
    deadline = time.perf_counter() + minutes * 60
    t0 = time.perf_counter()
    samples, requests, canaries = [], [], []
    stop = threading.Event()

    def sampler():
        while not stop.is_set():
            samples.append({"t_s": round(time.perf_counter() - t0, 1), **snapshot(P, e)})
            stop.wait(SAMPLE_EVERY_S)

    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    n_turns = len(c["replay"]["turns"])
    canary_text = c["slices"]["512"]
    prefill_text = c["slices"]["4096"]
    next_canary = time.perf_counter()
    i = 0
    lock = threading.Lock()

    def record(kind, r, err, extra=None):
        rec = {"kind": kind, "t_s": round(time.perf_counter() - t0, 1), "error": err}
        if r:
            rec.update({"ttft_s": round(r["ttft_s"], 2), "wall_s": round(r["wall_s"], 2),
                        "prompt_tokens": r["prompt_tokens"], "completion_tokens": r["completion_tokens"],
                        "decode_tps": None if r["decode_tps"] is None else round(r["decode_tps"], 2),
                        "finish": r["finish"], "reasoning_chars": r["reasoning_chars"]})
        rec.update(extra or {})
        with lock:
            requests.append(rec)

    def canary():
        # fixed temperature-0 decode and a unique-prefix 4K prefill, thinking off, so the series is comparable
        r, err = guarded(post, P, e, {"messages": [{"role": "user", "content": canary_text + "\n\nWrite a long essay."}],
                                      "max_tokens": 128, "temperature": 0, "seed": 0,
                                      "chat_template_kwargs": {"enable_thinking": False}})
        r2, err2 = guarded(post, P, e, {"messages": [{"role": "user", "content": f"# run {uuid.uuid4()}\n{prefill_text}"
                                                      "\n\nSay ok."}], "max_tokens": 1, "temperature": 0, "seed": 0,
                                        "chat_template_kwargs": {"enable_thinking": False}})
        canaries.append({"t_s": round(time.perf_counter() - t0, 1), "errors": [x for x in (err, err2) if x],
                         "decode_tps": None if not r or r["decode_tps"] is None else round(r["decode_tps"], 2),
                         "prefill_tps": None if not r2 else round(r2["prompt_tokens"] / r2["ttft_s"], 1)})

    try:
        while time.perf_counter() < deadline:
            if time.perf_counter() >= next_canary:
                canary()
                next_canary = time.perf_counter() + CANARY_EVERY_S
            kind = i % 8
            i += 1
            if kind in (0, 1, 2):  # agent replay turns with thinking on: the prompt cache sees growing prefixes
                k = (i // 8 * 3 + kind) % n_turns + 1
                r, err = guarded(post, P, e, {"messages": replay_messages(c, k), "tools": c["replay"]["tools"],
                                              "max_tokens": THINK_MAX, "temperature": 0.6, "seed": i})
                record("replay_think", r, err, {"turn": k})
            elif kind == 3:
                r, err = guarded(post, P, e, {**P.TOOLCALL_BODY, "max_tokens": THINK_MAX, "temperature": 0.6, "seed": i})
                record("toolcall_think", r, err, {"tool_call_ok": None if not r else tool_ok(r)})
            elif kind == 4:
                r, err = guarded(post, P, e, {"messages": [{"role": "user", "content": MATH[i % len(MATH)]}],
                                              "max_tokens": THINK_MAX, "temperature": 0.6, "seed": i})
                record("reason", r, err)
            elif kind == 5:  # a 32K context, unique prefix: a full prefill every time
                r, err = guarded(post, P, e, {"messages": [{"role": "user", "content": f"# run {uuid.uuid4()}\n"
                                                            f"{c['slices']['32768']}\n\nSummarize the documents above "
                                                            "in five bullet points."}],
                                              "max_tokens": 400, "temperature": 0.6, "seed": i})
                record("ctx32k", r, err)
            else:  # a burst of two replay turns at once
                def burst(j):
                    k = (i + j) % n_turns + 1
                    rr, ee = guarded(post, P, e, {"messages": replay_messages(c, k), "tools": c["replay"]["tools"],
                                                  "max_tokens": 512, "temperature": 0.6, "seed": i + j})
                    record("burst_think", rr, ee, {"turn": k})
                with concurrent.futures.ThreadPoolExecutor(2) as pool:
                    list(pool.map(burst, range(2)))
        canary()
    finally:
        stop.set()
        th.join(timeout=SAMPLE_EVERY_S + 5)
    return summarize_long(requests, canaries, samples, time.perf_counter() - t0)


def summarize_long(requests, canaries, samples, wall):
    pids = {s["engine_pid"] for s in samples if s.get("engine_pid")}
    # a pid that vanished and came back is a restart; an engine that never answers a sample shows as None
    changes = sum(1 for a, b in zip(samples, samples[1:]) if a.get("engine_pid") and b.get("engine_pid")
                  and a["engine_pid"] != b["engine_pid"])
    errors = [r for r in requests if r["error"]]
    kinds = {}
    for k in sorted({r["kind"] for r in requests}):
        rs = [r for r in requests if r["kind"] == k]
        ok = [r for r in rs if not r["error"]]
        kinds[k] = {"n": len(rs), "errors": len(rs) - len(ok), "ttft_median_s": med([r["ttft_s"] for r in ok]),
                    "decode_tps_median": med([r["decode_tps"] for r in ok if r["completion_tokens"] >= 64]),
                    "finish": {f: sum(1 for r in ok if r["finish"] == f) for f in sorted({r["finish"] for r in ok if r["finish"]})}}
    # decode rate by window: every kind with a long enough answer, so one slow kind cannot read as drift
    windows = []
    for w in range(int(wall // WINDOW_S) + 1):
        lo, hi = w * WINDOW_S, (w + 1) * WINDOW_S
        ok = [r for r in requests if not r["error"] and lo <= r["t_s"] < hi and r["completion_tokens"] >= 64]
        windows.append({"from_min": w * WINDOW_S // 60, "requests": len(ok),
                        "decode_tps_median": med([r["decode_tps"] for r in ok])})
    gtt = [s["gtt_delta_bytes"] for s in samples if s.get("gtt_delta_bytes") is not None]
    rss = [s["rss_kb"] for s in samples if s.get("rss_kb") is not None]
    anon = [s["rss_anon_kb"] for s in samples if s.get("rss_anon_kb") is not None]
    avail = [s["mem_available_kb"] for s in samples if s.get("mem_available_kb") is not None]
    return {"wall_s": round(wall, 1), "requests": len(requests), "errors": len(errors),
            "error_kinds": sorted({r["error"] for r in errors})[:10], "engine_pids": sorted(pids),
            "engine_restarts": max(len(pids) - 1, changes), "kinds": kinds, "windows": windows,
            "canaries": canaries, "samples": len(samples),
            "gtt_delta_bytes": {"first": gtt[0], "last": gtt[-1], "max": max(gtt)} if gtt else None,
            "rss_kb": {"first": rss[0], "last": rss[-1], "max": max(rss)} if rss else None,
            "rss_anon_kb": {"first": anon[0], "last": anon[-1], "max": max(anon)} if anon else None,
            "mem_available_kb": {"first": avail[0], "last": avail[-1], "min": min(avail)} if avail else None,
            "timeline": samples[:: max(1, len(samples) // 40)]}


# ---- image ------------------------------------------------------------------------------------------------------

def tagged_png(data, tag):
    """The same pixels with a different tEXt chunk, so the encoder's cache (keyed on the file's bytes) misses."""
    import struct
    import zlib
    body = b"nonce\x00" + tag.encode()
    chunk = struct.pack(">I", len(body)) + b"tEXt" + body + struct.pack(">I", zlib.crc32(b"tEXt" + body))
    end = data.rindex(b"\x00\x00\x00\x00IEND")
    return data[:end] + chunk + data[end:]


def image_body(png, question, nonce, max_tokens):
    url = "data:image/png;base64," + base64.b64encode(png).decode()
    return {"messages": [{"role": "user", "content": [
        {"type": "text", "text": f"# run {nonce}"},
        {"type": "image_url", "image_url": {"url": url}},
        {"type": "text", "text": question}]}],
        "max_tokens": max_tokens, "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}}


def vision_pid(P, e):
    for pid in P.group_members(e.pid.pgid):
        with contextlib.suppress(OSError), open(f"/proc/{pid}/comm") as f:
            if f.read().strip().startswith("strata-vision"):
                return pid
    return None


class EncodeWatch:
    """Samples the encoder process's CPU ticks every 50 ms: the encode window is where they rise."""

    def __init__(self, P, e):
        self.P, self.e, self.trace, self.stop = P, e, [], threading.Event()
        self.th = threading.Thread(target=self.run, daemon=True)

    def run(self):
        hz = os.sysconf("SC_CLK_TCK")
        while not self.stop.is_set():
            pid = vision_pid(self.P, self.e)
            ticks = self.P.cpu_ticks(pid) if pid else None
            self.trace.append((time.perf_counter(), None if ticks is None else ticks / hz))
            self.stop.wait(0.05)

    def __enter__(self):
        self.th.start()
        return self

    def __exit__(self, *exc):
        self.stop.set()
        self.th.join()

    def window(self, t_lo, t_hi):
        """(start, end, cpu seconds) of the span in [t_lo, t_hi] where the encoder used CPU, or None."""
        pts = [(t, v) for t, v in self.trace if v is not None and t_lo - 0.1 <= t <= t_hi + 0.1]
        rising = [(a, b) for a, b in zip(pts, pts[1:]) if b[1] - a[1] > 0.02]
        if not rising:
            return None
        start, end = rising[0][0][0], rising[-1][1][0]
        return {"start_s": round(start - t_lo, 2), "end_s": round(end - t_lo, 2), "encode_s": round(end - start, 2),
                "cpu_s": round(rising[-1][1][1] - rising[0][0][1], 2)}


def rate_in(stamps, n_tokens, lo, hi):
    """Decode tokens/s between lo and hi seconds after the send, assuming equal tokens per chunk."""
    if not stamps:
        return None
    per = n_tokens / len(stamps)
    k = sum(1 for s in stamps if lo <= s < hi)
    return round(k * per / (hi - lo), 2) if hi > lo else None


TEXT_ASK = ("Write a very long, detailed, multi-section essay about how a laptop's boot process works, at least 1500 "
            "words.")


def text_request(tokens):
    return {"messages": [{"role": "user", "content": f"# run {uuid.uuid4()}\n{TEXT_ASK}"}], "max_tokens": tokens,
            "temperature": 0, "seed": 0, "chat_template_kwargs": {"enable_thinking": False}}


def run_image(e, c, P):
    path = os.environ.get("SCREENSHOT_PNG")
    if not path:
        raise P.grid.RowError("the bigimage group needs SCREENSHOT_PNG (screenshot.py writes it)")
    png = open(path, "rb").read()
    q = "Describe what is on this screen: which program, which file, and what the code on the left does."
    out = {"image_bytes": len(png), "vision_max_tokens": getattr(e.args, "vision_max_tokens", None)}
    # the text-only prompt's own token count, to take the image's tokens out of the image requests'
    base, _ = guarded(post, P, e, {"messages": [{"role": "user", "content": f"# run x\n{q}"}], "max_tokens": 1,
                                     "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}})
    text_tokens = base["prompt_tokens"] if base else None
    with EncodeWatch(P, e) as watch:
        # baseline: the text request alone, twice
        out["text_alone"] = []
        for _ in range(2):
            t = time.perf_counter()
            r = post(P, e, text_request(600))
            out["text_alone"].append({"decode_tps": round(r["decode_tps"], 2),
                                      "first_8s_tps": rate_in(r["stamps"], r["completion_tokens"], r["ttft_s"], r["ttft_s"] + 8),
                                      "completion_tokens": r["completion_tokens"], "t0": t})
        # image alone, cold then the same image again (a new nonce line, so only the encoder's cache can hit)
        cold_png = tagged_png(png, uuid.uuid4().hex)
        t = time.perf_counter()
        r1 = post(P, e, image_body(cold_png, q, uuid.uuid4(), 64))
        w1 = watch.window(t, t + r1["wall_s"])
        t = time.perf_counter()
        r2 = post(P, e, image_body(cold_png, q, uuid.uuid4(), 64))
        w2 = watch.window(t, t + r2["wall_s"])
        out["image_alone"] = {
            "image_tokens": None if text_tokens is None else r1["prompt_tokens"] - text_tokens,
            "prompt_tokens": r1["prompt_tokens"],
            "cold": {"ttft_s": round(r1["ttft_s"], 2), "wall_s": round(r1["wall_s"], 2), "encode_window": w1,
                     "decode_tps": None if r1["decode_tps"] is None else round(r1["decode_tps"], 2), "answer": r1["text"][:160]},
            "repeat": {"ttft_s": round(r2["ttft_s"], 2), "wall_s": round(r2["wall_s"], 2), "encode_window": w2,
                       "decode_tps": None if r2["decode_tps"] is None else round(r2["decode_tps"], 2)},
            "encode_cache_hit": w2 is None, "ttft_cold_minus_repeat_s": round(r1["ttft_s"] - r2["ttft_s"], 2)}
        # the text request decoding while a new image encodes
        out["concurrent"] = []
        for _ in range(2):
            img = tagged_png(png, uuid.uuid4().hex)
            holder = {}
            t_text = time.perf_counter()

            def run_text():
                holder["text"] = post(P, e, text_request(1200))

            th = threading.Thread(target=run_text)
            th.start()
            time.sleep(4)  # into steady decode
            t_img = time.perf_counter()
            ri = post(P, e, image_body(img, q, uuid.uuid4(), 64))
            th.join()
            rt = holder["text"]
            w = watch.window(t_img, t_img + ri["wall_s"])
            off = t_img - t_text  # the image's send time on the text request's clock
            enc = None
            if w:
                lo, hi = off + w["start_s"], off + w["end_s"]
                enc = {"encode_s": w["encode_s"], "cpu_s": w["cpu_s"], "text_tps_during_encode":
                       rate_in(rt["stamps"], rt["completion_tokens"], lo, hi),
                       "text_tps_before": rate_in(rt["stamps"], rt["completion_tokens"], max(rt["ttft_s"], lo - 6), lo),
                       "text_tps_after": rate_in(rt["stamps"], rt["completion_tokens"], hi, hi + 6)}
            out["concurrent"].append({"image_ttft_s": round(ri["ttft_s"], 2), "image_wall_s": round(ri["wall_s"], 2),
                                      "text_decode_tps": round(rt["decode_tps"], 2), "encode": enc,
                                      "image_send_after_text_s": round(off, 1),
                                      "text_wall_s": round(rt["wall_s"], 1)})
    for r in out["text_alone"]:
        r.pop("t0", None)
    return out


# ---- quirks -----------------------------------------------------------------------------------------------------

TAG = "<tool_call>"
TOKEN_PROMPTS = {
    "prose": f"Explain what the literal text {TAG} means in Qwen's chat format. Quote it in a sentence and once in an "
             f"inline code span like `{TAG}`, then explain what the matching closing text does.",
    "code": f"Write a short Python function that splits a model reply on the literal strings '{TAG}' and "
            "'</tool_call>' and returns the JSON between them. Reply with a code block, then a paragraph explaining it.",
    "fence": f"Show me, in a fenced code block, an example reply that contains {TAG} followed by a JSON call and its "
             "closing tag, then describe in two sentences how a client should parse it.",
}


def judge(r):
    """Heuristics only: the tail of the text is kept so a reader can see where it stopped."""
    t = r["text"].rstrip()
    done = t.endswith((".", "!", "?", "`", ")", "*", ":")) and t.count("```") % 2 == 0
    return {"finish": r["finish"], "completion_tokens": r["completion_tokens"], "chars": len(t),
            "literal_tag_in_text": t.count(TAG), "spurious_tool_call": r["tool_chunks"] > 0 or r["finish"] == "tool_calls",
            "looks_truncated": not done or r["completion_tokens"] < 40, "tail": t[-100:]}


def run_quirks(e, c, P):
    out = {"token": []}
    for name, prompt in TOKEN_PROMPTS.items():
        for tools in (False, True):
            for temp, seed in ((0.0, 0), (0.7, 1), (0.7, 2)):
                body = {"messages": [{"role": "user", "content": prompt}], "max_tokens": 700, "temperature": temp,
                        "seed": seed, "chat_template_kwargs": {"enable_thinking": False}}
                if tools:
                    body["tools"] = c["replay"]["tools"]
                r, err = guarded(post, P, e, body)
                out["token"].append({"prompt": name, "tools": tools, "temperature": temp, "seed": seed,
                                     **({"error": err} if err else judge(r))})
    # sampling: what a request that omits everything gets, and whether what it sends is honoured
    q = {"messages": [{"role": "user", "content": "Name five unusual fruits and describe each in one sentence."}],
         "max_tokens": 120, "chat_template_kwargs": {"enable_thinking": False}}

    def text(**kw):
        r, err = guarded(post, P, e, {**q, **kw})
        return err or r["text"]

    omitted = [text(), text()]
    greedy = text(temperature=0)
    s1, s1b, s2 = text(temperature=0.7, seed=1), text(temperature=0.7, seed=1), text(temperature=0.7, seed=2)
    topk1 = text(temperature=0.7, top_k=1, seed=3)
    hot = text(temperature=1.5, top_p=1.0, top_k=64, seed=4)
    out["sampling"] = {
        "omitted_twice_identical": omitted[0] == omitted[1], "omitted_equals_temperature0": omitted[0] == greedy,
        "temperature0.7_same_seed_identical": s1 == s1b, "temperature0.7_seeds_differ": s1 != s2,
        "temperature0.7_differs_from_omitted": s1 != omitted[0], "top_k1_at_0.7_equals_greedy": topk1 == greedy,
        "temperature1.5_differs_from_greedy": hot != greedy}
    return out
