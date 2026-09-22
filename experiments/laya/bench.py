#!/usr/bin/env python3
"""Throwaway benchmark script for the typed-decisions exploration (#149).

Not a flake output. Run under experiments/laya/shell.nix, e.g.:

    nix-shell experiments/laya/shell.nix --run "python experiments/laya/bench.py probe"

Subcommands: probe, laya-latency, grade, baselines, report, contention.
"""

import argparse
import collections
import json
import math
import random
import re
import socket
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import torch

BASE_URL = "http://localhost:13305"
RESULTS_PATH = Path(__file__).parent / "results" / "halo-2026-09-22.json"
REPORT_PATH = Path(__file__).parent / "results" / "halo-2026-09-22.md"

FLM_MODEL = "llama3.2-1b-FLM"
FALLBACK_MODEL = "Qwen3.5-4B-GGUF"
JUDGE_MODEL = FALLBACK_MODEL

POOL_SEED = 149
LABEL_MAP = {"1": "A", "2": "B", "3": "C", "4": "D"}

# Step 3 pre-registered thresholds (spec Deliverable 2, plan Fixed inputs) — kill
# I1/I2 if ANY of these hold.
KILL_AUC_FLOOR = 0.65
KILL_AUC_MARGIN = 0.05
KILL_WARM_P50_MS = 250.0

ANSWER_LINE_RE = re.compile(r"answer\s*:\s*([A-Da-d])\b")
STANDALONE_LETTER_RE = re.compile(r"(?<![A-Za-z0-9])([A-D])(?![A-Za-z0-9])")

GRADE_STOP_MIN = 40
GRADE_STOP_MINORITY_UNMEASURABLE = 25
GRADE_CAP_FLM = 400
GRADE_CAP_FALLBACK = 600

CONTENTION_WALL_BUDGET_S = 30 * 60


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


def http_get(path: str, timeout: float = 10.0) -> dict:
    with urllib.request.urlopen(f"{BASE_URL}{path}", timeout=timeout) as resp:
        return json.loads(resp.read())


def http_post(path: str, body: dict, timeout: float = 120.0) -> tuple:
    """POST JSON, return (response_json, wall_ms)."""
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read())
    return payload, (time.monotonic() - t0) * 1000


def parse_answer(text: str) -> tuple:
    """Last "Answer: X" line; else the last standalone A-D token; else
    unparseable (`grade`'s rule). Returns (letter_or_None, unparseable)."""
    matches = ANSWER_LINE_RE.findall(text)
    if matches:
        return matches[-1].upper(), False
    matches = STANDALONE_LETTER_RE.findall(text)
    if matches:
        return matches[-1], False
    return None, True


def router_predict_one(agent, questions: dict, request_text: str) -> tuple:
    """One agent.predict() call, keyed by `request`. Returns (answers, ms)."""
    t0 = time.monotonic()
    answers = agent.predict({"request": request_text}, questions)["answers"]
    return answers, (time.monotonic() - t0) * 1000


def router_fields(answers: dict) -> dict:
    return {
        "difficulty_score": answers["difficulty"]["score"],
        "needs_tools": answers["needs_tools"]["noul"],
        "is_sensitive": answers["is_sensitive"]["noul"],
        "domain": answers["domain"]["choice"],
    }


def laya_timed_pass(agent, questions: dict, items: list) -> tuple:
    """Run router_predict_one over `items` (already-formatted prompts via
    format_prompt), return (p50_ms, p95_ms, times_ms)."""
    times_ms = []
    for item in items:
        _, ms = router_predict_one(agent, questions, format_prompt(item))
        times_ms.append(ms)
    times_sorted = sorted(times_ms)
    return percentile(times_sorted, 50), percentile(times_sorted, 95), times_ms


