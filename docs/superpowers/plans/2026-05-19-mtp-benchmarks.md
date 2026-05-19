# MTP benchmarks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--mtp-ab` mode to `pkgs/benchmark/benchmark.py` that runs a same-GGUF, same-prompt A/B between `--spec-type none` and `--spec-type draft-mtp` on `llama-server`, then publish the resulting numbers in a new README "MTP speedup: Qwen3.6 family" subsection.

**Architecture:** Single-file extension of the existing Python harness. New mode spawns `llama-server` directly (bypassing `lemond`) twice per backend, drives completions through `/v1/completions`, captures `predicted_per_second` from server-reported timings. Pure helpers are TDD'd via stdlib `unittest`; subprocess/network paths are validated by six manual smoke tests.

**Tech Stack:** Python 3 stdlib (`subprocess`, `urllib`, `socket`, `signal`, `argparse`, `unittest`), `llama-server` from `pkgs.llama-cpp-rocm` / `pkgs.llama-cpp-vulkan` (b9213, both already on `$PATH` via the NixOS module).

**Reference spec:** `docs/superpowers/specs/2026-05-19-mtp-benchmarks-design.md`

---

## Task 1: Test scaffolding + failing test for `find_free_port`

**Files:**
- Create: `pkgs/benchmark/tests/__init__.py`
- Create: `pkgs/benchmark/tests/test_benchmark.py`

- [ ] **Step 1: Create empty `__init__.py`**

```bash
touch /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark/tests/__init__.py
```

- [ ] **Step 2: Write the failing test**

Create `pkgs/benchmark/tests/test_benchmark.py`:

```python
"""Unit tests for benchmark.py pure helpers."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import benchmark


class FindFreePortTests(unittest.TestCase):
    def test_returns_int_in_valid_range(self):
        port = benchmark.find_free_port()
        self.assertIsInstance(port, int)
        self.assertGreater(port, 1024)
        self.assertLess(port, 65536)

    def test_returns_different_ports_on_repeated_calls(self):
        ports = {benchmark.find_free_port() for _ in range(5)}
        self.assertGreater(len(ports), 1)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run test to verify it fails**

Run:
```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: FAIL with `AttributeError: module 'benchmark' has no attribute 'find_free_port'`.

- [ ] **Step 4: Implement `find_free_port` in `benchmark.py`**

Add near the other helpers (after `http_post_stream`, before `set_llamacpp_backend`):

```python
def find_free_port():
    """Return an unused TCP port on localhost.

    Binds to port 0 to let the kernel pick, reads the port, then closes
    the socket. The port is briefly racy until the caller binds again,
    which is fine for our subprocess spawn flow.
    """
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git add pkgs/benchmark/tests/__init__.py pkgs/benchmark/tests/test_benchmark.py pkgs/benchmark/benchmark.py
git commit -m "test(benchmark): add unittest scaffolding + find_free_port helper"
```

---

## Task 2: `resolve_lemonade_gguf` helper

**Files:**
- Modify: `pkgs/benchmark/tests/test_benchmark.py`
- Modify: `pkgs/benchmark/benchmark.py`

- [ ] **Step 1: Add failing tests**

Append to `pkgs/benchmark/tests/test_benchmark.py`:

```python
import tempfile
import pathlib


class ResolveLemonadeGgufTests(unittest.TestCase):
    def test_returns_none_when_model_dir_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = benchmark.resolve_lemonade_gguf(
                "Qwen3.6-27B-MTP-GGUF",
                cache_root=tmp,
            )
            self.assertIsNone(result)

    def test_finds_single_gguf_in_model_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            model_dir = pathlib.Path(tmp) / "Qwen3.6-27B-MTP-GGUF"
            model_dir.mkdir()
            gguf = model_dir / "Qwen3.6-27B-UD-Q4_K_XL.gguf"
            gguf.write_bytes(b"")
            result = benchmark.resolve_lemonade_gguf(
                "Qwen3.6-27B-MTP-GGUF",
                cache_root=tmp,
            )
            self.assertEqual(result, str(gguf))

    def test_recursive_search_finds_nested_gguf(self):
        with tempfile.TemporaryDirectory() as tmp:
            nested = pathlib.Path(tmp) / "Qwen3.6-27B-MTP-GGUF" / "snapshots" / "abc"
            nested.mkdir(parents=True)
            gguf = nested / "model.gguf"
            gguf.write_bytes(b"")
            result = benchmark.resolve_lemonade_gguf(
                "Qwen3.6-27B-MTP-GGUF",
                cache_root=tmp,
            )
            self.assertEqual(result, str(gguf))


if __name__ == "__main__":
    unittest.main()
```

(Remove the second `if __name__ == "__main__"` block if it duplicates an earlier one — keep only the final one.)

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 3 new failures with `AttributeError: ... 'resolve_lemonade_gguf'`.

- [ ] **Step 3: Implement `resolve_lemonade_gguf`**

Add after `find_free_port`:

