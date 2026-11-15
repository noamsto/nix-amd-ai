"""Offline tests for footprint.py's summariser and process filter, on synthetic sample series.

python3 test_footprint.py
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import footprint as f

G = 2**30


def sample(t, gtt, mem, procs=(), mlocked=0, mapped=0, cached=0):
    """One sample; sizes in GiB. procs: (vm_rss, rss_anon, rss_file, vm_lck) per watched process."""
    return {
        "t": t,
        "gtt": None if gtt is None else int(gtt * G),
        "mem_available": None if mem is None else int(mem * G),
        "mlocked": int(mlocked * G),
        "mapped": int(mapped * G),
        "cached": int(cached * G),
        "procs": [
            dict(
                zip(
                    ("vm_rss", "rss_anon", "rss_file", "vm_lck"),
                    (int(x * G) for x in p),
                )
            )
            for p in procs
        ],
    }


def series():
    """lemond phase, bench appears (idle baseline), ramp, plateau with a one-sample GTT spike, teardown."""
    out = [
        sample(0.0, 70.0, 20.0, mapped=5.0, cached=30.0),
        sample(0.2, 70.0, 20.0, mapped=5.0, cached=30.0),
        # lemond unloaded; the bench process appears: this is the idle baseline
        sample(0.4, 2.0, 100.0, [(0.5, 0.4, 0.1, 0.0)], mapped=1.0, cached=10.0),
        # ramp: 3.9 GiB of GTT, then the jump to the plateau
        sample(0.6, 5.9, 95.0, [(4.0, 3.0, 1.0, 0.0)], mapped=20.0, cached=40.0),
        sample(0.8, 5.9, 94.0, [(4.0, 3.0, 1.0, 0.0)], mapped=20.0, cached=40.0),
    ]
    for i in range(13):
        spike = i == 5
        out.append(
            sample(
                1.0 + 0.2 * i,
                56.0 if spike else 52.0,
                50.0 if spike else 52.0,
                [(6.0, 3.5, 2.5, 1.0), (0.5, 0.4, 0.1, 0.0)],
                mlocked=1.0,
                mapped=30.0,
                cached=50.0,
            )
        )
    # teardown, longer than any fixed trailing window: GTT, RSS and MemAvailable fall back
    for i in range(12):
        out.append(
            sample(
                3.6 + 0.2 * i,
                3.0,
                100.0,
                [(0.2, 0.2, 0.0, 0.0)],
                mapped=2.0,
                cached=12.0,
            )
        )
    return out


class Summarise(unittest.TestCase):
    def setUp(self):
        self.s = f.summarise(series())

    def test_idle_baseline_is_first_sample_with_a_watched_process(self):
        self.assertEqual(self.s["gtt_baseline_gib"], 2.0)
        self.assertEqual(self.s["mem_available_baseline_gib"], 100.0)

    def test_peak_catches_the_one_sample_spike(self):
        self.assertEqual(self.s["gtt_peak_delta_gib"], 54.0)
        self.assertEqual(self.s["mem_available_min_drop_gib"], 50.0)

    def test_loaded_value_is_the_plateau_median_not_the_spike_or_teardown(self):
        self.assertEqual(self.s["gtt_loaded_delta_gib"], 50.0)
        self.assertEqual(self.s["mem_available_loaded_drop_gib"], 48.0)

    def test_page_cache_counters_are_loaded_deltas(self):
        self.assertEqual(self.s["mlocked_loaded_delta_gib"], 1.0)
        self.assertEqual(self.s["mapped_loaded_delta_gib"], 29.0)
        self.assertEqual(self.s["cached_loaded_delta_gib"], 40.0)

    def test_rss_split_sums_the_watched_processes(self):
        self.assertEqual(self.s["rss_loaded_gib"], 6.5)
        self.assertEqual(self.s["rss_anon_loaded_gib"], 3.9)
        self.assertEqual(self.s["rss_file_loaded_gib"], 2.6)
        self.assertEqual(self.s["vm_lck_loaded_gib"], 1.0)
        self.assertEqual(self.s["rss_peak_gib"], 6.5)

    def test_durations(self):
        self.assertEqual(self.s["watched_s"], 5.4)
        self.assertEqual(self.s["load_s"], 0.6)
        self.assertEqual(self.s["loaded_s"], 2.4)
        self.assertEqual(self.s["samples"], 30)

    def test_old_steady_and_final_keys_are_gone(self):
        self.assertEqual(
            [k for k in self.s if "steady" in k or "final" in k],
            [],
        )

    def test_values_round_to_a_tenth(self):
        r = f.summarise(
            [
                sample(0.0, 1.0, 10.0, [(0.1, 0.1, 0.0, 0.0)]),
                sample(0.2, 1.04, 9.0, [(0.1, 0.1, 0.0, 0.0)]),
            ]
        )
        self.assertEqual(r["gtt_loaded_delta_gib"], 0.0)
        self.assertEqual(r["mem_available_loaded_drop_gib"], 1.0)

    def test_single_live_sample_does_not_crash(self):
        r = f.summarise([sample(0.0, 2.0, 100.0, [(1.0, 0.5, 0.5, 0.0)])])
        self.assertEqual(r["gtt_baseline_gib"], 2.0)
        self.assertEqual(r["gtt_peak_delta_gib"], 0.0)
        self.assertEqual(r["gtt_loaded_delta_gib"], 0.0)
        self.assertEqual(r["mem_available_loaded_drop_gib"], 0.0)
        self.assertEqual(r["rss_loaded_gib"], 1.0)
        self.assertEqual(r["watched_s"], 0.0)
        self.assertEqual(r["loaded_s"], 0.0)
        self.assertEqual(r["load_s"], 0.0)

    def test_bench_process_never_seen_is_all_null(self):
        r = f.summarise(series()[:2])
        self.assertIsNone(r["gtt_baseline_gib"])
        self.assertIsNone(r["gtt_peak_delta_gib"])
        self.assertIsNone(r["gtt_loaded_delta_gib"])
        self.assertIsNone(r["mem_available_min_drop_gib"])
        self.assertIsNone(r["rss_loaded_gib"])
        self.assertIsNone(r["loaded_s"])
        self.assertIsNone(r["load_s"])

    def test_unreadable_gtt_gives_null_loaded_values_not_zero(self):
        r = f.summarise(
            [
                sample(0.0, None, 10.0, [(1.0, 1.0, 0.0, 0.0)]),
                sample(0.2, None, 9.0, [(1.0, 1.0, 0.0, 0.0)]),
            ]
        )
        self.assertIsNone(r["gtt_baseline_gib"])
        self.assertIsNone(r["gtt_peak_delta_gib"])
        for key in f.SUMMARY_KEYS:
            if "loaded" in key:
                self.assertIsNone(r[key], key)
        self.assertIsNone(r["load_s"])
        self.assertEqual(r["mem_available_min_drop_gib"], 1.0)
        self.assertEqual(r["rss_peak_gib"], 1.0)
        self.assertEqual(r["watched_s"], 0.2)

    def test_samples_after_the_process_exits_do_not_count(self):
        r = f.summarise(series() + [sample(9.0, 3.0, 99.0)])
        self.assertEqual(r["gtt_loaded_delta_gib"], 50.0)
        self.assertEqual(r["watched_s"], 5.4)


class Cli(unittest.TestCase):
    def test_summarise_raw_matches_summarise_and_writes_out(self):
        with tempfile.TemporaryDirectory() as d:
            raw, out = os.path.join(d, "raw.jsonl"), os.path.join(d, "out.json")
            with open(raw, "w") as fh:
                fh.writelines(json.dumps(s) + "\n" for s in series())
            f.main(["summarise", "--raw", raw, "--out", out])
            with open(out) as fh:
                self.assertEqual(json.load(fh), f.summarise(series()))


class Filter(unittest.TestCase):
    TABLE = {  # noqa: RUF012
        1: (0, "systemd"),
        100: (1, "lemond"),
        # 101 and 102: lemond's resident engine, not under the watched root
        101: (100, "strata-host"),
        102: (101, "strata"),
        200: (1, "bash"),  # the watched root
        201: (200, "run.sh"),
        202: (201, "python3"),
        203: (202, "strata-host"),
        204: (203, "strata"),
        205: (204, "strata-vision"),
        206: (202, "sleep"),
        300: (1, "strata"),  # unrelated strata outside the tree
    }

    def test_only_strata_descendants_of_root(self):
        self.assertEqual(f.watched_pids(self.TABLE, 200), [203, 204, 205])

    def test_root_itself_is_not_a_descendant(self):
        self.assertNotIn(200, f.watched_pids(self.TABLE, 200))

    def test_lemond_resident_is_ignored(self):
        self.assertEqual(f.watched_pids(self.TABLE, 100), [101, 102])
        self.assertEqual(f.watched_pids(self.TABLE, 200).count(102), 0)

    def test_unknown_root_has_no_descendants(self):
        self.assertEqual(f.watched_pids(self.TABLE, 999), [])

    def test_read_proc_table_parses_comm_with_spaces_and_parens(self):
        with tempfile.TemporaryDirectory() as d:
            for pid, ppid, comm in ((7, 1, "strata (x) y"), (8, 7, "strata")):
                os.mkdir(os.path.join(d, str(pid)))
                with open(os.path.join(d, str(pid), "stat"), "w") as fh:
                    fh.write(f"{pid} ({comm}) S {ppid} 0 0 0\n")
            os.mkdir(os.path.join(d, "self"))
            self.assertEqual(
                f.read_proc_table(d), {7: (1, "strata (x) y"), 8: (7, "strata")}
            )

    def test_read_status_converts_kb_and_marks_missing_none(self):
        with tempfile.TemporaryDirectory() as d:
            os.mkdir(os.path.join(d, "9"))
            with open(os.path.join(d, "9", "status"), "w") as fh:
                fh.write(
                    "Name:\tstrata\nVmRSS:\t   2048 kB\nRssAnon:\t 1024 kB\nRssFile:\t 1024 kB\n"
                )
            self.assertEqual(
                f.read_status(d, 9),
                {
                    "vm_rss": 2048 * 1024,
                    "rss_anon": 1024 * 1024,
                    "rss_file": 1024 * 1024,
                    "vm_lck": None,
                },
            )
            self.assertIsNone(f.read_status(d, 10))


if __name__ == "__main__":
    unittest.main()