def judge_policy() -> dict:
    """The minimal structurally valid routing/validate policy from the plan
    (Step 3d): every route_to/default_model/classifier-model name appears in
    `components` (docs/api/lemonade.md:126-128)."""
    return {
        "version": "1",
        "model_name": "user.laya-judge",
        "recipe": "collection.router",
        "components": [FLM_MODEL, JUDGE_MODEL],
        "routing": {
            "candidates": [FLM_MODEL, JUDGE_MODEL],
            "default_model": FLM_MODEL,
            "classifiers": [
                {
                    "id": "hard",
                    "type": "llm",
                    "model": JUDGE_MODEL,
                    "labels": ["EASY", "HARD"],
                    "default_label": "EASY",
                    "on_error": "match_false",
                    "prompt": (
                        "Classify how hard this request is for a 1-billion-parameter "
                        "language model to answer correctly. HARD if it needs "
                        "multi-step reasoning or specialist knowledge, EASY otherwise."
                    ),
                }
            ],
            "rules": [
                {
                    "id": "hard-to-big",
                    "match": {"classifier": "hard", "label": "HARD", "min_score": 0.5},
                    "route_to": JUDGE_MODEL,
                }
            ],
        },
    }


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
    results = load_results()
    prefix = host_prefix()
    candidate = results.get("candidate", FLM_MODEL)
    cap = GRADE_CAP_FLM if candidate == FLM_MODEL else GRADE_CAP_FALLBACK

    grade = results.get("grade", {})
    items = grade.get("items", {})
    if "health_at_start" not in grade:
        try:
            grade["health_at_start"] = http_get("/api/v1/health")
        except (urllib.error.URLError, OSError) as e:
            grade["health_at_start"] = {"error": f"{type(e).__name__}: {e}"}

    n_correct = sum(1 for v in items.values() if v["correct"])
    n_incorrect = sum(1 for v in items.values() if not v["correct"])
    n_unparseable = sum(1 for v in items.values() if v["unparseable"])
    n_graded = len(items)
    print(
        f"{prefix} grade: resuming with n_graded={n_graded} n_correct={n_correct} "
        f"n_incorrect={n_incorrect} cap={cap}"
    )

    pool = build_pool()
    t_start = time.monotonic()
    stop_reason = None

    for item in pool:
        if n_correct >= GRADE_STOP_MIN and n_incorrect >= GRADE_STOP_MIN:
            stop_reason = (
                f">= {GRADE_STOP_MIN} correct and >= {GRADE_STOP_MIN} incorrect "
                f"(n_graded={n_graded})"
            )
            break
        if n_graded >= cap:
            break
        if item["id"] in items:
            continue

        prompt = format_prompt(item)
        body = {
            "model": candidate,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 96,
            "temperature": 0,
        }
        try:
            payload, ms = http_post("/api/v1/chat/completions", body, timeout=60)
            answer_text = payload["choices"][0]["message"]["content"]
        except (urllib.error.URLError, OSError, TimeoutError, KeyError, IndexError) as e:
            answer_text = f"[request failed: {type(e).__name__}: {e}]"
            ms = float("nan")

        letter, unparseable = parse_answer(answer_text)
        correct = (not unparseable) and (letter == item["key"])
        items[item["id"]] = {
            "split": item["split"],
            "correct": correct,
            "unparseable": unparseable,
            "answer_letter": letter,
            "answer_text": answer_text,
            "ms": round(ms, 3) if ms == ms else None,  # NaN check
        }
        n_graded += 1
        if correct:
            n_correct += 1
        else:
            n_incorrect += 1
        if unparseable:
            n_unparseable += 1

        if n_graded % 10 == 0:
            grade.update(
                {
                    "candidate": candidate,
                    "n_graded": n_graded,
                    "n_correct": n_correct,
                    "n_incorrect": n_incorrect,
                    "n_unparseable": n_unparseable,
                    "items": items,
                }
            )
            results["grade"] = grade
            save_results(results)
            print(
                f"{prefix} grade: n_graded={n_graded} n_correct={n_correct} "
                f"n_incorrect={n_incorrect} n_unparseable={n_unparseable}"
            )
    else:
        stop_reason = stop_reason or "pool exhausted before cap"

    if stop_reason is None:
        minority = min(n_correct, n_incorrect)
        if minority >= GRADE_STOP_MIN:
            stop_reason = (
                f">= {GRADE_STOP_MIN}/{GRADE_STOP_MIN} reached exactly at cap {cap} "
                f"(n_graded={n_graded})"
            )
        elif minority >= GRADE_STOP_MINORITY_UNMEASURABLE:
            stop_reason = (
                f"cap {cap} reached; proceeding with realised counts "
                f"(minority class={minority})"
            )
        else:
            stop_reason = (
                f"cap {cap} reached; unmeasurable with this candidate "
                f"(minority class={minority} < {GRADE_STOP_MINORITY_UNMEASURABLE}); "
                "no candidate switch"
            )

    grade.update(
        {
            "candidate": candidate,
            "stop_reason": stop_reason,
            "n_graded": n_graded,
            "n_correct": n_correct,
            "n_incorrect": n_incorrect,
            "n_unparseable": n_unparseable,
            "items": items,
        }
    )
    results["grade"] = grade
    results["step3_wall_s"] = results.get("step3_wall_s", 0.0) + (time.monotonic() - t_start)
    save_results(results)

    print(
        f"{prefix} grade done: {stop_reason}; n_graded={n_graded} n_correct={n_correct} "
        f"n_incorrect={n_incorrect} n_unparseable={n_unparseable}"
    )