```python
def resolve_lemonade_gguf(model_id, cache_root=None):
    """Return the absolute path to the GGUF file for a lemonade model id.

    Looks under <cache_root>/<model_id>/ recursively for the first .gguf
    file. Returns None if the model directory does not exist or contains
    no .gguf.

    cache_root defaults to ~/.cache/lemonade/models.
    """
    import pathlib

    if cache_root is None:
        cache_root = os.path.expanduser(
            "~/.cache/lemonade/models"
        )
    model_dir = pathlib.Path(cache_root) / model_id
    if not model_dir.is_dir():
        return None
    for gguf in sorted(model_dir.rglob("*.gguf")):
        return str(gguf)
    return None
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 5 tests pass (2 existing + 3 new).

- [ ] **Step 5: Verify on the real cache** (one-shot manual check; OK if no MTP model pulled yet — should return None)

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -c "import benchmark; print(benchmark.resolve_lemonade_gguf('Qwen3.6-27B-MTP-GGUF'))"
```

Expected: prints `None` (no model pulled yet) or a path under `~/.cache/lemonade/models/Qwen3.6-27B-MTP-GGUF/...gguf` if already pulled.

- [ ] **Step 6: Commit**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git add pkgs/benchmark/tests/test_benchmark.py pkgs/benchmark/benchmark.py
git commit -m "feat(benchmark): add resolve_lemonade_gguf helper"
```

---

## Task 3: `parse_llama_devices` and `pick_device` helpers

**Files:**
- Modify: `pkgs/benchmark/tests/test_benchmark.py`
- Modify: `pkgs/benchmark/benchmark.py`

**Background:** First, confirm the exact output format of `llama-server --list-devices` on this host. Run it once before writing the test — the parser must match real output.

- [ ] **Step 1: Capture real `--list-devices` output for the test fixture**

Run:
```bash
llama-server --list-devices 2>&1 | tee /tmp/llama-devices.txt
```

Expected: lines like `Vulkan0: AMD Radeon Graphics (...)` and `ROCm0: AMD Radeon 890M (...)`. If the format is different, adapt the regex in Step 3 accordingly. **Paste the actual output into the implementation as a docstring example.**

- [ ] **Step 2: Add failing tests**

Append to `pkgs/benchmark/tests/test_benchmark.py`:

```python
class ParseLlamaDevicesTests(unittest.TestCase):
    SAMPLE = (
        "Available devices:\n"
        "  Vulkan0: AMD Radeon Graphics (gfx1150) (28000 MiB)\n"
        "  ROCm0: AMD Radeon 890M Graphics (28000 MiB)\n"
    )

    def test_parses_vulkan_and_rocm(self):
        devices = benchmark.parse_llama_devices(self.SAMPLE)
        self.assertIn("Vulkan0", devices)
        self.assertIn("ROCm0", devices)

    def test_empty_output_returns_empty(self):
        self.assertEqual(benchmark.parse_llama_devices(""), [])


class PickDeviceTests(unittest.TestCase):
    DEVICES = ["Vulkan0", "ROCm0"]

    def test_picks_rocm(self):
        self.assertEqual(
            benchmark.pick_device(self.DEVICES, "rocm"),
            "ROCm0",
        )

    def test_picks_vulkan(self):
        self.assertEqual(
            benchmark.pick_device(self.DEVICES, "vulkan"),
            "Vulkan0",
        )

    def test_unknown_backend_raises(self):
        with self.assertRaises(ValueError):
            benchmark.pick_device(self.DEVICES, "cuda")

    def test_missing_device_raises(self):
        with self.assertRaises(ValueError):
            benchmark.pick_device(["Vulkan0"], "rocm")
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 6 new failures referencing `parse_llama_devices` and `pick_device`.

- [ ] **Step 4: Implement both helpers**

Add after `resolve_lemonade_gguf`:

```python
def parse_llama_devices(output):
    """Parse the output of `llama-server --list-devices`.

    Returns a list of device identifier strings (e.g. ['Vulkan0',
    'ROCm0']) suitable for passing to `--device`. Tolerant of
    leading whitespace and trailing descriptions; uses the first
    non-whitespace token before ':' as the device id.
    """
    import re

    devices = []
    for line in output.splitlines():
        m = re.match(r"\s*([A-Za-z][A-Za-z0-9]*)\s*:", line)
        if m:
            tok = m.group(1)
            if tok.lower() in ("available", "devices"):
                continue
            devices.append(tok)
    return devices


_BACKEND_PREFIX = {"rocm": "ROCm", "vulkan": "Vulkan"}


def pick_device(devices, backend):
    """Return the device string matching the requested backend.

    backend must be 'rocm' or 'vulkan'. Raises ValueError if the
    backend is unknown or no matching device is present.
    """
    prefix = _BACKEND_PREFIX.get(backend)
    if prefix is None:
        raise ValueError(
            f"unknown backend {backend!r};"
            f" expected one of {sorted(_BACKEND_PREFIX)}"
        )
    for d in devices:
        if d.startswith(prefix):
            return d
    raise ValueError(
        f"no {backend} device found in {devices}; check"
        f" llama-server --list-devices"
    )
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 11 tests pass.

- [ ] **Step 6: Adjust regex if real output differs from sample**

If Step 1 captured a format different from the sample (e.g. `  device 0: Vulkan0` instead of `  Vulkan0:`), update both the `SAMPLE` constant in the test and the regex in `parse_llama_devices`, then re-run Step 5.

- [ ] **Step 7: Commit**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git add pkgs/benchmark/tests/test_benchmark.py pkgs/benchmark/benchmark.py
git commit -m "feat(benchmark): add llama-server device parsing + backend picker"
```

