#!/usr/bin/env python3
"""One benchmark row for Qwen3.8-Flash-Next MTP on stock llama.cpp (llama-server).

Each invocation starts one fresh llama-server, measures, prints exactly one JSON
line to stdout, and stops the server. Server, target and draft paths come from
arguments only.

Prompt: a corpus built from the repo's own tracked files (.md .nix .go .py .sh),
tokenized by the server and filtered so that no 64-token n-gram repeats; MTP
acceptance on repeated text is inflated, so every depth uses this builder.

--ngram-mod: llama-server's --spec-type is a comma-separated list, so
--ngram-mod appends ngram-mod (`draft-mtp,ngram-mod`, or plain `ngram-mod`
with --spec none). Verified against `llama-server --help` on build 11207.

Example:
  grid.py row --server BIN --target T.gguf --draft D.gguf --backend vulkan \
      --spec draft-mtp --nmax 3 --depth 512
"""
import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

WATCHED = {"llama-bench", "llama-server", "benchmark-go"}
NGRAM = 64
EXTS = (".md", ".nix", ".go", ".py", ".sh")
DEVICES = {"vulkan": "Vulkan0", "rocm": "ROCm0"}


class RowError(Exception):
    pass


class MemError(RowError):
    pass


def proc_info(pid):
    try:
        with open(f"/proc/{pid}/comm") as f:
            comm = f.read().strip()
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmd = f.read().split(b"\0")[0].decode(errors="replace")
        with open(f"/proc/{pid}/stat") as f:
            ppid = int(f.read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError):
        return None
    return comm, os.path.basename(cmd), ppid


def comm_of(pid):
    info = proc_info(pid)
    return info[0] if info else ""


def preflight_busy():
    me = os.getpid()
    busy = []
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == me:
            continue
        info = proc_info(int(d))
        if not info:
            continue
        comm, exe, ppid = info
        if comm not in WATCHED and exe not in WATCHED:
            continue
        if ppid == me or comm_of(ppid) == "lemond":
            continue
        busy.append(f"{d}:{comm}")
    return busy


def wait_for_quiet_load():
    """Return load_flag: True if the 1-min loadavg never dropped below 2."""
    deadline = time.time() + int(os.environ.get("GRID_LOAD_WAIT_S", "1800"))
    while os.getloadavg()[0] >= 2:
        if time.time() > deadline:
            return True
        time.sleep(15)
    return False


def mem_available_kb():
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1])
    raise RowError("MemAvailable missing from /proc/meminfo")


def model_bytes(target, draft):
    d = os.path.dirname(os.path.abspath(target))
    shard = re.match(r"(.*)-\d{5}-of-\d{5}\.gguf$", os.path.basename(target))
    files = [target]
    if shard:
        pat = re.compile(re.escape(shard.group(1)) + r"-\d{5}-of-\d{5}\.gguf$")
        files = [os.path.join(d, n) for n in sorted(os.listdir(d)) if pat.match(n)]
    if draft:
        files.append(draft)
    return sum(os.path.getsize(f) for f in files)


def check_memory(target, draft):
    gib = 1 << 30
    need = model_bytes(target, draft) + 6 * gib
    have = mem_available_kb() * 1024
    if have < need:
        raise MemError(f"insufficient memory: need {need / gib:.1f} GiB, MemAvailable {have / gib:.1f} GiB")


def http(port, path, body=None, timeout=3600):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise RowError(f"HTTP {e.code} on {path}: {e.read().decode()[:500]}") from e


def wait_ready(proc, port, deadline_s=900):
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        if proc.poll() is not None:
            return False
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(2)
    return False


def grams(ids):
    return [hashlib.sha1(json.dumps(ids[i:i + NGRAM]).encode()).digest()
            for i in range(len(ids) - NGRAM + 1)]


def ngram_dupes(ids):
    g = grams(ids)
    return len(g) - len(set(g))


