"""Offline tests for tasks.py: mock tools, scorers, needle builder, and the runner against a scripted fake server."""
import http.server
import json
import os
import contextlib
import io
import re
import shutil
import socket
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tables  # noqa: E402
import tasks  # noqa: E402

tasks.VERBOSE = False

BY_ID = {t.id: t for t in tasks.TASKS}
TOOL_IDS = [t.id for t in tasks.TASKS if t.kind == "tool"]
CODE_IDS = [t.id for t in tasks.TASKS if t.kind == "code"]
LC_IDS = [t.id for t in tasks.TASKS if t.kind == "lc"]

TOOL_SCRIPTS = {
    "tool_chain": ([("read_file", {"path": "README.md"}), ("read_file", {"path": "app/main.py"}),
                    ("read_file", {"path": "conf/server.toml"})], "The listener port is 8472."),
    "tool_grep_read": ([("grep", {"pattern": "E4417", "path": "src"}),
                        ("read_file", {"path": "src/net/client.py"})],
                       "send_frame raises E4417 and RETRY_CAP in that file is 23."),
    "tool_list_sum": ([("list_dir", {"path": "data/shards"}), ("read_file", {"path": "data/shards/shard_a.meta"}),
                       ("read_file", {"path": "data/shards/shard_b.meta"})], "The total is 3583."),
    "tool_edit_tests": ([("run_tests", {"target": "config"}), ("read_file", {"path": "config/app.cfg"}),
                         ("edit_file", {"path": "config/app.cfg", "old_str": "timeout_ms = 500",
                                        "new_str": "timeout_ms = 2500"}),
                         ("run_tests", {"target": "config"}),
                         ("edit_file", {"path": "config/app.cfg", "old_str": "retries = 0", "new_str": "retries = 3"}),
                         ("run_tests", {"target": "config"}),
                         ("edit_file", {"path": "config/app.cfg", "old_str": 'backoff = "linear"',
                                        "new_str": 'backoff = "exponential"'}),
                         ("run_tests", {"target": "config"})], "The tests pass now."),
    "tool_recover": ([("read_file", {"path": "src/config/settings.yaml"}),
                      ("read_file", {"path": "src/config/settings.yml"})], "retry_limit is 14."),
    "tool_ranges": ([("read_file", {"path": "logs/build.log", "start_line": 84, "end_line": 90})],
                    "The error code is ERR-70318."),
}

GOOD_CODE = {
    "code_bugfix_moving_average": '''def moving_average(xs, k):
    if k < 1:
        raise ValueError("k must be >= 1")
    return [sum(xs[i:i + k]) / k for i in range(len(xs) - k + 1)]
''',
    "code_refactor_duplicates": '''from collections import Counter


def duplicates(items):
    counts = Counter(items)
    seen = set()
    out = []
    for x in items:
        if counts[x] > 1 and x not in seen:
            seen.add(x)
            out.append(x)
    return out
''',
    "code_parse_duration": '''import re


def parse_duration(s):
    m = re.fullmatch(r"(?:(\\d+)d)?(?:(\\d+)h)?(?:(\\d+)m)?(?:(\\d+)s)?", s)
    if not s or m is None:
        raise ValueError(s)
    d, h, mi, sec = (int(g or 0) for g in m.groups())
    return d * 86400 + h * 3600 + mi * 60 + sec
''',
    "code_merge_intervals": '''def merge_intervals(intervals):
    out = []
    for a, b in sorted(tuple(i) for i in intervals):
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out
''',
    "code_split_csv_line": '''def split_csv_line(line):
    fields, cur, i, quoted = [], [], 0, False
    while i < len(line):
        ch = line[i]
        if quoted:
            if ch == '"':
                if line[i + 1:i + 2] == '"':
                    cur.append('"')
                    i += 1
                else:
                    quoted = False
            else:
                cur.append(ch)
        elif ch == '"':
            quoted = True
        elif ch == ",":
            fields.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    fields.append("".join(cur))
    return fields
''',
}

BAD_CODE = {
    "code_bugfix_moving_average": '''def moving_average(xs, k):
    out = []
    for i in range(len(xs) - k):
        out.append(sum(xs[i:i + k]) / k)
    return out
''',
    "code_refactor_duplicates": '''def duplicates(items):
    out = []
    for x in items:
        if items.count(x) > 1 and x not in out:
            out.append(x)
    return out
''',
    "code_parse_duration": '''def parse_duration(s):
    return int(s[:-1])
''',
    "code_merge_intervals": '''def merge_intervals(intervals):
    out = []
    for a, b in sorted(tuple(i) for i in intervals):
        if out and a < out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out
''',
    "code_split_csv_line": '''def split_csv_line(line):
    return line.split(",")
''',
}


