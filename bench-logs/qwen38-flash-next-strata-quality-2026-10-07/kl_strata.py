#!/usr/bin/env python3
"""Teacher-forced top-k scoring of Strata against #260's Q8_0 reference logits.

  run      start one `strata --serve` engine, feed it the reference's 2048-token chunks (token ids read from the
           reference file) and keep the engine's STRATA_LOGPOS rows: top-256 log-probabilities of every position
           that is read through its verify windows. The first half of each chunk goes through the batched prompt
           path (the code `--prefill` and the STRATA_PF_* switches change), the second half through the windows,
           where the rows are scored: the same 1023 positions per chunk that llama-perplexity scores.
  compare  KL(reference || candidate), top-1 agreement and perplexity per row. A Strata candidate has only its top-256
           log-probabilities, so KL is taken over its 256 tokens plus one bucket for the rest. A llama.cpp logits file
           is scored both ways (full vocabulary and the same top-256 estimator), which says how much the estimator
           loses on a candidate whose full distribution is known.

run is meant to sit behind run.sh's `exec` preset (memory gate, lemond hand-off). Env: STRATA_ENGINE STRATA_PACK
STRATA_REPO (checkout, for the hipBLASLt table) STRATA_MTP_RT. The arms mirror run.sh's `strata` and `strata-fast`
presets, minus vision and with --max-context 8192.
"""
import argparse
import contextlib
import ctypes
import json
import math
import os
import re
import signal
import struct
import subprocess
import sys
import time

import numpy as np

N_CTX = 2048
FIRST = N_CTX // 2
SCORED = N_CTX - 1 - FIRST  # 1023 positions per chunk
TOPK = 256
FLOOR = -16.0  # llama-perplexity ignores reference log-probs at or below this

FAST_ENV = ["STRATA_PF_FUSED", "STRATA_PF_GEMM", "STRATA_HC_UPMIX", "STRATA_PA_FAST", "STRATA_HIP_WMMA",
            "STRATA_SELECT_WMMA", "STRATA_HC_Q8"]
SWITCH_MIN_T = ("STRATA_PF_SWITCH_MIN_T", "4096")


def arm_spec(arm, cache, repo):
    """(engine flags, env) of an arm; `fast` minus or plus single switches via the `fast-` / `def+` prefixes.

    def                 run.sh's `strata` preset (--prefill auto, MTP only)
    fast                run.sh's `strata-fast` preset
    fast-<NAME|prefill|mtpq4>   fast with one switch removed (an env var without its STRATA_ prefix, case-insensitive)
    def+<NAME|prefill|mtpq4>    def with one switch added
    Several switches join with `,`: fast-pf_fused,pf_gemm. A trailing @<N> sets STRATA_PF_SWITCH_MIN_T=N: the preset's
    4096 keeps every prompt chunk below 4096 tokens on the default numerics, and the scored chunk's prefill is 1024 tokens.
    """
    profile = os.path.join(repo, "data", "expert-profile.bin")
    common = ["--spec", "4", "--spec-min-p", "0.5", "--kv", "int8", "--mmap-experts", "--expert-profile", profile,
              "--expert-cache", str(cache), "--vram-reserve-mib", "700", "--prompt-cache", "2", "--prompt-cache-every",
              str(FIRST)]
    tuning = os.path.join(repo, "tools", "hip", "gfx1151-hipblaslt-100401.txt")
    base_env = {"STRATA_HIPBLASLT_TUNING": tuning}
    fast_env = {**{k: "1" for k in FAST_ENV}, SWITCH_MIN_T[0]: SWITCH_MIN_T[1]}
    flags_def = ["--prefill", "auto"] + common
    flags_fast = ["--prefill", "16384", "--mtp-q4", "all"] + common

    m = re.fullmatch(r"(def|fast)(?:([-+])(\w+(?:,\w+)*))?(?:@(\d+))?", arm)
    if not m:
        raise SystemExit(f"bad arm {arm!r}")
    prefix, sign, names = m.group(1), m.group(2), [n.lower() for n in (m.group(3) or "").split(",") if n]
    flags = list(flags_fast if prefix == "fast" else flags_def)
    env = {**base_env, **(fast_env if prefix == "fast" else {})}
    if m.group(4):
        env[SWITCH_MIN_T[0]] = m.group(4)
    for n in names:
        if n == "prefill":
            # fast's --prefill 16384 vs def's --prefill auto
            i = flags.index("--prefill")
            flags[i + 1] = "auto" if sign == "-" else "16384"
        elif n == "mtpq4":
            if sign == "-":
                i = flags.index("--mtp-q4")
                del flags[i:i + 2]
            else:
                flags += ["--mtp-q4", "all"]
        else:
            key = "STRATA_" + n.upper()
            if key not in fast_env:
                raise SystemExit(f"unknown switch {n!r}")
            if sign == "-":
                env.pop(key, None)
            else:
                env[key] = fast_env[key]
    return flags, env