def cmd_baselines(args: argparse.Namespace) -> None:
    results = load_results()
    prefix = host_prefix()
    grade = results.get("grade")
    if not grade or not grade.get("items"):
        raise SystemExit("bench.py baselines: run `grade` first (no graded items in results).")

    candidate = grade["candidate"]
    graded = grade["items"]
    graded_ids = list(graded.keys())

    pool = build_pool()
    pool_by_id = {item["id"]: item for item in pool}

    baselines = results.get(
        "baselines",
        {
            "own_logprob": {},
            "own_logprob_template": "none",
            "llm_judge": {},
            "adequate": {},
            "difficulty_extra": {},
        },
    )
    baselines["own_logprob_template"] = "none"
    t_start = time.monotonic()

    # (a) own-logprob: raw prompt + "\nAnswer:", no chat template, logprobs of
    # the single greedy next token.
    own_logprob = baselines.setdefault("own_logprob", {})
    n_done = 0
    for gid in graded_ids:
        if gid in own_logprob:
            continue
        item = pool_by_id[gid]
        prompt = format_prompt(item) + "\nAnswer:"
        body = {
            "model": candidate,
            "prompt": prompt,
            "max_tokens": 1,
            "temperature": 0,
            "logprobs": True,
            "stream": False,
        }
        try:
            payload, _ = http_post("/api/v1/completions", body, timeout=60)
            lp = payload["choices"][0].get("logprobs")
            if not lp or not lp.get("content"):
                own_logprob[gid] = {"token": None, "logprob": None, "matches_graded_letter": None}
            else:
                content = lp["content"][0]
                token = content["token"]
                logprob = content["logprob"]
                graded_letter = graded[gid]["answer_letter"]
                matches = bool(graded_letter) and token.strip().upper()[:1] == graded_letter
                own_logprob[gid] = {"token": token, "logprob": logprob, "matches_graded_letter": matches}
        except (urllib.error.URLError, OSError, TimeoutError, KeyError, IndexError) as e:
            own_logprob[gid] = {
                "token": None,
                "logprob": None,
                "matches_graded_letter": None,
                "error": f"{type(e).__name__}: {e}",
            }
        n_done += 1
        if n_done % 20 == 0:
            baselines["own_logprob"] = own_logprob
            results["baselines"] = baselines
            save_results(results)
            print(f"{prefix} baselines: own_logprob {n_done}/{len(graded_ids)}")
    baselines["own_logprob"] = own_logprob
    results["baselines"] = baselines
    save_results(results)
    print(f"{prefix} baselines: own_logprob done ({len(own_logprob)} items)")

    # (d) llm_judge via routing/validate — every route_to/default_model/
    # classifier model is in `components` (docs/api/lemonade.md:126-128).
    #
    # Empirically (lemonade 11.9.0, halo, max_models.llm=1): routing/validate's
    # classifier evaluation does not itself swap the loaded LLM. If the judge
    # model isn't already resident it fails closed to the classifier's
    # `on_error` (`match_false` here, i.e. EASY) near-instantly and silently —
    # no error surfaces in the response. Since `grade` and own-logprob (a)
    # both leave the candidate (FLM) loaded, warm the judge model in first.
    try:
        http_post(
            "/api/v1/chat/completions",
            {
                "model": JUDGE_MODEL,
                "messages": [{"role": "user", "content": "Say OK."}],
                "max_tokens": 4,
                "temperature": 0,
            },
            timeout=60,
        )
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        print(f"{prefix} baselines: judge warm-up failed ({type(e).__name__}: {e}); llm_judge may fail closed to EASY")

    llm_judge = baselines.setdefault("llm_judge", {})
    policy = judge_policy()
    n_done = 0
    for gid in graded_ids:
        if gid in llm_judge:
            continue
        item = pool_by_id[gid]
        body = {"policy": policy, "prompt": item["question"]}
        try:
            payload, ms = http_post("/api/v1/routing/validate", body, timeout=60)
            matched_rule = payload["decision"].get("matched_rule") or None
            llm_judge[gid] = {"matched_rule": matched_rule, "ms": round(ms, 3)}
        except (urllib.error.URLError, OSError, TimeoutError, KeyError) as e:
            llm_judge[gid] = {"matched_rule": None, "ms": None, "error": f"{type(e).__name__}: {e}"}
        n_done += 1
        if n_done % 20 == 0:
            baselines["llm_judge"] = llm_judge
            results["baselines"] = baselines
            save_results(results)
            print(f"{prefix} baselines: llm_judge {n_done}/{len(graded_ids)}")
    baselines["llm_judge"] = llm_judge
    results["baselines"] = baselines
    save_results(results)
    print(f"{prefix} baselines: llm_judge done ({len(llm_judge)} items)")

    # (e) I2 adequacy and (f) I1 difficulty for graded ids not already in
    # laya.per_prompt — one Laya load serves both.
    per_prompt_existing = results.get("laya", {}).get("per_prompt", {})
    adequate = baselines.setdefault("adequate", {})
    difficulty_extra = baselines.setdefault("difficulty_extra", {})
    need_adequate = [gid for gid in graded_ids if gid not in adequate]
    need_difficulty = [
        gid for gid in graded_ids if gid not in per_prompt_existing and gid not in difficulty_extra
    ]

    if need_adequate or need_difficulty:
        import laya

        agent = laya.load("convaiinnovations/laya", device="cpu")
        adequate_q = {
            "adequate": {
                "type": "noul",
                "instructions": "Is `answer` a correct and adequate answer to `request`?",
            }
        }
        router_q = laya.router_questions()

        n_done = 0
        for gid in need_adequate:
            item = pool_by_id[gid]
            answer_text = graded[gid]["answer_text"]
            t0 = time.monotonic()
            answers = agent.predict(
                {"request": item["question"], "answer": answer_text}, adequate_q
            )["answers"]
            ms = (time.monotonic() - t0) * 1000
            adequate[gid] = {"noul": answers["adequate"]["noul"], "ms": round(ms, 3)}
            n_done += 1
            if n_done % 20 == 0:
                baselines["adequate"] = adequate
                results["baselines"] = baselines
                save_results(results)
                print(f"{prefix} baselines: adequate {n_done}/{len(need_adequate)}")
        baselines["adequate"] = adequate
        results["baselines"] = baselines
        save_results(results)
        print(f"{prefix} baselines: adequate done ({len(adequate)} items)")

        n_done = 0
        for gid in need_difficulty:
            item = pool_by_id[gid]
            answers, ms = router_predict_one(agent, router_q, format_prompt(item))
            difficulty_extra[gid] = {"ms": round(ms, 3), **router_fields(answers)}
            n_done += 1
            if n_done % 20 == 0:
                baselines["difficulty_extra"] = difficulty_extra
                results["baselines"] = baselines
                save_results(results)
                print(f"{prefix} baselines: difficulty_extra {n_done}/{len(need_difficulty)}")
        baselines["difficulty_extra"] = difficulty_extra
        results["baselines"] = baselines
        save_results(results)
        print(f"{prefix} baselines: difficulty_extra done ({len(difficulty_extra)} items)")

    results["baselines"] = baselines
    results["step3_wall_s"] = results.get("step3_wall_s", 0.0) + (time.monotonic() - t_start)
    save_results(results)
    print(f"{prefix} baselines done")