---

## Task 4: `build_llama_server_args` helper

**Files:**
- Modify: `pkgs/benchmark/tests/test_benchmark.py`
- Modify: `pkgs/benchmark/benchmark.py`

- [ ] **Step 1: Add failing test**

Append to `pkgs/benchmark/tests/test_benchmark.py`:

```python
class BuildLlamaServerArgsTests(unittest.TestCase):
    def test_includes_required_flags(self):
        args = benchmark.build_llama_server_args(
            gguf="/tmp/model.gguf",
            port=18080,
            device="Vulkan0",
            spec_type="draft-mtp",
            n_gpu_layers=99,
            ctx_size=4096,
        )
        self.assertEqual(args[0], "llama-server")
        self.assertIn("--model", args)
        self.assertIn("/tmp/model.gguf", args)
        self.assertIn("--port", args)
        self.assertIn("18080", args)
        self.assertIn("--device", args)
        self.assertIn("Vulkan0", args)
        self.assertIn("--spec-type", args)
        self.assertIn("draft-mtp", args)
        self.assertIn("--n-gpu-layers", args)
        self.assertIn("99", args)
        self.assertIn("--ctx-size", args)
        self.assertIn("4096", args)

    def test_spec_type_none_still_passed(self):
        args = benchmark.build_llama_server_args(
            gguf="/tmp/model.gguf",
            port=18080,
            device="ROCm0",
            spec_type="none",
            n_gpu_layers=99,
            ctx_size=4096,
        )
        self.assertIn("--spec-type", args)
        self.assertIn("none", args)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 2 new failures referencing `build_llama_server_args`.

- [ ] **Step 3: Implement**

Add after `pick_device`:

```python
def build_llama_server_args(
    gguf, port, device, spec_type, n_gpu_layers, ctx_size,
):
    """Build the argv list to spawn llama-server for an MTP A/B run.

    spec_type must be a value accepted by `--spec-type`. For our A/B:
    'none' (MTP off) and 'draft-mtp' (MTP on, requires b9213+).
    """
    return [
        "llama-server",
        "--model", gguf,
        "--port", str(port),
        "--host", "127.0.0.1",
        "--device", device,
        "--spec-type", spec_type,
        "--n-gpu-layers", str(n_gpu_layers),
        "--ctx-size", str(ctx_size),
        "--no-webui",
    ]
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 13 tests pass.

- [ ] **Step 5: Verify `--no-webui` is accepted on this build**

```bash
llama-server --help 2>&1 | grep -- '--no-webui'
```

Expected: one matching line. If missing, drop `--no-webui` from the args list and re-run Step 4.

- [ ] **Step 6: Commit**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git add pkgs/benchmark/tests/test_benchmark.py pkgs/benchmark/benchmark.py
git commit -m "feat(benchmark): add build_llama_server_args helper"
```

---

## Task 5: `LlamaServer` subprocess context manager (integration-tested, no unit test)

**Files:**
- Modify: `pkgs/benchmark/benchmark.py`

**Rationale:** Mocking `subprocess.Popen` would test the mock, not behavior. Validate this class by a manual smoke spawn against a tiny GGUF in Task 9. Keep the implementation tight enough to read.

- [ ] **Step 1: Add the class**

Add after `build_llama_server_args`:

```python
class LlamaServer:
    """Context manager that spawns and reaps a llama-server subprocess.

    Spawns the server with the given argv, polls /health until ready or
    timeout, exposes `base_url`. On exit sends SIGTERM, waits up to
    `term_timeout` seconds, then SIGKILLs if still alive.
    """

    def __init__(self, argv, port, ready_timeout=120, term_timeout=10):
        self.argv = argv
        self.port = port
        self.ready_timeout = ready_timeout
        self.term_timeout = term_timeout
        self.base_url = f"http://127.0.0.1:{port}"
        self.proc = None

    def __enter__(self):
        print(
            f"  Spawning: {' '.join(self.argv)}",
            file=sys.stderr,
        )
        self.proc = subprocess.Popen(
            self.argv,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        try:
            self._wait_ready()
        except Exception:
            self.__exit__(None, None, None)
            raise
        return self

    def _wait_ready(self):
        deadline = time.monotonic() + self.ready_timeout
        last_err = None
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                stderr = self.proc.stderr.read().decode(
                    "utf-8", errors="replace"
                )
                raise RuntimeError(
                    f"llama-server exited with code"
                    f" {self.proc.returncode} before becoming ready."
                    f" stderr:\n{stderr[-2000:]}"
                )
            try:
                http_get(self.base_url, "/health")
                return
            except (urllib.error.URLError, ConnectionError, OSError) as exc:
                last_err = exc
                time.sleep(0.5)
        raise TimeoutError(
            f"llama-server at {self.base_url} did not become ready"
            f" within {self.ready_timeout}s (last error: {last_err})"
        )

    def __exit__(self, exc_type, exc, tb):
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=self.term_timeout)
            except subprocess.TimeoutExpired:
                print(
                    "  WARNING: llama-server did not exit on SIGTERM;"
                    " sending SIGKILL",
                    file=sys.stderr,
                )
                self.proc.kill()
                self.proc.wait()
        self.proc = None