def read_tokens(ref):
    with open(ref, "rb") as f:
        if f.read(8) != b"_logits_":
            raise SystemExit(f"{ref}: not a llama.cpp logits file")
        n_ctx, n_vocab, n_chunk = struct.unpack("<iii", f.read(12))
        if n_ctx != N_CTX:
            raise SystemExit(f"{ref}: n_ctx {n_ctx}, expected {N_CTX}")
        toks = np.frombuffer(f.read(n_ctx * n_chunk * 4), dtype=np.int32).reshape(n_chunk, n_ctx)
    return toks, n_vocab


def chunk_offset(n_chunk, n_vocab, i):
    nv = 2 * ((n_vocab + 1) // 2) + 4
    return 8 + 12 + N_CTX * n_chunk * 4 + i * SCORED * nv * 2, nv


def die_with_parent():
    os.setsid()
    ctypes.CDLL("libc.so.6").prctl(1, signal.SIGKILL)  # PR_SET_PDEATHSIG: the engine must not outlive a killed row


def group_gone(pgid):
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/stat") as f:
                state, _, pgrp = f.read().rsplit(")", 1)[1].split()[:3]
        except (OSError, ValueError):
            continue
        if int(pgrp) == pgid and state not in ("Z", "X"):
            return False
    return True


def stop_engine(proc):
    """SIGTERM, SIGKILL after 60 s, then wait with no timeout for the group to release its GPU memory."""
    pgid = proc.pid
    for sig, wait in ((signal.SIGTERM, 60), (signal.SIGKILL, 0)):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pgid, sig)
        end = time.time() + wait
        while time.time() < end and not (proc.poll() is not None and group_gone(pgid)):
            time.sleep(0.2)
    proc.wait()
    while not group_gone(pgid):
        time.sleep(0.5)


def evict(paths):
    for p in paths:
        with contextlib.suppress(OSError), open(p, "rb") as f:
            os.posix_fadvise(f.fileno(), 0, 0, os.POSIX_FADV_DONTNEED)


def shards(first):
    m = re.match(r"^(.*)-\d{5}-of-(\d{5})\.gguf$", first)
    return [first] if not m else [f"{m.group(1)}-{i:05d}-of-{m.group(2)}.gguf" for i in range(1, int(m.group(2)) + 1)]