def fake_cache():
    text = "".join(f"line {i} lorem ipsum dolor sit amet consectetur {i * 7919 % 10007}\n" for i in range(4000))
    return {"slices": {"512": text[:100], "130000": text}, "slice_tokens": {"130000": 130000}}


def replay(script, repo):
    for name, args in script:
        repo.call(name, json.dumps(args))


class RepoTools(unittest.TestCase):
    def repo(self, tid):
        return tasks.Repo(BY_ID[tid].spec["files"], BY_ID[tid].spec["tests"])

    def test_read_file_and_missing_path_lists_nearby(self):
        r = self.repo("tool_recover")
        out = r.call("read_file", json.dumps({"path": "src/config/settings.yaml"}))
        self.assertTrue(out.startswith("error: no such file"))
        self.assertIn("src/config/settings.yml", out)
        self.assertNotIn("retry_limit: 14", out)
        self.assertEqual(r.reads, set())
        self.assertIn("retry_limit: 14", r.call("read_file", json.dumps({"path": "src/config/settings.yml"})))
        self.assertEqual(r.reads, {"src/config/settings.yml"})

    def test_path_normalisation_and_absolute_rejected(self):
        r = self.repo("tool_chain")
        self.assertIn("app/main.py", r.call("read_file", json.dumps({"path": "./README.md"})))
        self.assertTrue(r.call("read_file", json.dumps({"path": "/README.md"})).startswith("error"))

    def test_long_file_needs_a_valid_range(self):
        r = self.repo("tool_ranges")
        whole = r.call("read_file", json.dumps({"path": "logs/build.log"}))
        self.assertTrue(whole.startswith("error") and "start_line" in whole)
        self.assertTrue(r.call("read_file", json.dumps({"path": "logs/build.log", "start_line": "84",
                                                        "end_line": "90"})).startswith("error"))
        self.assertTrue(r.call("read_file", json.dumps({"path": "logs/build.log", "start_line": 1,
                                                        "end_line": 90})).startswith("error"))
        self.assertTrue(r.call("read_file", json.dumps({"path": "logs/build.log", "start_line": 90,
                                                        "end_line": 84})).startswith("error"))
        out = r.call("read_file", json.dumps({"path": "logs/build.log", "start_line": 84, "end_line": 90}))
        self.assertEqual(len(out.splitlines()), 7)
        self.assertIn("ERR-70318", out)

    def test_schema_violations(self):
        r = self.repo("tool_chain")
        self.assertIn("unknown argument", r.call("read_file", json.dumps({"path": "README.md", "mode": "r"})))
        self.assertIn("missing required argument 'path'", r.call("read_file", json.dumps({})))
        self.assertIn("must be a string", r.call("read_file", json.dumps({"path": 5})))
        self.assertIn("not valid JSON", r.call("read_file", "{path: README.md"))
        self.assertIn("JSON object", r.call("read_file", "[1]"))
        self.assertIn("unknown tool", r.call("delete_file", json.dumps({"path": "README.md"})))
        self.assertIn("missing required argument 'path'", r.call("grep", json.dumps({"pattern": "x"})))

    def test_grep(self):
        r = self.repo("tool_grep_read")
        out = r.call("grep", json.dumps({"pattern": "E4417", "path": "src"}))
        self.assertIn("src/net/client.py:", out)
        self.assertNotIn("docs/", out)
        self.assertEqual(r.call("grep", json.dumps({"pattern": "zzzz", "path": "src"})), "no matches")
        self.assertTrue(r.call("grep", json.dumps({"pattern": "(", "path": "src"})).startswith("error: invalid"))
        self.assertTrue(r.call("grep", json.dumps({"pattern": "x", "path": "nope"})).startswith("error"))

    def test_grep_deeply_nested_pattern_is_an_error_result(self):
        r = self.repo("tool_grep_read")
        out = r.call("grep", json.dumps({"pattern": "(" * 500 + ")" * 500, "path": "src"}))
        self.assertTrue(out.startswith("error: invalid regex"))

    def test_catastrophic_regex_times_out(self):
        r = tasks.Repo({"a.txt": "a" * 40 + "\n"}, {})
        t0 = time.time()
        out = r.call("grep", json.dumps({"pattern": "(a|a)*$x", "path": "a.txt"}))
        self.assertEqual(out, "error: regex timed out")
        self.assertLess(time.time() - t0, 4)

    def test_grep_reports_hits_with_line_numbers(self):
        r = tasks.Repo({"a.txt": "one\ntwo\nthree\n", "b.txt": "two\n"}, {})
        self.assertEqual(r.call("grep", json.dumps({"pattern": "^t", "path": "."})), "a.txt:2:two\na.txt:3:three\nb.txt:1:two")

    def test_list_dir(self):
        r = self.repo("tool_list_sum")
        out = r.call("list_dir", json.dumps({"path": "data/shards"}))
        self.assertEqual(out.splitlines(), ["notes.txt", "shard_a.meta", "shard_b.meta", "shard_c.bak"])
        self.assertIn("data/", r.call("list_dir", json.dumps({"path": "."})).splitlines())
        self.assertTrue(r.call("list_dir", json.dumps({"path": "data/shard"})).startswith("error"))

    def test_edit_file_needs_exactly_one_match(self):
        r = tasks.Repo({"a.txt": "x = 1\nx = 1\ny = 2\n"}, {})
        self.assertIn("matches 2 times", r.call("edit_file", json.dumps({"path": "a.txt", "old_str": "x = 1",
                                                                          "new_str": "x = 3"})))
        self.assertIn("not found", r.call("edit_file", json.dumps({"path": "a.txt", "old_str": "z", "new_str": "q"})))
        self.assertTrue(r.call("edit_file", json.dumps({"path": "a.txt", "old_str": "y = 2",
                                                         "new_str": "y = 5"})).startswith("ok"))
        self.assertEqual(r.files["a.txt"], "x = 1\nx = 1\ny = 5\n")
        self.assertTrue(r.call("edit_file", json.dumps({"path": "b.txt", "old_str": "a",
                                                         "new_str": "b"})).startswith("error"))

    def test_run_tests_reports_the_first_failure_until_green(self):
        r = self.repo("tool_edit_tests")
        first = r.call("run_tests", json.dumps({"target": "config"}))
        self.assertIn("FAIL", first)
        self.assertIn("timeout_ms", first)
        self.assertNotIn("retries", first)
        r.call("edit_file", json.dumps({"path": "config/app.cfg", "old_str": "timeout_ms = 500",
                                        "new_str": "timeout_ms = 2000"}))
        self.assertIn("retries must be exactly 3", r.call("run_tests", json.dumps({"target": "config"})))
        self.assertEqual(r.test_runs, [False, False])
        self.assertIn("unknown target", r.call("run_tests", json.dumps({"target": "unit"})))

    def test_run_tests_green_after_the_known_good_edits(self):
        r = self.repo("tool_edit_tests")
        replay(TOOL_SCRIPTS["tool_edit_tests"][0], r)
        self.assertEqual(r.test_runs, [False, False, False, True])
        self.assertTrue(r.call("run_tests", json.dumps({"target": "config"})).startswith("PASS"))