def roc_auc(scores: list, labels: list) -> float:
    """Rank-based ROC-AUC (Mann-Whitney U form), ties averaged, pure Python.
    `labels` are booleans; True is the positive class."""
    n = len(scores)
    if n == 0:
        return float("nan")
    order = sorted(range(n), key=lambda i: scores[i])
    ranks = [0.0] * n
    i = 0
    while i < n:
        j = i
        while j + 1 < n and scores[order[j + 1]] == scores[order[i]]:
            j += 1
        avg_rank = (i + j) / 2 + 1  # 1-indexed
        for k in range(i, j + 1):
            ranks[order[k]] = avg_rank
        i = j + 1
    n_pos = sum(1 for label in labels if label)
    n_neg = n - n_pos
    if n_pos == 0 or n_neg == 0:
        return float("nan")
    sum_ranks_pos = sum(ranks[i] for i in range(n) if labels[i])
    return (sum_ranks_pos - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg)


def gather_signal(graded_ids: list, values: dict) -> tuple:
    """`values` maps id -> score or None. Returns (ids_used, scores) over ids
    with a non-None score, in `graded_ids` order."""
    ids_used, scores = [], []
    for gid in graded_ids:
        v = values.get(gid)
        if v is None:
            continue
        ids_used.append(gid)
        scores.append(v)
    return ids_used, scores