def run(a):
    toks, n_vocab = read_tokens(a.ref)
    n = min(a.chunks, len(toks))
    flags, env = arm_spec(a.arm, a.expert_cache, a.repo)
    os.makedirs(a.out, exist_ok=True)
    logpos = os.path.join(a.out, "logpos.tsv")
    open(logpos, "w").close()
    env = {**os.environ, **env, "STRATA_LOGPOS": logpos, "STRATA_LOGPOS_TOPK": str(TOPK)}
    argv = [a.engine, "--serve", "--pack", a.pack, "--native", a.target, "--mtp", a.mtp_rt, "--max-context", "8192",
            "--short-read", str(a.short_read)] + flags
    log = open(os.path.join(a.out, "engine.log"), "wb")
    t0 = time.time()
    proc = subprocess.Popen(argv, cwd=a.repo, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True,
                            bufsize=1, env=env, preexec_fn=die_with_parent)
    rows, err = [], None
    try:
        for line in proc.stdout:
            if line.startswith("READY"):
                break
        else:
            raise SystemExit("the engine exited before READY (engine.log)")
        load_s = time.time() - t0
        print(f"ready after {load_s:.0f} s", flush=True)
        offsets = [0]

        def gen(ids):
            """One GEN request; the lines of its answer up to DONE."""
            proc.stdin.write(f"GEN 1 {','.join(str(int(t)) for t in ids)}\n")
            proc.stdin.flush()
            lines = []
            for line in proc.stdout:
                if line.startswith(("ERR", "FATAL")):
                    raise SystemExit(f"{line.strip()} (engine.log)")
                lines.append(line.strip())
                if line.startswith("DONE"):
                    return lines
            raise SystemExit(f"the engine exited ({proc.poll()})")

        for i in range(n):
            t1 = time.time()
            # A: the first half, read by the batched prompt path, which ends in a conversation checkpoint at its last
            # token. B: the whole chunk resumes from that checkpoint and reads the rest through the verify windows.
            gen(toks[i][:FIRST])
            lines = gen(toks[i])
            resume = next((int(x.split()[1]) for x in lines if x.startswith("RESUME")), None)
            if resume != FIRST:
                raise SystemExit(f"chunk {i}: resumed from token {resume}, expected {FIRST}")
            offsets.append(os.path.getsize(logpos))
            rows.append({"chunk": i, "wall_s": round(time.time() - t1, 2), "done": lines[-1]})
            print(f"chunk {i + 1}/{n} {rows[-1]['wall_s']} s", flush=True)
        with open(os.path.join(a.out, "chunks.json"), "w") as f:
            json.dump({"arm": a.arm, "argv": argv[1:], "env": {k: v for k, v in env.items() if k.startswith("STRATA_")
                                                               and k not in ("STRATA_LOGPOS",)},
                       "offsets": offsets, "load_s": round(load_s, 1), "rows": rows}, f)
    finally:
        stop_engine(proc)
        evict(shards(a.target))
    return 0


# ---- compare ----------------------------------------------------------------------------------------------------

def load_ref_chunk(mm, off, nv, n_vocab):
    raw = np.frombuffer(mm, dtype=np.uint16, count=SCORED * nv, offset=off).reshape(SCORED, nv)
    d = raw[:, :4].copy().view(np.float32)  # scale, min_log_prob
    q = raw[:, 4:4 + n_vocab].astype(np.float32)
    return q * d[:, 0:1] + d[:, 1:2]


def parse_logpos(path, lo, hi):
    """Rows of one chunk: tgt ids, tgt logprob, top ids, top-k ids and logprobs; only positions FIRST..N_CTX-2."""
    pos, tgt, lp_t, top, ids, lps = [], [], [], [], [], []
    with open(path, "rb") as f:
        f.seek(lo)
        for line in f.read(hi - lo).decode().splitlines():
            c = line.split("\t")
            p = int(c[0])
            if p < FIRST:
                continue
            pos.append(p)
            tgt.append(int(c[1]))
            lp_t.append(float(c[2]))
            top.append(int(c[3]))
            kv = [x.split(":") for x in c[8:]]
            ids.append([int(i) for i, _ in kv])
            lps.append([float(v) for _, v in kv])
    pos = np.array(pos)
    if len(pos) != SCORED or not (pos == np.arange(FIRST, N_CTX - 1)).all():
        raise SystemExit(f"{path}: expected positions {FIRST}..{N_CTX - 2}, got {len(pos)} rows "
                         f"({pos[:1]}..{pos[-1:]})")
    return np.array(tgt), np.array(lp_t), np.array(top), np.array(ids), np.array(lps)


