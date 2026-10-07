#!/usr/bin/env python3
"""Halogen 0.16.2 (closed OCI image) on halo, measured through the #249 harness groups.

Subcommands:
  row        start one Halogen container under rootless podman, run --do groups, write one JSON row to --out
  cotenant   start the container, hold a fixed anonymous-memory load beside it, write one JSON row to --out
  ppl        run the image's `ppl` mode on a file (no server), write its --json object to --out

Meant to run as the child of `run.sh exec` (the gate, signal file and lemond hand-off live there). The container
is `--rm`, labelled, and killed by the SIGTERM handler, so it cannot outlive its row: run.sh's stop budget is 5 s.
Groups for `row` (--do, comma list): the harness groups toolcall prefill4k decode512 decode32k decode128k replay
correctness tasks, plus vision and checks (sampling defaults and honouring, tool-call tokens as text, greedy with
speculation on and off, logprobs exposure). Exit: 0 ok, 1 row error, 2 foreign benchmark, 3 memory gate,
4 load wait expired, 7 usage, 143 signalled.
"""
import argparse
import base64
import contextlib
import importlib.util
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "probe", os.path.join(HERE, "..", "qwen38-flash-next-engine-bakeoff-2026-10-05", "probe.py"))
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)
grid = probe.grid

PODMAN = os.environ.get("PODMAN", "podman")
LABEL = "bench=halogen258"
CONTAINER_PORT = 8731
GIB = 1 << 30
containers = []  # names of live containers, for the signal handler


def podman(*args, **kw):
    return subprocess.run([PODMAN, *args], capture_output=True, text=True, **kw)


def hygiene_args(name, models):
    """Everything the closed image gets: the two GPU nodes, a read-only model mount, a loopback-only port."""
    return ["--rm", "--name", name, "--label", LABEL,
            "--device", "/dev/kfd", "--device", "/dev/dri", "--group-add", "keep-groups",
            "--ipc=host", "--ulimit", "memlock=-1:-1", "-v", f"{models}:/models:ro"]


# An --internal netavark network has no route out; the published loopback port still works (checked with a stub
# server in the image before the first row). A pasta network with its DHCP and RA options off does not: podman
# configures the namespace's address and routes itself, and outbound traffic still left.
OFFLINE_NETWORK = "halogen258-offline"


def ensure_offline_network():
    if podman("network", "exists", OFFLINE_NETWORK).returncode:
        made = podman("network", "create", "--internal", OFFLINE_NETWORK)
        if made.returncode:
            raise grid.RowError(f"cannot create the internal network: {made.stderr.strip()[:300]}")


def run_args(a, name):
    net = ["--network", OFFLINE_NETWORK] if getattr(a, "offline", False) else []
    argv = ["run", "-d", *hygiene_args(name, a.models), *net, "-p", f"127.0.0.1:{a.port}:{CONTAINER_PORT}",
            "-e", f"HALOGEN_CHECKPOINT=/models/{a.checkpoint}"]
    for kv in a.env:
        argv += ["-e", kv]
    return [*argv, a.image]


def mode_args(a, name, mode, extra):
    scratch = ["-v", f"{a.scratch}:/ppl"] if getattr(a, "scratch", None) else []
    return ["run", *hygiene_args(name, a.models), *scratch, "-e", f"HALOGEN_CHECKPOINT=/models/{a.checkpoint}",
            *[x for kv in a.env for x in ("-e", kv)], a.image, mode, *extra]


def teardown(name):
    """Kill and wait until the container is gone; a container left holding GPU memory is what wedges amdgpu."""
    podman("kill", name)
    podman("rm", "-f", name)
    deadline = time.time() + 30
    while time.time() < deadline:
        if not podman("ps", "-aq", "--filter", f"name=^{name}$").stdout.strip():
            break
        time.sleep(0.5)
    if name in containers:
        containers.remove(name)


def teardown_all():
    for name in list(containers):
        teardown(name)


