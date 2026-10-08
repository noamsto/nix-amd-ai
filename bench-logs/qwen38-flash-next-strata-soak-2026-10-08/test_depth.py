"""Offline tests for depth.py: the stage ladder, the text source, the summaries, and both groups against a fake engine.

    python3 test_depth.py
"""
import os
import sys
import types
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import depth as d  # noqa: E402


class FakeP:
    """The slice of probe.py the groups use. Tokens are chars/4 plus a 700-token fixed part. Each of `slots` slots
    holds its last request; a request takes the slot sharing over half its prompt, else the least recently used."""
    REPLAY_GEN = 300
    os = os

    def __init__(self, slots=1):
        self.slots, self.held, self.calls, self.used = slots, [[] for _ in range(slots)], [], [0] * slots
        self.grid = types.SimpleNamespace(http=lambda *a, **k: {"slots": slots})

    @staticmethod
    def thinking_off(_e):
        return {"chat_template_kwargs": {"enable_thinking": False}}

    @staticmethod
    def decode_tps(r):
        return (r["completion_tokens"] - 1) / r["gen_s"] if r["completion_tokens"] > 1 and r["gen_s"] > 0 else None

    @staticmethod
    def mem_snapshot(_pid, _g, _v):
        return {"gtt_delta_bytes": 1}

    @staticmethod
    def tokens(msgs):
        return 700 + sum(len(m["content"]) for m in msgs) // 4

    def stream(self, _e, _path, body):
        msgs = body["messages"]
        shared = [self.tokens(msgs[:self.lcp(self.held[i], msgs)]) / self.tokens(msgs) for i in range(self.slots)]
        best = max(range(self.slots), key=shared.__getitem__)
        if shared[best] <= 0.5:
            best = min(range(self.slots), key=self.used.__getitem__)
        self.used[best] = len(self.calls) + 1
        cached = self.tokens(msgs[:self.lcp(self.held[best], msgs)]) if self.lcp(self.held[best], msgs) else 0
        self.held[best] = list(msgs)
        n = self.tokens(msgs)
        self.calls.append((n, cached))
        return {"ttft_s": 1.0 + (n - cached) / 1000, "gen_s": 2.0, "wall_s": 3.0, "text": "a reply", "finish_reason": "stop",
                "prompt_tokens": n, "completion_tokens": body["max_tokens"], "cached_tokens": cached,
                "timings": {"draft_n": 10, "draft_n_accepted": 7}, "gufo": None}

    @staticmethod
    def lcp(a, b):
        k = 0
        while k < min(len(a), len(b)) and a[k] == b[k]:
            k += 1
        return k


def fake_corpus(chars=5_000_000):
    return "".join(f"{i:07d} lorem ipsum dolor sit amet\n" for i in range(chars // 36))


class Pure(unittest.TestCase):
    def test_stage_targets_end_under_the_limit(self):
        t = d.stage_targets(262144)
        self.assertEqual(t[-1], 262144 - d.HEADROOM)
        self.assertEqual(t[:3], [8192, 32768, 65536])
        self.assertEqual(d.stage_targets(196608)[-1], 196608 - d.HEADROOM)
        self.assertNotIn(196608, d.stage_targets(196608))
        self.assertEqual(d.stage_targets(131072)[-2:], [98304, 131072 - d.HEADROOM])

    def test_source_never_repeats_and_runs_out(self):
        s = d.Source("abcdef")
        self.assertEqual((s.take(2), s.take(3)), ("ab", "cde"))
        with self.assertRaises(RuntimeError):
            s.take(2)

    def test_acceptance_and_aggregate(self):
        self.assertEqual(d.acceptance({"timings": {"draft_n": 8, "draft_n_accepted": 6}}), 0.75)
        self.assertIsNone(d.acceptance({"timings": {}}))
        self.assertIsNone(d.acceptance({"timings": None}))
        rs = [{"ttft_s": 1, "gen_s": 9, "completion_tokens": 100}, {"ttft_s": 2, "gen_s": 8, "completion_tokens": 100}]
        self.assertEqual(d.aggregate_tps(rs), 22.22)

    def test_fill_turns_are_bounded(self):
        c = {"replay": {"system": "s", "user": "u", "tools": []}}
        convo = d.Convo(c, d.Source("x" * 1_000_000), "t", 1)
        convo.add_tokens(40000)
        self.assertEqual([len(m["content"]) for m in convo.msgs[3::2]], [16000, 16000, 8000])


class Groups(unittest.TestCase):
    c = {"replay": {"system": "s" * 4000, "user": "task", "tools": []}}

    def engine(self, ctx, slots):
        return types.SimpleNamespace(args=types.SimpleNamespace(ctx=ctx, slots=slots), port=1, pid=1, gtt0=0, vram0=0, model="m", engine="strata")

    def run_group(self, fn, ctx, slots, fake_slots):
        p = FakeP(fake_slots)
        orig = d.load_text
        d.load_text = lambda _p: fake_corpus()
        try:
            return fn(self.engine(ctx, slots), self.c, p), p
        finally:
            d.load_text = orig

    def test_depth_reaches_the_limit_and_reuses_the_prefix(self):
        out, _ = self.run_group(d.run_depth, 131072, 1, 1)
        self.assertEqual([s["target"] for s in out["stages"]], d.stage_targets(131072))
        last = out["stages"][-1]
        self.assertAlmostEqual(last["fill"]["prompt_tokens"], 131072 - d.HEADROOM, delta=3000)
        self.assertGreater(last["turn"]["cached_tokens"], 0.9 * last["turn"]["prompt_tokens"])
        self.assertEqual(last["essay"]["acceptance"], 0.7)
        self.assertNotIn("stopped_at", out)

    def test_depth_records_a_failure_and_stops(self):
        p = FakeP()
        real = p.stream
        p.stream = lambda *a, **k: real(*a, **k) if len(p.calls) < 6 else (_ for _ in ()).throw(RuntimeError("boom"))
        orig = d.load_text
        d.load_text = lambda _p: fake_corpus()
        try:
            out = d.run_depth(self.engine(131072, 1), self.c, p)
        finally:
            d.load_text = orig
        self.assertIn("boom", out["stages"][-1]["error"])
        self.assertEqual(out["stopped_at"], out["stages"][-1]["target"])

    def test_twosession_keeps_both_caches_with_two_slots(self):
        out, _ = self.run_group(d.run_twosession, 262144, 2, 2)
        self.assertNotIn("error", out)
        for key in ("alone_A", "alone_B", "alone_A_again"):
            self.assertGreater(out[key]["cached_tokens"], 0.9 * out[key]["prompt_tokens"], key)
        self.assertEqual(len(out["rounds"]), 3)
        self.assertAlmostEqual(out["alone_A"]["prompt_tokens"], out["session_tokens"], delta=0.04 * out["session_tokens"])
        self.assertAlmostEqual(out["rounds"][0]["aggregate_tps"], 400.0, delta=1)

    def test_twosession_third_session_thrashes_two_lru_slots(self):
        out, _ = self.run_group(d.run_twosession, 262144, 2, 2)
        for key in ("after_third_A", "after_third_B"):  # C takes A's slot, A's refill takes B's
            self.assertLess(out[key]["cached_tokens"], 0.5 * out[key]["prompt_tokens"], key)

    def test_twosession_third_session_fits_with_three_slots(self):
        out, _ = self.run_group(d.run_twosession, 262144, 2, 3)
        for key in ("after_third_A", "after_third_B"):
            self.assertGreater(out[key]["cached_tokens"], 0.9 * out[key]["prompt_tokens"], key)


if __name__ == "__main__":
    unittest.main()
