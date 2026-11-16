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
        header = next(cells(l) for l in out.splitlines() if cells(l)[0] == "split of freed GTT (GiB)")
        self.assertEqual(header[-1], "parts sum to freed (by construction)")

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
            ["42.0", "40.2", "1.5", "21.6", "87.5", "53.0", "2.0", "47.0"],  # 50 GiB before - 3 GiB after = 47.0 dropped
        )
        warm = by_key[("5000", "warm")]
        self.assertEqual(warm[2:5], ["11.0", "9.0", "unmeasured"])  # ttft null
        self.assertEqual(warm[6], "unmeasured")  # rss peak null
        self.assertEqual(warm[8], "50.0")  # Cached at start
        self.assertEqual(warm[9:], ["-"])  # no pre-eviction on warm rows

    def test_drop_column_header_and_small_drop(self):
        rows = [
            {
                "label": "base-reload5000-cold",
                "cached_kb_at_start": 50 * 2**20,
                "cached_kb_before_evict_pre": 50 * 2**20,
                "cached_kb_after_evict_pre": int(49.5 * 2**20),  # DONTNEED did not take: really warm
            },
        ]
        d, path = write_dir({"foot-base-reload5000-cold.json": {}}, rows)
        out = run(["reload", "--dir", d, "--rows", path])
        header = next(cells(l) for l in out.splitlines() if cells(l)[0] == "--expert-cache")
        self.assertEqual(header[-1], "page cache dropped (GiB)")
        self.assertNotIn("Cached before pre-eviction", header)
        cold = {(r[0], r[1]): r for r in table_rows(out, "--expert-cache")}[("5000", "cold")]
        self.assertEqual(cold[-1], "0.5")

    def test_drop_unmeasured_when_either_side_null(self):
        base = {"label": "base-reload5000-cold", "cached_kb_at_start": 2**20}
        for missing in ("cached_kb_before_evict_pre", "cached_kb_after_evict_pre"):
            row: dict[str, object] = dict(base, cached_kb_before_evict_pre=2**20, cached_kb_after_evict_pre=2**19)
            row[missing] = None
            d, path = write_dir({"foot-base-reload5000-cold.json": {}}, [row])
            out = run(["reload", "--dir", d, "--rows", path])
            cold = {(r[0], r[1]): r for r in table_rows(out, "--expert-cache")}[("5000", "cold")]
            self.assertEqual(cold[-1], "unmeasured")

    def test_missing_row_and_summary_is_unmeasured(self):
        d, path = write_dir({"foot-base-reload5000-cold.json": {}}, [])
        out = run(["reload", "--dir", d, "--rows", path])
        cold = {(r[0], r[1]): r for r in table_rows(out, "--expert-cache")}[("5000", "cold")]
        self.assertTrue(all(c == "unmeasured" for c in cold[2:]))


def stat(mean, stdev=None):
    return {"mean": mean, "stdev": stdev}


def speed_a(prefill4k, decode32k_acc, **replay):
    return {
        "prefill4k": {"prefill_tps": stat(prefill4k)},
        "decode512": {"decode_tps": stat(31.84, 3.66), "acceptance": 0.6234},
        "decode32k": {"prefill_tps": stat(700.26), "decode_tps": stat(20.04, 1.96), "acceptance": decode32k_acc},
        "replay": dict({"normalized_total_s": 120.46, "ttft_total_s": 30.04}, **replay),
        "load_s": 55.62,
        "loadavg_max": 27.6,
    }


SPEED_ROWS = [
    dict(speed_a(812.34, 0.5), label="base-def-A"),
    {
        "label": "base-def-B",
        "decode128k": {"prefill_tps": stat(310.51), "decode_tps": stat(9.96, 0.44), "acceptance": 0.41234},
        "loadavg_max": 34.9,
    },
    dict(speed_a(1.0, 0.1), label="base-def-A-c5000"),  # superseded by the re-run below
    dict(speed_a(900.1, None, normalized_incomplete=True, normalized_total_s=99.94), label="base-def-A-c5000"),
]


class SpeedCliTest(unittest.TestCase):
    def setUp(self):
        _, path = write_dir({}, SPEED_ROWS)
        out = run(["speed", "--rows", path, "--sizes", "20000,10000,5000"])
        self.header = next(cells(l) for l in out.splitlines())
        self.table = {r[0]: r[1:] for r in table_rows(out, "")}

    def test_header(self):
        self.assertEqual(
            self.header, ["", "--expert-cache 20000", "--expert-cache 10000", "--expert-cache 5000"]
        )

    def test_full_column_from_a_and_b_rows(self):
        col = [r[0] for r in self.table.values()]
        self.assertEqual(
            col,
            [
                "812.3",
                "700.3",
                "310.5",
                "31.8 ± 3.7",
                "20.0 ± 2.0",
                "10.0 ± 0.4",
                "0.623 / 0.500 / 0.412",
                "120.5",
                "30.0",
                "55.6",
                "27.6 / 34.9",
            ],
        )

    def test_last_duplicate_wins_and_missing_b_row_is_unmeasured(self):
        col = [r[2] for r in self.table.values()]
        self.assertEqual(
            col,
            [
                "900.1",
                "700.3",
                "unmeasured",  # no B row
                "31.8 ± 3.7",
                "20.0 ± 2.0",
                "unmeasured ± unmeasured",
                "0.623 / unmeasured / unmeasured",  # null acceptance, no B row
                "99.9 (incomplete)",
                "30.0",
                "55.6",
                "27.6 / unmeasured",
            ],
        )

    def test_size_without_rows_is_all_unmeasured(self):
        for cell in (r[1] for r in self.table.values()):
            self.assertEqual(set(cell.replace("±", "/").split(" / ")), {"unmeasured"})

    def test_null_stdev_is_unmeasured_part(self):
        _, path = write_dir({}, [{"label": "base-def-A", "decode512": {"decode_tps": stat(31.84)}}])
        out = run(["speed", "--rows", path, "--sizes", "20000"])
        self.assertEqual(table_rows(out, "")[3][1], "31.8 ± unmeasured")


if __name__ == "__main__":
    unittest.main()