def _on_signal(sig, _frame):
    for name in list(containers):  # kill first, all of them: run.sh follows its SIGTERM with SIGKILL after 5 s
        podman("kill", name)
    teardown_all()
    sys.exit(143)


def cgroup_dir(pid):
    with open(f"/proc/{pid}/cgroup") as f:
        for line in f:
            if line.startswith("0::"):
                return "/sys/fs/cgroup" + line[3:].strip()
    return None


def cgroup_mem(pid):
    """memory.current/peak and the anon/file split of the container's cgroup; None where the kernel hides it."""
    out = {}
    try:
        d = cgroup_dir(pid)
        for key in ("memory.current", "memory.peak"):
            with open(os.path.join(d, key)) as f:
                out[key.split(".")[1] + "_bytes"] = int(f.read())
        with open(os.path.join(d, "memory.stat")) as f:
            stat = dict(line.split() for line in f)
        out["anon_bytes"], out["file_bytes"] = int(stat["anon"]), int(stat["file"])
    except (OSError, TypeError, KeyError, ValueError):
        pass
    return out


@contextlib.contextmanager
def mem_watch(floor_gib, name):
    """Track the lowest MemAvailable; below the floor kill the container (a request then fails) and say so."""
    state = {"min_avail_kb": None, "breach": False}
    stop = threading.Event()

    def sample():
        while not stop.wait(1):
            try:
                kb = grid.mem_available_kb()
            except OSError:
                continue
            state["min_avail_kb"] = kb if state["min_avail_kb"] is None else min(state["min_avail_kb"], kb)
            if kb < floor_gib * GIB / 1024 and not state["breach"]:
                state["breach"] = True
                podman("kill", name)

    t = threading.Thread(target=sample, daemon=True)
    t.start()
    try:
        yield state
    finally:
        stop.set()
        t.join(timeout=2)


def iommu_mode():
    try:
        with open("/proc/cmdline") as f:
            cmd = f.read()
    except OSError:
        return None
    m = re.search(r"(?:amd_)?iommu[.=][^\s]+", cmd)
    return m.group(0) if m else "default (translated; no iommu flag on the kernel command line)"


