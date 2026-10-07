#!/usr/bin/env python3
"""Fixed 16-task quality set for comparing quantisations of one model, scored automatically.

Everything goes through /v1/chat/completions with thinking off (the harness's chat_template_kwargs).
  tool  6 multi-step agent tasks against a deterministic in-process mock repo (read_file, grep, list_dir,
        edit_file, run_tests); <= 12 turns; scored on the final answer and/or the final repo state
  code  5 write/fix-a-function tasks; hidden asserts run against the extracted solution in a time-limited,
        rlimited subprocess inside bwrap (no network, 64 MiB /tmp, read-only work dir) and, when the user
        systemd accepts it, a cgroup scope capping processes and memory; refuses to run without bwrap unless
        TASKS_UNSANDBOXED=1
  lc    5 needle retrievals in 64K/120K-token corpus slices (needles at 10/50/90 % depth, one two-needle task)
Each task runs greedy (temperature 0, seed 0, once) and sampled with temperature 0.7, top_p 0.8, top_k 20 and
presence_penalty 1.5 from the model card's instruct set (seeds 1..5, 1..3 for the 120K tasks). min_p is left at
the server default; the card lists 0.0, so the sampled mode is slightly more truncated than the card's. The
sampling is identical for both quantisations.
Needle values come from a fixed hash, so they are identical across quantisations and runs.

probe.py --do tasks calls run(e, c, quick). `python3 tasks.py --selftest` drives run() against a scripted
fake server (test_tasks.py): known-good transcripts must pass every task, wrong answers must fail them.
"""
import argparse
import contextlib
import dataclasses
import difflib
import functools
import hashlib
import http.client
import json
import os
import posixpath
import re
import resource
import shutil
import signal
import string
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
VERBOSE = True
MAX_TURNS = 12
MAX_TOKENS = {"tool": 1024, "code": 2048, "lc": 256}
GREEDY = {"temperature": 0, "seed": 0}
SAMPLED = {"temperature": 0.7, "top_p": 0.8, "top_k": 20, "presence_penalty": 1.5}
SEEDS, SEEDS_120K = 5, 3
QUICK = ("tool_chain", "code_bugfix_moving_average", "lc64_d50")
FULL_READ_MAX, RANGE_MAX = 60, 20
PYTHON = os.path.realpath(sys.executable)
RO_DIRS = ("/nix/store", "/usr", "/bin", "/sbin", "/lib", "/lib64")
FAIL_HEAD = 300
GREP_TIMEOUT_S = 2
TMP_BYTES = 64 << 20
OUT_TAIL = 4096
CGROUP_PROPS = ("TasksMax=64", "MemoryMax=3G", "MemorySwapMax=0")


@dataclasses.dataclass(frozen=True)
class Task:
    id: str
    kind: str
    seeds: int
    spec: dict


class RequestFailed(Exception):
    pass


class ServerDown(ConnectionError):
    pass


# ---- HTTP -------------------------------------------------------------------------------------

def thinking_off(e):
    if e.engine == "gufo":
        return {"reasoning_effort": "none"}
    return {"chat_template_kwargs": {"enable_thinking": False}}


def ask(e, body, acc):
    """One chat completion; returns the assistant message and adds usage to acc."""
    body = {**body, "model": e.model, "cache_prompt": True, **thinking_off(e)}
    req = urllib.request.Request(f"http://127.0.0.1:{e.port}/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=1800) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as err:
        raise RequestFailed(f"HTTP {err.code}: {err.read().decode(errors='replace')[:200]}") from err
    except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError) as err:
        if isinstance(getattr(err, "reason", err), ConnectionRefusedError):
            raise ServerDown(f"llama-server is not accepting connections on port {e.port}") from err
        raise RequestFailed(repr(err)[:300]) from err
    try:
        choice = resp["choices"][0]
        msg = choice["message"]
    except (KeyError, IndexError, TypeError) as err:
        raise RequestFailed(f"unexpected response shape: {str(resp)[:200]}") from err
    if msg.get("reasoning_content"):
        raise RuntimeError("reasoning_content returned with thinking disabled")
    usage = resp.get("usage") or {}
    acc["prompt_tokens"] += usage.get("prompt_tokens") or 0
    acc["completion_tokens"] += usage.get("completion_tokens") or 0
    acc["finish_reason"] = choice.get("finish_reason")
    acc["turns"] += 1
    return msg


# ---- mock repo and tools ----------------------------------------------------------------------

def tool(name, description, properties, required):
    return {"type": "function", "function": {
        "name": name, "description": description,
        "parameters": {"type": "object", "properties": properties, "required": required}}}