class ToolTaskChecks(unittest.TestCase):
    def test_every_tool_task_accepts_its_good_transcript(self):
        for tid in TOOL_IDS:
            spec = BY_ID[tid].spec
            r = tasks.Repo(spec["files"], spec["tests"])
            script, final = TOOL_SCRIPTS[tid]
            replay(script, r)
            ok, note = spec["check"](final, r)
            self.assertTrue(ok, f"{tid}: {note}")

    def test_every_tool_task_rejects_doing_nothing_and_a_guess(self):
        for tid in TOOL_IDS:
            spec = BY_ID[tid].spec
            for final in ("", "I could not find it.", "The answer is 42."):
                r = tasks.Repo(spec["files"], spec["tests"])
                self.assertFalse(spec["check"](final, r)[0], f"{tid}: {final!r}")

    def test_answer_without_the_required_tool_use_fails(self):
        for tid in ("tool_recover", "tool_edit_tests"):
            spec = BY_ID[tid].spec
            r = tasks.Repo(spec["files"], spec["tests"])
            self.assertFalse(spec["check"](TOOL_SCRIPTS[tid][1], r)[0], tid)

    def test_decoy_values_fail(self):
        spec = BY_ID["tool_chain"].spec
        r = tasks.Repo(spec["files"], spec["tests"])
        replay(TOOL_SCRIPTS["tool_chain"][0], r)
        self.assertFalse(spec["check"]("The listener port is 9913.", r)[0])
        spec = BY_ID["tool_list_sum"].spec
        r = tasks.Repo(spec["files"], spec["tests"])
        self.assertFalse(spec["check"]("The total is 4582.", r)[0])

    def test_edit_task_requires_a_final_green_run_and_untouched_name(self):
        spec = BY_ID["tool_edit_tests"].spec
        r = tasks.Repo(spec["files"], spec["tests"])
        replay(TOOL_SCRIPTS["tool_edit_tests"][0][:-1], r)  # state is green but tests were not re-run
        self.assertFalse(spec["check"]("done", r)[0])
        r.call("run_tests", json.dumps({"target": "config"}))
        self.assertTrue(spec["check"]("done", r)[0])
        r.files["config/app.cfg"] = r.files["config/app.cfg"].replace('"svc"', '"other"')
        self.assertFalse(spec["check"]("done", r)[0])


