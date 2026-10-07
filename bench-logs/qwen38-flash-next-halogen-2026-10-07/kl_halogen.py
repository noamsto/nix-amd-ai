#!/usr/bin/env python3
"""Score Halogen's per-position top-k log-probabilities against #260's Q8_0 reference logits.

  ids      write the reference's token ids (little-endian int32, n_chunk x n_ctx) for `halogen ppl --ids`
  compare  KL(reference || candidate), top-1 agreement and perplexity ratio on the positions llama-perplexity
           scores (the second half of each chunk), from a `halogen ppl --seq <n_ctx> --ref-out` dump (HREF)

A Halogen dump holds the candidate's top-K log-probabilities per position (K=128) and the log-mass of the rest, so
KL is taken over those K tokens plus one bucket for everything else, as kl_strata.py does for Strata's top-256. The
estimator reads below the full-vocabulary KL (#276 measured about 4% for top-256 on GSQHalo; K=128 reads lower).
Reader and estimator follow the #276 worktree's kl_strata.py (reference-file layout, floor, bucket).
"""
import argparse
import json
import math
import struct
import sys

import numpy as np

FLOOR = -16.0  # llama-perplexity ignores reference log-probs at or below this


def read_ref_header(ref):
    with open(ref, "rb") as f:
        if f.read(8) != b"_logits_":
            raise SystemExit(f"{ref}: not a llama.cpp logits file")
        n_ctx, n_vocab, n_chunk = struct.unpack("<iii", f.read(12))
        toks = np.frombuffer(f.read(n_ctx * n_chunk * 4), dtype=np.int32).reshape(n_chunk, n_ctx)
    return toks, n_ctx, n_vocab


def scored(n_ctx):
    return n_ctx - 1 - n_ctx // 2