def build_signals(results: dict) -> dict:
    """Return {signal_name: {id: score}} for every Step 3 report signal,
    over all graded ids (never an intersection — (f) backfills ids missing
    from the Step 2 idle run)."""
    grade = results["grade"]
    graded = grade["items"]
    baselines = results.get("baselines", {})
    pool_by_id = {item["id"]: item for item in build_pool()}

    per_prompt = results.get("laya", {}).get("per_prompt", {})
    difficulty_extra = baselines.get("difficulty_extra", {})
    own_logprob = baselines.get("own_logprob", {})
    adequate = baselines.get("adequate", {})
    llm_judge = baselines.get("llm_judge", {})

    difficulty_score, adequate_noul, neg_own_logprob = {}, {}, {}
    easy_challenge, min_chars, llm_judge_hard = {}, {}, {}

    for gid in graded:
        item = pool_by_id[gid]
        dscore = per_prompt.get(gid, difficulty_extra.get(gid, {})).get("difficulty_score")
        if dscore is not None:
            difficulty_score[gid] = dscore

        adeq = adequate.get(gid, {}).get("noul")
        if adeq is not None:
            adequate_noul[gid] = 1.0 - adeq

        lp = own_logprob.get(gid, {}).get("logprob")
        if lp is not None:
            neg_own_logprob[gid] = -lp

        easy_challenge[gid] = 1.0 if item["split"] == "Challenge" else 0.0
        min_chars[gid] = float(min(len(text.encode("utf-8")) for _, text in item["choices"]))

        rule = llm_judge.get(gid, {}).get("matched_rule")
        if gid in llm_judge:
            llm_judge_hard[gid] = 1.0 if rule == "hard-to-big" else 0.0

    return {
        "difficulty_score": difficulty_score,
        "1 - adequate_noul": adequate_noul,
        "-own_logprob": neg_own_logprob,
        "easy_challenge": easy_challenge,
        "min_chars": min_chars,
        "llm_judge == HARD": llm_judge_hard,
    }


def cmd_report(args: argparse.Namespace) -> None:
    results = load_results()
    prefix = host_prefix()
    grade = results.get("grade")
    if not grade or not grade.get("items"):
        raise SystemExit("bench.py report: run `grade` and `baselines` first.")

    t_start = time.monotonic()
    graded = grade["items"]
    graded_ids = list(graded.keys())
    label_incorrect = {gid: (not graded[gid]["correct"]) for gid in graded_ids}
    label_challenge = {gid: (graded[gid]["split"] == "Challenge") for gid in graded_ids}

    signals = build_signals(results)

    auc_rows = []
    auc_by_name = {}
    for name, values in signals.items():
        ids_used, scores = gather_signal(graded_ids, values)
        labels_incorrect = [label_incorrect[i] for i in ids_used]
        labels_challenge = [label_challenge[i] for i in ids_used]
        auc_incorrect = roc_auc(scores, labels_incorrect)
        auc_challenge = roc_auc(scores, labels_challenge)
        auc_by_name[name] = auc_incorrect
        auc_rows.append((name, len(ids_used), auc_incorrect, auc_challenge))

    laya_auc = auc_by_name["difficulty_score"]
    best_baseline_name, best_baseline_auc = None, float("-inf")
    for name in ("-own_logprob", "easy_challenge"):
        v = auc_by_name.get(name, float("nan"))
        if v == v and v > best_baseline_auc:  # not NaN
            best_baseline_name, best_baseline_auc = name, v

    # Latency: kill-line p50/p95 is the Step 2 idle run only.
    laya = results.get("laya", {})
    idle_p50 = laya.get("p50_ms")
    idle_p95 = laya.get("p95_ms")

    difficulty_extra = results.get("baselines", {}).get("difficulty_extra", {})
    f_times = sorted(v["ms"] for v in difficulty_extra.values())
    f_p50 = percentile(f_times, 50) if f_times else None

    llm_judge = results.get("baselines", {}).get("llm_judge", {})
    judge_times = sorted(v["ms"] for v in llm_judge.values() if v.get("ms") is not None)
    judge_p50 = percentile(judge_times, 50) if judge_times else None
    judge_p95 = percentile(judge_times, 95) if judge_times else None

    # Top greedy tokens from the own-logprob baseline (a), so a reader can
    # tell letter confidence from formatting confidence.
    own_logprob = results.get("baselines", {}).get("own_logprob", {})
    token_counts = collections.Counter(
        v["token"] for v in own_logprob.values() if v.get("token") is not None
    )
    top_tokens = token_counts.most_common(10)

    # Supplementary thread sweep — NOT the kill-line measurement.
    thread_sweep = results.get("thread_sweep")
    if thread_sweep is None:
        thread_sweep = run_thread_sweep(prefix)
        results["thread_sweep"] = thread_sweep
        save_results(results)

    # PASS/KILL per pre-registered criterion.
    kills = []
    c1_kill = (laya_auc == laya_auc) and laya_auc < KILL_AUC_FLOOR
    kills.append(("Laya AUC < %.2f" % KILL_AUC_FLOOR, c1_kill, f"laya_auc={laya_auc:.4f}" if laya_auc == laya_auc else "laya_auc=nan"))

    c2_kill = (
        laya_auc == laya_auc
        and best_baseline_auc != float("-inf")
        and laya_auc <= best_baseline_auc + KILL_AUC_MARGIN
    )
    kills.append((
        "Laya AUC <= best-baseline AUC + %.2f (best of own-logprob, easy/challenge)" % KILL_AUC_MARGIN,
        c2_kill,
        f"laya_auc={laya_auc:.4f} best_baseline={best_baseline_name}={best_baseline_auc:.4f}"
        if laya_auc == laya_auc and best_baseline_auc != float("-inf")
        else "insufficient data",
    ))

    c3_kill = idle_p50 is not None and idle_p50 >= KILL_WARM_P50_MS
    kills.append((
        "Laya warm p50 >= %.0fms on halo CPU" % KILL_WARM_P50_MS,
        c3_kill,
        f"idle_p50={idle_p50}ms" if idle_p50 is not None else "unmeasured",
    ))

    c4_kill = idle_p50 is not None and judge_p50 is not None and idle_p50 >= judge_p50
    kills.append((
        "Laya p50 >= llm-judge p50",
        c4_kill,
        f"idle_p50={idle_p50}ms judge_p50={judge_p50}ms"
        if idle_p50 is not None and judge_p50 is not None
        else "insufficient data",
    ))

    overall_kill = any(k for _, k, _ in kills)

    unmeasured_notes = []
    if all(v.get("token") is None for v in own_logprob.values()) and own_logprob:
        unmeasured_notes.append(
            f"own_logprob: unmeasured for candidate={grade['candidate']} "
            "(no `logprobs` object returned by /api/v1/completions)"
        )
    if results.get("candidate_reason", "").startswith("FLM probe"):
        pass
    if grade["candidate"] != FLM_MODEL:
        unmeasured_notes.append(
            "llm_judge: self-judging — the judge (Qwen3.5-4B-GGUF) also names itself as the "
            "route target, and the candidate being graded is the 4B fallback"
        )

    write_report_md(
        results=results,
        prefix=prefix,
        grade=grade,
        auc_rows=auc_rows,
        best_baseline_name=best_baseline_name,
        best_baseline_auc=best_baseline_auc,
        idle_p50=idle_p50,
        idle_p95=idle_p95,
        f_p50=f_p50,
        judge_p50=judge_p50,
        judge_p95=judge_p95,
        top_tokens=top_tokens,
        thread_sweep=thread_sweep,
        kills=kills,
        overall_kill=overall_kill,
        unmeasured_notes=unmeasured_notes,
    )

    results["step3_wall_s"] = results.get("step3_wall_s", 0.0) + (time.monotonic() - t_start)
    save_results(results)

    print(f"{prefix} report: written to {REPORT_PATH}")
    for name, kill, detail in kills:
        print(f"{prefix} {'KILL' if kill else 'PASS'}: {name} ({detail})")
    print(f"{prefix} overall: {'KILL' if overall_kill else 'PASS'}")