```

- [ ] **Step 2: Add missing imports**

Near the top of `benchmark.py`, alongside the existing imports, ensure these are present:

```python
import signal
```

(`subprocess`, `time`, `sys`, `urllib.error` are already imported by the existing file.)

- [ ] **Step 3: Verify the module still imports cleanly**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -c "import benchmark; print(benchmark.LlamaServer)"
```

Expected: prints `<class 'benchmark.LlamaServer'>`.

- [ ] **Step 4: Verify all existing tests still pass**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 13 tests still pass.

- [ ] **Step 5: Commit**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git add pkgs/benchmark/benchmark.py
git commit -m "feat(benchmark): add LlamaServer subprocess context manager"
```

---

## Task 6: `--mtp-ab` argparse wiring (skeleton, no execution yet)

**Files:**
- Modify: `pkgs/benchmark/benchmark.py`

- [ ] **Step 1: Add the flag in `main()`**

In `main()`, after the existing `--no-restart` argument and before `args = parser.parse_args()`:

```python
    parser.add_argument(
        "--mtp-ab",
        metavar="MODEL_ID",
        default=None,
        help=(
            "Run a same-GGUF A/B between --spec-type none and"
            " --spec-type draft-mtp on the given lemonade model id."
            " Spawns llama-server directly (bypasses lemond); requires"
            " the model to be pulled and to have an MTP head."
            " Mutually exclusive with the positional MODEL_ID arguments."
        ),
    )
    parser.add_argument(
        "--mtp-ab-backends",
        default="rocm,vulkan",
        help=(
            "Comma-separated list of backends to sweep when --mtp-ab"
            " is set (default: rocm,vulkan)."
        ),
    )
```

Also relax the existing positional `model_ids` to accept zero args when `--mtp-ab` is set. Change:

```python
    parser.add_argument(
        "model_ids",
        metavar="MODEL_ID",
        nargs="+",
        help="One or more lemonade model IDs to benchmark",
    )
```

To:

```python
    parser.add_argument(
        "model_ids",
        metavar="MODEL_ID",
        nargs="*",
        default=[],
        help=(
            "One or more lemonade model IDs to benchmark (lemonade"
            " HTTP mode). Omit when using --mtp-ab."
        ),
    )
```

- [ ] **Step 2: Dispatch to the new mode early in `main()`**

After `args = parser.parse_args()` and before the existing `model_ids = args.model_ids` line, insert:

```python
    if args.mtp_ab:
        if args.model_ids:
            print(
                "ERROR: --mtp-ab is mutually exclusive with"
                " positional MODEL_ID arguments",
                file=sys.stderr,
            )
            sys.exit(2)
        backends = [
            b.strip() for b in args.mtp_ab_backends.split(",") if b.strip()
        ]
        run_mtp_ab(
            model_id=args.mtp_ab,
            backends=backends,
            prompt_tokens=args.prompt_tokens,
            gen_tokens=args.gen_tokens,
            warmup=args.warmup,
            repeat=args.repeat,
        )
        return
```

Also, immediately after the dispatch, restore the existing check that requires positional model IDs (since they are no longer `nargs="+"`):

```python
    if not args.model_ids:
        print(
            "ERROR: at least one MODEL_ID is required (or use"
            " --mtp-ab)",
            file=sys.stderr,
        )
        sys.exit(2)
```

- [ ] **Step 3: Add `run_mtp_ab` stub**

Add above `def main()`:

```python
def run_mtp_ab(
    model_id, backends, prompt_tokens, gen_tokens, warmup, repeat,
):
    """Drive an MTP-on / MTP-off A/B across the given backends.

    Spawns llama-server twice per backend (--spec-type none, then
    --spec-type draft-mtp) against the same GGUF. Prints a markdown
    table.
    """
    raise NotImplementedError("filled in by Task 7")
```

- [ ] **Step 4: Smoke-test that argparse rejects the conflict**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 benchmark.py --mtp-ab Qwen3.6-27B-MTP-GGUF SomeOther 2>&1 | head -3
echo "exit=$?"
```

Expected: `ERROR: --mtp-ab is mutually exclusive ...` and `exit=2`.

- [ ] **Step 5: Smoke-test that argparse rejects empty invocation**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 benchmark.py 2>&1 | head -3
echo "exit=$?"
```

Expected: `ERROR: at least one MODEL_ID is required ...` and `exit=2`.

- [ ] **Step 6: Smoke-test that the new flag dispatches to the stub**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 benchmark.py --mtp-ab Qwen3.6-27B-MTP-GGUF 2>&1 | head -3
echo "exit=$?"
```

Expected: `NotImplementedError: filled in by Task 7` and non-zero exit.

- [ ] **Step 7: Verify unit tests still pass**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 13 tests pass.

