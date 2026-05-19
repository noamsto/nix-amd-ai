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

    def test_returns_none_when_model_dir_has_no_gguf(self):
        with tempfile.TemporaryDirectory() as tmp:
            model_dir = pathlib.Path(tmp) / "Qwen3.6-27B-MTP-GGUF"
            model_dir.mkdir()
            (model_dir / "config.json").write_text("{}")
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


class ParseLlamaDevicesTests(unittest.TestCase):
    ROCM_OUTPUT = (
        "Available devices:\n"
        "  ROCm0: AMD Radeon 890M Graphics (27935 MiB, 49248 MiB free)\n"
    )
    VULKAN_OUTPUT = (
        "Available devices:\n"
        "  Vulkan0: AMD Radeon 890M Graphics (RADV STRIX1)"
        " (36127 MiB, 35117 MiB free)\n"
    )

    def test_parses_rocm(self):
        self.assertEqual(
            benchmark.parse_llama_devices(self.ROCM_OUTPUT),
            ["ROCm0"],
        )

    def test_parses_vulkan(self):
        self.assertEqual(
            benchmark.parse_llama_devices(self.VULKAN_OUTPUT),
            ["Vulkan0"],
        )

    def test_empty_output_returns_empty(self):
        self.assertEqual(benchmark.parse_llama_devices(""), [])

    def test_non_empty_output_with_no_devices_raises(self):
        # Simulates a format change where llama-server emits text but
        # nothing matching a known device prefix.
        with self.assertRaises(RuntimeError):
            benchmark.parse_llama_devices(
                "Some unrelated diagnostic output: foo bar\n"
            )

    def test_header_only_output_raises(self):
        # "Available devices:" line alone, no device entries — should
        # raise rather than return [].
        with self.assertRaises(RuntimeError):
            benchmark.parse_llama_devices("Available devices:\n")


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


class BuildLlamaServerArgsTests(unittest.TestCase):
    def test_includes_required_flags(self):
        args = benchmark.build_llama_server_args(
            bin_path="/nix/store/abc/bin/llama-server",
            gguf="/tmp/model.gguf",
            port=18080,
            device="Vulkan0",
            spec_type="draft-mtp",
            n_gpu_layers=99,
            ctx_size=4096,
        )
        self.assertEqual(args[0], "/nix/store/abc/bin/llama-server")
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
            bin_path="/usr/bin/llama-server",
            gguf="/tmp/model.gguf",
            port=18080,
            device="ROCm0",
            spec_type="none",
            n_gpu_layers=99,
            ctx_size=4096,
        )
        self.assertIn("--spec-type", args)
        self.assertIn("none", args)


if __name__ == "__main__":
    unittest.main()
