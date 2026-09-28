#!/usr/bin/env python3
"""Stdlib-only runner for OFLM-Next's specs/server-api/tests/*.py.

Those files import pytest for markers (skipif/parametrize) but their test
bodies use only urllib/json/math from the standard library (see spec.md:28-32
in the OFLM-Next repo). This shims just enough of pytest's marker API to
collect and run them with plain python3, no pip install.
"""
import importlib.util
import os
import signal
import sys
import types

PER_TEST_TIMEOUT = int(os.environ.get("OFLM_HARNESS_TEST_TIMEOUT", "60"))


class _AlarmTimeout(Exception):
    pass


def _alarm_handler(signum, frame):
    raise _AlarmTimeout(f"test exceeded {PER_TEST_TIMEOUT}s (server may be hung/crashed)")


class SkipMark(Exception):
    def __init__(self, cond, reason=""):
        self.cond = cond
        self.reason = reason

    def __call__(self, fn):
        if self.cond:
            fn.__skip__ = True
            fn.__skip_reason__ = self.reason
        return fn


class ParamMark:
    def __init__(self, argnames, argvalues):
        self.argnames = argnames
        self.argvalues = argvalues

    def __call__(self, fn):
        fn.__params__ = (self.argnames, self.argvalues)
        return fn


class Mark:
    @staticmethod
    def skipif(cond, reason=""):
        return SkipMark(cond, reason)

    @staticmethod
    def parametrize(argnames, argvalues):
        return ParamMark(argnames, argvalues)


pytest_shim = types.ModuleType("pytest")
pytest_shim.mark = Mark()
def _skip(reason=""):
    raise SkipMark(True, reason)


pytest_shim.skip = _skip
sys.modules["pytest"] = pytest_shim


def load_module(path):
    name = os.path.splitext(os.path.basename(path))[0]
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def expand_params(argnames, argvalues):
    names = [n.strip() for n in argnames.split(",")] if isinstance(argnames, str) else list(argnames)
    cases = []
    for v in argvalues:
        if len(names) == 1:
            cases.append({names[0]: v})
        else:
            cases.append(dict(zip(names, v)))
    return cases


def record(results, mod_name, label, verdict, detail):
    results.append((mod_name, label, verdict, detail))
    line = f"{verdict:6} {mod_name}::{label}"
    if detail:
        line += f"  -- {' '.join(str(detail).split())}"
    print(line, flush=True)


def run_module(path, results):
    mod_name = os.path.basename(path)
    try:
        mod = load_module(path)
    except Exception as e:
        record(results, mod_name, "<import>", "ERROR", f"{type(e).__name__}: {e}")
        return

    module_skip = getattr(mod, "pytestmark", None)
    module_marks = module_skip if isinstance(module_skip, list) else [module_skip] if module_skip else []
    active_skip = next((m for m in module_marks if isinstance(m, SkipMark) and m.cond), None)
    if active_skip:
        for fname in dir(mod):
            if fname.startswith("test_"):
                record(results, mod_name, fname, "SKIP", active_skip.reason)
        return

    test_fns = []
    for fname in dir(mod):
        if not fname.startswith("test_"):
            continue
        fn = getattr(mod, fname)
        if callable(fn):
            test_fns.append((fn.__code__.co_firstlineno, fname, fn))
    test_fns.sort(key=lambda t: t[0])

    had_signal = hasattr(signal, "SIGALRM")
    if had_signal:
        signal.signal(signal.SIGALRM, _alarm_handler)

    for _, fname, fn in test_fns:
        if getattr(fn, "__skip__", False):
            record(results, mod_name, fname, "SKIP", getattr(fn, "__skip_reason__", ""))
            continue
        params = getattr(fn, "__params__", None)
        cases = expand_params(*params) if params else [{}]
        for case in cases:
            label = fname if not case else f"{fname}[{case}]"
            try:
                if had_signal:
                    signal.alarm(PER_TEST_TIMEOUT)
                fn(**case)
                if had_signal:
                    signal.alarm(0)
                record(results, mod_name, label, "PASS", "")
            except AssertionError as e:
                if had_signal:
                    signal.alarm(0)
                record(results, mod_name, label, "FAIL", str(e))
            except _AlarmTimeout as e:
                record(results, mod_name, label, "ERROR", str(e))
            except SkipMark as e:
                if had_signal:
                    signal.alarm(0)
                record(results, mod_name, label, "SKIP", e.reason)
            except Exception as e:
                if had_signal:
                    signal.alarm(0)
                record(results, mod_name, label, "ERROR", f"{type(e).__name__}: {e}")


def main():
    paths = sys.argv[1:]
    results = []
    for p in paths:
        run_module(p, results)

    counts = {}
    for _, _, verdict, _ in results:
        counts[verdict] = counts.get(verdict, 0) + 1
    print("\n=== Summary ===")
    print("  " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))

    return 1 if counts.get("FAIL") or counts.get("ERROR") else 0


if __name__ == "__main__":
    sys.exit(main())
