#!/usr/bin/env python3
"""Throwaway benchmark script for the typed-decisions exploration (#149).

Not a flake output. Run under experiments/laya/shell.nix, e.g.:

    nix-shell experiments/laya/shell.nix --run "python experiments/laya/bench.py probe"

Subcommands: probe, laya-latency (Step 2, implemented here); grade,
baselines, report, contention (Step 3, stubbed below).
"""

import argparse
import json
import math
import random
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path

import torch

BASE_URL = "http://localhost:13305"
RESULTS_PATH = Path(__file__).parent / "results" / "halo-2026-09-22.json"

FLM_MODEL = "llama3.2-1b-FLM"
FALLBACK_MODEL = "Qwen3.5-4B-GGUF"

POOL_SEED = 149
LABEL_MAP = {"1": "A", "2": "B", "3": "C", "4": "D"}


def cpu_model() -> str:
    with open("/proc/cpuinfo") as f:
        for line in f:
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    return "unknown"


def host_prefix() -> str:
    return f"{socket.gethostname()} / {cpu_model()} / CPU {torch.get_num_threads()} threads"


def load_results() -> dict:
    if RESULTS_PATH.exists():
        return json.loads(RESULTS_PATH.read_text())
    return {}


def save_results(results: dict) -> None:
    RESULTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    RESULTS_PATH.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")


def percentile(sorted_values: list, pct: float) -> float:
    if not sorted_values:
        return float("nan")
    k = (len(sorted_values) - 1) * (pct / 100)
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return sorted_values[int(k)]
    return sorted_values[f] + (sorted_values[c] - sorted_values[f]) * (k - f)


def build_pool() -> list:
    """ARC-Challenge test then ARC-Easy test, 4-choice items only, each
    split independently shuffled with seed 149. Shared with Step 3's
    `grade` so the two subcommands see the same pool/order.
    """
    from huggingface_hub import hf_hub_download
    import pyarrow.parquet as pq

    pool = []
    for split, filename in (
        ("Challenge", "ARC-Challenge/test-00000-of-00001.parquet"),
        ("Easy", "ARC-Easy/test-00000-of-00001.parquet"),
    ):
        local_path = hf_hub_download(
            repo_id="allenai/ai2_arc", repo_type="dataset", filename=filename
        )
        rows = pq.read_table(local_path).to_pylist()

        split_items = []
        for row in rows:
            labels = row["choices"]["label"]
            texts = row["choices"]["text"]
            if len(labels) != 4:
                continue
            norm_labels = [LABEL_MAP.get(lab, lab) for lab in labels]
            if any(lab not in ("A", "B", "C", "D") for lab in norm_labels):
                continue
            key = LABEL_MAP.get(row["answerKey"], row["answerKey"])
            if key not in norm_labels:
                continue
            split_items.append(
                {
                    "id": row["id"],
                    "split": split,
                    "question": row["question"],
                    "choices": list(zip(norm_labels, texts)),
                    "key": key,
                }
            )

        random.Random(POOL_SEED).shuffle(split_items)
        pool.extend(split_items)

    return pool


def format_prompt(item: dict) -> str:
    """The exact grading prompt: Step 3's `grade` parses against this text
    verbatim, so keep every caller going through this one function.
    """
    lines = [item["question"], ""]
    for label, text in item["choices"]:
        lines.append(f"{label}. {text}")
    lines.append("")
    lines.append('Give one sentence of reasoning, then a final line "Answer: <letter>".')
    return "\n".join(lines)