- [ ] **Step 8: Commit**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git add pkgs/benchmark/benchmark.py
git commit -m "feat(benchmark): wire --mtp-ab argparse flag and dispatch stub"
```

---

## Task 7: Implement `run_mtp_ab` happy path + `format_mtp_row`

**Files:**
- Modify: `pkgs/benchmark/tests/test_benchmark.py`
- Modify: `pkgs/benchmark/benchmark.py`

- [ ] **Step 1: Add failing tests for `format_mtp_row`**

Append to `pkgs/benchmark/tests/test_benchmark.py`:

```python
class FormatMtpRowTests(unittest.TestCase):
    def test_typical_row(self):
        row = benchmark.format_mtp_row(
            model_id="Qwen3.6-27B-MTP-GGUF",
            backend="vulkan",
            off_tps=20.0,
            on_tps=30.0,
        )
        self.assertIn("Qwen3.6-27B-MTP-GGUF", row)
        self.assertIn("vulkan", row)
        self.assertIn("20.0", row)
        self.assertIn("30.0", row)
        self.assertIn("1.50x", row)

    def test_missing_data_shows_na(self):
        row = benchmark.format_mtp_row(
            model_id="X",
            backend="rocm",
            off_tps=None,
            on_tps=10.0,
        )
        self.assertIn("N/A", row)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 2 new failures referencing `format_mtp_row`.

- [ ] **Step 3: Implement `format_mtp_row` and replace the `run_mtp_ab` stub**

Replace the `run_mtp_ab` stub from Task 6 with:

```python
def format_mtp_row(model_id, backend, off_tps, on_tps):
    """Format one markdown table row for the MTP A/B sweep."""

    def fmt(v):
        return f"{v:.1f}" if isinstance(v, (int, float)) else "N/A"

    if isinstance(off_tps, (int, float)) and off_tps > 0 \
            and isinstance(on_tps, (int, float)):
        speedup = f"{on_tps / off_tps:.2f}x"
    else:
        speedup = "N/A"
    return (
        f"| {model_id} | {backend} | {fmt(off_tps)} |"
        f" {fmt(on_tps)} | {speedup} |"
    )


def _measure_one_spec(server, prompt_tokens, gen_tokens, warmup, repeat):
    """Run warmup + repeat completions against a live llama-server.

    Returns the mean decode t/s (from server-reported timings), or None
    if no successful iterations.
    """
    prompt = build_prompt(prompt_tokens)
    for _ in range(warmup):
        run_completion(server.base_url, "default", prompt, gen_tokens)

    tps_samples = []
    for i in range(repeat):
        _, tps, ntok = run_completion(
            server.base_url, "default", prompt, gen_tokens,
        )
        if tps is None:
            print(
                f"    iter {i + 1}: no tokens received",
                file=sys.stderr,
            )
            continue
        print(
            f"    iter {i + 1}: decode={tps:.1f} t/s, tokens={ntok}",
            file=sys.stderr,
        )
        tps_samples.append(tps)

    if not tps_samples:
        return None
    return statistics.mean(tps_samples)


def run_mtp_ab(
    model_id, backends, prompt_tokens, gen_tokens, warmup, repeat,
):
    """Drive an MTP-on / MTP-off A/B across the given backends."""
    gguf = resolve_lemonade_gguf(model_id)
    if gguf is None:
        print(
            f"ERROR: model {model_id!r} not found in lemonade cache."
            f" Run: lemonade pull {model_id}",
            file=sys.stderr,
        )
        sys.exit(2)

    devices_output = subprocess.run(
        ["llama-server", "--list-devices"],
        capture_output=True, text=True, timeout=30,
    ).stdout
    devices = parse_llama_devices(devices_output)

    print(
        f"\nMTP A/B sweep: model={model_id}\n"
        f"  gguf={gguf}\n"
        f"  devices={devices}\n"
        f"  backends={backends}\n"
        f"  protocol: prompt={prompt_tokens} tokens,"
        f" gen={gen_tokens} tokens,"
        f" {warmup} warmup + {repeat} measured\n",
        file=sys.stderr,
    )

    rows = []
    for backend in backends:
        device = pick_device(devices, backend)

        results = {}
        for spec_type in ("none", "draft-mtp"):
            print(
                f"\n[{backend}] --spec-type {spec_type}",
                file=sys.stderr,
            )
            port = find_free_port()
            argv = build_llama_server_args(
                gguf=gguf, port=port, device=device,
                spec_type=spec_type, n_gpu_layers=99, ctx_size=4096,
            )
            try:
                with LlamaServer(argv, port) as server:
                    results[spec_type] = _measure_one_spec(
                        server, prompt_tokens, gen_tokens, warmup, repeat,
                    )
            except RuntimeError as exc:
                msg = str(exc)
                if spec_type == "draft-mtp" and "mtp" in msg.lower():
                    print(
                        f"ERROR: model {model_id!r} has no MTP head"
                        f" (--spec-type draft-mtp rejected by"
                        f" llama-server). Pick an MTP-labeled model.",
                        file=sys.stderr,
                    )
                    sys.exit(1)
                raise

        row = format_mtp_row(
            model_id=model_id,
            backend=backend,
            off_tps=results.get("none"),
            on_tps=results.get("draft-mtp"),
        )
        rows.append(row)
        print("\n" + row, file=sys.stderr)

    print()
    print("| Model | Backend | MTP off (t/s) | MTP on (t/s) | Speedup |")
    print("| ----- | ------- | ------------: | -----------: | ------: |")
    for row in rows:
        print(row)
```

- [ ] **Step 4: Run unit tests to verify they pass**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 15 tests pass.

- [ ] **Step 5: Verify argparse still rejects empty / conflicting invocations**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 benchmark.py 2>&1 | head -3
echo "exit=$?"
```

Expected: `ERROR: at least one MODEL_ID is required ...` and `exit=2`.

- [ ] **Step 6: Commit**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git add pkgs/benchmark/tests/test_benchmark.py pkgs/benchmark/benchmark.py
git commit -m "feat(benchmark): implement run_mtp_ab + format_mtp_row"
```