def topk_kl(p_log, ids, lps):
    """KL(P || Q) over Q's token set plus one bucket for the rest. p_log: reference log-probs (rows, vocab)."""
    pl = np.take_along_axis(p_log, ids, axis=1)
    pl = np.where(pl > FLOOR, pl, -np.inf)
    p = np.exp(pl.astype(np.float64))
    q = np.exp(lps.astype(np.float64))
    with np.errstate(divide="ignore", invalid="ignore"):
        term = np.where(p > 0, p * (pl - lps), 0.0).sum(axis=1)
    p_rest = np.clip(1 - p.sum(axis=1), 1e-12, None)
    q_rest = np.clip(1 - q.sum(axis=1), 1e-12, None)
    return term + p_rest * np.log(p_rest / q_rest), p_rest, q_rest


def full_kl(p_log, q_log):
    mask = p_log > FLOOR
    p = np.exp(np.where(mask, p_log, -np.inf))
    return np.where(mask, p * (p_log - q_log), 0.0).sum(axis=1, dtype=np.float64)


def summary(name, kl, same, nll, nll_base, p_diff):
    n = len(kl)
    se = lambda x: float(np.std(x, ddof=1) / math.sqrt(len(x)))
    d = nll - nll_base
    out = {"row": name, "positions": n, "kl_mean": float(kl.mean()), "kl_se": se(kl), "kl_median": float(np.median(kl)),
           "kl_p99": float(np.percentile(kl, 99)), "kl_max": float(kl.max()), "top1_same": float(same.mean()),
           "top1_se": float(math.sqrt(same.mean() * (1 - same.mean()) / (n - 1))),
           "ppl": float(np.exp(nll.mean())), "ppl_ref": float(np.exp(nll_base.mean())),
           "ppl_ratio": float(np.exp(d.mean())), "ppl_ratio_se": float(np.exp(d.mean()) * se(d)),
           "dp_rms": float(np.sqrt((p_diff ** 2).mean()))}
    return out