def run_thread_sweep(prefix: str) -> dict:
    """Supplementary: laya-latency-style p50/p95 at 8/16/32 threads, n=40
    each. Never the kill-line measurement — that is the Step 2 idle run at
    the process-default thread count."""
    import laya

    saved_threads = torch.get_num_threads()
    pool = build_pool()
    items = pool[:40]
    sweep = {}
    for threads in (8, 16, 32):
        torch.set_num_threads(threads)
        agent = laya.load("convaiinnovations/laya", device="cpu")
        questions = laya.router_questions()
        for item in items[:5]:
            router_predict_one(agent, questions, format_prompt(item))
        p50, p95, _ = laya_timed_pass(agent, questions, items)
        sweep[str(threads)] = {"n": len(items), "p50_ms": round(p50, 3), "p95_ms": round(p95, 3)}
        print(f"{prefix} thread_sweep threads={threads} p50={p50:.1f}ms p95={p95:.1f}ms")
        del agent
    torch.set_num_threads(saved_threads)
    return sweep


def write_report_md(
    results,
    prefix,
    grade,
    auc_rows,
    best_baseline_name,
    best_baseline_auc,
    idle_p50,
    idle_p95,
    f_p50,
    judge_p50,
    judge_p95,
    top_tokens,
    thread_sweep,
    kills,
    overall_kill,
    unmeasured_notes,
) -> None:
    lines = []
    lines.append("# Laya (#149) — Step 3 results, I1/I2 arm")
    lines.append("")
    lines.append("Generated by `experiments/laya/bench.py report`. Throwaway — not a flake output.")
    lines.append("")

    lines.append("## Grading")
    lines.append("")
    lines.append(f"{prefix} — candidate: `{grade['candidate']}`, stop reason: {grade['stop_reason']}")
    lines.append("")
    lines.append("| n_graded | n_correct | n_incorrect | n_unparseable |")
    lines.append("|---|---|---|---|")
    lines.append(
        f"| {grade['n_graded']} | {grade['n_correct']} | {grade['n_incorrect']} | {grade['n_unparseable']} |"
    )
    lines.append("")

    lines.append("## Signal AUCs")
    lines.append("")
    lines.append(f"{prefix} — rank-based ROC-AUC (ties averaged), pure Python, no sklearn.")
    lines.append("")
    lines.append("| signal | n | AUC vs incorrect | AUC vs split==Challenge |")
    lines.append("|---|---|---|---|")
    for name, n, auc_i, auc_c in auc_rows:
        auc_i_s = f"{auc_i:.4f}" if auc_i == auc_i else "n/a"
        auc_c_s = f"{auc_c:.4f}" if auc_c == auc_c else "n/a"
        lines.append(f"| {name} | {n} | {auc_i_s} | {auc_c_s} |")
    lines.append("")
    if best_baseline_auc != float("-inf"):
        lines.append(
            f"{prefix} — best baseline (own-logprob vs easy/challenge): "
            f"`{best_baseline_name}` = {best_baseline_auc:.4f}"
        )
    else:
        lines.append(f"{prefix} — best baseline: insufficient data (own-logprob and easy/challenge both n/a)")
    lines.append("")

    lines.append("## Latency")
    lines.append("")
    lines.append(f"{prefix} — kill-line p50/p95 (Step 2 idle run, warm, n={results.get('laya', {}).get('n')})")
    lines.append("")
    idle_p50_s = f"{idle_p50:.1f}" if idle_p50 is not None else "unmeasured"
    idle_p95_s = f"{idle_p95:.1f}" if idle_p95 is not None else "unmeasured"
    lines.append(f"p50={idle_p50_s}ms p95={idle_p95_s}ms")
    lines.append("")
    f_p50_s = f"{f_p50:.1f}ms" if f_p50 is not None else "unmeasured (no ids missing from the idle run)"
    lines.append(
        f"{prefix} — baseline (f) difficulty p50, measured while lemonade calls interleaved "
        f"(not the kill line): p50={f_p50_s}"
    )
    lines.append("")
    judge_p50_s = f"{judge_p50:.1f}" if judge_p50 is not None else "unmeasured"
    judge_p95_s = f"{judge_p95:.1f}" if judge_p95 is not None else "unmeasured"
    lines.append(f"{prefix} — llm_judge (`/api/v1/routing/validate`) p50/p95: p50={judge_p50_s}ms p95={judge_p95_s}ms")
    lines.append("")

    lines.append("## Top greedy tokens (own-logprob baseline (a))")
    lines.append("")
    lines.append(f"{prefix} — greedy next token after the raw prompt + \"\\nAnswer:\", by count.")
    lines.append("")
    if top_tokens:
        lines.append("| token | count |")
        lines.append("|---|---|")
        for token, count in top_tokens:
            lines.append(f"| `{token!r}` | {count} |")
    else:
        lines.append("(none — own_logprob returned no `logprobs` object for any graded item)")
    lines.append("")

    lines.append("## PASS/KILL")
    lines.append("")
    lines.append(f"{prefix} — pre-registered thresholds (spec Deliverable 2 / plan Fixed inputs).")
    lines.append("")
    for name, kill, detail in kills:
        lines.append(f"- **{'KILL' if kill else 'PASS'}**: {name} ({detail})")
    lines.append("")
    lines.append(f"**Overall: {'KILL' if overall_kill else 'PASS'}**")
    lines.append("")

    lines.append("## Supplementary — thread sweep")
    lines.append("")
    lines.append(
        f"{prefix} — supplementary only; NOT the kill-line measurement. The kill line is the "
        "pre-registered 32-thread Step 2 idle run above."
    )
    lines.append("")
    lines.append("| threads | n | p50_ms | p95_ms |")
    lines.append("|---|---|---|---|")
    for threads in ("8", "16", "32"):
        row = thread_sweep.get(threads)
        if row:
            lines.append(f"| {threads} | {row['n']} | {row['p50_ms']:.1f} | {row['p95_ms']:.1f} |")
    lines.append("")

    lines.append("## Contention (Laya on CPU while an LLM generates)")
    lines.append("")
    contention = results.get("contention")
    if contention and contention.get("status") == "measured":
        lines.append(f"{prefix} — Laya p50/p95 under a background NPU/iGPU streaming load, n=40 each.")
        lines.append("")
        lines.append("| condition | p50_ms | p95_ms |")
        lines.append("|---|---|---|")
        lines.append(
            f"| idle | {contention['idle_p50_ms']:.1f} | {contention['idle_p95_ms']:.1f} |"
        )
        for label, caption in (
            ("npu_contended", f"NPU contended (`{FLM_MODEL}` streaming)"),
            ("igpu_contended", f"iGPU contended (`{FALLBACK_MODEL}` streaming)"),
        ):
            p50 = contention.get(f"{label}_p50_ms")
            if p50 is None:
                lines.append(f"| {caption} | skipped ({contention.get(f'{label}_reason', 'unmeasured')}) | |")
            else:
                lines.append(f"| {caption} | {p50:.1f} | {contention[f'{label}_p95_ms']:.1f} |")
        lines.append("")
        lines.append(
            f"{prefix} — this idle p50 (n=40, run after grading) is not the kill-line p50 "
            "(n=120, Step 2)."
        )
    elif contention:
        lines.append(f"{prefix} — status: unmeasured ({contention.get('reason', 'no reason recorded')})")
    else:
        lines.append(f"{prefix} — status: unmeasured (contention step not run)")
    lines.append("")

    lines.append("## Unmeasured")
    lines.append("")
    if unmeasured_notes:
        for note in unmeasured_notes:
            lines.append(f"- {note}")
    else:
        lines.append("- (none beyond what is already marked above)")
    lines.append("")

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines) + "\n")


