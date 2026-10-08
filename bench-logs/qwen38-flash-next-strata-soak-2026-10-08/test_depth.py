"""Offline tests for depth.py and tables.py: the stage ladder, the text source, the summaries, both groups against a fake
engine that can also fail the way the real ones did, and every table over rows that hold errors.

    python3 test_depth.py
"""
import os
import sys
import threading
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import depth as d  # noqa: E402
import tables as tb  # noqa: E402


class FakeP:
    """The slice of probe.py the groups use. Tokens are chars/4 plus a 700-token fixed part. Each of `slots` slots holds
    its last request; a request takes the slot sharing over half its prompt, else the least recently used. A request whose
    last message asks for an essay runs to its token limit; any other ends as a short tool call, as the real model did
    (`always_long` makes every request run to its limit). `fail_after` raises once that many requests have been made."""
    REPLAY_GEN = 300
    os = os

    def __init__(self, slots=1, always_long=False, fail_after=None):
        self.slots, self.always_long, self.fail_after = slots, always_long, fail_after
        self.held, self.calls, self.used = [[] for _ in range(slots)], [], [0] * slots
        self.lock = threading.Lock()
        self.grid = types.SimpleNamespace(http=lambda *_a, **_k: [{"id": i, "n_ctx": 1, "prompt": "x" * 9} for i in range(slots)])

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

    @staticmethod
    def lcp(a, b):
        k = 0
        while k < min(len(a), len(b)) and a[k] == b[k]:
            k += 1
        return k

    def stream(self, _e, _path, body):
        with self.lock:
            if self.fail_after is not None and len(self.calls) >= self.fail_after:
                raise RuntimeError("boom")
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
        long = self.always_long or d.ESSAY in msgs[-1]["content"]
        tokens, finish = (body["max_tokens"], "length") if long else (min(40, body["max_tokens"]), "tool_calls")
        return {"ttft_s": 1.0 + (n - cached) / 1000, "gen_s": 2.0, "wall_s": 3.0, "text": "a reply", "finish_reason": finish,
                "prompt_tokens": n, "completion_tokens": tokens, "cached_tokens": cached,
                "timings": {"draft_n": 10, "draft_n_accepted": 7}, "gufo": None}