TOOLS = [
    tool("read_file", f"Read a file in the repository. Files longer than {FULL_READ_MAX} lines must be read "
         f"with start_line and end_line (1-based, inclusive, at most {RANGE_MAX} lines).",
         {"path": {"type": "string"}, "start_line": {"type": "integer"}, "end_line": {"type": "integer"}},
         ["path"]),
    tool("grep", "Search files under a path for a regular expression; prints path:line:text.",
         {"pattern": {"type": "string"}, "path": {"type": "string"}}, ["pattern", "path"]),
    tool("list_dir", "List the entries of a directory; directories end with a slash.",
         {"path": {"type": "string"}}, ["path"]),
    tool("edit_file", "Replace exactly one occurrence of old_str with new_str in a file.",
         {"path": {"type": "string"}, "old_str": {"type": "string"}, "new_str": {"type": "string"}},
         ["path", "old_str", "new_str"]),
    tool("run_tests", "Run a test target and return its output.", {"target": {"type": "string"}}, ["target"]),
]
SCHEMAS = {t["function"]["name"]: t["function"]["parameters"] for t in TOOLS}
PY_TYPES = {"string": str, "integer": int}
ROOT_ONLY = "error: paths are relative to the repository root"


def validate(name, args):
    schema = SCHEMAS[name]
    for k in args:
        if k not in schema["properties"]:
            return f"unknown argument '{k}' for {name}; allowed: {', '.join(schema['properties'])}"
    for k in schema["required"]:
        if k not in args:
            return f"missing required argument '{k}'"
    for k, v in args.items():
        kind = schema["properties"][k]["type"]
        if not isinstance(v, PY_TYPES[kind]) or isinstance(v, bool):
            return f"argument '{k}' must be {'an integer' if kind == 'integer' else 'a string'}"
    return None


GREP_WORKER = """import json, re, sys
pattern, lines = json.load(sys.stdin)
rx = re.compile(pattern)
print(json.dumps([i for i, line in enumerate(lines) if rx.search(line)]))
"""


class Repo:
    """In-memory repository with deterministic tools; `tests` maps a target to a callable(files) -> first failure or None."""

    def __init__(self, files, tests):
        self.files = dict(files)
        self.tests = tests
        self.reads = set()
        self.test_runs = []

    def dirs(self):
        return {"/".join(p.split("/")[:i]) for p in self.files for i in range(1, len(p.split("/")))}

    def norm(self, path):
        p = posixpath.normpath(path)
        if path.startswith("/") or p.startswith(".."):
            return None
        return "" if p == "." else p

    def missing(self, p):
        near = difflib.get_close_matches(p, sorted(self.files) + sorted(self.dirs()), n=3, cutoff=0.6)
        return f"error: no such file or directory: {p}" + (f". Nearby paths: {', '.join(near)}" if near else "")

    def call(self, name, raw):
        if name not in SCHEMAS:
            return f"error: unknown tool '{name}'; available: {', '.join(SCHEMAS)}"
        try:
            args = json.loads(raw) if isinstance(raw, str) else raw
        except json.JSONDecodeError:
            return "error: arguments are not valid JSON"
        if not isinstance(args, dict):
            return "error: arguments must be a JSON object"
        problem = validate(name, args)
        return f"error: {problem}" if problem else getattr(self, f"t_{name}")(**args)

    def t_read_file(self, path, start_line=None, end_line=None):
        p = self.norm(path)
        if p is None:
            return ROOT_ONLY
        if p in self.dirs() or p == "":
            return f"error: {p or '.'} is a directory; use list_dir"
        if p not in self.files:
            return self.missing(p)
        lines = self.files[p].splitlines()
        if start_line is None and end_line is None:
            if len(lines) > FULL_READ_MAX:
                return (f"error: {p} has {len(lines)} lines; pass start_line and end_line "
                        f"(at most {RANGE_MAX} lines)")
            self.reads.add(p)
            return self.files[p]
        if start_line is None or end_line is None:
            return "error: start_line and end_line must be given together"
        if not 1 <= start_line <= end_line:
            return "error: need 1 <= start_line <= end_line"
        if end_line - start_line + 1 > RANGE_MAX:
            return f"error: at most {RANGE_MAX} lines per read"
        if start_line > len(lines):
            return f"error: {p} has only {len(lines)} lines"
        self.reads.add(p)
        return "\n".join(lines[start_line - 1:end_line])

    def t_grep(self, pattern, path):
        try:
            re.compile(pattern)
        except (re.error, RecursionError) as err:
            return f"error: invalid regex: {err}"
        p = self.norm(path)
        if p is None:
            return ROOT_ONLY
        if p in self.files:
            names = [p]
        elif p == "" or p in self.dirs():
            names = [f for f in sorted(self.files) if p == "" or f.startswith(p + "/")]
        else:
            return self.missing(p)
        lines = [(f, i, line) for f in names for i, line in enumerate(self.files[f].splitlines(), 1)]
        try:
            found = subprocess.run([PYTHON, "-I", "-c", GREP_WORKER], input=json.dumps([pattern, [l[2] for l in lines]]),
                                   capture_output=True, text=True, timeout=GREP_TIMEOUT_S, check=True)
        except subprocess.TimeoutExpired:
            return "error: regex timed out"
        hits = [f"{f}:{i}:{line}" for f, i, line in (lines[k] for k in json.loads(found.stdout))]
        if not hits:
            return "no matches"
        return "\n".join(hits[:50] + (["... (truncated)"] if len(hits) > 50 else []))

    def t_list_dir(self, path):
        p = self.norm(path)
        if p is None:
            return ROOT_ONLY
        if p in self.files:
            return f"error: {p} is a file; use read_file"
        if p != "" and p not in self.dirs():
            return self.missing(p)
        prefix = f"{p}/" if p else ""
        names = {rest.split("/")[0] + ("/" if "/" in rest else "")
                 for f in self.files if f.startswith(prefix) for rest in [f[len(prefix):]]}
        return "\n".join(sorted(names))

    def t_edit_file(self, path, old_str, new_str):
        p = self.norm(path)
        if p is None:
            return ROOT_ONLY
        if p not in self.files:
            return self.missing(p)
        n = self.files[p].count(old_str)
        if not old_str or n == 0:
            return f"error: old_str not found in {p}"
        if n > 1:
            return f"error: old_str matches {n} times in {p}; add more context"
        self.files[p] = self.files[p].replace(old_str, new_str)
        return f"ok: edited {p}"

    def t_run_tests(self, target):
        if target not in self.tests:
            return f"error: unknown target '{target}'; available: {', '.join(self.tests) or 'none'}"
        failure = self.tests[target](self.files)
        self.test_runs.append(failure is None)
        return "PASS: all checks passed" if failure is None else f"FAIL: {failure}"