def kfd_check():
    """The documented kernel requirements, read from KFD: SVM capability bit and the cwsr/ctl_stack relation."""
    base = "/sys/class/kfd/kfd/topology/nodes"
    try:
        for node in sorted(os.listdir(base)):
            with open(os.path.join(base, node, "properties")) as f:
                p = dict(line.split(None, 1) for line in f if line.strip())
            if p.get("gfx_target_version", "").strip() != "110501":
                continue
            cap = int(p["capability"])
            out = {"node": node, "svm_capability_bit": bool(cap & 0x08000000)}
            if "cwsr_size" in p:
                cwsr, ctl, simd = int(p["cwsr_size"]), int(p["ctl_stack_size"]), int(p["simd_count"])
                out["cwsr_fix_present"] = cwsr == ctl + (simd // 2) * 479232
            else:
                out["cwsr_fix_present"] = False
            return out
    except (OSError, ValueError, KeyError):
        pass
    return {"error": "no gfx1151 KFD node readable"}


def is_loopback(addr):
    host = addr.rsplit(":", 1)[0].strip("[]")
    return host.startswith("127.") or host in ("::1", "*", "0.0.0.0", "::", "")


@contextlib.contextmanager
def egress_watch():
    """Sample `ss -tunp` about once a second and keep every non-loopback peer of the passt/pasta process (the host side
    of the container's network). Hostnames are not visible here; DNS shows as a flow to the host's resolver."""
    seen = {}
    stop = threading.Event()

    def sample():
        while not stop.is_set():
            out = subprocess.run(["ss", "-tunpH"], capture_output=True, text=True).stdout
            for line in out.splitlines():
                cols = line.split()
                if len(cols) < 6 or not ("passt" in line or "pasta" in line):
                    continue
                peer = cols[5]
                if not is_loopback(peer):
                    key = f"{cols[0]} {cols[4]} -> {peer}"
                    seen[key] = seen.get(key, 0) + 1
            stop.wait(1)

    t = threading.Thread(target=sample, daemon=True)
    t.start()
    try:
        yield seen
    finally:
        stop.set()
        t.join(timeout=3)


OFFLINE_PROBE = ("import socket,sys\nr={}\n"
                 "for k,f in (('connect_1.1.1.1:443',lambda:socket.create_connection(('1.1.1.1',443),timeout=5)),"
                 "('resolve_huggingface.co',lambda:socket.getaddrinfo('huggingface.co',443))):\n"
                 "    try:\n        f();r[k]='SUCCEEDED'\n    except Exception as e:\n        r[k]='failed: '+type(e).__name__\n"
                 "import json;print(json.dumps(r))")


def offline_probe(name):
    out = podman("exec", name, "python3", "-c", OFFLINE_PROBE)
    try:
        return json.loads(out.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": (out.stdout + out.stderr)[-300:]}


def http_get(port, path, timeout=30):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as r:
        return r.status, r.read()


@contextlib.contextmanager
def server(a, log):
    name = f"halogen258-{re.sub(r'[^A-Za-z0-9_.-]', '-', a.label)}-{os.getpid()}"
    if getattr(a, "offline", False):
        ensure_offline_network()
    started = podman(*run_args(a, name))
    if started.returncode:
        raise grid.RowError(f"podman run failed: {started.stderr.strip()[:500]}")
    containers.append(name)
    try:
        pid = int(podman("inspect", "-f", "{{.State.Pid}}", name).stdout)
        deadline = time.time() + a.ready_s
        while True:
            if podman("inspect", "-f", "{{.State.Running}}", name).stdout.strip() != "true":
                raise grid.RowError("container exited before becoming ready")
            try:
                status, _ = http_get(a.port, "/health", timeout=5)
                if status == 200:
                    break
            except (OSError, urllib.error.URLError):
                pass
            if time.time() > deadline:
                raise grid.RowError(f"not ready after {a.ready_s} s")
            time.sleep(2)
        yield pid, name
    except BaseException:
        tail = podman("logs", "--tail", "120", name)
        log.write(tail.stdout + tail.stderr)
        raise
    finally:
        # keep the last log lines (memory accounting, version) before the container goes
        try:
            tail = podman("logs", "--tail", "200", name)
            log.write(tail.stdout + tail.stderr)
        except OSError:
            pass
        teardown(name)


MEM_LINE = re.compile(r"(memory|GiB|GTT|host memory|version|pinned|registered)", re.I)


def log_facts(text):
    return [ln.strip()[:300] for ln in text.splitlines() if MEM_LINE.search(ln)][:40]


def snapshot(pid, gtt0, vram0):
    s = probe.mem_snapshot(pid, gtt0, vram0)
    s["cgroup"] = cgroup_mem(pid)
    return s


# ---- groups -----------------------------------------------------------------------------------------------

def install_completions(decode_via):
    """probe's speed groups call stream_complete; `chat` routes it through the chat essay path (no ignore_eos)."""
    orig = probe.stream_complete

    def wrapper(e, prompt_text, max_tokens, temperature, seed, ignore_eos=True, cache_prompt=False):
        if decode_via == "chat":
            e = types.SimpleNamespace(**{**vars(e), "engine": "strata"})
        return orig(e, prompt_text, max_tokens, temperature, seed, ignore_eos, cache_prompt)

    probe.stream_complete = wrapper


def chat(e, content, **extra):
    body = {"model": e.model, "messages": [{"role": "user", "content": content}], "max_tokens": 256,
            "temperature": 0, **probe.thinking_off(e), **extra}
    return grid.http(e.port, "/v1/chat/completions", body)


def g_vision(e):
    url = "data:image/png;base64," + base64.b64encode(probe.red_blue_png()).decode()
    r = probe.stream(e, "/v1/chat/completions", {
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": url}},
            {"type": "text", "text": "Which two colors does this image show? Answer with the color names only."}]}],
        "max_tokens": 64, "temperature": 0, **probe.thinking_off(e)})
    return {"ok": {"red", "blue"} <= set(re.findall(r"[a-z]+", r["text"].lower())), "answer": r["text"][:200],
            "ttft_s": round(r["ttft_s"], 3), "wall_s": round(r["wall_s"], 3), "prompt_tokens": r["prompt_tokens"]}


