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
import statistics
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


def check_backends(base_url, required_recipes):
    """Assert all backends needed for requested recipes are ready."""
    try:
        backends = http_get(base_url, "/api/v0/backends")
    except urllib.error.URLError as exc:
        print(
            f"ERROR: cannot reach lemonade at {base_url}: {exc}",
            file=sys.stderr,
        )
        sys.exit(2)

    # backends is a list of dicts: [{name, status, ...}, ...]
    backend_map = {}
    for entry in backends:
        name = entry.get("name") or entry.get("backend_name") or ""
        status = entry.get("status", "")
        backend_map[name] = status

    not_ready = []
    for recipe in required_recipes:
        # recipe format: "llamacpp:rocm", "llamacpp:vulkan", "flm"
        # lemonade backend names match the recipe prefix
        backend_name = recipe.split(":")[0] if ":" in recipe else recipe
        # also try full recipe name
        status = (
            backend_map.get(recipe)
            or backend_map.get(backend_name)
            or "unknown"
        )
        if status not in ("ready", "installed"):
            not_ready.append(f"{recipe!r} (status={status!r})")

    if not_ready:
        print(
            "ERROR: the following backends are not ready: "
            + ", ".join(not_ready),
            file=sys.stderr,
        )
        print(
            "This means lemonade will silently fall back to CPU. "
            "Check LEMONADE_LLAMACPP_ROCM_BIN / "
            "LEMONADE_LLAMACPP_VULKAN_BIN env vars.",
            file=sys.stderr,
        )
        sys.exit(2)


def check_models(base_url, model_ids):
    """Assert models exist and are downloaded. Returns model info map."""
    try:
        models_list = http_get(base_url, "/api/v0/models")
    except urllib.error.URLError as exc:
        print(
            f"ERROR: cannot reach lemonade at {base_url}: {exc}",
            file=sys.stderr,
        )
        sys.exit(2)

    # Build a map from model_name to model metadata
    model_map = {}
    for m in models_list:
        name = m.get("model_name") or m.get("name") or ""
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
            "/api/v0/load",
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


def run_completion(base_url, prompt, gen_tokens):
    """Run one streaming completion.

    Returns (ttft_sec, decode_tps, total_tokens_generated).
    """
    payload = {
        "prompt": prompt,
        "max_tokens": gen_tokens,
        "stream": True,
    }

    t_start = time.monotonic()
    t_first_token = None
    token_count = 0
    t_last_token = None

    # Track usage from final SSE chunk if provided
    final_usage = None

    for raw_line in http_post_stream(base_url, "/v1/completions", payload):
        if raw_line.strip() == "[DONE]":
            break
        try:
            chunk = json.loads(raw_line)
        except json.JSONDecodeError:
            continue

        # Check for usage in final chunk (some servers send it)
        if "usage" in chunk and chunk.get("usage"):
            final_usage = chunk["usage"]

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

    if completion_tokens <= 1:
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
        run_completion(base_url, prompt, gen_tokens)

    print(
        f"  Measuring ({repeat} iteration(s))...", file=sys.stderr
    )
    ttft_samples = []
    tps_samples = []
    for i in range(repeat):
        ttft, tps, ntok = run_completion(base_url, prompt, gen_tokens)
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


def main():
    parser = argparse.ArgumentParser(
        description="Benchmark lemonade backends via HTTP API",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "model_ids",
        metavar="MODEL_ID",
        nargs="+",
        help="One or more lemonade model IDs to benchmark",
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
    args = parser.parse_args()

    model_ids = args.model_ids
    base_url = args.base_url.rstrip("/")

    print(
        f"Benchmarking {len(model_ids)} model(s) against {base_url}",
        file=sys.stderr,
    )

    # Step 1: get model info to find recipes, validate models exist
    model_map = check_models(base_url, model_ids)

    # Step 2: collect required recipes and validate backends are ready
    required_recipes = set()
    for mid in model_ids:
        recipe = (
            model_map[mid].get("recipe")
            or model_map[mid].get("backend")
            or "unknown"
        )
        required_recipes.add(recipe)

    print(
        "Required recipes: " + ", ".join(sorted(required_recipes)),
        file=sys.stderr,
    )
    check_backends(base_url, required_recipes)

    # Step 3: benchmark each model
    rows = []
    below_threshold = []

    for mid in model_ids:
        recipe = (
            model_map[mid].get("recipe")
            or model_map[mid].get("backend")
            or "unknown"
        )
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
