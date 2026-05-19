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
    MODEL_ID = "Qwen3.6-27B-MTP-GGUF"
    HF_DIR = "models--unsloth--Qwen3.6-27B-MTP-GGUF"

    def test_returns_none_when_cache_root_missing(self):
        # Point at a path that doesn't exist
        with tempfile.TemporaryDirectory() as tmp:
            result = benchmark.resolve_lemonade_gguf(
                self.MODEL_ID,
                cache_root=str(pathlib.Path(tmp) / "nonexistent"),
            )
            self.assertIsNone(result)

    def test_returns_none_when_model_dir_missing(self):
        # Cache root exists but no matching models--*--<id> dir
        with tempfile.TemporaryDirectory() as tmp:
            result = benchmark.resolve_lemonade_gguf(
                self.MODEL_ID,
                cache_root=tmp,
            )
            self.assertIsNone(result)

    def test_returns_none_when_model_dir_has_no_gguf(self):
        with tempfile.TemporaryDirectory() as tmp:
            model_dir = pathlib.Path(tmp) / self.HF_DIR / "snapshots" / "abc"
            model_dir.mkdir(parents=True)
            (model_dir / "config.json").write_text("{}")
            result = benchmark.resolve_lemonade_gguf(
                self.MODEL_ID,
                cache_root=tmp,
            )
            self.assertIsNone(result)

    def test_finds_gguf_in_snapshots_subdir(self):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot_dir = pathlib.Path(tmp) / self.HF_DIR / "snapshots" / "abc"
            snapshot_dir.mkdir(parents=True)
            gguf = snapshot_dir / "Qwen3.6-27B-UD-Q4_K_XL.gguf"
            gguf.write_bytes(b"")
            result = benchmark.resolve_lemonade_gguf(
                self.MODEL_ID,
                cache_root=tmp,
            )
            self.assertEqual(result, str(gguf))

    def test_ignores_other_models_in_cache(self):
        # Cache contains other HF models, none matching our id
        with tempfile.TemporaryDirectory() as tmp:
            other = (
                pathlib.Path(tmp)
                / "models--unsloth--SomeOtherModel-GGUF"
                / "snapshots" / "def"
            )
            other.mkdir(parents=True)
            (other / "irrelevant.gguf").write_bytes(b"")
            result = benchmark.resolve_lemonade_gguf(
                self.MODEL_ID,
                cache_root=tmp,
            )
            self.assertIsNone(result)

    def test_ignores_non_model_directories(self):
        # Subdir not matching `models--*--*` pattern is ignored
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / "version.txt").write_text("1")
            (pathlib.Path(tmp) / "tmp_dir").mkdir()
            (pathlib.Path(tmp) / "models--malformed").mkdir()
            result = benchmark.resolve_lemonade_gguf(
                self.MODEL_ID,
                cache_root=tmp,
            )
            self.assertIsNone(result)


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
        expected_pairs = [
            ("--model", "/tmp/model.gguf"),
            ("--port", "18080"),
            ("--host", "127.0.0.1"),
            ("--device", "Vulkan0"),
            ("--spec-type", "draft-mtp"),
            ("--n-gpu-layers", "99"),
            ("--ctx-size", "4096"),
            ("--parallel", "1"),
            ("--spec-draft-n-max", "6"),
        ]
        for flag, value in expected_pairs:
            self.assertIn(flag, args)
            idx = args.index(flag)
            self.assertEqual(
                args[idx + 1], value,
                f"{flag} not immediately followed by {value!r}",
            )

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
        # --spec-draft-n-max is only relevant when speculative decoding
        # is on; should be absent for spec_type='none'.
        self.assertNotIn("--spec-draft-n-max", args)


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

    def test_on_tps_none_also_shows_na(self):
        row = benchmark.format_mtp_row(
            model_id="X",
            backend="rocm",
            off_tps=20.0,
            on_tps=None,
        )
        self.assertIn("N/A", row)
        # speedup column must also be N/A when on_tps is None
        self.assertEqual(row.count("N/A"), 2)


class BuildMtpPromptTests(unittest.TestCase):
    def test_returns_naturalistic_english(self):
        prompt = benchmark.build_mtp_prompt(64)
        # Should contain well-known opening lines (canary check)
        self.assertIn("quick brown fox", prompt)

    def test_length_scales_with_token_count(self):
        small = benchmark.build_mtp_prompt(16)
        large = benchmark.build_mtp_prompt(256)
        self.assertGreater(len(large), len(small))

    def test_token_count_estimate_is_in_ballpark(self):
        # ~3.5 chars per English token, so 100 tokens ~= 350 chars
        # Our formula uses 4 chars per token, so output should be ~400 chars
        prompt = benchmark.build_mtp_prompt(100)
        self.assertGreater(len(prompt), 300)
        self.assertLess(len(prompt), 500)


if __name__ == "__main__":
    unittest.main()