def distinct(xs):
    return len(set(xs))


def g_checks(e, port):
    out = {}
    health = json.loads(http_get(port, "/health")[1])
    out["health"] = {k: health.get(k) for k in (
        "version", "server_defaults", "sampling", "sampling_fields", "drafter", "modes", "checkpoint_format",
        "chat_template", "thinking_answer_room") if k in health}
    out["health_keys"] = sorted(health)
    prompt = "Write two sentences about a lighthouse keeper."

    def texts(n, **kw):
        return [chat(e, prompt, max_tokens=64, **kw)["choices"][0]["message"].get("content") or ""
                for _ in range(n)]

    # (a) defaults an omitting request gets, and whether request values are honoured
    out["sampling"] = {
        "omitted_temperature_distinct_of_3": distinct([chat_no_temp(e, prompt) for _ in range(3)]),
        "temp1_no_topk_distinct_of_4": distinct(texts(4, temperature=1.0)),
        "temp1_top_k1_distinct_of_3": distinct(texts(3, temperature=1.0, top_k=1)),
        "temp1_top_p_0.01_distinct_of_3": distinct(texts(3, temperature=1.0, top_p=0.01)),
        "temp1_seed7_distinct_of_3": distinct(texts(3, temperature=1.0, seed=7)),
        "temp1_min_p_accepted": request_ok(e, prompt, temperature=1.0, min_p=0.1),
        "greedy_with_repetition_penalty_2_status": status_of(e, prompt, temperature=0, repetition_penalty=2.0),
    }
    # logprobs exposure: first token only, top-20 cap
    out["logprobs"] = {
        "top5_first_token": top_logprobs(e, prompt, 5),
        "top20_first_token": top_logprobs(e, prompt, 20),
        "top21_status": status_of(e, prompt, temperature=0, max_tokens=1, logprobs=True, top_logprobs=21),
        "stream_logprobs_status": status_of(e, prompt, temperature=0, max_tokens=1, logprobs=True, top_logprobs=2,
                                            stream=True),
    }
    # (b) the model's own tool-call token written as text
    out["tool_token_text"] = tool_token_text(e)
    # (c) greedy with speculation on and off
    out["spec_identity"] = spec_identity(e)
    return out


def chat_no_temp(e, prompt):
    body = {"model": e.model, "messages": [{"role": "user", "content": prompt}], "max_tokens": 64,
            **probe.thinking_off(e)}
    return grid.http(e.port, "/v1/chat/completions", body)["choices"][0]["message"].get("content") or ""


def post_status(port, body):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode(errors="replace")[:300]


def status_of(e, prompt, **kw):
    body = {"model": e.model, "messages": [{"role": "user", "content": prompt}], "max_tokens": 16,
            **probe.thinking_off(e), **kw}
    status, text = post_status(e.port, body)
    return status if status == 200 else f"{status}: {text[:160]}"


def request_ok(e, prompt, **kw):
    return status_of(e, prompt, **kw) == 200


def top_logprobs(e, prompt, k):
    body = {"model": e.model, "messages": [{"role": "user", "content": prompt}], "max_tokens": 1, "temperature": 0,
            "logprobs": True, "top_logprobs": k, **probe.thinking_off(e)}
    status, text = post_status(e.port, body)
    if status != 200:
        return {"status": status, "body": text[:200]}
    content = (json.loads(text)["choices"][0].get("logprobs") or {}).get("content") or []
    return {"status": 200, "positions": len(content),
            "top_returned": len(content[0].get("top_logprobs", [])) if content else 0}