def parse_cfg(text):
    out = {}
    for line in text.splitlines():
        k, sep, v = line.partition("=")
        if sep:
            v = v.strip()
            out[k.strip()] = int(v) if v.lstrip("-").isdigit() else v.strip('"')
    return out


def config_tests(files):
    cfg = parse_cfg(files.get("config/app.cfg", ""))
    timeout, retries, backoff = cfg.get("timeout_ms"), cfg.get("retries"), cfg.get("backoff")
    if not isinstance(timeout, int) or timeout < 2000:
        return f"test_timeout: timeout_ms must be at least 2000 (got {timeout})"
    if retries != 3:
        return f"test_retries: retries must be exactly 3 (got {retries})"
    if backoff != "exponential":
        return f'test_backoff: backoff must be "exponential" (got "{backoff}")'
    return None


def has_num(text, n):
    return re.search(rf"(?<!\d){n}(?!\d)", re.sub(r"(?<=\d),(?=\d{3}\b)", "", text)) is not None


# ---- tool tasks -------------------------------------------------------------------------------

BUILD_LOG = "\n".join(
    f"[{i:05d}] step {i} failed: build aborted with ERR-70318 (exit status 2)" if i == 87
    else f"[{i:05d}] step {i} completed in {i * 13 % 97} ms" for i in range(1, 121)) + "\n"

CLIENT_PY = '''"""Frame client."""
import time

RETRY_CAP = 23
BACKOFF_S = 0.5


def send_frame(sock, frame):
    for attempt in range(RETRY_CAP):
        try:
            return sock.sendall(frame)
        except OSError:
            time.sleep(BACKOFF_S * attempt)
    raise FrameError("E4417: frame rejected after retries")
'''
SERVER_PY = '''"""Frame server."""

RETRY_CAP = 11


def accept_frame(sock):
    data = sock.recv(4096)
    if not data:
        raise FrameError("E4410: peer closed before a full frame")
    return data
'''

TOOL_SYSTEM = ("You are a coding agent with tools to inspect and edit a small repository. Paths are relative to "
               "the repository root. Use the tools to find out what you need; when you are done, reply with the "
               "final answer in plain text.")