---

## Task 8: Manual smoke tests (6 cases from the spec)

**Files:** none — runtime verification only.

**Pre-flight:** `sudo systemctl stop lemond` to free VRAM and avoid port contention.

- [ ] **Step 1: Bogus model ID → exit 2, no spawn**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
pgrep llama-server  # expect: no output
nix run .#benchmark -- --mtp-ab Nonexistent-Model-XYZ 2>&1 | tail -3
echo "exit=$?"
pgrep llama-server  # expect: still no output
```

Expected: `ERROR: model 'Nonexistent-Model-XYZ' not found in lemonade cache. Run: lemonade pull ...`, `exit=2`, no orphan.

- [ ] **Step 2: Valid but unpulled model → exit 2, no spawn**

Same as Step 1 but with `Qwen3.6-27B-MTP-GGUF` *before* pulling it.

```bash
nix run .#benchmark -- --mtp-ab Qwen3.6-27B-MTP-GGUF 2>&1 | tail -3
echo "exit=$?"
```

Expected: `exit=2`. If the model is already pulled from earlier exploration, skip this step and note it.

- [ ] **Step 3: Pulled non-MTP model → exit 1 with clean error**

Pre-condition: `Qwen3.5-9B-GGUF` already in `~/.cache/lemonade/models` from earlier README benchmarks.

```bash
ls ~/.cache/lemonade/models/Qwen3.5-9B-GGUF/ 2>&1 | head -3
nix run .#benchmark -- --mtp-ab Qwen3.5-9B-GGUF 2>&1 | tail -10
echo "exit=$?"
pgrep llama-server  # expect: no output
```

Expected: `--spec-type none` row should measure successfully, then `--spec-type draft-mtp` should fail at server startup, surfacing `ERROR: model 'Qwen3.5-9B-GGUF' has no MTP head ...`, `exit=1`, no orphan llama-server. **If draft-mtp does not reject non-MTP models at startup (e.g. the binary silently no-ops), document this finding in the README's methodology note — it changes how the A/B detects misconfiguration.**

- [ ] **Step 4: Happy path (deferred to Task 10 once models are pulled)**

Tracked as Task 10's responsibility. Do not run here.

- [ ] **Step 5: SIGINT mid-sweep**

Run the happy-path command but Ctrl-C ~5 seconds into the first server's measurement window:

```bash
nix run .#benchmark -- --mtp-ab Qwen3.6-27B-MTP-GGUF
# press Ctrl-C while it says "iter 1: ..." in stderr
pgrep llama-server  # expect: no output
```

Expected: no orphan `llama-server` processes. If `pgrep` returns a PID, the `LlamaServer.__exit__` reaping path is broken; investigate before proceeding.

- [ ] **Step 6: Regression on existing default mode**

```bash
sudo systemctl start lemond  # restore lemond
nix run .#benchmark -- Qwen3.5-9B-GGUF 2>&1 | tail -10
echo "exit=$?"
```

Expected: existing behavior unchanged — markdown table with one row, `exit=0` (or `exit=1` if t/s < 5, same as before).

- [ ] **Step 7: Stop lemond again before pulling MTP models**

```bash
sudo systemctl stop lemond
```

(Models still pull fine while lemond is stopped — `lemonade pull` runs as a CLI client and talks to the configured backend, but the pull itself only writes to the cache. If a future lemonade version changes that, restart lemond around `lemonade pull` calls.)

- [ ] **Step 8: Commit any fixes uncovered by the smoke tests**

If any of Steps 1-6 surfaced a bug, fix it and add a focused unit test if possible. Then:

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git add pkgs/benchmark/
git commit -m "fix(benchmark): <describe>"
```

If no fixes needed, no commit here — proceed to Task 9.

---

## Task 9: Pull models + quality gate

**Files:** none — runtime verification.

**Pre-condition:** `lemond` stopped (per Task 8 Step 7).

- [ ] **Step 1: Pull Qwen3.6-27B-MTP-GGUF**

```bash
lemonade pull Qwen3.6-27B-MTP-GGUF  # ~17 GB; can take 10-30 min
```

Expected: download completes; `lemonade list 2>&1 | grep -i 27b-mtp` shows downloaded.

- [ ] **Step 2: Pull Qwen3.6-35B-A3B-MTP-GGUF**

```bash
lemonade pull Qwen3.6-35B-A3B-MTP-GGUF  # ~20 GB
```

Expected: download completes.

- [ ] **Step 3a: Verify `llama-cli` accepts `--spec-type`**

```bash
llama-cli --help 2>&1 | grep -- '--spec-type'
```

Expected: one matching line listing `none,draft-simple,draft-eagle3,draft-mtp,...`. If absent, fall back to running `llama-server` for the quality gate (spawn it twice, send a single completion via `curl`, diff the response strings); update Steps 3 and 4 accordingly.

- [ ] **Step 3: Quality gate on 27B (byte-identical generated text under greedy)**