def tool_token_text(e):
    marker = '<tool_call>\n{"name": "get_weather", "arguments": {"city": "Paris"}}\n</tool_call>'
    ask = f"Copy the text between BEGIN and END exactly, then write the word DONE.\nBEGIN\n{marker}\nEND"
    tools = probe.TOOLCALL_BODY["tools"]
    rows = {}
    for label, extra in (("no_tools", {}), ("with_tools", {"tools": tools})):
        for stream in (False, True):
            body = {"model": e.model, "messages": [{"role": "user", "content": ask}], "max_tokens": 200,
                    "temperature": 0, **probe.thinking_off(e), **extra}
            if stream:
                try:
                    r = probe.stream(e, "/v1/chat/completions", body)
                except grid.RowError as err:  # an empty or cut stream is the finding, not a harness failure
                    rows[f"{label}_stream"] = {"error": str(err)[:300]}
                    continue
                text, finish, calls = r["text"], r["finish_reason"], None
            else:
                choice = grid.http(e.port, "/v1/chat/completions", body)["choices"][0]
                text, finish, calls = choice["message"].get("content") or "", choice.get("finish_reason"), \
                    choice["message"].get("tool_calls")
            rows[f"{label}_{'stream' if stream else 'plain'}"] = {
                "finish_reason": finish, "tool_calls": bool(calls), "reached_DONE": "DONE" in text,
                "kept_marker_text": "get_weather" in text, "text_head": text[:160]}
    return rows


def spec_identity(e):
    results = []
    for pid, prompt in probe.PROMPTS[:6]:
        out = {}
        for drafter in ("mtp", "serial"):
            r = grid.http(e.port, "/v1/chat/completions", {
                "model": e.model, "messages": [{"role": "user", "content": prompt}], "max_tokens": 256,
                "temperature": 0, "drafter": drafter, **probe.thinking_off(e)})
            choice = r["choices"][0]
            out[drafter] = (choice["message"].get("content") or "", r["usage"]["completion_tokens"],
                            (r.get("timings") or {}).get("draft_n"))
        results.append({"id": pid, "identical": out["mtp"][0] == out["serial"][0],
                        "tokens": [out["mtp"][1], out["serial"][1]], "draft_n": [out["mtp"][2], out["serial"][2]]})
    return {"identical": sum(r["identical"] for r in results), "of": len(results), "prompts": results}


def run_groups(a, e, cache, do, row):
    if "toolcall" in do:
        row["toolcall"] = probe.g_toolcall(e, cache, a.quick)
    if "prefill4k" in do:
        row["prefill4k"] = probe.g_prefill4k(e, cache, a.quick)
    for group in probe.DECODE_SLICE:
        if group in do:
            row[group] = probe.g_decode(e, cache, a.quick, group)
    if "replay" in do:
        row["replay"] = probe.g_replay(e, cache, a.quick, row.get("decode32k"))
    if "correctness" in do:
        row["correctness"] = probe.g_correctness(e, cache, a.quick)
    if "vision" in do:
        row["vision"] = g_vision(e)
    if "tasks" in do:
        row["tasks"] = probe.g_tasks(e, cache, a.quick)
    if "checks" in do:
        row["checks"] = g_checks(e, a.port)


def base_row(a, load_flag):
    return {"host": socket.gethostname(), "engine": "halogen", "label": a.label, "image": a.image,
            "checkpoint": a.checkpoint, "env": dict(kv.split("=", 1) for kv in a.env),
            "iommu": iommu_mode(), "kernel": os.uname().release, "kfd": kfd_check(),
            "loadavg_start": round(os.getloadavg()[0], 2), "load_flag": load_flag}