class CodeScoring(unittest.TestCase):
    def test_good_solutions_pass_and_bad_ones_fail(self):
        for tid in CODE_IDS:
            spec = BY_ID[tid].spec
            self.assertTrue(tasks.score_code(spec, f"```python\n{GOOD_CODE[tid]}```", timeout=10)[0], tid)
            self.assertFalse(tasks.score_code(spec, f"```python\n{BAD_CODE[tid]}```", timeout=5)[0], tid)

    def test_one_bug_fix_and_one_refactor(self):
        self.assertIn("code_bugfix_moving_average", CODE_IDS)
        self.assertIn("code_refactor_duplicates", CODE_IDS)
        self.assertEqual(len(CODE_IDS), 5)

    def test_infinite_loop_times_out(self):
        spec = BY_ID["code_merge_intervals"].spec
        t0 = time.time()
        ok, note = tasks.score_code(spec, "```python\ndef merge_intervals(x):\n    while True:\n        pass\n```", timeout=2)
        self.assertFalse(ok)
        self.assertIn("timeout", note)
        self.assertLess(time.time() - t0, 8)

    def test_memory_hog_and_syntax_error_fail(self):
        spec = BY_ID["code_merge_intervals"].spec
        self.assertFalse(tasks.score_code(spec, "def merge_intervals(x):\n    return bytearray(8 << 30)\n", timeout=5)[0])
        self.assertFalse(tasks.score_code(spec, "def merge_intervals(x) return x", timeout=5)[0])

    def test_hidden_asserts_cannot_be_faked_by_exiting_early(self):
        spec = BY_ID["code_merge_intervals"].spec
        self.assertFalse(tasks.score_code(spec, "import sys\nsys.exit(0)\n", timeout=5)[0])

    def test_extraction(self):
        good = GOOD_CODE["code_merge_intervals"]
        self.assertEqual(tasks.extract_code(f"Sure:\n```python\n{good}```\nDone.", "merge_intervals"), good)
        self.assertEqual(tasks.extract_code(good, "merge_intervals"), good)
        two = f"```python\nx = 1\n```\n```python\n{good}```"
        self.assertEqual(tasks.extract_code(two, "merge_intervals"), good)
        self.assertEqual(tasks.extract_code(f"```\n{good}```", "merge_intervals"), good)
        self.assertEqual(tasks.extract_code(f"```python\n{good}", "merge_intervals").strip(), good.strip())

    def test_fence_language_tag_is_optional_and_case_insensitive(self):
        good = GOOD_CODE["code_merge_intervals"]
        for tag in ("Python", "PYTHON", "python3", "py", ""):
            self.assertEqual(tasks.extract_code(f"```{tag}\n{good}```", "merge_intervals"), good, tag)
            self.assertTrue(tasks.score_code(BY_ID["code_merge_intervals"].spec, f"```{tag}\n{good}```")[0], tag)

    def test_main_demo_in_the_reply_is_not_executed(self):
        spec = BY_ID["code_merge_intervals"].spec
        demo = GOOD_CODE["code_merge_intervals"] + '\n\nif __name__ == "__main__":\n    input("press enter")\n'
        self.assertTrue(tasks.score_code(spec, f"```python\n{demo}```")[0])

    def test_hidden_asserts_run_against_the_solution_as_a_module(self):
        spec = BY_ID["code_parse_duration"].spec
        ok, note = tasks.score_code(spec, f"```python\n{GOOD_CODE['code_parse_duration']}```")
        self.assertTrue(ok, note)
        self.assertFalse(tasks.score_code(spec, "```python\ndef parse_duration(s):\n    return 0\n```")[0])

    def test_refuses_to_run_without_a_sandbox(self):
        with mock.patch.object(tasks, "sandbox_kind", return_value="none"), \
                mock.patch.dict(os.environ), self.assertRaisesRegex(RuntimeError, "bwrap sandbox unusable"):
            os.environ.pop("TASKS_UNSANDBOXED", None)
            tasks.run_hidden("print(1)", "")

    def test_unsandboxed_override_runs_the_code(self):
        with mock.patch.object(tasks, "sandbox_kind", return_value="none"), \
                mock.patch.dict(os.environ, {"TASKS_UNSANDBOXED": "1"}):
            self.assertTrue(tasks.run_hidden("x = 1", "assert x == 1")[0])

    def test_timeout_survives_a_group_that_is_already_gone(self):
        real = os.killpg

        def killpg_then_vanish(pgid, sig):
            real(pgid, sig)
            raise ProcessLookupError

        with mock.patch.object(tasks.os, "killpg", killpg_then_vanish):
            ok, note = tasks.run_hidden("while True:\n    pass\n", "", timeout=1)
        self.assertFalse(ok)
        self.assertIn("timeout", note)

    def test_huge_output_fails_and_only_a_tail_is_kept(self):
        ok, note = tasks.run_hidden("while True:\n    print('x' * 1000)\n", "", timeout=10)
        self.assertFalse(ok)
        self.assertLess(len(note), 400)

    def test_large_output_before_the_token_still_passes(self):
        self.assertTrue(tasks.run_hidden("print('x' * 2000000)", "")[0])

    def test_argv_is_size_capped_and_scoped_when_the_cgroup_is_usable(self):
        with mock.patch.object(tasks, "limits_kind", return_value="cgroup"):
            argv = tasks.launch_argv("/work", "/usr/bin/bwrap", "/usr/bin/systemd-run")
        self.assertEqual(argv[0], "/usr/bin/systemd-run")
        for prop in ("TasksMax=64", "MemoryMax=3G", "MemorySwapMax=0"):
            self.assertIn(prop, argv)
        self.assertEqual(argv.index("--tmpfs") - 2, argv.index("--size"))
        self.assertEqual(argv[argv.index("--size") + 1], str(64 << 20))
        self.assertIn("--clearenv", argv)
        self.assertLess(argv.index("/usr/bin/systemd-run"), argv.index("/usr/bin/bwrap"))
        with mock.patch.object(tasks, "limits_kind", return_value="rlimit"):
            self.assertEqual(tasks.launch_argv("/work", "/usr/bin/bwrap", "/usr/bin/systemd-run")[0], "/usr/bin/bwrap")

    @unittest.skipUnless(tasks.sandbox_kind() == "bwrap", "bwrap not usable")
    def test_tmp_is_size_capped(self):
        code = ("for i in range(10):\n    with open(f'/tmp/f{i}', 'wb') as f:\n        f.write(b'x' * (7 << 20))\n")
        self.assertFalse(tasks.run_hidden(code, "")[0])

    @unittest.skipUnless(tasks.sandbox_kind() == "bwrap" and tasks.limits_kind() == "cgroup", "cgroup scope not usable")
    def test_process_count_is_capped(self):
        code = ("import os, time\nfor i in range(200):\n    if os.fork() == 0:\n        time.sleep(3)\n"
                "        os._exit(0)\n")
        ok, note = tasks.run_hidden(code, "", timeout=10)
        self.assertFalse(ok)
        self.assertIn("BlockingIOError", note)

    def test_sandbox_has_no_network(self):
        if tasks.sandbox_kind() != "bwrap":
            if shutil.which("bwrap"):
                self.fail("bwrap is on PATH but unusable")
            self.skipTest("bwrap is not installed")
        probe = ("import socket\ns = socket.socket()\ns.settimeout(2)\n"
                 "try:\n    s.connect(('93.184.216.34', 80))\nexcept OSError:\n    pass\n"
                 "else:\n    raise SystemExit('connected')\n")
        self.assertTrue(tasks.run_hidden(probe, "", timeout=10)[0])

    def test_sandbox_cannot_reach_the_nix_daemon_socket(self):
        if tasks.sandbox_kind() != "bwrap":
            if shutil.which("bwrap"):
                self.fail("bwrap is on PATH but unusable")
            self.skipTest("bwrap is not installed")
        probe = ("import socket\ns = socket.socket(socket.AF_UNIX)\n"
                 "try:\n    s.connect('/nix/var/nix/daemon-socket/socket')\nexcept OSError:\n    pass\n"
                 "else:\n    raise SystemExit('connected')\n")
        self.assertTrue(tasks.run_hidden(probe, "", timeout=10)[0])