def chunk_offset(n_ctx, n_chunk, n_vocab, i):
    nv = 2 * ((n_vocab + 1) // 2) + 4  # uint16 per row: 2 float32 header values, then one per vocab entry
    return 8 + 12 + n_ctx * n_chunk * 4 + i * scored(n_ctx) * nv * 2, nv


def load_ref_chunk(mm, n_ctx, off, nv, n_vocab):
    raw = np.frombuffer(mm, dtype=np.uint16, count=scored(n_ctx) * nv, offset=off).reshape(scored(n_ctx), nv)
    d = raw[:, :4].copy().view(np.float32)  # scale, min_log_prob
    return raw[:, 4:4 + n_vocab].astype(np.float32) * d[:, 0:1] + d[:, 1:2]


def read_href(path):
    with open(path, "rb") as f:
        magic, version, k, vocab, positions, seq = struct.unpack("<4sIIIQQ", f.read(32))
        if magic != b"HREF":
            raise SystemExit(f"{path}: not a Halogen reference dump")
        rec = np.dtype([("nll", "<f4"), ("argmax", "<i4"), ("tail", "<f8"), ("ids", "<i4", (k,)), ("lps", "<f8", (k,))])
        data = np.frombuffer(f.read(), dtype=rec)
    if len(data) != positions:
        raise SystemExit(f"{path}: header says {positions} positions, file holds {len(data)}")
    return {"version": version, "k": k, "vocab": vocab, "seq": seq}, data


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


def se(x):
    return float(np.std(x, ddof=1) / math.sqrt(len(x)))


def positions_per_seq(meta, data, n_ctx, n_chunk):
    """Row stride per sequence: Halogen 0.16.2 writes one row per stream position, n_chunk * n_ctx - 1 in all
    (row p scores token p + 1; verified against the reference's own target log-probs), so the stride is n_ctx."""
    if meta["seq"] != n_ctx:
        raise SystemExit(f"dump was made with --seq {meta['seq']}, expected {n_ctx}")
    if len(data) == n_chunk * n_ctx - 1:
        return n_ctx
    per, rem = divmod(len(data), n_chunk)
    if rem or per not in (n_ctx - 1, n_ctx):
        raise SystemExit(f"{len(data)} positions for {n_chunk} sequences of {n_ctx}: layout not understood")
    return per


def compare(ref, dump, chunks=0, estimator_check=False):
    toks, n_ctx, n_vocab = read_ref_header(ref)
    n_chunk = len(toks)
    meta, data = read_href(dump)
    per = positions_per_seq(meta, data, n_ctx, n_chunk)
    n = min(chunks or n_chunk, n_chunk)
    mm = np.memmap(ref, dtype=np.uint8, mode="r")
    first = n_ctx // 2
    acc = {k: [] for k in ("kl", "same", "nll", "nll_base", "p_rest", "q_rest")}
    for i in range(n):
        off, nv = chunk_offset(n_ctx, n_chunk, n_vocab, i)
        refl = load_ref_chunk(mm, n_ctx, off, nv, n_vocab)
        rows = data[i * per + first: i * per + first + scored(n_ctx)]
        tgt = toks[i, first + 1:].astype(np.int64)
        ref_top = refl.argmax(axis=1)
        nll_base = -np.take_along_axis(refl, tgt[:, None], axis=1)[:, 0]
        ids = rows["ids"].astype(np.int64)
        kl, p_rest, q_rest = topk_kl(refl, ids, rows["lps"])
        acc["kl"].append(kl)
        acc["same"].append(rows["argmax"] == ref_top)
        acc["nll"].append(rows["nll"].astype(np.float64))
        acc["nll_base"].append(nll_base)
        acc["p_rest"].append(p_rest)
        acc["q_rest"].append(q_rest)
    cat = {k: np.concatenate(v) for k, v in acc.items()}
    d = cat["nll"] - cat["nll_base"]
    same = cat["same"].astype(np.float64)
    return {"chunks": n, "positions": len(cat["kl"]), "k": meta["k"], "estimator": f"top{meta['k']}+bucket",
            "kl_mean": float(cat["kl"].mean()), "kl_se": se(cat["kl"]), "kl_median": float(np.median(cat["kl"])),
            "kl_p99": float(np.percentile(cat["kl"], 99)), "kl_max": float(cat["kl"].max()),
            "top1_same": float(same.mean()), "top1_se": float(math.sqrt(same.mean() * (1 - same.mean()) / (len(same) - 1))),
            "ppl": float(np.exp(cat["nll"].mean())), "ppl_ref": float(np.exp(cat["nll_base"].mean())),
            "ppl_ratio": float(np.exp(d.mean())), "ppl_ratio_se": float(np.exp(d.mean()) * se(d)),
            "rest_mass_ref": float(cat["p_rest"].mean()), "rest_mass_cand": float(cat["q_rest"].mean())}


def estimator_gap(ref, cand, k, chunks):
    """Full-vocabulary KL vs the top-k+bucket estimator on a llama.cpp candidate's own logits (same two files)."""
    toks, n_ctx, n_vocab = read_ref_header(ref)
    n_chunk = len(toks)
    a, b = np.memmap(ref, dtype=np.uint8, mode="r"), np.memmap(cand, dtype=np.uint8, mode="r")
    full, top = [], []
    for i in range(min(chunks, n_chunk)):
        off, nv = chunk_offset(n_ctx, n_chunk, n_vocab, i)
        p, q = load_ref_chunk(a, n_ctx, off, nv, n_vocab), load_ref_chunk(b, n_ctx, off, nv, n_vocab)
        full.append(full_kl(p, q))
        ids = np.argpartition(-q, k, axis=1)[:, :k]
        top.append(topk_kl(p, ids, np.take_along_axis(q, ids, axis=1))[0])
    full, top = np.concatenate(full), np.concatenate(top)
    return {"chunks": min(chunks, n_chunk), "k": k, "kl_full": float(full.mean()), "kl_topk": float(top.mean()),
            "topk_over_full": float(top.mean() / full.mean())}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("ids")
    i.add_argument("--ref", required=True)
    i.add_argument("--out", required=True)
    g = sub.add_parser("gap")
    g.add_argument("--ref", required=True)
    g.add_argument("--cand", required=True, help="a llama.cpp logits file of the candidate")
    g.add_argument("--k", type=int, default=128)
    g.add_argument("--chunks", type=int, default=64)
    c = sub.add_parser("compare")
    c.add_argument("--ref", required=True)
    c.add_argument("--chunks", type=int, default=0)
    c.add_argument("name_dump", nargs="+", help="name=<HREF dump>")
    a = p.parse_args()
    if a.cmd == "ids":
        toks, n_ctx, _ = read_ref_header(a.ref)
        toks.astype("<i4").tofile(a.out)
        print(f"{len(toks)} chunks x {n_ctx} tokens")
        return 0
    if a.cmd == "gap":
        print(json.dumps(estimator_gap(a.ref, a.cand, a.k, a.chunks)))
        return 0
    for spec in a.name_dump:
        name, _, path = spec.partition("=")
        print(json.dumps({"row": name, **compare(a.ref, path, a.chunks)}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