def run_row(a, log):
    load_flag = probe.gate(a, "")
    with open(a.cache, encoding="utf-8") as f:
        cache = json.load(f)
    install_completions(a.decode_via)
    row = base_row(a, load_flag)
    row["corpus_sha256"] = cache["corpus_sha256"]
    row["podman_run"] = "podman " + " ".join(run_args(a, "<name>")).replace(a.models, "<models>")
    do = set(a.do.split(","))
    gtt0, vram0 = grid.gpu_mem()
    t0 = time.time()
    with probe.gtt_peak(gtt0) as peak, probe.loadavg_peak() as load, egress_watch() as egress:
        with server(a, log) as (pid, name), mem_watch(a.floor_gib, name) as watch:
            row["load_s"] = round(time.time() - t0, 1)
            if a.offline:
                row["offline_probe"] = offline_probe(name)
            e = types.SimpleNamespace(port=a.port, engine="halogen",
                                      model=grid.http(a.port, "/v1/models", timeout=30)["data"][0]["id"])
            row["mem_after_load"] = snapshot(pid, gtt0, vram0)
            run_groups(a, e, cache, do, row)
            row["mem_end"] = snapshot(pid, gtt0, vram0)
            row["gtt_peak_delta_bytes"] = peak["bytes"]
            row["min_mem_available_kb"] = watch["min_avail_kb"]
            row["floor_breached"] = watch["breach"]
        row["egress_non_loopback_flows"] = dict(egress)
        row["offline"] = bool(a.offline)
        row["loadavg_end"] = round(os.getloadavg()[0], 2)
        row["loadavg_max"] = None if load["max"] is None else round(load["max"], 2)
    gtt, _ = grid.gpu_mem()
    row["gtt_after_stop_delta_bytes"] = None if gtt0 is None or gtt is None else gtt - gtt0
    log.seek(0)
    text = log.read()
    row["server_log_facts"] = log_facts(text)
    row["server_log_problems"] = [ln.strip()[:300] for ln in text.splitlines()
                                  if re.search(r"killed|OOM|out of memory|Traceback|error|exited|crash|stall", ln, re.I)][-30:]
    return row


def hold_memory(gib):
    """Anonymous memory held and touched by a child process, so it is the child's RSS and not ours."""
    code = ("import sys,time;n=int(sys.argv[1]);b=bytearray(n<<30);"
            "[b.__setitem__(slice(i,i+4096),b'x'*4096) for i in range(0,len(b),4096)];print('held',flush=True);"
            "time.sleep(86400)")
    return subprocess.Popen([sys.executable, "-c", code, str(gib)], stdout=subprocess.PIPE, text=True)


def run_cotenant(a, log):
    load_flag = probe.gate(a, "")
    row = base_row(a, load_flag)
    gtt0, vram0 = grid.gpu_mem()
    loader = None
    try:
        with server(a, log) as (pid, name), mem_watch(a.floor_gib, name) as watch:
            row["mem_after_load"] = snapshot(pid, gtt0, vram0)
            row["mem_available_before_load_kb"] = grid.mem_available_kb()
            loader = hold_memory(a.load_gib)
            held = False
            deadline = time.time() + 600
            while time.time() < deadline and not watch["breach"]:
                if loader.poll() is not None:
                    break
                if loader.stdout.readable():
                    line = loader.stdout.readline()
                    if line.startswith("held"):
                        held = True
                        break
            row["load_held"] = held
            row["mem_with_load"] = snapshot(pid, gtt0, vram0)
            e = types.SimpleNamespace(port=a.port, engine="halogen",
                                      model=grid.http(a.port, "/v1/models", timeout=30)["data"][0]["id"])
            if held and not watch["breach"]:
                r = probe.stream(e, "/v1/chat/completions", {
                    "messages": [{"role": "user", "content": "Count from 1 to 40 separated by spaces."}],
                    "max_tokens": 128, "temperature": 0, **probe.thinking_off(e)})
                row["request_with_load"] = {"ok": True, "decode_tps": probe.decode_tps(r),
                                            "ttft_s": round(r["ttft_s"], 3)}
            row["min_mem_available_kb"] = watch["min_avail_kb"]
            row["floor_breached"] = watch["breach"]
    finally:
        if loader is not None:
            loader.kill()
            loader.wait()
    gtt, _ = grid.gpu_mem()
    row["gtt_after_stop_delta_bytes"] = None if gtt0 is None or gtt is None else gtt - gtt0
    if row.get("floor_breached"):
        row["error"] = "MemAvailable fell below the floor; container killed"
    return row