def compare(a):
    toks, n_vocab = read_tokens(a.ref)
    n_chunk = len(toks)
    ref_mm = np.memmap(a.ref, dtype=np.uint8, mode="r")
    results, cats = [], []
    for spec in a.candidates:
        name, _, path = spec.partition("=")
        kind = "llama" if path.endswith(".logits") else "strata"
        acc = {k: [] for k in ("kl", "same", "nll", "nll_base", "p_diff", "kl_full", "p_rest", "q_rest", "argmax")}
        if kind == "strata":
            meta = json.load(open(os.path.join(path, "chunks.json")))
            n = min(a.chunks or n_chunk, len(meta["offsets"]) - 1)
        else:
            n = a.chunks or n_chunk
            cand_mm = np.memmap(path, dtype=np.uint8, mode="r")
        for i in range(n):
            off, nv = chunk_offset(n_chunk, n_vocab, i)
            ref = load_ref_chunk(ref_mm, off, nv, n_vocab)
            tgt_ref = toks[i, FIRST + 1:]
            ref_top = ref.argmax(axis=1)
            nll_base = -np.take_along_axis(ref, tgt_ref[:, None].astype(np.int64), axis=1)[:, 0]
            if kind == "strata":
                tgt, lp_t, top, ids, lps = parse_logpos(os.path.join(path, "logpos.tsv"), meta["offsets"][i],
                                                        meta["offsets"][i + 1])
                if not (tgt == tgt_ref).all():
                    raise SystemExit(f"{path}: chunk {i} target tokens differ from the reference's")
                kl, p_rest, q_rest = topk_kl(ref, ids, lps)
                acc["p_rest"].append(p_rest)
                acc["q_rest"].append(q_rest)
                nll, same = -lp_t, top == ref_top
                acc["argmax"].append(top)
                p_tgt, q_tgt = np.exp(-nll_base), np.exp(lp_t)
            else:
                cand = load_ref_chunk(cand_mm, off, nv, n_vocab)
                kl_full = full_kl(ref, cand)
                acc["kl_full"].append(kl_full)
                ids = np.argpartition(-cand, TOPK, axis=1)[:, :TOPK]
                lps = np.take_along_axis(cand, ids, axis=1)
                kl, p_rest, q_rest = topk_kl(ref, ids, lps)
                acc["p_rest"].append(p_rest)
                acc["q_rest"].append(q_rest)
                nll = -np.take_along_axis(cand, tgt_ref[:, None].astype(np.int64), axis=1)[:, 0]
                same = cand.argmax(axis=1) == ref_top
                acc["argmax"].append(cand.argmax(axis=1))
                p_tgt, q_tgt = np.exp(-nll_base), np.exp(-nll)
            acc["kl"].append(kl)
            acc["same"].append(same)
            acc["nll"].append(nll)
            acc["nll_base"].append(nll_base)
            acc["p_diff"].append(q_tgt - p_tgt)
        cat = {k: np.concatenate(v) for k, v in acc.items() if v}
        res = summary(name, cat["kl"], cat["same"].astype(np.float64), cat["nll"], cat["nll_base"], cat["p_diff"])
        res["chunks"] = n
        res["estimator"] = "top256+bucket"
        res["rest_mass_ref"] = float(cat["p_rest"].mean())
        res["rest_mass_cand"] = float(cat["q_rest"].mean())
        if "kl_full" in cat:
            res["kl_full_mean"] = float(cat["kl_full"].mean())
            res["kl_full_se"] = float(np.std(cat["kl_full"], ddof=1) / math.sqrt(len(cat["kl_full"])))
        results.append(res)
        print(json.dumps(res), flush=True)
        cats.append((name, cat))
    # paired against the first candidate: the same positions, so the difference carries far less noise than either KL
    for name, cat in cats[1:]:
        base_name, base = cats[0]
        m = min(len(cat["kl"]), len(base["kl"]))
        dk, dn = cat["kl"][:m] - base["kl"][:m], cat["nll"][:m] - base["nll"][:m]
        flips = cat["argmax"][:m] != base["argmax"][:m]
        pair = {"row": f"{name} - {base_name}", "positions": m, "dkl_mean": float(dk.mean()),
                "dkl_se": float(np.std(dk, ddof=1) / math.sqrt(m)), "dnll_mean": float(dn.mean()),
                "dnll_se": float(np.std(dn, ddof=1) / math.sqrt(m)), "top1_flips": float(flips.mean())}
        results.append(pair)
        print(json.dumps(pair), flush=True)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(results, f, indent=1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--arm", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--ref", required=True, help="#260's reference logits (token ids come from its header)")
    r.add_argument("--target", required=True, help="GGUF shard 1")
    r.add_argument("--chunks", type=int, default=64)
    r.add_argument("--expert-cache", type=int, default=int(os.environ.get("STRATA_EXPERT_CACHE", "20000")))
    r.add_argument("--short-read", type=int, default=1100)
    r.add_argument("--engine", default=os.environ.get("STRATA_ENGINE"))
    r.add_argument("--pack", default=os.environ.get("STRATA_PACK"))
    r.add_argument("--repo", default=os.environ.get("STRATA_REPO"))
    r.add_argument("--mtp-rt", default=os.environ.get("STRATA_MTP_RT"))
    c = sub.add_parser("compare")
    c.add_argument("--ref", required=True)
    c.add_argument("--chunks", type=int, default=0, help="score only the first N chunks (default all)")
    c.add_argument("--json")
    c.add_argument("candidates", nargs="+", help="name=<run dir> (Strata) or name=<file>.logits (llama.cpp)")
    a = p.parse_args()
    if a.cmd == "run":
        for k in ("engine", "pack", "repo", "mtp_rt"):
            if not getattr(a, k):
                p.error(f"--{k.replace('_', '-')} or its STRATA_ env var is required")
        sys.exit(run(a))
    compare(a)


if __name__ == "__main__":
    main()