def fake_corpus(chars=5_000_000):
    return "".join(f"{i:07d} lorem ipsum dolor sit amet\n" for i in range(chars // 36))


def engine(ctx, slots=1, kind="strata"):
    return types.SimpleNamespace(args=types.SimpleNamespace(ctx=ctx, slots=slots), port=1, pid=1, gtt0=0, vram0=0, model="m",
                                 engine=kind)


class Pure(unittest.TestCase):
    def test_stage_targets_end_under_the_limit(self):
        t = d.stage_targets(262144)
        self.assertEqual(t[-1], 262144 - d.HEADROOM)
        self.assertEqual(t[:3], [8192, 32768, 65536])
        self.assertNotIn(196608, d.stage_targets(196608))
        self.assertEqual(d.stage_targets(131072)[-2:], [98304, 131072 - d.HEADROOM])

    def test_limit_divides_only_llama_by_its_slots(self):
        self.assertEqual(d.limit_of(engine(262144, 2, "llama")), 131072)
        self.assertEqual(d.limit_of(engine(262144, 2, "strata")), 262144)

    def test_source_never_repeats_and_runs_out(self):
        s = d.Source("abcdef")
        self.assertEqual((s.take(2), s.take(3)), ("ab", "cde"))
        with self.assertRaises(RuntimeError):
            s.take(2)

    def test_acceptance(self):
        self.assertEqual(d.acceptance({"timings": {"draft_n": 8, "draft_n_accepted": 6}}), 0.75)
        self.assertIsNone(d.acceptance({"timings": {}}))
        self.assertIsNone(d.acceptance({"timings": None}))

    def test_aggregate_uses_each_requests_send_time(self):
        a = {"ttft_s": 1, "gen_s": 9, "completion_tokens": 100}
        b = {"ttft_s": 2, "gen_s": 8, "completion_tokens": 100}
        self.assertEqual(d.aggregate_tps([(a, 0), (b, 0)]), 22.22)
        # b sent 3 s later: its window is 5..13 on the round's clock, so the span is 1..13
        self.assertEqual(d.aggregate_tps([(a, 0), (b, 3)]), round(200 / 12, 2))

    def test_summarize_drops_the_rate_of_a_short_reply(self):
        r = {"prompt_tokens": 100, "cached_tokens": 90, "ttft_s": 1.0, "completion_tokens": 40, "gen_s": 1.0, "wall_s": 2.0,
             "finish_reason": "tool_calls", "timings": {"draft_n": 4, "draft_n_accepted": 3}}
        s = d.summarize(FakeP(), r, long=True)
        self.assertTrue(s["short"])
        self.assertIsNone(s["decode_tps"])
        self.assertIsNone(s["acceptance"])
        self.assertEqual((s["new_tokens"], s["prefill_tps"]), (10, 10.0))
        self.assertIsNotNone(d.summarize(FakeP(), r)["decode_tps"])

    def test_summarize_does_not_guess_when_the_server_reports_no_cache(self):
        r = {"prompt_tokens": 100, "cached_tokens": None, "ttft_s": 1.0, "completion_tokens": 8, "gen_s": 1.0, "wall_s": 2.0,
             "finish_reason": "length", "timings": None}
        s = d.summarize(FakeP(), r)
        self.assertIsNone(s["new_tokens"])
        self.assertIsNone(s["prefill_tps"])

    def test_fill_turns_are_bounded(self):
        c = {"replay": {"system": "s", "user": "u", "tools": []}}
        convo = d.Convo(c, d.Source("x" * 1_000_000), "t", 1)
        convo.add_tokens(40000)
        self.assertEqual([len(m["content"]) for m in convo.msgs[3::2]], [16000, 16000, 8000])

    def test_ask_is_a_user_message_after_the_tool_result(self):
        c = {"replay": {"system": "s", "user": "u", "tools": []}}
        convo = d.Convo(c, d.Source("x" * 10000), "t", 1)
        convo.add_turn(100, d.ESSAY)
        self.assertEqual([m["role"] for m in convo.msgs], ["system", "user", "assistant", "tool", "user"])
        convo.commit({"text": "reply"})
        convo.add_turn(100)
        self.assertEqual([m["role"] for m in convo.msgs[5:]], ["assistant", "user", "assistant", "tool"])


class Groups(unittest.TestCase):
    c = {"replay": {"system": "s" * 4000, "user": "task", "tools": []}}

    def run_group(self, fn, ctx, slots=1, fake_slots=1, **fake):
        p = FakeP(fake_slots, **fake)
        with mock.patch.object(d, "load_text", lambda _p: fake_corpus()):
            return fn(engine(ctx, slots), self.c, p), p

    def test_depth_reaches_the_limit_and_reuses_the_prefix(self):
        out, _ = self.run_group(d.run_depth, 131072)
        self.assertEqual([s["target"] for s in out["stages"]], d.stage_targets(131072))
        last = out["stages"][-1]
        self.assertAlmostEqual(last["fill"]["prompt_tokens"], 131072 - d.HEADROOM, delta=3000)
        self.assertGreater(last["turn"]["cached_tokens"], 0.9 * last["turn"]["prompt_tokens"])
        self.assertEqual(last["essay"]["acceptance"], 0.7)
        self.assertNotIn("stopped_at", out)

    def test_depth_records_a_failure_and_stops(self):
        out, _ = self.run_group(d.run_depth, 131072, fail_after=6)
        self.assertIn("boom", out["stages"][-1]["error"])
        self.assertEqual(out["stopped_at"], out["stages"][-1]["target"])

    def test_a_setup_failure_is_the_groups_error(self):
        def broken(_p):
            raise RuntimeError("no corpus")

        with mock.patch.object(d, "load_text", broken):
            for fn in (d.run_depth, d.run_twosession):
                self.assertIn("no corpus", fn(engine(131072), self.c, FakeP())["error"])

    def test_twosession_keeps_both_caches_with_two_slots(self):
        out, _ = self.run_group(d.run_twosession, 262144, fake_slots=2, always_long=True)
        self.assertNotIn("error", out)
        for key in ("alone_A", "alone_B", "alone_A_again"):
            self.assertGreater(out[key]["cached_tokens"], 0.9 * out[key]["prompt_tokens"], key)
        self.assertEqual(len(out["rounds"]), 3)
        self.assertAlmostEqual(out["alone_A"]["prompt_tokens"], out["session_tokens"], delta=0.04 * out["session_tokens"])
        self.assertEqual(out["slots_seen"], [{"id": 0, "n_ctx": 1}, {"id": 1, "n_ctx": 1}])

    def test_rounds_report_a_combined_rate_only_when_every_stream_ran_long(self):
        out, _ = self.run_group(d.run_twosession, 262144, fake_slots=2, always_long=True)
        concurrent, staggered = out["rounds"][0], out["rounds"][2]
        self.assertAlmostEqual(concurrent["combined_tps"], 400.0, delta=1)
        self.assertIsNone(staggered["combined_tps"])  # B's answer is one line by design
        self.assertAlmostEqual(staggered["streams"][1]["start_s"], d.STAGGER_S, delta=0.5)

    def test_short_replies_are_not_published_as_rates(self):
        out, _ = self.run_group(d.run_twosession, 262144, fake_slots=2)  # nothing runs long except the essays
        for rd in out["rounds"][:2]:
            self.assertEqual(rd["streams"][0]["finish"], "length")
        out, _ = self.run_group(d.run_depth, 131072)
        self.assertTrue(all(not s["essay"].get("short") for s in out["stages"]))
        out["stages"][0]["essay"].update(short=True, decode_tps=None, acceptance=None)
        self.assertEqual(out["stages"][0]["essay"]["decode_tps"], None)

    def test_third_session_thrashes_two_lru_slots(self):
        out, _ = self.run_group(d.run_twosession, 262144, fake_slots=2, always_long=True)
        for key in ("after_third_A", "after_third_B"):  # C takes A's slot, A's refill takes B's
            self.assertLess(out[key]["cached_tokens"], 0.5 * out[key]["prompt_tokens"], key)

    def test_third_session_fits_with_three_slots(self):
        out, _ = self.run_group(d.run_twosession, 262144, fake_slots=3, always_long=True)
        for key in ("after_third_A", "after_third_B"):
            self.assertGreater(out[key]["cached_tokens"], 0.9 * out[key]["prompt_tokens"], key)


class Tables(unittest.TestCase):
    def rows(self):
        full, _ = Groups().run_group(d.run_depth, 131072)
        partial, _ = Groups().run_group(d.run_depth, 131072)
        del partial["stages"][-1]["turn"], partial["stages"][-1]["essay"]  # a turn that failed after its fill
        partial["stages"][-1]["error"] = "RowError: a | b\nc"
        two, _ = Groups().run_group(d.run_twosession, 262144, fake_slots=2, always_long=True)
        failed = {"error": "RowError: stream produced no output"}
        base = {"label": "", "gtt_peak_delta_bytes": 1, "ctx": 1}
        return {"depth192": {**base, "depth": full}, "depth256": {**base, "depth": partial},
                "nomtp-depth128": {**base, "depth": failed}, "gsq-depth192": {**base, "error": "row failed"},
                "two128": {**base, "twosession": two}, "two256-park": {**base, "twosession": failed},
                "soak": {**base, "soak": failed}, "longsoak": {**base, "longsoak": failed},
                "soak-batch": {**base, "soak": {"replay": [], "concurrency": {}}}}

    def test_every_section_renders_rows_that_hold_errors(self):
        rows = self.rows()
        for name, fn in tb.SECTIONS.items():
            self.assertIsInstance(fn(rows), str, name)

    def test_error_text_cannot_break_a_row(self):
        text = tb.depth_table(self.rows())
        self.assertNotIn("a | b", text)
        self.assertTrue(all(line.count("|") == text.split("\n")[0].count("|") for line in text.split("\n")))

    def test_errors_are_counted(self):
        rows = self.rows()
        self.assertEqual(tb.errors_of(rows["depth256"]), 1)
        self.assertEqual(tb.errors_of(rows["nomtp-depth128"]), 1)
        self.assertEqual(tb.errors_of(rows["depth192"]), 0)
        self.assertEqual(tb.errors_of(rows["gsq-depth192"]), "row failed")


if __name__ == "__main__":
    unittest.main()