def tool_task(tid, prompt, files, check, tests=None):
    return Task(tid, "tool", SEEDS, {"prompt": prompt, "files": files, "check": check, "tests": tests or {}})


def check_chain(final, repo):
    return has_num(final, 8472), "expected the listener port from conf/server.toml (8472)"


def check_grep_read(final, repo):
    return "send_frame" in final and has_num(final, 23), "expected send_frame and RETRY_CAP 23 from src/net/client.py"


def check_list_sum(final, repo):
    return has_num(final, 3583), "expected 1375 + 2208 = 3583 over the .meta files only"


def check_edit_tests(final, repo):
    cfg = parse_cfg(repo.files.get("config/app.cfg", ""))
    ok = config_tests(repo.files) is None and cfg.get("name") == "svc" and bool(repo.test_runs) and repo.test_runs[-1]
    return ok, "expected config/app.cfg to satisfy the tests, name untouched, and a final green run_tests"


def check_recover(final, repo):
    return "src/config/settings.yml" in repo.reads and has_num(final, 14), \
        "expected src/config/settings.yml to be read and retry_limit 14 reported"


def check_ranges(final, repo):
    return "ERR-70318" in final, "expected ERR-70318 from lines 84-90 of logs/build.log"


TOOL_TASKS = [
    tool_task(
        "tool_chain",
        "Starting from README.md, follow the pointers: find the entry point file, then the configuration file it "
        "reads, and tell me the listener port configured there. Answer with the port number.",
        {"README.md": "# Orbit service\n\nThe entry point is `app/main.py`.\n",
         "app/main.py": '"""Orbit entry point."""\nCONFIG_PATH = "conf/server.toml"  # listener settings are read '
                        'from here\n\n\ndef main():\n    print("starting")\n',
         "conf/server.toml": '[listener]\nhost = "0.0.0.0"\nport = 8472\n',
         "conf/client.toml": '[remote]\nhost = "orbit.internal"\nport = 9913\n'},
        check_chain),
    tool_task(
        "tool_grep_read",
        "Search the `src` directory for where error code E4417 is raised. Which function raises it, and what is "
        "the value of RETRY_CAP in that same file?",
        {"src/net/client.py": CLIENT_PY, "src/net/server.py": SERVER_PY,
         "src/net/errors.py": '"""Errors."""\n\n\nclass FrameError(Exception):\n    pass\n',
         "docs/errors.md": "# Errors\n\n- E4410: peer closed\n- E4417: frame rejected\n"},
        check_grep_read),
    tool_task(
        "tool_list_sum",
        "List the directory `data/shards`. Read every `.meta` file in it and tell me the total of their `count` "
        "values.",
        {"data/shards/shard_a.meta": "owner: ingest\ncount: 1375\nformat: v2\n",
         "data/shards/shard_b.meta": "owner: ingest\ncount: 2208\nformat: v2\n",
         "data/shards/shard_c.bak": "owner: ingest\ncount: 999\nformat: v1\n",
         "data/shards/notes.txt": "Only .meta files are live; .bak files are stale copies.\n",
         "data/README.md": "# Data\n"},
        check_list_sum),
    tool_task(
        "tool_edit_tests",
        "The tests for target `config` are failing. Fix `config/app.cfg` so that run_tests on target `config` "
        "passes, changing only what the failures require. Run the tests again after each change.",
        {"config/app.cfg": 'name = "svc"\ntimeout_ms = 500\nretries = 0\nbackoff = "linear"\n'},
        check_edit_tests, {"config": config_tests}),
    tool_task(
        "tool_recover",
        "Read `src/config/settings.yaml` and tell me the value of retry_limit.",
        {"src/config/settings.yml": "retry_limit: 14\ntimeout: 30\n",
         "src/config/defaults.yml": "retry_limit: 5\ntimeout: 10\n",
         "src/main.py": "print('hi')\n"},
        check_recover),
    tool_task(
        "tool_ranges",
        "`logs/build.log` is long. Use read_file with start_line=84 and end_line=90 to read lines 84 to 90, then "
        "tell me the error code reported there.",
        {"logs/build.log": BUILD_LOG},
        check_ranges),
]


# ---- code tasks -------------------------------------------------------------------------------

RAISES = '''def raises(f, *a):
    try:
        f(*a)
    except ValueError:
        return True
    return False

'''
ONE_BLOCK = "Reply with only the complete code in a single ```python block."


def code_task(tid, fname, prompt, asserts):
    return Task(tid, "code", SEEDS, {"prompt": f"{prompt}\n\n{ONE_BLOCK}", "fname": fname, "asserts": asserts})