def cmd_contention(args: argparse.Namespace) -> None:
    results = load_results()
    prefix = host_prefix()

    wall_s = results.get("step3_wall_s", 0.0)
    if wall_s >= CONTENTION_WALL_BUDGET_S:
        reason = f"grade+baselines+report already took {wall_s:.0f}s (>= {CONTENTION_WALL_BUDGET_S}s budget)"
        results["contention"] = {"status": "unmeasured", "reason": reason}
        save_results(results)
        print(f"{prefix} contention: skipped — {reason}")
        return

    import laya

    agent = laya.load("convaiinnovations/laya", device="cpu")
    questions = laya.router_questions()
    pool = build_pool()
    items = pool[:40]
    for item in items[:5]:
        router_predict_one(agent, questions, format_prompt(item))

    idle_p50, idle_p95, _ = laya_timed_pass(agent, questions, items)
    print(f"{prefix} contention idle: p50={idle_p50:.1f}ms p95={idle_p95:.1f}ms")

    contention = {"idle_p50_ms": round(idle_p50, 3), "idle_p95_ms": round(idle_p95, 3)}

    def stream_loader(model: str, stop_event: threading.Event) -> None:
        body = {
            "model": model,
            "prompt": "Write a long, detailed short story about a journey across the mountains.",
            "max_tokens": 512,
            "temperature": 0.7,
            "stream": True,
        }
        data = json.dumps(body).encode()
        while not stop_event.is_set():
            try:
                req = urllib.request.Request(
                    f"{BASE_URL}/api/v1/completions",
                    data=data,
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urllib.request.urlopen(req, timeout=120) as resp:
                    for _ in resp:
                        if stop_event.is_set():
                            break
            except (urllib.error.URLError, OSError, TimeoutError):
                if stop_event.is_set():
                    break

    runs = [("igpu_contended", FALLBACK_MODEL, True)]
    npu_available = results.get("candidate") == FLM_MODEL
    runs.append(("npu_contended", FLM_MODEL, npu_available))

    for label, model, run_it in runs:
        if not run_it:
            contention[f"{label}_p50_ms"] = None
            contention[f"{label}_reason"] = "FLM probe did not pass; NPU candidate unavailable"
            print(f"{prefix} contention {label}: skipped (FLM probe did not pass)")
            continue

        stop_event = threading.Event()
        thread = threading.Thread(target=stream_loader, args=(model, stop_event), daemon=True)
        thread.start()
        try:
            time.sleep(1)  # let the stream ramp up before measuring
            p50, p95, _ = laya_timed_pass(agent, questions, items)
        finally:
            stop_event.set()
            thread.join(timeout=30)
        contention[f"{label}_p50_ms"] = round(p50, 3)
        contention[f"{label}_p95_ms"] = round(p95, 3)
        print(f"{prefix} contention {label} ({model}): p50={p50:.1f}ms p95={p95:.1f}ms")

    contention["status"] = "measured"
    results["contention"] = contention
    save_results(results)
    print(f"{prefix} contention done")


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