class Needles(unittest.TestCase):
    def test_depths_and_length(self):
        c = fake_cache()
        needles = [(0.1, "NEEDLE ONE"), (0.5, "NEEDLE TWO"), (0.9, "NEEDLE THREE")]
        text, depths = tasks.build_haystack(c, 64000, needles)
        base = c["slices"]["130000"]
        self.assertAlmostEqual(len(text) / len(base), 64000 / 130000, delta=0.01)
        self.assertEqual(len(depths), 3)
        for depth, sentence in needles:
            self.assertEqual(text.count(sentence), 1)
            self.assertAlmostEqual(depths[sentence], depth, delta=0.005)
            i = text.index(sentence)
            self.assertAlmostEqual(i / len(text), depth, delta=0.005)
            self.assertTrue(i == 0 or text[i - 1] == "\n")
            self.assertEqual(text[i + len(sentence)], "\n")

    def test_haystack_without_needles_is_a_corpus_prefix(self):
        c = fake_cache()
        text, _ = tasks.build_haystack(c, 120000, [])
        self.assertTrue(c["slices"]["130000"].startswith(text))
        self.assertAlmostEqual(len(text) / len(c["slices"]["130000"]), 120000 / 130000, delta=0.01)

    def test_haystack_is_capped_at_the_slice(self):
        c = fake_cache()
        text, _ = tasks.build_haystack(c, 500000, [])
        self.assertEqual(text, c["slices"]["130000"])

    def test_long_context_task_set(self):
        self.assertEqual(len(LC_IDS), 5)
        sizes = sorted(BY_ID[t].spec["tokens"] for t in LC_IDS)
        self.assertEqual(sizes, [64000] * 3 + [120000] * 2)
        depths = sorted(d for t in LC_IDS if BY_ID[t].spec["tokens"] == 64000 for d, *_ in BY_ID[t].spec["needles"])
        self.assertEqual(depths, [0.1, 0.5, 0.9])
        two = [t for t in LC_IDS if len(BY_ID[t].spec["needles"]) == 2]
        self.assertEqual(len(two), 1)
        self.assertEqual(BY_ID[two[0]].spec["tokens"], 120000)

    def test_needle_values_are_fixed_and_unique(self):
        values, names = [], []
        for t in LC_IDS:
            task_names = [n for _, n, _ in BY_ID[t].spec["needles"]] + [BY_ID[t].spec["decoy"][1]]
            self.assertEqual(len(set(task_names)), len(task_names), t)
            names += task_names
            values += [v for _, _, v in BY_ID[t].spec["needles"]] + [BY_ID[t].spec["decoy"][2]]
        self.assertEqual(len(set(values)), len(values))
        self.assertTrue(all(re.fullmatch(r"[A-Z]{4}-\d{4}", v) for v in values))
        self.assertEqual(tasks.derive("probe-tag"), tasks.derive("probe-tag"))
        self.assertEqual(tasks.derive("probe-tag"), ("kelp", "BABW-4328"))

    def test_scoring_is_exact_substring(self):
        spec = BY_ID[LC_IDS[0]].spec
        self.assertTrue(tasks.score_lc(spec, f"The code is {spec['expected']}.")[0])
        self.assertFalse(tasks.score_lc(spec, spec["expected"].lower())[0])
        self.assertFalse(tasks.score_lc(spec, spec["decoy"][2])[0])
        two = next(BY_ID[t].spec for t in LC_IDS if len(BY_ID[t].spec["needles"]) == 2)
        a, b = (v for _, _, v in two["needles"])
        self.assertEqual(two["expected"], f"{a}+{b}")
        self.assertTrue(tasks.score_lc(two, f"{a}+{b}")[0])
        ok, note = tasks.score_lc(two, f"{b}+{a}")
        self.assertFalse(ok)
        ok, note = tasks.score_lc(two, f"{a} and {b}")
        self.assertFalse(ok)
        self.assertIn("both values present", note)