CODE_TASKS = [
    code_task(
        "code_bugfix_moving_average", "moving_average",
        "The following Python function has a bug. Fix it so that it behaves as its docstring says.\n\n"
        "```python\ndef moving_average(xs, k):\n"
        '    """Return the mean of every window of k consecutive items of xs, in order.\n\n'
        '    Return [] if k > len(xs); raise ValueError if k < 1.\n    """\n'
        "    out = []\n    for i in range(len(xs) - k):\n        out.append(sum(xs[i:i + k]) / k)\n"
        "    return out\n```",
        RAISES + "assert moving_average([1, 2, 3, 4], 2) == [1.5, 2.5, 3.5]\n"
        "assert moving_average([1, 2, 3], 3) == [2.0]\nassert moving_average([5], 1) == [5.0]\n"
        "assert moving_average([1, 2], 3) == []\nassert moving_average([], 1) == []\n"
        "assert raises(moving_average, [1, 2], 0)\nassert raises(moving_average, [1, 2], -1)\n"),
    code_task(
        "code_refactor_duplicates", "duplicates",
        "Refactor this function so that it runs in linear time on large inputs (the items are hashable) without "
        "changing its behaviour.\n\n```python\ndef duplicates(items):\n"
        '    """Return the items that occur more than once, each once, in order of first appearance."""\n'
        "    out = []\n    for x in items:\n        if items.count(x) > 1 and x not in out:\n"
        "            out.append(x)\n    return out\n```",
        'assert duplicates([]) == []\nassert duplicates(["a", "b", "a", "c", "b"]) == ["a", "b"]\n'
        "assert duplicates([3, 1, 3, 1, 3, 2]) == [3, 1]\nxs = [1, 2, 3]\nduplicates(xs)\nassert xs == [1, 2, 3]\n"
        "big = list(range(100000)) * 2\nassert duplicates(big) == list(range(100000))\n"),
    code_task(
        "code_parse_duration", "parse_duration",
        "Write a Python function `parse_duration(s)` that converts a duration string to an integer number of "
        "seconds. A duration is one or more `<integer><unit>` groups with units `d` (86400 s), `h` (3600 s), "
        "`m` (60 s) and `s` (1 s), each unit at most once and in that order, for example `90s`, `2h` or "
        "`1d2h3m4s`. Raise `ValueError` for an empty string, a missing number, an unknown unit, a repeated or "
        "out-of-order unit, or any other stray character (spaces, signs, decimals).",
        RAISES + 'assert parse_duration("90s") == 90\nassert parse_duration("1h30m") == 5400\n'
        'assert parse_duration("1d") == 86400\nassert parse_duration("1d2h3m4s") == 93784\n'
        'assert parse_duration("0s") == 0\n'
        'for bad in ["", "5", "s", "5x", "1m2h", "1h1h", "1h 30m", "-5s", "1.5h"]:\n'
        "    assert raises(parse_duration, bad), bad\n"),
    code_task(
        "code_merge_intervals", "merge_intervals",
        "Write a Python function `merge_intervals(intervals)`. Each interval is a `(start, end)` pair with "
        "start <= end. Merge intervals that overlap or touch (the end of one equals the start of the next) and "
        "return the merged intervals as a list of `(start, end)` tuples sorted by start. Do not modify the "
        "argument.",
        "assert merge_intervals([]) == []\n"
        "assert merge_intervals([(1, 3), (2, 6), (8, 10), (15, 18)]) == [(1, 6), (8, 10), (15, 18)]\n"
        "assert merge_intervals([(1, 4), (4, 5)]) == [(1, 5)]\n"
        "assert merge_intervals([(5, 6), (1, 2)]) == [(1, 2), (5, 6)]\n"
        "assert merge_intervals([(1, 10), (2, 3)]) == [(1, 10)]\n"
        "assert merge_intervals([[1, 2], [2, 3]]) == [(1, 3)]\n"
        "xs = [(5, 6), (1, 2)]\nmerge_intervals(xs)\nassert xs == [(5, 6), (1, 2)]\n"),
    code_task(
        "code_split_csv_line", "split_csv_line",
        'Write a Python function `split_csv_line(line)` that splits one CSV line into a list of fields. Fields '
        'are separated by commas. A field may be wrapped in double quotes, in which case it may contain commas, '
        'and a doubled quote (`""`) inside a quoted field stands for one literal quote. Do not strip '
        "whitespace. An empty line gives `['']`, and a trailing comma gives a trailing empty field.",
        "assert split_csv_line('a,b,c') == ['a', 'b', 'c']\n"
        "assert split_csv_line('a,\"b,c\",d') == ['a', 'b,c', 'd']\n"
        "assert split_csv_line('\"say \"\"hi\"\"\",x') == ['say \"hi\"', 'x']\n"
        "assert split_csv_line('') == ['']\nassert split_csv_line('a,') == ['a', '']\n"
        "assert split_csv_line(',') == ['', '']\nassert split_csv_line(' a , b ') == [' a ', ' b ']\n"
        "assert split_csv_line('\"\",x') == ['', 'x']\n"),
]

