"""Benchmark lemonade backends (ROCm, Vulkan, FLM/NPU) via HTTP API.

Drives requested models through the lemonade OpenAI-compatible API,
measures TTFT and decode throughput, and prints a markdown table.

Exit codes:
  0 - all models measured decode t/s >= --min-decode-tps
  1 - at least one model fell below threshold (likely CPU fallback)
  2 - backend not ready or model not downloaded

NOTE: lemonade does not expose a per-request endpoint that reports
which hardware backend actually handled inference. We use the model's
recipe field from /api/v0/models (e.g. "llamacpp:rocm",
"llamacpp:vulkan", "flm") as the "Backend" column. If the backend
silently falls back to CPU, the recipe will still read the intended
backend but the measured decode t/s will be far below
--min-decode-tps, which is how this harness detects the fallback.
"""

import argparse
import json
import os
import pathlib
import re
import shlex
import signal
import socket
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request


def http_get(base_url, path):
    """Perform a GET request and return parsed JSON."""
    url = f"{base_url}{path}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.loads(resp.read())


def http_post(base_url, path, payload, timeout=120):
    """Perform a POST request and return (parsed JSON, raw bytes)."""
    url = f"{base_url}{path}"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw), raw


def http_post_stream(base_url, path, payload, timeout=300):
    """Perform a streaming POST and yield SSE data lines as strings."""
    url = f"{base_url}{path}"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        buf = b""
        while True:
            chunk = resp.read(4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.rstrip(b"\r")
                if line.startswith(b"data: "):
                    yield line[6:].decode("utf-8", errors="replace")


def find_free_port():
    """Return an unused TCP port on localhost.

    Binds to port 0 to let the kernel pick, reads the port, then closes
    the socket. The port is briefly racy until the caller binds again,
    which is fine for our subprocess spawn flow.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def resolve_lemonade_gguf(model_id, cache_root=None):
    """Return the absolute path to the GGUF file for a lemonade model id.

    Lemonade stores models in the HuggingFace hub cache layout:
    <cache_root>/models--<owner>--<repo>/snapshots/<rev>/<file>.gguf

    The lemonade model id is the trailing repo segment (everything
    after the second `--`). This resolver scans top-level entries,
    matches by repo segment, then recursively finds the lexicographically
    first .gguf file under the matched directory.

    Returns None if no matching `models--*--<model_id>` directory
    exists or the matched directory contains no .gguf file.

    cache_root defaults to ~/.cache/huggingface/hub.
    """
    if cache_root is None:
        cache_root = os.path.expanduser("~/.cache/huggingface/hub")
    cache_dir = pathlib.Path(cache_root)
    if not cache_dir.is_dir():
        return None
    for entry in sorted(cache_dir.iterdir()):
        if not entry.is_dir():
            continue
        if not entry.name.startswith("models--"):
            continue
        # name pattern: models--<owner>--<repo>
        parts = entry.name.split("--", 2)
        if len(parts) != 3:
            continue
        if parts[2] != model_id:
            continue
        for gguf in sorted(entry.rglob("*.gguf")):
            return str(gguf)
        return None  # matched dir but no gguf
    return None


_BACKEND_PREFIX = {"rocm": "ROCm", "vulkan": "Vulkan"}


def parse_llama_devices(output):
    """Parse the output of `llama-server --list-devices`.

    Returns a list of device identifier strings (e.g. ['Vulkan0',
    'ROCm0']) suitable for passing to `--device`. Recognizes only
    tokens whose prefix matches a known backend (see _BACKEND_PREFIX);
    other ':'-suffixed words (headers, diagnostics) are skipped.

    Raises RuntimeError if output is non-empty but no devices are
    parsed — likely indicates a format change in llama-server that
    needs the regex or prefix list updated.
    """
    devices = []
    known_prefixes = tuple(_BACKEND_PREFIX.values())
    for line in output.splitlines():
        m = re.match(r"\s*([A-Za-z][A-Za-z0-9]*)\s*:", line)
        if m and m.group(1).startswith(known_prefixes):
            devices.append(m.group(1))
    if output.strip() and not devices:
        raise RuntimeError(
            f"parse_llama_devices: no devices parsed from"
            f" non-empty output (format change?). Raw output:\n"
            f"{output!r}"
        )
    return devices


def pick_device(devices, backend):
    """Return the device string matching the requested backend.

    backend must be a key of _BACKEND_PREFIX (e.g. 'rocm', 'vulkan').
    Raises ValueError if the backend is unknown or no matching device
    is present in `devices`.
    """
    prefix = _BACKEND_PREFIX.get(backend)
    if prefix is None:
        raise ValueError(
            f"unknown backend {backend!r};"
            f" expected one of {sorted(_BACKEND_PREFIX)}"
        )
    for d in devices:
        if d.startswith(prefix):
            return d
    raise ValueError(
        f"no {backend} device found in {devices}; check"
        f" llama-server --list-devices"
    )


def build_llama_server_args(
    bin_path, gguf, port, device, spec_type, n_gpu_layers, ctx_size,
):
    """Build the argv list to spawn llama-server for an MTP A/B run.

    bin_path is the absolute path to the backend-specific llama-server
    binary (ROCm and Vulkan are separately-compiled builds in this
    flake, exposed via LEMONADE_LLAMACPP_{ROCM,VULKAN}_BIN env vars).

    port, n_gpu_layers, and ctx_size are integers (stringified here).

    spec_type must be a value accepted by `--spec-type`. For our A/B:
    'none' (MTP off) and 'draft-mtp' (MTP on, requires b9213+).
    """
    return [
        bin_path,
        "--model", gguf,
        "--port", str(port),
        "--host", "127.0.0.1",
        "--device", device,
        "--spec-type", spec_type,
        "--n-gpu-layers", str(n_gpu_layers),
        "--ctx-size", str(ctx_size),
    ]


class LlamaServer:
    """Context manager that spawns and reaps a llama-server subprocess.

    Spawns the server with the given argv, polls /health until ready or
    timeout, exposes `base_url`. On exit sends SIGTERM, waits up to
    `term_timeout` seconds, then SIGKILLs if still alive.
    """

    def __init__(self, argv, port, ready_timeout=300, term_timeout=10):
        self.argv = argv
        self.port = port
        self.ready_timeout = ready_timeout
        self.term_timeout = term_timeout
        self.base_url = f"http://127.0.0.1:{port}"
        self.proc = None

    def __enter__(self):
        print(
            f"  Spawning: {shlex.join(self.argv)}",
            file=sys.stderr,
        )
        self.proc = subprocess.Popen(
            self.argv,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        try:
            self._wait_ready()
        except Exception:
            self.__exit__(None, None, None)
            raise
        return self

    def _wait_ready(self):
        assert self.proc is not None
        assert self.proc.stderr is not None
        deadline = time.monotonic() + self.ready_timeout
        last_err = None
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                stderr = self.proc.stderr.read().decode(
                    "utf-8", errors="replace"
                )
                raise RuntimeError(
                    f"llama-server exited with code"
                    f" {self.proc.returncode} before becoming ready."
                    f" stderr:\n{stderr[-2000:]}"
                )
            try:
                http_get(self.base_url, "/health")
                return
            except (urllib.error.URLError, ConnectionError, OSError) as exc:
                last_err = exc
                time.sleep(0.5)
        raise TimeoutError(
            f"llama-server at {self.base_url} did not become ready"
            f" within {self.ready_timeout}s (last error: {last_err})"
        )

    def __exit__(self, _exc_type, _exc, _tb):
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=self.term_timeout)
            except subprocess.TimeoutExpired:
                print(
                    "  WARNING: llama-server did not exit on SIGTERM;"
                    " sending SIGKILL",
                    file=sys.stderr,
                )
                self.proc.kill()
                self.proc.wait()
        self.proc = None


def set_llamacpp_backend(config_path, backend):
    """Write llamacpp.backend into lemonade's config.json.

    Returns the previous value (or None if the key was absent), so the
    caller can restore state on exit.
    """
    if os.path.exists(config_path):
        with open(config_path, "r") as f:
            config = json.load(f)
    else:
        config = {}
        os.makedirs(os.path.dirname(config_path), exist_ok=True)

    llamacpp = config.setdefault("llamacpp", {})
    prev = llamacpp.get("backend")
    llamacpp["backend"] = backend

    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    return prev


def restore_llamacpp_backend(config_path, prev):
    """Restore a previously captured llamacpp.backend value."""
    if not os.path.exists(config_path):
        return
    with open(config_path, "r") as f:
        config = json.load(f)
    llamacpp = config.setdefault("llamacpp", {})
    if prev is None:
        llamacpp.pop("backend", None)
    else:
        llamacpp["backend"] = prev
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)


def restart_lemond(service):
    """Restart lemond via sudo systemctl. Raises on failure."""
    print(
        f"  Restarting {service} (may prompt for sudo)...",
        file=sys.stderr,
    )
    subprocess.run(
        ["sudo", "systemctl", "restart", service],
        check=True,
    )


def wait_for_lemond(base_url, timeout=60):
    """Poll /api/v1/models until lemond answers, or raise TimeoutError."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            http_get(base_url, "/api/v1/models")
            return
        except (urllib.error.URLError, ConnectionError, OSError):
            time.sleep(1)
    raise TimeoutError(
        f"lemond did not become reachable at {base_url} within"
        f" {timeout}s"
    )


def check_backends(_base_url, _required_recipes):
    """Backend readiness check.

    Lemonade does not expose a /api/v1/backends HTTP endpoint -- the
    `lemonade backends` CLI reads local config files directly. We rely on
    the post-hoc --min-decode-tps threshold to catch silent CPU fallback.
    """
    return


def check_models(base_url, model_ids):
    """Assert models exist and are downloaded. Returns model info map."""
    try:
        response = http_get(base_url, "/api/v1/models")
    except urllib.error.URLError as exc:
        print(
            f"ERROR: cannot reach lemonade at {base_url}: {exc}",
            file=sys.stderr,
        )
        sys.exit(2)

    # /api/v1/models returns {"data": [...], "object": "list"}
    if isinstance(response, dict):
        models_list = response.get("data", [])
    else:
        models_list = response

    # Build a map from model id to metadata
    model_map = {}
    for m in models_list:
        name = m.get("id") or m.get("model_name") or m.get("name") or ""
        model_map[name] = m

    not_found = []
    not_downloaded = []
    for mid in model_ids:
        if mid not in model_map:
            not_found.append(mid)
        elif not model_map[mid].get("downloaded", False):
            not_downloaded.append(mid)

    if not_found:
        print(
            "ERROR: models not found: " + ", ".join(not_found),
            file=sys.stderr,
        )
        sys.exit(2)
    if not_downloaded:
        print(
            "ERROR: models not downloaded"
            " (run 'lemonade pull <model>'): "
            + ", ".join(not_downloaded),
            file=sys.stderr,
        )
        sys.exit(2)

    return model_map


def load_model(base_url, model_id):
    """Load a model into lemonade."""
    try:
        result, _ = http_post(
            base_url,
            "/api/v1/load",
            {"model_name": model_id},
            timeout=300,
        )
        return result
    except urllib.error.URLError as exc:
        print(
            f"ERROR: failed to load model {model_id!r}: {exc}",
            file=sys.stderr,
        )
        sys.exit(2)


def build_prompt(prompt_tokens):
    """Build a rough prompt of approximately prompt_tokens tokens.

    Uses 'The ' repeated to approximate target length.
    We don't need to be precise -- lemonade uses its own tokenizer.
    """
    return "The " * prompt_tokens


def run_completion(
    base_url, model_id, prompt, gen_tokens,
    completions_path="/api/v1/completions",
):
    """Run one streaming completion.

    completions_path defaults to lemonade's '/api/v1/completions'. Pass
    '/v1/completions' when talking to a raw llama-server (the MTP A/B
    mode spawns the server directly without the lemonade prefix).

    Returns (ttft_sec, decode_tps, total_tokens_generated).
    """
    payload = {
        "model": model_id,
        "prompt": prompt,
        "max_tokens": gen_tokens,
        "stream": True,
    }

    t_start = time.monotonic()
    t_first_token = None
    token_count = 0
    t_last_token = None

    # Track usage and timings from final SSE chunk
    final_usage = None
    final_timings = None

    for raw_line in http_post_stream(
        base_url, completions_path, payload
    ):
        if raw_line.strip() == "[DONE]":
            break
        try:
            chunk = json.loads(raw_line)
        except json.JSONDecodeError:
            continue

        # Check for usage in final chunk (some servers send it)
        if "usage" in chunk and chunk.get("usage"):
            final_usage = chunk["usage"]
        if "timings" in chunk and chunk.get("timings"):
            final_timings = chunk["timings"]

        choices = chunk.get("choices", [])
        for choice in choices:
            text = choice.get("text", "")
            if text:
                now = time.monotonic()
                if t_first_token is None:
                    t_first_token = now
                token_count += 1
                t_last_token = now

    if t_first_token is None:
        # No tokens received
        return None, None, 0

    ttft = t_first_token - t_start

    # Use server-reported completion token count if available
    if final_usage and final_usage.get("completion_tokens"):
        completion_tokens = final_usage["completion_tokens"]
    else:
        completion_tokens = token_count

    # Prefer server-reported timings (llama.cpp's predicted_per_second)
    # over client-side measurement -- they exclude HTTP/SSE overhead.
    if final_timings and final_timings.get("predicted_per_second"):
        decode_tps = final_timings["predicted_per_second"]
    elif completion_tokens <= 1:
        decode_tps = 0.0
    else:
        decode_elapsed = t_last_token - t_first_token
        if decode_elapsed <= 0:
            decode_tps = float("inf")
        else:
            decode_tps = (completion_tokens - 1) / decode_elapsed

    return ttft, decode_tps, completion_tokens


def benchmark_model(
    base_url, model_id, prompt_tokens, gen_tokens, warmup, repeat
):
    """Benchmark a single model.

    Returns (mean_ttft, mean_tps, stdev_tps).
    """
    print(f"  Loading {model_id!r}...", file=sys.stderr)
    load_model(base_url, model_id)

    prompt = build_prompt(prompt_tokens)

    print(
        f"  Warming up ({warmup} iteration(s))...", file=sys.stderr
    )
    for _ in range(warmup):
        run_completion(base_url, model_id, prompt, gen_tokens)

    print(
        f"  Measuring ({repeat} iteration(s))...", file=sys.stderr
    )
    ttft_samples = []
    tps_samples = []
    for i in range(repeat):
        ttft, tps, ntok = run_completion(
            base_url, model_id, prompt, gen_tokens
        )
        if ttft is None:
            print(
                f"  WARNING: iteration {i + 1} produced no tokens",
                file=sys.stderr,
            )
            continue
        print(
            f"    iter {i + 1}: TTFT={ttft:.3f}s,"
            f" decode={tps:.1f} t/s, tokens={ntok}",
            file=sys.stderr,
        )
        ttft_samples.append(ttft)
        tps_samples.append(tps)

    if not tps_samples:
        return None, None, None

    mean_ttft = statistics.mean(ttft_samples)
    mean_tps = statistics.mean(tps_samples)
    stdev_tps = (
        statistics.stdev(tps_samples) if len(tps_samples) > 1 else 0.0
    )

    return mean_ttft, mean_tps, stdev_tps


def print_markdown_table(rows):
    """Print results as a GitHub-flavored markdown table."""
    header = "| Model | Backend | TTFT (s) | Decode (t/s) |"
    sep = "| ----- | ------- | -------: | -----------: |"
    print(header)
    print(sep)
    for model_id, recipe, mean_ttft, mean_tps, stdev_tps in rows:
        ttft_str = f"{mean_ttft:.2f}" if mean_ttft is not None else "N/A"
        if mean_tps is None:
            tps_str = "N/A"
        elif stdev_tps > 0:
            tps_str = f"{mean_tps:.1f} +/- {stdev_tps:.1f}"
        else:
            tps_str = f"{mean_tps:.1f}"
        print(
            f"| {model_id} | {recipe} | {ttft_str} | {tps_str} |"
        )


def format_mtp_row(model_id, backend, off_tps, on_tps):
    """Format one markdown table row for the MTP A/B sweep."""

    def fmt(v):
        return f"{v:.1f}" if isinstance(v, (int, float)) else "N/A"

    if isinstance(off_tps, (int, float)) and off_tps > 0 \
            and isinstance(on_tps, (int, float)):
        speedup = f"{on_tps / off_tps:.2f}x"
    else:
        speedup = "N/A"
    return (
        f"| {model_id} | {backend} | {fmt(off_tps)} |"
        f" {fmt(on_tps)} | {speedup} |"
    )


_BACKEND_BIN_ENV = {
    "rocm": "LEMONADE_LLAMACPP_ROCM_BIN",
    "vulkan": "LEMONADE_LLAMACPP_VULKAN_BIN",
}

_BACKEND_NIX_OPTION = {
    "rocm": "enableROCm",
    "vulkan": "enableVulkan",
}


def _resolve_backend_bin(backend):
    """Look up the llama-server binary for a backend.

    Each backend is a separately-compiled build in this flake. The
    NixOS module exports LEMONADE_LLAMACPP_<BACKEND>_BIN pointing at
    the relevant /nix/store path.
    """
    env_var = _BACKEND_BIN_ENV.get(backend)
    if env_var is None:
        raise ValueError(
            f"unknown backend {backend!r};"
            f" expected one of {sorted(_BACKEND_BIN_ENV)}"
        )
    path = os.environ.get(env_var)
    if not path:
        nix_opt = _BACKEND_NIX_OPTION[backend]
        raise RuntimeError(
            f"{env_var} not set in environment; the nix-amd-ai"
            f" module sets it when hardware.amd-npu.{nix_opt} = true."
            f" Run from a session where the module env is active."
        )
    return path


def _measure_one_spec(server, prompt_tokens, gen_tokens, warmup, repeat):
    """Run warmup + repeat completions against a live llama-server.

    Returns the mean decode t/s (from server-reported timings), or None
    if no successful iterations.
    """
    prompt = build_prompt(prompt_tokens)
    for _ in range(warmup):
        run_completion(
            server.base_url, "default", prompt, gen_tokens,
            completions_path="/v1/completions",
        )

    tps_samples = []
    for i in range(repeat):
        _ttft, tps, ntok = run_completion(
            server.base_url, "default", prompt, gen_tokens,
            completions_path="/v1/completions",
        )
        if tps is None:
            print(
                f"    iter {i + 1}: no tokens received",
                file=sys.stderr,
            )
            continue
        print(
            f"    iter {i + 1}: decode={tps:.1f} t/s, tokens={ntok}",
            file=sys.stderr,
        )
        tps_samples.append(tps)

    if not tps_samples:
        return None
    return statistics.mean(tps_samples)


def run_mtp_ab(
    model_id, backends, prompt_tokens, gen_tokens, warmup, repeat,
):
    """Drive an MTP-on / MTP-off A/B across the given backends.

    Spawns llama-server twice per backend (--spec-type none, then
    --spec-type draft-mtp) against the same GGUF. Prints a markdown
    table.
    """
    if not backends:
        print(
            "ERROR: --mtp-ab-backends produced an empty backend list",
            file=sys.stderr,
        )
        sys.exit(2)

    gguf = resolve_lemonade_gguf(model_id)
    if gguf is None:
        print(
            f"ERROR: model {model_id!r} not found in lemonade cache."
            f" Run: lemonade pull {model_id}",
            file=sys.stderr,
        )
        sys.exit(2)

    print(
        f"\nMTP A/B sweep: model={model_id}\n"
        f"  gguf={gguf}\n"
        f"  backends={backends}\n"
        f"  protocol: prompt={prompt_tokens} tokens,"
        f" gen={gen_tokens} tokens,"
        f" {warmup} warmup + {repeat} measured\n",
        file=sys.stderr,
    )

    rows = []
    for backend in backends:
        bin_path = _resolve_backend_bin(backend)
        devices_output = subprocess.run(
            [bin_path, "--list-devices"],
            capture_output=True, text=True, timeout=30, check=True,
        ).stdout
        devices = parse_llama_devices(devices_output)
        device = pick_device(devices, backend)
        print(
            f"\n[{backend}] bin={bin_path} device={device}",
            file=sys.stderr,
        )

        results = {}
        for spec_type in ("none", "draft-mtp"):
            print(
                f"\n[{backend}] --spec-type {spec_type}",
                file=sys.stderr,
            )
            port = find_free_port()
            argv = build_llama_server_args(
                bin_path=bin_path, gguf=gguf, port=port,
                device=device, spec_type=spec_type,
                n_gpu_layers=99, ctx_size=4096,
            )
            try:
                with LlamaServer(argv, port) as server:
                    results[spec_type] = _measure_one_spec(
                        server, prompt_tokens, gen_tokens, warmup, repeat,
                    )
            except RuntimeError as exc:
                msg = str(exc)
                if spec_type == "draft-mtp" and "mtp" in msg.lower():
                    print(
                        f"ERROR: model {model_id!r} has no MTP head"
                        f" (--spec-type draft-mtp rejected by"
                        f" llama-server). Pick an MTP-labeled model.",
                        file=sys.stderr,
                    )
                    sys.exit(1)
                raise

        row = format_mtp_row(
            model_id=model_id,
            backend=backend,
            off_tps=results.get("none"),
            on_tps=results.get("draft-mtp"),
        )
        rows.append(row)
        print("\n" + row, file=sys.stderr)

    print()
    print("| Model | Backend | MTP off (t/s) | MTP on (t/s) | Speedup |")
    print("| ----- | ------- | ------------: | -----------: | ------: |")
    for row in rows:
        print(row)


def main():
    parser = argparse.ArgumentParser(
        description="Benchmark lemonade backends via HTTP API",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "model_ids",
        metavar="MODEL_ID",
        nargs="*",
        default=[],
        help=(
            "One or more lemonade model IDs to benchmark (lemonade"
            " HTTP mode). Omit when using --mtp-ab."
        ),
    )
    parser.add_argument(
        "--base-url",
        default="http://localhost:13305",
        help="Lemonade server base URL",
    )
    parser.add_argument(
        "--prompt-tokens",
        type=int,
        default=512,
        help="Approximate number of prompt tokens",
    )
    parser.add_argument(
        "--gen-tokens",
        type=int,
        default=128,
        help="Number of tokens to request per completion",
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=1,
        help="Number of warmup iterations before measurement",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=3,
        help="Number of measurement iterations",
    )
    parser.add_argument(
        "--min-decode-tps",
        type=float,
        default=5.0,
        help=(
            "Minimum acceptable decode t/s; exit 1 if any model"
            " falls below this (signals CPU fallback)"
        ),
    )
    parser.add_argument(
        "--backend",
        choices=["rocm", "vulkan", "auto"],
        default=None,
        help=(
            "Force llamacpp.backend in lemonade config and restart"
            " lemond before benchmarking (llamacpp-recipe models only)."
            " Original config is restored on exit."
            " Requires sudo unless --no-restart is set."
        ),
    )
    parser.add_argument(
        "--config-path",
        default=os.path.expanduser("~/.cache/lemonade/config.json"),
        help="Path to lemonade's config.json",
    )
    parser.add_argument(
        "--lemond-service",
        default="lemond.service",
        help="systemd service name to restart when --backend is set",
    )
    parser.add_argument(
        "--no-restart",
        action="store_true",
        help=(
            "Skip sudo systemctl restart after writing the config."
            " Useful if you've already restarted lemond manually or"
            " are running in an environment without sudo."
        ),
    )
    parser.add_argument(
        "--mtp-ab",
        metavar="MODEL_ID",
        default=None,
        help=(
            "Run a same-GGUF A/B between --spec-type none and"
            " --spec-type draft-mtp on the given lemonade model id."
            " Spawns llama-server directly (bypasses lemond); requires"
            " the model to be pulled and to have an MTP head."
            " Mutually exclusive with the positional MODEL_ID arguments."
        ),
    )
    parser.add_argument(
        "--mtp-ab-backends",
        default="rocm,vulkan",
        help=(
            "Comma-separated list of backends to sweep when --mtp-ab"
            " is set."
        ),
    )
    args = parser.parse_args()

    if args.mtp_ab:
        if args.model_ids:
            print(
                "ERROR: --mtp-ab is mutually exclusive with"
                " positional MODEL_ID arguments",
                file=sys.stderr,
            )
            sys.exit(2)
        backends = [
            b.strip() for b in args.mtp_ab_backends.split(",") if b.strip()
        ]
        run_mtp_ab(
            model_id=args.mtp_ab,
            backends=backends,
            prompt_tokens=args.prompt_tokens,
            gen_tokens=args.gen_tokens,
            warmup=args.warmup,
            repeat=args.repeat,
        )
        return

    if not args.model_ids:
        print(
            "ERROR: at least one MODEL_ID is required (or use"
            " --mtp-ab)",
            file=sys.stderr,
        )
        sys.exit(2)

    model_ids = args.model_ids
    base_url = args.base_url.rstrip("/")

    print(
        f"Benchmarking {len(model_ids)} model(s) against {base_url}",
        file=sys.stderr,
    )

    # Optionally force a specific llamacpp backend by rewriting
    # lemonade's config.json + restarting lemond. Guaranteed to be
    # restored on exit via try/finally below.
    forced_backend = args.backend
    prev_backend = None
    backend_forced = False
    if forced_backend is not None:
        prev_backend = set_llamacpp_backend(
            args.config_path, forced_backend
        )
        backend_forced = True
        print(
            f"  Forced llamacpp.backend = {forced_backend!r}"
            f" (was {prev_backend!r}) in {args.config_path}",
            file=sys.stderr,
        )
        if not args.no_restart:
            restart_lemond(args.lemond_service)
            wait_for_lemond(base_url)

    try:
        run_benchmarks(args, base_url, model_ids, forced_backend)
    finally:
        if backend_forced:
            restore_llamacpp_backend(args.config_path, prev_backend)
            print(
                f"  Restored llamacpp.backend to {prev_backend!r}",
                file=sys.stderr,
            )
            if not args.no_restart:
                try:
                    restart_lemond(args.lemond_service)
                except subprocess.CalledProcessError as exc:
                    print(
                        f"  WARNING: failed to restart lemond during"
                        f" cleanup: {exc}",
                        file=sys.stderr,
                    )


def run_benchmarks(args, base_url, model_ids, forced_backend):
    """Execute the benchmark against an already-prepared lemond."""
    # Step 1: get model info to find recipes, validate models exist
    model_map = check_models(base_url, model_ids)

    def model_recipe(mid):
        raw = (
            model_map[mid].get("recipe")
            or model_map[mid].get("backend")
            or "unknown"
        )
        # When the user forces a specific llamacpp backend, rewrite the
        # recipe label so the table reflects what actually ran. FLM and
        # other non-llamacpp recipes are untouched.
        if (
            forced_backend in ("rocm", "vulkan")
            and raw.startswith("llamacpp")
        ):
            return f"llamacpp:{forced_backend}"
        return raw

    # Step 2: collect required recipes and validate backends are ready
    required_recipes = {model_recipe(mid) for mid in model_ids}

    print(
        "Required recipes: " + ", ".join(sorted(required_recipes)),
        file=sys.stderr,
    )
    check_backends(base_url, required_recipes)

    # Step 3: benchmark each model
    rows = []
    below_threshold = []

    for mid in model_ids:
        recipe = model_recipe(mid)
        print(
            f"\nBenchmarking {mid!r} (recipe={recipe})...",
            file=sys.stderr,
        )

        mean_ttft, mean_tps, stdev_tps = benchmark_model(
            base_url,
            mid,
            args.prompt_tokens,
            args.gen_tokens,
            args.warmup,
            args.repeat,
        )

        rows.append((mid, recipe, mean_ttft, mean_tps, stdev_tps))

        if mean_tps is not None and mean_tps < args.min_decode_tps:
            below_threshold.append(
                f"{mid!r} ({recipe}): {mean_tps:.1f} t/s"
                f" < {args.min_decode_tps} t/s threshold"
            )

    # Step 4: print results table
    print()
    print_markdown_table(rows)

    # Step 5: exit non-zero if any model fell below threshold
    if below_threshold:
        print(
            "\nERROR: the following models are below the minimum"
            f" decode t/s threshold ({args.min_decode_tps} t/s)"
            " -- likely CPU fallback:",
            file=sys.stderr,
        )
        for msg in below_threshold:
            print(f"  {msg}", file=sys.stderr)
        sys.exit(1)

    print(
        "\nAll models passed minimum decode t/s threshold.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