class Stats(unittest.TestCase):
    def test_wilson(self):
        lo, hi = tasks.wilson(5, 10)
        self.assertAlmostEqual(lo, 0.2366, places=3)
        self.assertAlmostEqual(hi, 0.7634, places=3)
        lo, hi = tasks.wilson(10, 10)
        self.assertAlmostEqual(lo, 0.7225, places=3)
        self.assertEqual(hi, 1.0)
        lo, hi = tasks.wilson(0, 10)
        self.assertEqual(lo, 0.0)
        self.assertAlmostEqual(hi, 0.2775, places=3)
        self.assertEqual(tasks.wilson(0, 0), (0.0, 1.0))


class Tables(unittest.TestCase):
    @staticmethod
    def mode(passes, errors=0):
        return {"pass": passes, "errors": errors}

    @staticmethod
    def agg(k, n, errors=0):
        return {"passes": k, "n": n, "errors": errors, "wilson95": [0.1, 0.9]}

    def row(self, label, errors):
        modes = {"greedy": self.mode([True], 0), "sampled": self.mode([True, False, False], errors)}
        agg = {cat: {m: self.agg(1, 1, 0) if m == "greedy" else self.agg(1, 3, errors) for m in modes}
               for cat in ("tool", "code", "lc", "all")}
        return {"label": label, "tasks": {"tasks": {"t1": {"modes": modes}}, "aggregate": agg},
                "loadavg_start": 0.5, "load_flag": False, "gtt_peak_delta_bytes": 2 ** 30,
                "mem_after_load": {"gtt_delta_bytes": 2 ** 30}}

    def render(self, rows):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as f:
            f.write("".join(json.dumps(r) + "\n" for r in rows))
            f.flush()
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                tables.tasks(f.name)
        return out.getvalue()

    def test_error_count_is_shown_only_when_nonzero(self):
        out = self.render([self.row("tasks-iq4", 0), self.row("tasks-iq3", 2)])
        self.assertIn("| t1 | 1/1 | 1/1 | 1/3 | 1/3 err=2 |", out)
        self.assertIn("| all sampled | 1/3 (0.10-0.90) | 1/3 err=2 (0.10-0.90) |", out)
        self.assertNotIn("err=0", out)

    def test_wilson_interval_is_labelled_per_run(self):
        self.assertIn("per run", self.render([self.row("tasks-iq4", 0), self.row("tasks-iq3", 0)]))

    def test_rows_with_an_error_key_never_replace_a_good_row(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as f:
            f.write(json.dumps({"label": "tasks-iq4", "v": 1}) + "\n")
            f.write(json.dumps({"label": "tasks-iq4", "error": "refused"}) + "\n")
            f.write(json.dumps({"label": "tasks-iq3", "error": "refused"}) + "\n")
            f.flush()
            self.assertEqual(tables.rows(f.name), {"tasks-iq4": {"label": "tasks-iq4", "v": 1}})

    def test_a_row_without_error_counts_reads_as_zero(self):
        self.assertEqual(tables.cell({"greedy": {"pass": [True, False]}}, "greedy"), "1/2")


# ---- fake OpenAI server -------------------------------------------------------------------------

class FakeServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, respond):
        super().__init__(("127.0.0.1", 0), FakeHandler)
        self.respond = respond
        self.seen = []
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.shutdown()
        self.server_close()


class FakeHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.seen.append({k: v for k, v in body.items() if k != "messages"})
        result = self.server.respond(body)
        if isinstance(result, int):
            payload, code = b'{"error": "boom"}', result
        else:
            msg = {"role": "assistant", "content": None, **result}
            finish = "tool_calls" if msg.get("tool_calls") else "stop"
            payload = json.dumps({"choices": [{"index": 0, "message": msg, "finish_reason": finish}],
                                  "usage": {"prompt_tokens": 100, "completion_tokens": 10}}).encode()
            code = 200
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def user_text(body):
    return next(m["content"] for m in body["messages"] if m["role"] == "user")


def good_oracle(body):
    user = user_text(body)
    for tid in TOOL_IDS:
        if user == BY_ID[tid].spec["prompt"]:
            script, final = TOOL_SCRIPTS[tid]
            step = sum(m["role"] == "assistant" for m in body["messages"])
            if step < len(script):
                name, args = script[step]
                call = {"id": f"call_{step}", "type": "function",
                        "function": {"name": name, "arguments": json.dumps(args)}}
                return {"tool_calls": [call]}
            return {"content": final}
    for tid in CODE_IDS:
        if user == BY_ID[tid].spec["prompt"]:
            return {"content": f"```python\n{GOOD_CODE[tid]}```"}
    question = user.rsplit("\n---\n", 1)[1]
    codes = [re.search(rf"The access code for vault {name} is ([A-Z]{{4}}-\d{{4}})\.", user).group(1)
             for name in re.findall(r"access code for vault ([a-z]+)", question)]
    return {"content": "+".join(codes)}


def bad_oracle(body):
    user = user_text(body)
    if any(user == BY_ID[t].spec["prompt"] for t in CODE_IDS):
        return {"content": "```python\ndef nothing():\n    pass\n```"}
    return {"content": "I could not find it."}


def env(server):
    return types.SimpleNamespace(port=server.server_address[1], model="fake", engine="llama")