FENCE = re.compile(r"```[ \t]*(?:[A-Za-z0-9_+-]+)?[ \t]*\n(.*?)(?:```|\Z)", re.S | re.I)


def extract_code(reply, fname):
    blocks = FENCE.findall(reply)
    for b in blocks:
        if re.search(rf"\b(?:def|class)\s+{fname}\b", b):
            return b
    return blocks[0] if blocks else reply


def bwrap_argv(bwrap, workdir):
    argv = [bwrap, "--unshare-all", "--die-with-parent", "--clearenv", "--setenv", "PATH", "/usr/bin:/bin",
            "--setenv", "PYTHONDONTWRITEBYTECODE", "1", "--proc", "/proc", "--dev", "/dev",
            "--size", str(TMP_BYTES), "--tmpfs", "/tmp"]
    for d in RO_DIRS:
        if os.path.isdir(d):
            argv += ["--ro-bind", d, d]
    return argv + ["--ro-bind", workdir, workdir, "--chdir", workdir]


def scope_argv(systemd_run):
    return [systemd_run, "--user", "--scope", "--quiet", *(a for p in CGROUP_PROPS for a in ("-p", p))]


@functools.cache
def sandbox_kind():
    bwrap = shutil.which("bwrap")
    if not bwrap:
        return "none"
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run([*bwrap_argv(bwrap, d), PYTHON, "-c", "pass"], capture_output=True, timeout=30)
    return "bwrap" if r.returncode == 0 else "none"


@functools.cache
def limits_kind():
    systemd_run = shutil.which("systemd-run")
    if not systemd_run:
        return "rlimit"
    r = subprocess.run([*scope_argv(systemd_run), "true"], capture_output=True, timeout=30)
    return "cgroup" if r.returncode == 0 else "rlimit"


def launch_argv(workdir, bwrap, systemd_run):
    scope = scope_argv(systemd_run) if limits_kind() == "cgroup" else []
    return [*scope, *(bwrap_argv(bwrap, workdir) if bwrap else [])]


def run_hidden(code, asserts, timeout=10):
    """Run the solution plus asserts in a fresh tempdir under wall, CPU, address-space and file-size limits.
    The asserts see the solution as the module `solution`, so a __main__ demo in the reply never runs."""
    if sandbox_kind() != "bwrap" and os.environ.get("TASKS_UNSANDBOXED") != "1":
        raise RuntimeError("bwrap sandbox unusable; refusing to run model code (set TASKS_UNSANDBOXED=1 to override)")
    token = uuid.uuid4().hex
    cpu_s, as_bytes = timeout + 2, 2 << 30

    def limits():
        resource.setrlimit(resource.RLIMIT_CPU, (cpu_s, cpu_s + 1))
        resource.setrlimit(resource.RLIMIT_AS, (as_bytes, as_bytes))
        resource.setrlimit(resource.RLIMIT_FSIZE, (8 << 20, 8 << 20))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    proc_env = {"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"}
    if limits_kind() == "cgroup":
        proc_env |= {k: os.environ[k] for k in ("XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS") if k in os.environ}
    with tempfile.TemporaryDirectory() as root:
        work, out_path = os.path.join(root, "work"), os.path.join(root, "out")
        os.mkdir(work)
        with open(os.path.join(work, "solution.py"), "w", encoding="utf-8") as f:
            f.write(code)
        with open(os.path.join(work, "check.py"), "w", encoding="utf-8") as f:
            f.write(f"import sys\nsys.path.insert(0, '.')\nfrom solution import *\n\n{asserts}\nprint({token!r})\n")
        prefix = launch_argv(work, shutil.which("bwrap") if sandbox_kind() == "bwrap" else None,
                             shutil.which("systemd-run"))
        with open(out_path, "wb") as out:
            proc = subprocess.Popen([*prefix, PYTHON, "-I", "check.py"], cwd=work, stdin=subprocess.DEVNULL,
                                    stdout=out, stderr=subprocess.STDOUT, env=proc_env, start_new_session=True,
                                    preexec_fn=limits)
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                return False, f"timeout after {timeout}s"
        with open(out_path, "rb") as f:
            f.seek(max(0, os.path.getsize(out_path) - OUT_TAIL))
            tail = f.read().decode(errors="replace")
    ok = proc.returncode == 0 and tail.rstrip().endswith(token)
    return ok, "" if ok else f"rc={proc.returncode}: {tail.replace(token, '')[-200:]}"


