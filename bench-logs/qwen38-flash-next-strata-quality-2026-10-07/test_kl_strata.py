"""Offline tests for kl_strata.py: arm grammar, the top-k KL estimator, the logits-file reader. Needs numpy.

    python3 test_kl_strata.py
"""
import os
import struct
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kl_strata as k  # noqa: E402


def log_softmax(x):
    x = x - x.max(axis=1, keepdims=True)
    return x - np.log(np.exp(x).sum(axis=1, keepdims=True))


class Arms(unittest.TestCase):
    def spec(self, arm):
        return k.arm_spec(arm, 100, "/repo")

    def test_presets(self):
        flags, env = self.spec("def")
        self.assertEqual(flags[:2], ["--prefill", "auto"])
        self.assertEqual(list(env), ["STRATA_HIPBLASLT_TUNING"])
        flags, env = self.spec("fast")
        self.assertEqual(flags[:4], ["--prefill", "16384", "--mtp-q4", "all"])
        self.assertEqual(env["STRATA_PF_SWITCH_MIN_T"], "4096")
        self.assertEqual(sum(v == "1" for v in env.values()), 7)

    def test_min_t_and_switches(self):
        _, env = self.spec("fast@0")
        self.assertEqual(env["STRATA_PF_SWITCH_MIN_T"], "0")
        _, env = self.spec("fast-pf_gemm,hc_q8@0")
        self.assertNotIn("STRATA_PF_GEMM", env)
        self.assertNotIn("STRATA_HC_Q8", env)
        self.assertEqual(env["STRATA_PF_FUSED"], "1")
        flags, env = self.spec("def+hip_wmma")
        self.assertEqual(env["STRATA_HIP_WMMA"], "1")
        self.assertNotIn("--mtp-q4", flags)

    def test_flag_switches(self):
        flags, _ = self.spec("fast-prefill")
        self.assertEqual(flags[:2], ["--prefill", "auto"])
        flags, _ = self.spec("fast-mtpq4")
        self.assertNotIn("--mtp-q4", flags)
        flags, _ = self.spec("fast+kvf16@0")
        self.assertEqual(flags[flags.index("--kv") + 1], "fp16")
        flags, _ = self.spec("def+mtpq4")
        self.assertEqual(flags[-2:], ["--mtp-q4", "all"])

    def test_rejects(self):
        for bad in ("slow", "fast-nope", "fast-", "def+", "def-pf_fused", "fast+mtpq4", "fast-kvf16"):
            with self.assertRaises(SystemExit):
                self.spec(bad)


class Estimator(unittest.TestCase):
    def test_identical_distributions_are_zero(self):
        rng = np.random.default_rng(0)
        p = log_softmax(rng.normal(size=(5, 600)) * 3)
        ids = np.argsort(-p, axis=1)[:, :256]
        kl, p_rest, q_rest = k.topk_kl(p, ids, np.take_along_axis(p, ids, axis=1))
        self.assertTrue(np.allclose(kl, 0, atol=1e-9))
        self.assertTrue(np.allclose(p_rest, q_rest))

    def test_lower_bound_close_to_full(self):
        rng = np.random.default_rng(1)
        a = rng.normal(size=(8, 600)) * 3
        p, q = log_softmax(a), log_softmax(a + rng.normal(size=a.shape) * 0.5)
        ids = np.argsort(-q, axis=1)[:, :256]
        full = k.full_kl(p.astype(np.float32), q.astype(np.float32))
        top, _, _ = k.topk_kl(p, ids, np.take_along_axis(q, ids, axis=1))
        self.assertTrue((top <= full + 1e-6).all())
        self.assertLess(np.abs(top - full).max(), 0.02 * full.max() + 1e-3)


class Reader(unittest.TestCase):
    def test_chunk_roundtrip(self):
        n_vocab, n_chunk = 7, 2
        nv = 2 * ((n_vocab + 1) // 2) + 4
        rng = np.random.default_rng(2)
        lp = log_softmax(rng.normal(size=(k.SCORED, n_vocab)).astype(np.float32))
        scale = (lp.max(axis=1) - lp.min(axis=1)) / 65535
        q = np.round((lp - lp.min(axis=1, keepdims=True)) / scale[:, None]).astype(np.uint16)
        raw = np.zeros((k.SCORED, nv), dtype=np.uint16)
        head = np.stack([scale, lp.min(axis=1)], axis=1).astype(np.float32).view(np.uint16)
        raw[:, :4], raw[:, 4:4 + n_vocab] = head, q
        with tempfile.NamedTemporaryFile(suffix=".logits", delete=False) as f:
            f.write(b"_logits_" + struct.pack("<iii", k.N_CTX, n_vocab, n_chunk))
            f.write(np.arange(k.N_CTX * n_chunk, dtype=np.int32).tobytes())
            f.write(raw.tobytes() + raw.tobytes())
        try:
            toks, nvocab = k.read_tokens(f.name)
            self.assertEqual((toks.shape, nvocab), ((n_chunk, k.N_CTX), n_vocab))
            off, got_nv = k.chunk_offset(n_chunk, n_vocab, 1)
            self.assertEqual(got_nv, nv)
            mm = np.memmap(f.name, dtype=np.uint8, mode="r")
            back = k.load_ref_chunk(mm, off, nv, n_vocab)
            self.assertLess(np.abs(back - lp).max(), 1e-3)
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
