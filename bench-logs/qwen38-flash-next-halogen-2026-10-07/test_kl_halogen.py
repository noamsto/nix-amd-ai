#!/usr/bin/env python3
"""Offline tests for kl_halogen.py on a tiny synthetic reference (n_ctx 16, vocab 20, 2 chunks)."""
import os
import struct
import tempfile
import unittest

import numpy as np

import kl_halogen as kh

N_CTX, VOCAB, CHUNKS, K = 16, 20, 2, 8


def make_ref(path, logp, toks):
    """llama.cpp layout: per scored row two float32 (scale, min) then uint16 per vocab entry (padded even)."""
    nv = 2 * ((VOCAB + 1) // 2) + 4
    with open(path, "wb") as f:
        f.write(b"_logits_" + struct.pack("<iii", N_CTX, VOCAB, CHUNKS) + toks.astype("<i4").tobytes())
        for i in range(CHUNKS):
            for row in logp[i]:
                lo, hi = float(row.min()), float(row.max())
                scale = (hi - lo) / 65535 or 1.0
                q = np.round((row - lo) / scale).astype("<u2")
                f.write(struct.pack("<ff", scale, lo) + q.tobytes() + b"\0" * (2 * (nv - 4 - VOCAB)))


def make_href(path, cand, toks, per, seq=N_CTX):
    """cand: (chunks, per, VOCAB) log-probs; writes the top-K plus tail like `halogen ppl --ref-out`."""
    rec = []
    for i in range(CHUNKS):
        for j in range(per):
            lp = cand[i, j]
            order = np.argsort(-lp)[:K]
            tail = float(np.log(max(1e-12, 1 - np.exp(lp[order]).sum())))
            nll = -lp[toks[i, j + 1]] if j + 1 < N_CTX else 0.0
            rec.append(struct.pack("<fid", nll, int(order[0]), tail) + order.astype("<i4").tobytes()
                       + lp[order].astype("<f8").tobytes())
    with open(path, "wb") as f:
        f.write(struct.pack("<4sIIIQQ", b"HREF", 2, K, VOCAB, CHUNKS * per, seq) + b"".join(rec))


def softmax_log(x):
    x = x - x.max(axis=-1, keepdims=True)
    return x - np.log(np.exp(x).sum(axis=-1, keepdims=True))


class Compare(unittest.TestCase):
    def setUp(self):
        rng = np.random.default_rng(1)
        self.dir = tempfile.mkdtemp()
        self.toks = rng.integers(0, VOCAB, (CHUNKS, N_CTX), dtype=np.int32)
        sc = kh.scored(N_CTX)
        self.ref_rows = softmax_log(rng.normal(size=(CHUNKS, sc, VOCAB)) * 2).astype(np.float32)
        self.ref = os.path.join(self.dir, "ref.logits")
        make_ref(self.ref, self.ref_rows, self.toks)

    def dump_from(self, ref_logp, per):
        """A candidate whose scored rows are `ref_logp` (the rest padding), laid out per sequence."""
        cand = np.full((CHUNKS, per, VOCAB), -np.log(VOCAB))
        cand[:, N_CTX // 2: N_CTX // 2 + kh.scored(N_CTX)] = ref_logp
        path = os.path.join(self.dir, f"c{per}.href")
        make_href(path, cand, self.toks, per)
        return path

    def test_identical_candidate_has_near_zero_kl_and_full_agreement(self):
        for per in (N_CTX - 1, N_CTX):
            out = kh.compare(self.ref, self.dump_from(self.ref_rows, per))
            self.assertEqual(out["positions"], CHUNKS * kh.scored(N_CTX))
            self.assertLess(out["kl_mean"], 5e-3)  # uint16 quantisation of the reference plus the bucket
            self.assertEqual(out["top1_same"], 1.0)
            self.assertAlmostEqual(out["ppl_ratio"], 1.0, places=3)

    def test_stream_dump_missing_the_last_row(self):
        path = self.dump_from(self.ref_rows, N_CTX)
        with open(path, "r+b") as f:
            rec = (os.path.getsize(path) - 32) // (CHUNKS * N_CTX)
            f.truncate(os.path.getsize(path) - rec)
            f.seek(16)
            f.write(struct.pack("<Q", CHUNKS * N_CTX - 1))
        out = kh.compare(self.ref, path)
        self.assertEqual(out["positions"], CHUNKS * kh.scored(N_CTX))
        self.assertEqual(out["top1_same"], 1.0)

    def test_perturbed_candidate_has_positive_kl(self):
        rng = np.random.default_rng(2)
        noisy = softmax_log(self.ref_rows + rng.normal(size=self.ref_rows.shape)).astype(np.float32)
        out = kh.compare(self.ref, self.dump_from(noisy, N_CTX))
        self.assertGreater(out["kl_mean"], 0.05)
        self.assertLess(out["top1_same"], 1.0)

    def test_wrong_seq_is_refused(self):
        path = os.path.join(self.dir, "bad.href")
        make_href(path, np.full((CHUNKS, N_CTX, VOCAB), -np.log(VOCAB)), self.toks, N_CTX, seq=32)
        with self.assertRaises(SystemExit):
            kh.compare(self.ref, path)

    def test_topk_estimator_is_a_lower_bound_of_full_kl(self):
        rng = np.random.default_rng(3)
        p = softmax_log(rng.normal(size=(50, VOCAB)) * 2)
        q = softmax_log(rng.normal(size=(50, VOCAB)) * 2)
        ids = np.argsort(-q, axis=1)[:, :K]
        kl, _, _ = kh.topk_kl(p, ids, np.take_along_axis(q, ids, axis=1))
        self.assertTrue((kl <= kh.full_kl(p, q) + 1e-9).all())


if __name__ == "__main__":
    unittest.main()