def score_code(spec, reply, timeout=10):
    return run_hidden(extract_code(reply, spec["fname"]), spec["asserts"], timeout)


# ---- long-context tasks -----------------------------------------------------------------------

WORDS = ("amber basalt cobalt dune ember fjord garnet harbor indigo juniper kestrel lagoon meadow nimbus "
         "obsidian pewter quartz russet sable tundra umber velvet willow xenon yarrow zephyr alder birch cedar "
         "dahlia elm fern gorse hazel iris jasmine kelp larch maple nettle olive poplar").split()


def derive(tag):
    """Reproducible (word, code) pair for a tag; independent of Python's random module."""
    h = hashlib.sha256(f"flash-next-iq3-quality:{tag}".encode()).digest()
    letters = "".join(string.ascii_uppercase[b % 26] for b in h[:4])
    return WORDS[h[6] % len(WORDS)], f"{letters}-{1000 + int.from_bytes(h[4:6], 'big') % 9000}"


def sentence(name, value):
    return f"The access code for vault {name} is {value}."


def lc_task(tid, tokens, needle_depths, decoy_depth):
    needles = [(d, *derive(f"{tid}:{i}")) for i, d in enumerate(needle_depths)]
    decoy = (decoy_depth, *derive(f"{tid}:decoy"))
    if len(needles) == 1:
        (_, name, value), = needles
        question = f"What is the access code for vault {name}? Reply with only the code."
        expected = value
    else:
        (_, a, va), (_, b, vb) = needles
        question = (f"What is the access code for vault {a} and what is the access code for vault {b}? Reply with "
                    f"only the two codes, vault {a}'s first, joined by a plus sign with no spaces.")
        expected = f"{va}+{vb}"
    return Task(tid, "lc", SEEDS if tokens <= 64000 else SEEDS_120K,
                {"tokens": tokens, "needles": needles, "decoy": decoy, "question": question, "expected": expected})


LC_TASKS = [
    lc_task("lc64_d10", 64000, [0.1], 0.4),
    lc_task("lc64_d50", 64000, [0.5], 0.8),
    lc_task("lc64_d90", 64000, [0.9], 0.2),
    lc_task("lc120_d50", 120000, [0.5], 0.8),
    lc_task("lc120_two", 120000, [0.1, 0.9], 0.5),
]


def build_haystack(c, tokens, needles):
    """Cut the corpus to ~tokens (by the cache's chars-per-token ratio, on a line boundary) and insert each
    (depth, sentence) on its own line at the first line start at or before depth * length. Returns the text and
    {sentence: realised depth}."""
    key = max(c["slices"], key=int)
    base = c["slices"][key]
    text = base[:min(len(base), round(len(base) * tokens / c["slice_tokens"][key]))]
    text = text[:text.rfind("\n") + 1] or text
    for depth, line in sorted(needles, key=lambda n: -n[0]):
        pos = text.rfind("\n", 0, int(depth * len(text))) + 1
        text = f"{text[:pos]}{line}\n{text[pos:]}"
    return text, {line: round(text.index(line) / len(text), 4) for _, line in needles}


def score_lc(spec, text):
    if spec["expected"] in text:
        return True, ""
    values = [v for _, _, v in spec["needles"]]
    if len(values) > 1 and all(v in text for v in values):
        return False, "both values present but not as the requested expected string"
    if spec["decoy"][2] in text:
        return False, "returned the decoy vault's code"
    return False, f"{sum(v in text for v in values)} of {len(values)} needle values present"


# ---- runner -----------------------------------------------------------------------------------

TASKS = [*TOOL_TASKS, *CODE_TASKS, *LC_TASKS]


def run_tool(e, c, spec, params, acc):
    repo = Repo(spec["files"], spec["tests"])
    msgs = [{"role": "system", "content": TOOL_SYSTEM}, {"role": "user", "content": spec["prompt"]}]
    for _ in range(MAX_TURNS):
        msg = ask(e, {"messages": msgs, "tools": TOOLS, "max_tokens": MAX_TOKENS["tool"], **params}, acc)
        calls = msg.get("tool_calls") or []
        if not calls:
            final = msg.get("content") or ""
            return (final, *spec["check"](final, repo))
        msgs.append({"role": "assistant", "content": msg.get("content") or "", "tool_calls": calls})
        for call in calls:
            fn = call.get("function") or {}
            msgs.append({"role": "tool", "tool_call_id": call["id"],
                         "content": repo.call(fn.get("name"), fn.get("arguments") or "")})
    return "", False, "turn limit"


