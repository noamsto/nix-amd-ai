"""Offline tests for tables.py on in-memory summaries written to a temp dir (the #352 figures for 20000 vs 5000).

python3 test_tables.py
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables as t

REF = {
    "gtt_loaded_delta_gib": 61.6,
    "rss_file_loaded_gib": 41.5,
    "rss_anon_loaded_gib": 1.9,
    "rss_loaded_gib": 44.7,
    "vm_lck_loaded_gib": 26.8,
    "mlocked_loaded_delta_gib": 26.8,
    "mem_available_loaded_drop_gib": 73.1,
    "active_file_loaded_delta_gib": 10.0,
    "inactive_file_loaded_delta_gib": 5.0,
}
SMALL = {
    "gtt_loaded_delta_gib": 21.6,
    "rss_file_loaded_gib": 83.2,
    "rss_anon_loaded_gib": 2.9,
    "rss_loaded_gib": 87.1,
    "vm_lck_loaded_gib": 26.8,
    "mlocked_loaded_delta_gib": 26.8,
    "mem_available_loaded_drop_gib": 52.5,
    "active_file_loaded_delta_gib": 30.0,
    "inactive_file_loaded_delta_gib": 8.0,
}


def write_dir(summaries, rows=()):
    d = tempfile.mkdtemp()
    for name, summary in summaries.items():
        with open(os.path.join(d, name), "w") as fh:
            json.dump(summary, fh)
    path = os.path.join(d, "rows.jsonl")
    with open(path, "w") as fh:
        for row in rows:
            fh.write(json.dumps(row) + "\n")
    return d, path


def run(argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        t.main(argv)
    return out.getvalue()


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def table_rows(text, first_header):
    """Rows (as cell lists) of the table whose header starts with `first_header`."""
    lines = text.splitlines()
    start = next(i for i, l in enumerate(lines) if cells(l)[0].startswith(first_header))
    body = []
    for line in lines[start + 2 :]:
        if not line.startswith("|"):
            break
        body.append(cells(line))
    return body


class SplitTest(unittest.TestCase):
    def test_split_arithmetic(self):
        s = t.freed_split(REF, SMALL)
        self.assertEqual(s["freed_gtt"], 40.0)
        self.assertEqual(s["d_rss_file"], 41.7)
        self.assertEqual(s["d_vm_lck"], 0.0)
        self.assertEqual(s["d_rss_anon"], 1.0)
        self.assertEqual(s["d_mlocked"], 0.0)
        self.assertEqual(s["d_active_file"], 20.0)
        self.assertEqual(s["d_inactive_file"], 3.0)
        self.assertEqual(s["d_mem_available_drop"], -20.6)
        self.assertEqual(s["locked"], 0.0)
        self.assertEqual(s["reclaimable"], 41.7)
        self.assertEqual(s["anon"], 1.0)
        self.assertEqual(s["rest"], -2.7)

    def test_sum_check_equals_freed(self):
        s = t.freed_split(REF, SMALL)
        self.assertEqual(s["check"], s["freed_gtt"])

    def test_locked_difference_enters_split(self):
        other = dict(SMALL, vm_lck_loaded_gib=20.8)
        s = t.freed_split(REF, other)
        self.assertEqual(s["locked"], -6.0)
        self.assertEqual(s["reclaimable"], 47.7)
        self.assertEqual(s["rest"], -2.7)
        self.assertEqual(s["check"], s["freed_gtt"])

    def test_missing_active_inactive_is_none_but_split_survives(self):
        old_ref = {k: v for k, v in REF.items() if "active" not in k}
        old_small = dict(SMALL, active_file_loaded_delta_gib=None)
        s = t.freed_split(old_ref, old_small)
        self.assertIsNone(s["d_active_file"])
        self.assertIsNone(s["d_inactive_file"])
        self.assertEqual(s["rest"], -2.7)

    def test_missing_component_makes_rest_and_check_none(self):
        s = t.freed_split(REF, dict(SMALL, rss_anon_loaded_gib=None))
        self.assertIsNone(s["anon"])
        self.assertIsNone(s["rest"])
        self.assertIsNone(s["check"])
        self.assertEqual(s["reclaimable"], 41.7)


class FootprintCliTest(unittest.TestCase):
    def setUp(self):
        self.dir, _ = write_dir(
            {
                "foot-base-foot20000.json": REF,
                "foot-base-foot5000.json": SMALL,
            }
        )

    def test_old_series_without_active_inactive_keys_does_not_crash(self):
        old = {k: v for k, v in REF.items() if "active" not in k}
        d, _ = write_dir({"foot-base-foot20000.json": old, "foot-base-foot5000.json": old})
        out = run(["footprint", "--dir", d, "--sizes", "20000,5000"])
        self.assertIn("unmeasured", out)

    def test_footprint_row_values(self):
        out = run(["footprint", "--dir", self.dir, "--sizes", "20000,5000"])
        rows = table_rows(out, "--expert-cache")
        by_size = {r[0]: r for r in rows}
        self.assertIn("61.6", by_size["20000"])
        self.assertIn("44.7 (41.5 / 1.9)", by_size["20000"])
        self.assertIn("106.3", by_size["20000"])  # GTT + RSS
        self.assertIn("+10.0", by_size["20000"])  # signed Active(file) delta

    def test_missing_size_file_is_unmeasured(self):
        out = run(["footprint", "--dir", self.dir, "--sizes", "20000,10000,5000"])
        row = {r[0]: r for r in table_rows(out, "--expert-cache")}["10000"]
        self.assertTrue(all(c == "unmeasured" for c in row[1:]))

    def test_freed_tables(self):
        out = run(["footprint", "--dir", self.dir, "--sizes", "20000,5000"])
        raw = {r[0]: r for r in table_rows(out, "freed against")}["5000"]
        self.assertIn("+40.0", raw)
        self.assertIn("+41.7", raw)
        self.assertIn("+20.0", raw)
        self.assertIn("-20.6", raw)
        derived = {r[0]: r for r in table_rows(out, "split of freed GTT")}["5000"]
        self.assertEqual(derived[1:], ["+40.0", "+0.0", "+41.7", "+1.0", "-2.7", "+40.0"])

    def test_null_renders_unmeasured_in_freed_table(self):
        d, _ = write_dir(
            {
                "foot-base-foot20000.json": REF,
                "foot-base-foot5000.json": dict(SMALL, rss_file_loaded_gib=None),
            }
        )
        out = run(["footprint", "--dir", d, "--sizes", "20000,5000"])
        derived = {r[0]: r for r in table_rows(out, "split of freed GTT")}["5000"]
        self.assertEqual(derived[3], "unmeasured")  # reclaimable
        self.assertEqual(derived[5], "unmeasured")  # rest
        self.assertEqual(derived[6], "unmeasured")  # sum check


class ReloadCliTest(unittest.TestCase):
    def test_reload_rows(self):
        summary = {
            "gtt_peak_delta_gib": 21.6,
            "rss_peak_gib": 87.5,
            "mem_available_min_drop_gib": 53.0,
        }
        rows = [
            {
                "label": "base-reload5000-cold",
                "load_s": 40.2,
                "cached_kb_at_start": 2 * 2**20,
                "cached_kb_before_evict_pre": 50 * 2**20,
                "cached_kb_after_evict_pre": 3 * 2**20,
                "firsttoken": {"ttft_s": 1.5, "since_spawn_s": 42.0},
            },
            {
                "label": "base-reload5000-warm",
                "load_s": 9.0,
                "cached_kb_at_start": 50 * 2**20,
                "firsttoken": {"ttft_s": None, "since_spawn_s": 11.0},
            },
        ]
        d, path = write_dir(
            {
                "foot-base-reload5000-cold.json": summary,
                "foot-base-reload5000-warm.json": dict(summary, rss_peak_gib=None),
            },
            rows,
        )
        out = run(["reload", "--dir", d, "--rows", path])
        by_key = {(r[0], r[1]): r for r in table_rows(out, "--expert-cache")}
        cold = by_key[("5000", "cold")]
        self.assertEqual(
            cold[2:],
            ["42.0", "40.2", "1.5", "21.6", "87.5", "53.0", "2.0", "50.0", "3.0"],
        )
        warm = by_key[("5000", "warm")]
        self.assertEqual(warm[2:5], ["11.0", "9.0", "unmeasured"])  # ttft null
        self.assertEqual(warm[6], "unmeasured")  # rss peak null
        self.assertEqual(warm[8], "50.0")  # Cached at start
        self.assertEqual(warm[9:], ["-", "-"])  # no pre-eviction on warm rows

    def test_missing_row_and_summary_is_unmeasured(self):
        d, path = write_dir({"foot-base-reload5000-cold.json": {}}, [])
        out = run(["reload", "--dir", d, "--rows", path])
        cold = {(r[0], r[1]): r for r in table_rows(out, "--expert-cache")}[("5000", "cold")]
        self.assertTrue(all(c == "unmeasured" for c in cold[2:]))


if __name__ == "__main__":
    unittest.main()
