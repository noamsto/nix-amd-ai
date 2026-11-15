"""Offline tests for footprint.py's summariser and process filter, on synthetic sample series.

python3 test_footprint.py
"""

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
    """lemond phase (resident model, no bench process), bench appears, load ramp with a one-sample spike, steady."""
    out = [
        sample(0.0, 70.0, 20.0, mapped=5.0, cached=30.0),
        sample(0.2, 70.0, 20.0, mapped=5.0, cached=30.0),
    ]
    # lemond unloaded; the bench process appears: this is the idle baseline
    out.append(
        sample(
            0.4,
            2.0,
            100.0,
            [(0.5, 0.4, 0.1, 0.0)],
            mlocked=0.0,
            mapped=1.0,
            cached=10.0,
        )
    )
    ramp = [
        (10.0, 90.0),
        (30.0, 70.0),
        (60.0, 45.0),
        (52.0, 50.0),
    ]  # 60.0 is the one-sample spike
    for i, (gtt, mem) in enumerate(ramp):
        out.append(
            sample(
                0.6 + 0.2 * i,
                gtt,
                mem,
                [(4.0, 3.0, 1.0, 0.0)],
                mapped=20.0,
                cached=40.0,
            )
        )
    for i in range(12):
        out.append(
            sample(
                1.4 + 0.2 * i,
                52.0,
                52.0,
                [(6.0, 3.5, 2.5, 1.0), (0.5, 0.4, 0.1, 0.0)],
                mlocked=1.0,
                mapped=30.0,
                cached=50.0,
            )
        )
    return out


class Summarise(unittest.TestCase):
    def setUp(self):
        self.s = f.summarise(series())

    def test_idle_baseline_is_first_sample_with_a_watched_process(self):
        self.assertEqual(self.s["gtt_baseline_gib"], 2.0)
        self.assertEqual(self.s["mem_available_baseline_gib"], 100.0)

    def test_load_peak_catches_one_sample_spike(self):
        self.assertEqual(self.s["gtt_peak_delta_gib"], 58.0)

    def test_steady_value_ignores_the_spike(self):
        self.assertEqual(self.s["gtt_steady_delta_gib"], 50.0)

    def test_mem_available_min_and_final_are_drops_vs_baseline(self):
        self.assertEqual(self.s["mem_available_min_drop_gib"], 55.0)
        self.assertEqual(self.s["mem_available_final_drop_gib"], 48.0)

    def test_page_cache_counters_are_final_deltas(self):
        self.assertEqual(self.s["mlocked_final_delta_gib"], 1.0)
        self.assertEqual(self.s["mapped_final_delta_gib"], 29.0)
        self.assertEqual(self.s["cached_final_delta_gib"], 40.0)

    def test_rss_split_sums_the_watched_processes(self):
        self.assertEqual(self.s["rss_steady_gib"], 6.5)
        self.assertEqual(self.s["rss_anon_steady_gib"], 3.9)
        self.assertEqual(self.s["rss_file_steady_gib"], 2.6)
        self.assertEqual(self.s["vm_lck_steady_gib"], 1.0)
        self.assertEqual(self.s["rss_peak_gib"], 6.5)

    def test_values_round_to_a_tenth(self):
        r = f.summarise(
            [
                sample(0.0, 1.0, 10.0, [(0.1, 0.1, 0.0, 0.0)]),
                sample(0.2, 1.04, 9.0, [(0.1, 0.1, 0.0, 0.0)]),
            ]
        )
        self.assertEqual(r["gtt_steady_delta_gib"], 0.0)
        self.assertEqual(r["mem_available_final_drop_gib"], 1.0)

    def test_bench_process_never_seen_is_all_null(self):
        r = f.summarise(series()[:2])
        self.assertIsNone(r["gtt_baseline_gib"])
        self.assertIsNone(r["gtt_peak_delta_gib"])
        self.assertIsNone(r["mem_available_min_drop_gib"])
        self.assertIsNone(r["rss_steady_gib"])

    def test_unreadable_gtt_is_null_not_zero(self):
        r = f.summarise(
            [
                sample(0.0, None, 10.0, [(1.0, 1.0, 0.0, 0.0)]),
                sample(0.2, None, 9.0, [(1.0, 1.0, 0.0, 0.0)]),
            ]
        )
        self.assertIsNone(r["gtt_baseline_gib"])
        self.assertIsNone(r["gtt_peak_delta_gib"])
        self.assertIsNone(r["gtt_steady_delta_gib"])
        self.assertEqual(r["mem_available_final_drop_gib"], 1.0)

    def test_samples_after_the_process_exits_do_not_count(self):
        tail = [sample(9.0, 3.0, 99.0)]
        r = f.summarise(series() + tail)
        self.assertEqual(r["gtt_steady_delta_gib"], 50.0)
        self.assertEqual(r["mem_available_final_drop_gib"], 48.0)


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