```bash
GGUF=$(python3 -c "import sys; sys.path.insert(0, 'pkgs/benchmark'); import benchmark; print(benchmark.resolve_lemonade_gguf('Qwen3.6-27B-MTP-GGUF'))")
echo "GGUF=$GGUF"

# --log-disable suppresses the banner/perf-summary noise so the diff
# only compares the generated tokens. -no-cnv runs in plain completion
# mode (no chat template). Adjust flag names if --help shows different
# spellings on this b9213 build.
llama-cli --model "$GGUF" --spec-type none      --temp 0 -n 64 \
  --log-disable -no-cnv \
  --prompt "Write a haiku about NPUs." > /tmp/mtp-off-27b.txt 2>/dev/null
llama-cli --model "$GGUF" --spec-type draft-mtp --temp 0 -n 64 \
  --log-disable -no-cnv \
  --prompt "Write a haiku about NPUs." > /tmp/mtp-on-27b.txt 2>/dev/null

if diff -q /tmp/mtp-off-27b.txt /tmp/mtp-on-27b.txt > /dev/null; then
  echo "QUALITY GATE PASS"
else
  echo "QUALITY GATE FAIL"
  diff /tmp/mtp-off-27b.txt /tmp/mtp-on-27b.txt | head -40
fi
```

Expected: `QUALITY GATE PASS`. If FAIL, abort — do not publish numbers; file an upstream bug with the diff. If the failure is clearly cosmetic (trailing whitespace, a single trailing token from EOS handling), document it in the README footnote rather than blocking — but the *prefix* of generated tokens must match.

- [ ] **Step 4: Quality gate on 35B-A3B**

Same as Step 3 with `Qwen3.6-35B-A3B-MTP-GGUF`. Expected: PASS.

- [ ] **Step 5: Commit the quality-gate evidence**

Save the (small, identical) outputs as benchmark evidence:

```bash
mkdir -p docs/superpowers/specs/mtp-evidence
cp /tmp/mtp-off-27b.txt docs/superpowers/specs/mtp-evidence/
cp /tmp/mtp-off-35b-a3b.txt docs/superpowers/specs/mtp-evidence/ 2>/dev/null || true
git add docs/superpowers/specs/mtp-evidence/
git commit -m "docs(benchmark): record MTP quality-gate outputs"
```

(If `git diff --cached` is empty because cli logs vary slightly, scrub the timing/log noise to a single representative line and re-add. Outputs being byte-identical refers to *the generated text*; logging headers may differ.)

---

## Task 10: Run real benchmark, capture numbers

**Files:** none — data capture.

**Pre-condition:** both models pulled, quality gate passed, `lemond` stopped.

- [ ] **Step 1: Warm GPU + run 27B sweep**

```bash
nix run .#benchmark -- --mtp-ab Qwen3.6-27B-MTP-GGUF 2>&1 | tee /tmp/mtp-27b.log
```

Expected: final markdown table with two rows (Vulkan + ROCm). Save the table to `/tmp/mtp-27b-table.md`.

- [ ] **Step 2: Run 35B-A3B sweep**

```bash
nix run .#benchmark -- --mtp-ab Qwen3.6-35B-A3B-MTP-GGUF 2>&1 | tee /tmp/mtp-35b.log
```

Expected: two more rows. Save table to `/tmp/mtp-35b-table.md`.

- [ ] **Step 3: Sanity-check the numbers**

For each row, confirm:
- MTP-on > MTP-off, OR documented in the README footnote if not.
- MTP-off matches existing non-MTP baselines within ~10% (e.g. 27B Vulkan MTP-off should be in the same ballpark as Gemma-4-26B Vulkan decode: ~17 t/s).
- No `N/A` cells (would indicate a measurement failure to investigate before publishing).

- [ ] **Step 4: Restart lemond**

```bash
sudo systemctl start lemond
```

- [ ] **Step 5: Commit the raw logs as evidence**

```bash
mkdir -p docs/superpowers/specs/mtp-evidence
cp /tmp/mtp-27b.log /tmp/mtp-35b.log docs/superpowers/specs/mtp-evidence/
git add docs/superpowers/specs/mtp-evidence/
git commit -m "docs(benchmark): record raw MTP A/B benchmark logs"
```

---

## Task 11: README — new "MTP speedup" subsection + Recommendation bullet

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read current README structure to find insertion point**

```bash
grep -n "^### \|^## " /home/noams/git/noamsto/nix-amd-ai/README.md | head -30
```

Find the line range that holds "Mid-size, chat-shaped: Qwen3.5-9B" (currently around lines 156-163) and the "Recommendation:" line that follows it (around line 165). The new subsection inserts between them.

- [ ] **Step 2: Insert the new subsection**

Edit `README.md`. Find:

```markdown
Notes: FLM's TTFT is dominated by a one-off NPU compile-to-cache; steady-state decode is the useful number. FLM's GGUF-vs-proprietary format means quantization isn't bit-identical to the llamacpp row, so treat these as same-family, not same-weights.

**Recommendation:**
```

Insert immediately before `**Recommendation:**` (after the `Notes:` paragraph):

```markdown
### MTP speedup: Qwen3.6 family (Q4_K_XL, llama.cpp b9213, lemonade v10.5.1)

Same GGUF, same prompt, only `--spec-type` flag changes. `llama-server` spawned directly (bypassing `lemond`) via `nix run .#benchmark -- --mtp-ab <model-id>`. Prompt 256, generation 128, 3 iterations after 1 warmup.

<!-- Replace cells with the numbers captured in Task 10. -->