def run_ppl(a, log):
    load_flag = probe.gate(a, "")
    name = f"halogen258-ppl-{os.getpid()}"
    containers.append(name)
    gtt0, _ = grid.gpu_mem()
    t0 = time.time()
    try:
        with probe.gtt_peak(gtt0) as peak, mem_watch(a.floor_gib, name) as watch:
            proc = podman(*mode_args(a, name, "ppl", a.ppl_args))
    finally:
        teardown(name)
    row = {**base_row(a, load_flag), "mode": "ppl", "rc": proc.returncode, "wall_s": round(time.time() - t0, 1),
           "gtt_peak_delta_bytes": peak["bytes"], "min_mem_available_kb": watch["min_avail_kb"]}
    if proc.returncode:
        row["error"] = f"ppl exited {proc.returncode}"
        row["stderr_tail"] = proc.stderr[-1500:]
        return row
    with open(a.out, "w") as f:
        f.write(proc.stdout)
    row["stdout_bytes"] = len(proc.stdout)
    return row


def build_parser():
    ap = probe.Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("row", "cotenant", "ppl"):
        p = sub.add_parser(name)
        p.add_argument("--image", required=True, help="image reference, by digest")
        p.add_argument("--models", required=True, help="host directory mounted read-only at /models")
        p.add_argument("--checkpoint", required=True, help="file under --models (v2.hgn, or a GGUF shard 1)")
        p.add_argument("--env", action="append", default=[], metavar="K=V", help="HALOGEN_* setting, repeatable")
        p.add_argument("--label", required=True)
        p.add_argument("--out", required=True, help="file for this row's JSON")
        p.add_argument("--floor-gib", type=float, default=6.0, help="kill the container below this MemAvailable")
        p.add_argument("--ready-s", type=int, default=1800)
        p.set_defaults(target="", draft="")
        probe.gate_args(p)
        if name == "row":
            p.add_argument("--cache", required=True)
            p.add_argument("--do", required=True)
            p.add_argument("--quick", action="store_true")
            p.add_argument("--decode-via", choices=("completions", "chat"), default="completions")
            p.add_argument("--offline", action="store_true", help="no outbound network; the published port still works")
        if name == "cotenant":
            p.add_argument("--load-gib", type=int, required=True)
        if name == "ppl":
            p.add_argument("--scratch", required=True, help="writable host directory, /ppl in the container")
            p.add_argument("ppl_args", nargs=argparse.REMAINDER, help="after --: arguments for the ppl mode")
    return ap


def main(argv=None):
    ap = build_parser()
    a = ap.parse_args(argv)
    if a.need_gib is None:
        ap.error("--need-gib is required (the GiB the memory gate must find free)")
    if a.cmd == "ppl" and a.ppl_args and a.ppl_args[0] == "--":
        a.ppl_args = a.ppl_args[1:]
    if a.cmd == "row":
        unknown = set(a.do.split(",")) - (set(probe.GROUPS) - {"concurrency"}) - {"checks"}
        if unknown:
            ap.error(f"unknown groups: {sorted(unknown)}")
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, _on_signal)
    runner = {"row": run_row, "cotenant": run_cotenant, "ppl": run_ppl}[a.cmd]
    with tempfile.TemporaryFile(mode="w+", errors="replace") as log:
        try:
            result = runner(a, log)
        except (grid.RowError, OSError) as err:
            log.seek(0)
            result = {"error": str(err), "label": a.label, "server_tail": log.read()[-4000:]}
            code = {grid.BusyError: 2, grid.MemError: 3, probe.LoadError: 4}.get(type(err), 1)
            with open(a.out, "w") as f:
                json.dump(result, f)
            print(json.dumps(result))
            return code
    if a.cmd != "ppl":
        with open(a.out, "w") as f:
            json.dump(result, f)
    print(json.dumps({k: v for k, v in result.items() if k in ("label", "error", "rc", "wall_s")}))
    return 1 if "error" in result else 0


if __name__ == "__main__":
    sys.exit(main())