def cmd_probe(args: argparse.Namespace) -> None:
    results = load_results()
    results["host"] = socket.gethostname()
    results["cpu"] = cpu_model()
    results["threads"] = torch.get_num_threads()
    prefix = host_prefix()

    try:
        with urllib.request.urlopen(f"{BASE_URL}/api/v1/health", timeout=10) as resp:
            health = json.loads(resp.read())
        print(f"{prefix} health: {json.dumps(health)}")
    except (urllib.error.URLError, OSError) as e:
        health = {"error": f"{type(e).__name__}: {e}"}
        print(f"{prefix} health probe failed: {health['error']}")
    results["health_at_probe"] = health

    body = json.dumps(
        {
            "model": FLM_MODEL,
            "messages": [{"role": "user", "content": "Say OK."}],
            "max_tokens": 8,
            "temperature": 0,
        }
    ).encode()
    req = urllib.request.Request(
        f"{BASE_URL}/api/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            payload = json.loads(resp.read())
        candidate, candidate_reason = FLM_MODEL, "FLM probe ok"
        print(f"{prefix} FLM probe ok: {json.dumps(payload)[:200]}")
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        reason = f"{type(e).__name__}: {e}"
        print(f"FLM probe failed: {reason}")
        candidate, candidate_reason = FALLBACK_MODEL, reason

    results["candidate"] = candidate
    results["candidate_reason"] = candidate_reason
    save_results(results)


def cmd_laya_latency(args: argparse.Namespace) -> None:
    results = load_results()
    results["host"] = socket.gethostname()
    results["cpu"] = cpu_model()
    results["threads"] = torch.get_num_threads()
    prefix = host_prefix()

    key = "laya" if args.checkpoint == "root" else "laya_typed_decisions"
    subfolder = None if args.checkpoint == "root" else "typed-decisions"

    try:
        import laya
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
        print(f"{prefix} import laya failed: {err}")
        results.setdefault(key, {})["import_error"] = err
        save_results(results)
        return

    t0 = time.monotonic()
    try:
        agent = laya.load("convaiinnovations/laya", device="cpu", subfolder=subfolder)
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
        print(f"{prefix} laya.load failed: {err}")
        results.setdefault(key, {})["import_error"] = err
        save_results(results)
        return
    load_s = time.monotonic() - t0
    print(f"{prefix} laya.load({args.checkpoint}) took {load_s:.2f}s")

    pool = build_pool()
    questions = laya.router_questions()

    for item in pool[:5]:
        agent.predict({"request": format_prompt(item)}, questions)

    bench_items = pool[: args.n]
    per_prompt = {}
    times_ms = []
    for item in bench_items:
        prompt = format_prompt(item)
        t0 = time.monotonic()
        answers = agent.predict({"request": prompt}, questions)["answers"]
        ms = (time.monotonic() - t0) * 1000
        times_ms.append(ms)
        per_prompt[item["id"]] = {
            "ms": round(ms, 3),
            "difficulty_score": answers["difficulty"]["score"],
            "needs_tools": answers["needs_tools"]["noul"],
            "is_sensitive": answers["is_sensitive"]["noul"],
            "domain": answers["domain"]["choice"],
        }

    times_sorted = sorted(times_ms)
    p50 = percentile(times_sorted, 50)
    p95 = percentile(times_sorted, 95)

    # Batched cost: ask 10 questions in a single predict() by cycling the
    # four router_questions() defs under distinct ids.
    base_keys = list(questions.keys())
    ten_questions = {f"q{i}": questions[base_keys[i % len(base_keys)]] for i in range(10)}
    t0 = time.monotonic()
    agent.predict({"request": format_prompt(bench_items[0])}, ten_questions)
    batched10_ms_per_q = (time.monotonic() - t0) * 1000 / 10

    results[key] = {
        "checkpoint": args.checkpoint,
        "load_s": round(load_s, 3),
        "threads": torch.get_num_threads(),
        "n": len(bench_items),
        "p50_ms": round(p50, 3),
        "p95_ms": round(p95, 3),
        "batched10_ms_per_q": round(batched10_ms_per_q, 3),
        "per_prompt": per_prompt,
    }
    save_results(results)

    print(
        f"{prefix} laya {args.checkpoint}: load={load_s:.2f}s n={len(bench_items)} "
        f"p50={p50:.1f}ms p95={p95:.1f}ms batched10/q={batched10_ms_per_q:.1f}ms"
    )


def cmd_grade(args: argparse.Namespace) -> None:
    raise SystemExit("bench.py grade: implemented in Step 3 of the plan, not yet built.")


def cmd_baselines(args: argparse.Namespace) -> None:
    raise SystemExit("bench.py baselines: implemented in Step 3 of the plan, not yet built.")


def cmd_report(args: argparse.Namespace) -> None:
    raise SystemExit("bench.py report: implemented in Step 3 of the plan, not yet built.")


def cmd_contention(args: argparse.Namespace) -> None:
    raise SystemExit("bench.py contention: implemented in Step 3 of the plan, not yet built.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("probe", help="Check lemonade health and the FLM candidate.")

    latency = sub.add_parser("laya-latency", help="Measure Laya load + predict latency over the ARC pool.")
    latency.add_argument("--checkpoint", choices=["root", "typed-decisions"], default="root")
    latency.add_argument("--n", type=int, default=120)

    sub.add_parser("grade", help="Step 3: grade the candidate over the ARC pool.")
    sub.add_parser("baselines", help="Step 3: compute baseline signals per graded item.")
    sub.add_parser("report", help="Step 3: AUC + latency report, PASS/KILL lines.")
    sub.add_parser("contention", help="Step 3: latency under NPU/iGPU contention.")

    args = parser.parse_args()

    dispatch = {
        "probe": cmd_probe,
        "laya-latency": cmd_laya_latency,
        "grade": cmd_grade,
        "baselines": cmd_baselines,
        "report": cmd_report,
        "contention": cmd_contention,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()
