#!/usr/bin/env python3
"""Depth-curve probe for Qwen3.8-Flash-Next MTP on stock llama.cpp.

Starts llama-server (target [+ MTP draft head]), sends one /completion request
with a long prompt and 128 generated tokens, and prints the server-reported
prompt/decode timings plus draft acceptance. One process per
(device, spec, depth) row.

Example:
  depth-probe.py --server .../bin/llama-server --target .../target.gguf \
      --draft .../mtp.gguf --device Vulkan0 --ctx 82176 --depth 78000 \
      --spec draft-mtp --filler-file corpus.txt
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

SERVER = TARGET = DRAFT = DEVICE = ""
PORT = 18120
CTX = 2048
NGEN = 128
DEPTH = 512
SPEC = "none"
NMAX = 3
FILLER_FILE = ""
SRVLOG = ""

FILLER = ("The quick brown fox jumps over the lazy dog. "
          "In a distant galaxy, an ancient signal repeats. ")


def tokenize(text):
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/tokenize",
        data=json.dumps({"content": text}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["tokens"]


def build_prompt(target_tokens):
    """Return (prompt, repeats): token ids sliced to exactly target_tokens."""
    if target_tokens <= 16:
        return "The capital of France is", 1
    filler = FILLER
    if FILLER_FILE:
        with open(FILLER_FILE, encoding="utf-8", errors="replace") as fh:
            filler = fh.read()
    ids = tokenize(filler)
    if not ids:
        raise SystemExit("filler tokenized to zero tokens")
    k = -(-target_tokens // len(ids))
    return (ids * k)[:target_tokens], k


def wait_ready(proc, deadline_s=900):
    t0 = time.time()
    while time.time() - t0 < deadline_s:
        if proc.poll() is not None:
            return False
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=5) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(2)
    return False


def fail(msg):
    tail = ""
    if SRVLOG and os.path.exists(SRVLOG):
        with open(SRVLOG, errors="replace") as fh:
            tail = fh.read()[-1500:]
    print(json.dumps({"error": msg, "server_tail": tail}))
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--draft", default="")
    ap.add_argument("--device", required=True)
    ap.add_argument("--ctx", type=int, required=True)
    ap.add_argument("--depth", type=int, required=True)
    ap.add_argument("--spec", choices=["none", "draft-mtp"], required=True)
    ap.add_argument("--nmax", type=int, default=3)
    ap.add_argument("--filler-file", default="")
    ap.add_argument("--port", type=int, default=18120)
    a = ap.parse_args()
    globals().update(
        SERVER=a.server, TARGET=a.target, DRAFT=a.draft, DEVICE=a.device,
        PORT=a.port, CTX=a.ctx, DEPTH=a.depth, SPEC=a.spec, NMAX=a.nmax,
        FILLER_FILE=a.filler_file,
        SRVLOG=os.path.join(tempfile.gettempdir(), f"mtp-depth-{a.device}-{a.spec}-{a.depth}.log"),
    )

    argv = [SERVER, "--model", TARGET, "--port", str(PORT), "--host", "127.0.0.1",
            "--device", DEVICE, "--n-gpu-layers", "99", "--ctx-size", str(CTX),
            "--parallel", "1", "--flash-attn", "on", "--spec-type", SPEC]
    if SPEC == "draft-mtp":
        argv += ["--model-draft", DRAFT, "--spec-draft-n-max", str(NMAX)]
    with open(SRVLOG, "w") as lf:
        proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=lf)
    try:
        if not wait_ready(proc):
            return fail("server not ready")
        prompt, repeats = build_prompt(DEPTH)
        body = json.dumps({
            "prompt": prompt, "n_predict": NGEN, "temperature": 0,
            "ignore_eos": True, "cache_prompt": False,
        }).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{PORT}/completion", data=body,
                                     headers={"Content-Type": "application/json"})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=3600) as r:
                resp = json.load(r)
        except urllib.error.HTTPError as e:
            return fail(f"HTTP {e.code}: {e.read().decode()[:500]}")
        except Exception as e:  # noqa: BLE001 - surface the server tail for any failure
            return fail(repr(e))
        t = resp.get("timings", {})
        if SPEC == "draft-mtp" and t.get("draft_n") is None:
            return fail("draft-mtp run drafted no tokens (draft_n missing)")
        if t.get("predicted_n") != NGEN:
            return fail(f"generation stopped short: predicted_n={t.get('predicted_n')} != {NGEN}")
        print(json.dumps({
            "device": DEVICE, "spec": SPEC, "nmax": NMAX, "depth_req": DEPTH, "repeats": repeats,
            "ctx": CTX, "prompt_n": t.get("prompt_n"), "predicted_n": t.get("predicted_n"),
            "prompt_tps": t.get("prompt_per_second"), "decode_tps": t.get("predicted_per_second"),
            "draft_n": t.get("draft_n"), "draft_n_accepted": t.get("draft_n_accepted"),
            "wall_s": round(time.time() - t0, 1),
        }))
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