def run_code(e, c, spec, params, acc):
    msg = ask(e, {"messages": [{"role": "user", "content": spec["prompt"]}], "max_tokens": MAX_TOKENS["code"],
                  **params}, acc)
    reply = msg.get("content") or ""
    return (reply, *score_code(spec, reply))


def run_lc(e, c, spec, params, acc):
    lines = [(d, sentence(n, v)) for d, n, v in (*spec["needles"], spec["decoy"])]
    text, _ = build_haystack(c, spec["tokens"], lines)
    msg = ask(e, {"messages": [{"role": "user", "content": f"{text}\n\n---\n{spec['question']}"}],
                  "max_tokens": MAX_TOKENS["lc"], **params}, acc)
    reply = msg.get("content") or ""
    return (reply, *score_lc(spec, reply))


RUNNERS = {"tool": run_tool, "code": run_code, "lc": run_lc}


def run_task(e, c, task, params):
    acc = {"prompt_tokens": 0, "completion_tokens": 0, "turns": 0, "finish_reason": None}
    t0 = time.perf_counter()
    error = None
    try:
        final, ok, note = RUNNERS[task.kind](e, c, task.spec, params, acc)
    except RequestFailed as err:
        final, ok, note, error = "", False, "", str(err)
    run = {"seed": params["seed"], "pass": ok, "wall_s": round(time.perf_counter() - t0, 3), **acc,
           "error": error, "note": "" if ok else note}
    if not ok:
        run["fail_head"] = (final or error or note)[:FAIL_HEAD]
    return run


def wilson(k, n, z=1.96):
    if n == 0:
        return 0.0, 1.0
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5) / denom
    return round(max(0.0, centre - half), 4), round(min(1.0, centre + half), 4)


def tally(runs):
    k, n = sum(r["pass"] for r in runs), len(runs)
    return {"passes": k, "n": n, "errors": sum(r["error"] is not None for r in runs),
            "rate": round(k / n, 4) if n else None, "wilson95": list(wilson(k, n))}


def run(e, c, quick):
    selected = [t for t in TASKS if t.id in QUICK] if quick else TASKS
    out = {}
    for task in selected:
        entry = {"category": task.kind, "modes": {}}
        sampled = [{**SAMPLED, "seed": s} for s in range(1, (1 if quick else task.seeds) + 1)]
        for mode, plist in (("greedy", [GREEDY]), ("sampled", sampled)):
            runs = [run_task(e, c, task, p) for p in plist]
            entry["modes"][mode] = {"pass": [r["pass"] for r in runs],
                                    "errors": sum(r["error"] is not None for r in runs), "runs": runs}
        every = [r for m in entry["modes"].values() for r in m["runs"]]
        entry["wall_s"] = round(sum(r["wall_s"] for r in every), 3)
        entry["prompt_tokens"] = sum(r["prompt_tokens"] for r in every)
        entry["completion_tokens"] = sum(r["completion_tokens"] for r in every)
        out[task.id] = entry
        if VERBOSE:
            print(f"tasks: {task.id} greedy {sum(entry['modes']['greedy']['pass'])}/"
                  f"{len(entry['modes']['greedy']['pass'])} sampled {sum(entry['modes']['sampled']['pass'])}/"
                  f"{len(entry['modes']['sampled']['pass'])} in {entry['wall_s']:.0f}s", file=sys.stderr, flush=True)
    aggregate = {}
    for cat in (*dict.fromkeys(t["category"] for t in out.values()), "all"):
        aggregate[cat] = {mode: tally([r for t in out.values() if cat in ("all", t["category"])
                                       for r in t["modes"][mode]["runs"]]) for mode in ("greedy", "sampled")}
    return {"quick": quick, "sandbox": sandbox_kind(), "limits": limits_kind(), "sampling": {"greedy": GREEDY, "sampled": SAMPLED},
            "max_turns": MAX_TURNS, "tasks": out, "aggregate": aggregate}


def selftest():
    sys.path.insert(0, HERE)
    import test_tasks
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(test_tasks.FakeServerTests)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true", help="run the scripted fake-server check")
    if not ap.parse_args().selftest:
        ap.error("nothing to do; probe.py --do tasks runs the tasks against a live server")
    sys.exit(selftest())