| Model | Backend | MTP off (t/s) | MTP on (t/s) | Speedup |
| ----- | ------- | ------------: | -----------: | ------: |
| Qwen3.6-27B (dense)       | Vulkan | XX.X | XX.X | X.XXx |
| Qwen3.6-27B (dense)       | ROCm   | XX.X | XX.X | X.XXx |
| Qwen3.6-35B-A3B (MoE, 3B) | Vulkan | XX.X | XX.X | X.XXx |
| Qwen3.6-35B-A3B (MoE, 3B) | ROCm   | XX.X | XX.X | X.XXx |

MTP (multi-token prediction) is a small head on top of the base model that proposes several tokens per forward pass; `llama-server` verifies them in parallel against the base model and only keeps accepted ones, so output remains lossless under greedy sampling. See llama.cpp [#22673](https://github.com/ggml-org/llama.cpp/pull/22673) and lemonade [#1944](https://github.com/lemonade-sdk/lemonade/pull/1944). The `mtp` label in lemonade's `server_models.json` automatically enables `--spec-type draft-mtp` for these three models (27B dense, 35B-A3B MoE, and 122B-A10B MoE — the last doesn't fit cleanly in 64 GiB).

```

- [ ] **Step 3: Replace the placeholder cells with real numbers from Task 10**

For each `XX.X` and `X.XXx`, substitute the values from `/tmp/mtp-27b-table.md` and `/tmp/mtp-35b-table.md` (or the `docs/superpowers/specs/mtp-evidence/` copies).

Remove the `<!-- Replace cells ... -->` comment after substitution.

- [ ] **Step 4: Add a bullet to the existing "Recommendation:" list**

In the same file, find the `**Recommendation:**` block (the bulleted list with "General LLM inference", "Power-budget", "ROCm" entries). Append a new bullet at the end:

```markdown
- **MTP-labeled models (Qwen3.6 family):** pull the `-MTP-GGUF` variants and let lemonade pick `llamacpp:<backend>` — the model's `mtp` label auto-enables `--spec-type draft-mtp`, giving the speedup documented above. Non-MTP siblings will not use the draft head.
```

- [ ] **Step 5: Render-check the README locally**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
glow README.md 2>/dev/null | head -200 || cat README.md | head -250
```

(Or open in your usual markdown previewer.) Verify the new section sits between the Qwen3.5-9B row and the Recommendation list, the table renders correctly, and the new bullet appears in the recommendation list.

- [ ] **Step 6: Commit**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git add README.md
git commit -m "docs(readme): publish Qwen3.6 MTP A/B benchmark numbers

Adds a 'MTP speedup: Qwen3.6 family' subsection with same-GGUF
--spec-type none vs draft-mtp numbers on Vulkan and ROCm for the
27B dense and 35B-A3B MoE MTP-labeled models. Reproducer: nix run
.#benchmark -- --mtp-ab <model-id>."
```

---

## Task 12: Build verification + final PR

**Files:** none — verification only.

- [ ] **Step 1: Verify the benchmark package still builds**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
nix build .#benchmark --print-out-paths
```

Expected: build succeeds, prints a `/nix/store/...-benchmark` path. The Python script must pass `writePython3Bin`'s built-in lint checks.

- [ ] **Step 2: Verify `nix flake check` still passes**

```bash
nix flake check
```

Expected: no errors.

- [ ] **Step 3: Verify the full unit-test suite still passes**

```bash
cd /home/noams/git/noamsto/nix-amd-ai/pkgs/benchmark && python3 -m unittest tests.test_benchmark -v
```

Expected: 15 tests pass.

- [ ] **Step 4: Open the PR**

```bash
cd /home/noams/git/noamsto/nix-amd-ai
git push -u origin HEAD
gh pr create --assignee @me --title "feat(benchmark): MTP A/B mode + Qwen3.6 published numbers" --body "$(cat <<'EOF'
## Summary
- New `--mtp-ab <model-id>` mode in `pkgs/benchmark/benchmark.py`. Spawns `llama-server` directly twice per backend (`--spec-type none` vs `--spec-type draft-mtp`) on the same GGUF, prints a markdown row with the speedup ratio. Bypasses `lemond` entirely.
- Published numbers added to README "Which backend should I use?" — new "MTP speedup: Qwen3.6 family" subsection covering `Qwen3.6-27B-MTP-GGUF` and `Qwen3.6-35B-A3B-MTP-GGUF` on Vulkan and ROCm.
- Recommendation list gains an MTP-labeled-models bullet.

## Test plan
- [x] Unit tests for pure helpers (`find_free_port`, `resolve_lemonade_gguf`, `parse_llama_devices`, `pick_device`, `build_llama_server_args`, `format_mtp_row`) via `python3 -m unittest`.
- [x] Manual smoke tests from spec: bogus ID, unpulled model, non-MTP model, SIGINT mid-sweep, regression on existing default mode.
- [x] Quality gate: byte-identical output under `--temp 0` for both MTP models.
- [x] `nix build .#benchmark` and `nix flake check` clean.

Spec: `docs/superpowers/specs/2026-05-19-mtp-benchmarks-design.md`
Plan: `docs/superpowers/plans/2026-05-19-mtp-benchmarks.md`
EOF
)"
```

Expected: PR URL printed.