class FakeServerTests(unittest.TestCase):
    def run_against(self, respond, quick=False):
        server = FakeServer(respond)
        self.addCleanup(server.close)
        return tasks.run(env(server), fake_cache(), quick), server

    def test_known_good_transcripts_pass_every_task_in_both_modes(self):
        res, server = self.run_against(good_oracle)
        self.assertEqual(len(res["tasks"]), 16)
        for tid, t in res["tasks"].items():
            for mode, want in (("greedy", 1), ("sampled", 3 if tid in LC_IDS and BY_ID[tid].spec["tokens"] > 64000 else 5)):
                self.assertEqual(t["modes"][mode]["pass"], [True] * want, f"{tid} {mode}")
        for cat, n_tasks in (("tool", 6), ("code", 5), ("lc", 5)):
            for mode in ("greedy", "sampled"):
                agg = res["aggregate"][cat][mode]
                self.assertEqual(agg["passes"], agg["n"])
                self.assertEqual(agg["wilson95"][1], 1.0)
        self.assertEqual(res["aggregate"]["tool"]["greedy"]["n"], 6)
        self.assertEqual(res["aggregate"]["tool"]["sampled"]["n"], 30)
        self.assertEqual(res["aggregate"]["lc"]["sampled"]["n"], 3 * 5 + 2 * 3)
        self.assertEqual(res["aggregate"]["all"]["greedy"]["passes"], 16)
        self.assertEqual(res["limits"], tasks.limits_kind())
        for t in res["tasks"].values():
            self.assertEqual([m["errors"] for m in t["modes"].values()], [0, 0])
        self.assertEqual({a["errors"] for cat in res["aggregate"].values() for a in cat.values()}, {0})
        json.dumps(res)

    def test_requests_carry_the_harness_settings(self):
        res, server = self.run_against(good_oracle)
        greedy = [s for s in server.seen if s["temperature"] == 0]
        sampled = [s for s in server.seen if s["temperature"] == 0.7]
        self.assertTrue(greedy and sampled)
        self.assertEqual({s["seed"] for s in greedy}, {0})
        self.assertEqual({s["seed"] for s in sampled}, {1, 2, 3, 4, 5})
        for s in server.seen:
            self.assertEqual(s["chat_template_kwargs"], {"enable_thinking": False})
            self.assertEqual(s["model"], "fake")
        for s in sampled:
            self.assertEqual((s["top_p"], s["top_k"], s["presence_penalty"]), (0.8, 20, 1.5))
        self.assertTrue(any("tools" in s for s in server.seen))
        self.assertTrue(all("tools" not in s for s in server.seen if s.get("max_tokens") != tasks.MAX_TOKENS["tool"]))

    def test_wrong_answers_fail_every_task_and_record_the_output_head(self):
        res, _ = self.run_against(bad_oracle)
        for tid, t in res["tasks"].items():
            for mode in ("greedy", "sampled"):
                self.assertFalse(any(t["modes"][mode]["pass"]), f"{tid} {mode}")
                for run in t["modes"][mode]["runs"]:
                    self.assertLessEqual(len(run["fail_head"]), 300)
                    self.assertTrue(run["fail_head"])
        self.assertEqual(res["aggregate"]["all"]["greedy"]["passes"], 0)
        self.assertEqual(res["aggregate"]["all"]["sampled"]["passes"], 0)

    def test_quick_runs_one_task_per_category_and_one_sample(self):
        res, _ = self.run_against(good_oracle, quick=True)
        self.assertEqual(len(res["tasks"]), 3)
        self.assertEqual(sorted(t["category"] for t in res["tasks"].values()), ["code", "lc", "tool"])
        for t in res["tasks"].values():
            self.assertEqual(t["modes"]["greedy"]["pass"], [True])
            self.assertEqual(t["modes"]["sampled"]["pass"], [True])
        self.assertTrue(all(BY_ID[t].spec.get("tokens", 0) <= 64000 for t in res["tasks"]))

    def test_turn_limit_fails_the_run(self):
        loop = {"tool_calls": [{"id": "c", "type": "function",
                                "function": {"name": "list_dir", "arguments": json.dumps({"path": "."})}}]}
        server = FakeServer(lambda body: loop)
        self.addCleanup(server.close)
        run = tasks.run_task(env(server), fake_cache(), BY_ID["tool_chain"], {"temperature": 0, "seed": 0})
        self.assertFalse(run["pass"])
        self.assertEqual(run["turns"], tasks.MAX_TURNS)
        self.assertIn("turn limit", run["note"])
        self.assertEqual(len(server.seen), tasks.MAX_TURNS)

    def test_malformed_tool_arguments_are_returned_to_the_model(self):
        calls = []

        def respond(body):
            calls.append([m for m in body["messages"] if m["role"] == "tool"])
            if len(calls) == 1:
                return {"tool_calls": [{"id": "x1", "type": "function",
                                        "function": {"name": "read_file", "arguments": "{oops"}}]}
            return {"content": "The listener port is 1234."}

        server = FakeServer(respond)
        self.addCleanup(server.close)
        run = tasks.run_task(env(server), fake_cache(), BY_ID["tool_chain"], {"temperature": 0, "seed": 0})
        self.assertFalse(run["pass"])
        self.assertEqual(calls[1][0]["tool_call_id"], "x1")
        self.assertIn("not valid JSON", calls[1][0]["content"])

    def test_http_errors_fail_the_run_without_aborting_the_row(self):
        res, _ = self.run_against(lambda body: 500)
        run = res["tasks"]["tool_chain"]["modes"]["greedy"]["runs"][0]
        self.assertFalse(run["pass"])
        self.assertIn("HTTP 500", run["error"])
        self.assertEqual(res["aggregate"]["all"]["greedy"]["passes"], 0)
        self.assertEqual(res["tasks"]["tool_chain"]["modes"]["greedy"]["errors"], 1)
        self.assertEqual(res["tasks"]["tool_chain"]["modes"]["sampled"]["errors"], 5)
        self.assertEqual(res["aggregate"]["all"]["greedy"]["errors"], 16)
        self.assertEqual(res["aggregate"]["tool"]["sampled"]["errors"], 30)

    def test_wrong_answers_are_not_counted_as_errors(self):
        res, _ = self.run_against(bad_oracle)
        self.assertEqual(res["aggregate"]["all"]["greedy"]["errors"], 0)
        self.assertEqual(res["aggregate"]["all"]["sampled"]["errors"], 0)

    def test_connection_refused_raises(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        e = types.SimpleNamespace(port=port, model="fake", engine="llama")
        with self.assertRaises(tasks.ServerDown):
            tasks.run(e, fake_cache(), True)

    def test_reasoning_content_with_thinking_off_raises(self):
        server = FakeServer(lambda body: {"content": "x", "reasoning_content": "hmm"})
        self.addCleanup(server.close)
        with self.assertRaises(RuntimeError):
            tasks.run(env(server), fake_cache(), True)


if __name__ == "__main__":
    unittest.main()