def build_corpus(port, repo, depth):
    """Return (token ids sliced to depth, files used, sha256 of the ids)."""
    out = subprocess.run(["git", "-C", repo, "ls-files"], capture_output=True,
                         text=True, check=True).stdout.split("\n")
    files = sorted(f for f in out if f.endswith(EXTS)
                   and not re.fullmatch(r"bench-logs/[^/]+/README\.md", f))
    seen, ids, used = set(), [], 0
    for f in files:
        with open(os.path.join(repo, f), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        if not text.strip():
            continue
        toks = http(port, "/tokenize", {"content": text}, timeout=120)["tokens"]
        g = grams(toks)
        if len(set(g)) != len(g) or seen & set(g):
            continue
        seen.update(g)
        ids += toks
        used += 1
        if len(ids) >= depth:
            break
    if len(ids) < depth:
        raise RowError(f"corpus yields only {len(ids)} tokens < depth {depth}")
    ids = ids[:depth]
    if ngram_dupes(ids):
        raise RowError("final slice has repeated 64-grams")
    return ids, used, hashlib.sha256(json.dumps(ids).encode()).hexdigest()


def gpu_mem():
    """(gtt_used, vram_used) of the amdgpu card with the largest GTT, or (None, None)."""
    best, size = None, -1
    for d in os.listdir("/sys/class/drm"):
        dev = f"/sys/class/drm/{d}/device"
        if not re.fullmatch(r"card\d+", d) or not os.path.exists(f"{dev}/mem_info_gtt_total"):
            continue
        total = int(open(f"{dev}/mem_info_gtt_total").read())
        if total > size:
            best, size = dev, total

    def rd(name):
        try:
            return int(open(f"{best}/{name}").read())
        except OSError:
            return None
    return (rd("mem_info_gtt_used"), rd("mem_info_vram_used")) if best else (None, None)


def proc_status_kb(pid, key):
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith(key + ":"):
                return int(line.split()[1])
    return None


def server_build(binary):
    r = subprocess.run([binary, "--version"], capture_output=True, text=True)
    m = re.search(r"build (\d+), commit (\w+)", r.stdout + r.stderr)
    return f"b{m.group(1)}-{m.group(2)}" if m else None


def own_children():
    me = os.getpid()
    return [d for d in os.listdir("/proc")
            if d.isdigit() and (proc_info(int(d)) or (0, 0, 0))[2] == me]


def tool_call(port):
    resp = http(port, "/v1/chat/completions", {
        "messages": [{"role": "user", "content": "What is the weather in Paris right now? Use the tool."}],
        "tools": [{"type": "function", "function": {
            "name": "get_weather", "description": "Get the current weather for a city.",
            "parameters": {"type": "object", "properties": {"city": {"type": "string"}},
                           "required": ["city"]}}}],
        "max_tokens": 512, "temperature": 0,
    })
    choice = resp["choices"][0]
    msg = choice["message"]
    ok = False
    calls = msg.get("tool_calls")
    if isinstance(calls, list) and calls:
        try:
            ok = "city" in json.loads(calls[0]["function"]["arguments"])
        except (json.JSONDecodeError, KeyError, TypeError):
            pass
    return {"tool_call_ok": ok, "finish_reason": choice.get("finish_reason"),
            "content_head": (msg.get("content") or "")[:200]}


def completion(port, ids, gen):
    t = http(port, "/completion", {
        "prompt": ids, "n_predict": gen, "temperature": 0,
        "ignore_eos": True, "cache_prompt": False,
    })["timings"]
    if t.get("predicted_n") != gen:
        raise RowError(f"generation stopped short: predicted_n={t.get('predicted_n')} != {gen}")
    return t


def run_row(a, log):
    port = a.port
    a.ctk = a.ctk or ("q8_0" if a.fa == "on" else "f16")
    a.ctv = a.ctv or ("q8_0" if a.fa == "on" else "f16")
    ctx = -(-(a.depth + a.gen + 2048) // 256) * 256
    spec_types = []
    if a.spec == "draft-mtp":
        spec_types.append("draft-mtp")
    if a.ngram_mod:
        spec_types.append("ngram-mod")
    pmin = a.pmin if a.spec == "draft-mtp" else 0.0
    argv = [a.server, "--model", a.target, "--port", str(port), "--host", "127.0.0.1",
            "--device", DEVICES[a.backend], "-ngl", "99", "-c", str(ctx),
            "-ctk", a.ctk, "-ctv", a.ctv, "-fa", a.fa, "-t", str(a.threads),
            "--spec-type", ",".join(spec_types) or "none"]
    if a.parallel != "auto":
        argv += ["-np", a.parallel]
    if a.spec == "draft-mtp":
        argv += ["--model-draft", a.draft, "--spec-draft-n-max", str(a.nmax)]
        if pmin > 0:
            argv += ["--spec-draft-p-min", str(pmin)]
    if a.tool_call:
        argv.append("--jinja")

    busy = preflight_busy()
    if busy:
        raise RowError(f"other benchmark processes running: {busy}")
    load_flag = wait_for_quiet_load()
    check_memory(a.target, a.draft)
    loadavg_start = round(os.getloadavg()[0], 2)

    row = {"backend": a.backend, "build": server_build(a.server), "spec": ",".join(spec_types) or "none",
           "nmax": a.nmax if a.spec == "draft-mtp" else None, "pmin_effective": pmin,
           "depth": a.depth, "ctx": ctx, "ctk": a.ctk, "ctv": a.ctv, "parallel": a.parallel,
           "threads": a.threads, "flash_attn": a.fa, "loadavg_start": loadavg_start,
           "load_flag": load_flag, "label": a.label}

    gtt0, vram0 = gpu_mem() if a.residency else (None, None)
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=log)
    try:
        if not wait_ready(proc, port):
            raise RowError("server not ready")
        if a.parallel == "auto":
            row["parallel"] = f"auto ({http(port, '/props', timeout=30).get('total_slots')} slots)"
        if a.tool_call:
            row.update(tool_call(port))
            return row

        if a.depth <= 16:
            ids = http(port, "/tokenize", {"content": "The capital of France is"}, timeout=120)["tokens"][:a.depth]
            files, sha = 0, hashlib.sha256(json.dumps(ids).encode()).hexdigest()
        else:
            ids, files, sha = build_corpus(port, a.corpus_glob_root, a.depth)
        row.update(corpus_files=files, corpus_sha256=sha, ngram64_dupes=ngram_dupes(ids))

        for _ in range(a.warmup):
            completion(port, ids, a.gen)
        if a.residency:
            gtt1, vram1 = gpu_mem()
            row.update(
                gtt_delta_bytes=None if gtt0 is None else gtt1 - gtt0,
                vram_delta_bytes=None if vram0 is None else vram1 - vram0,
                rss_kb=proc_status_kb(proc.pid, "VmRSS"), hwm_kb=proc_status_kb(proc.pid, "VmHWM"))

        runs = [completion(port, ids, a.gen) for _ in range(a.repeat)]
        decode = [r["predicted_per_second"] for r in runs]
        drafted = sum(r.get("draft_n") or 0 for r in runs)
        accepted = sum(r.get("draft_n_accepted") or 0 for r in runs)
        row.update(
            prompt_n=runs[0]["prompt_n"],
            decode_tps_mean=round(statistics.mean(decode), 3),
            decode_tps_stdev=round(statistics.stdev(decode), 3) if len(decode) > 1 else 0.0,
            decode_tps_runs=[round(d, 3) for d in decode],
            prompt_tps_runs=[round(r["prompt_per_second"], 3) for r in runs],
            acceptance=None if not spec_types else (round(accepted / drafted, 4) if drafted else None),
            draft_n=drafted, draft_n_accepted=accepted)
        return row
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        if own_children():
            print("warning: leftover child process after server stop", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("row", help="run one benchmark row")
    p.add_argument("--server", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--draft", default="")
    p.add_argument("--backend", choices=list(DEVICES), required=True)
    p.add_argument("--spec", choices=["none", "draft-mtp"], default="none")
    p.add_argument("--nmax", type=int, default=3)
    p.add_argument("--pmin", type=float, default=0.0)
    p.add_argument("--depth", type=int, default=512)
    p.add_argument("--gen", type=int, default=128)
    p.add_argument("--parallel", default="1", help="slot count, or 'auto' to omit -np")
    p.add_argument("--fa", choices=["on", "off"], default="on")
    p.add_argument("--ctk", default=None, help="default: q8_0 with --fa on, f16 with --fa off")
    p.add_argument("--ctv", default=None, help="default: q8_0 with --fa on, f16 with --fa off")
    p.add_argument("--threads", type=int, default=8)
    p.add_argument("--warmup", type=int, default=1)
    p.add_argument("--repeat", type=int, default=3)
    p.add_argument("--corpus-glob-root", default=".", help="git repo whose files build the prompt corpus")
    p.add_argument("--residency", action="store_true")
    p.add_argument("--ngram-mod", action="store_true")
    p.add_argument("--tool-call", action="store_true")
    p.add_argument("--label", default="")
    p.add_argument("--port", type=int, default=18120)
    a = ap.parse_args()
    if a.spec == "draft-mtp" and not a.draft:
        ap.error("--spec draft-mtp needs --draft")

    with tempfile.TemporaryFile(mode="w+") as log:
        try:
            row = run_row(a, log)
        except MemError as e:
            print(json.dumps({"error": str(e)}))
            return 3
        except RowError as e:
            log.seek(0)
            err = {"error": str(e), "server_tail": log.read()[-1500:]}
            print(json.dumps(err))
            return 2 if str(e).startswith("other benchmark") else 1
    print(json.dumps(row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
