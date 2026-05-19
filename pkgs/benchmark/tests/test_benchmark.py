"""Unit tests for benchmark.py pure helpers."""

# pyright: reportAttributeAccessIssue=false

import os
import pathlib
import sys
import tempfile
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
