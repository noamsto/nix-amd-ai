# Performance measurements

Benchmark tables moved out of the README. Each states its host; numbers are hardware-specific and do not transfer between GPU targets. Per-run evidence with reproduction scripts lives in the [bench-logs index](../bench-logs/README.md).

## Strix Point (gfx1150): Vulkan vs ROCm vs FLM

All numbers measured on Strix Point (gfx1150, Radeon 890M iGPU, 64 GiB DDR5-5600). Prompt 256 tokens, generation 128 tokens, 3 iterations after 1 warmup.

> **⚠️ The ROCm rows below were measured on a numerically broken backend.** gfx1150 is hit by the same RDNA3.5 host-access bug as gfx1151: on this host, ROCm reads perplexity 250,459 against a CPU reference of 385 for the very Gemma-4-26B-A4B model benchmarked here (and 1,638 vs 6.79 for Qwen3.5-4B), while CPU and Vulkan are correct. The throughput figures are real, but they time a backend producing garbage, so the ROCm-vs-Vulkan comparison is not a choice worth making from these numbers. Upstream has since fixed the underlying regression (`d4389a4d`, [ggml-org/llama.cpp#28604](https://github.com/ggml-org/llama.cpp/issues/28604)), and this flake's llama.cpp pin (b11382) is past that revert, so no patch is carried anymore. The rows below are left in place, unrevised, until they can be re-measured on the fixed build. Vulkan and FLM rows are unaffected. See [rocm-gfx1151-numerics.md](rocm-gfx1151-numerics.md).

### Large: Gemma-4-26B-A4B-it-GGUF (~15.7 GB, via `llama-bench`, llama.cpp b8770)

| Metric | ROCm | Vulkan | Winner |
| ------ | ---- | ------ | ------ |
| Prefill (pp512) | 360 ± 18 t/s | 370 ± 3 t/s | Vulkan (+3%, within noise) |
| Decode (tg128)  | 13.86 ± 0.18 t/s | 17.52 ± 0.33 t/s | Vulkan (+26%) |

### Mid-size, chat-shaped: Qwen3.5-9B (same family on all three backends)

| Backend | Model | TTFT (s) | Decode (t/s) |
| ------- | ----- | -------: | -----------: |
| Vulkan (llamacpp:vulkan) | `Qwen3.5-9B-GGUF` (UD-Q4_K_XL) | 1.36 | 12.9 +/- 0.1 |
| ROCm (llamacpp:rocm)     | `Qwen3.5-9B-GGUF` (UD-Q4_K_XL) | 1.69 | 10.8 +/- 0.1 |
| FLM (flm:npu)            | `qwen3.5-9b-FLM`               | 4.17 | 11.9 +/- 4.5 |

Notes: FLM's TTFT is dominated by a one-off NPU compile-to-cache; steady-state decode is the useful number. FLM's GGUF-vs-proprietary format means quantization isn't bit-identical to the llamacpp row, so treat these as same-family, not same-weights.


## Strix Halo (gfx1151 / XDNA2 NPU5): NPU measured

The tables above are Strix Point. These rows are from a Strix Halo host: ASUS ROG Flow Z13 (GZ302EA), Ryzen AI MAX+ 395, 128 GB, NixOS 26.11, kernel 7.1.0 with in-tree `amdxdna` 0.8, NPU firmware 1.1.2.65, `fastflowlm` 0.9.43. These figures run ahead of community Strix Point numbers for the same model, but the cause is not established here and nothing below depends on it. (It is not the column count: Strix Point, Krackan and Halo are all XDNA2 with the same 8-column array, as noted in the README's Krackan Point note.)

| Test | Result |
| ---- | ------ |
| `flm validate` | rc=0, 8-column NPU, FW 1.1.2.65, `Memlock Limit: infinity` |
| Llama-3.2-1B (q4nx, `--pmode performance`) | **~49–50 t/s** decode |
| Llama-3.1-8B | ~8 t/s decode |
| Package power (RAPL), idle → 1B inference | 5.1 W → 19.5 W (**+14.4 W**, includes CPU serving overhead) |
| **NPU 1B + iGPU ROCm 7B concurrently** | NPU ~40 t/s, **iGPU 37.1 t/s (full speed, no degradation)**, 36.2 W total |

The concurrency row is the interesting one: an NPU workload running alongside an iGPU ROCm workload costs the iGPU nothing measurable and costs the NPU about 20%. That is a genuine low-power co-processor for small models while the iGPU handles 7B and up — not a way to make one model faster.

**The NPU niche on Halo is genuinely small models (1–3B).** At 8B the NPU manages ~8 t/s while the iGPU runs the same class of model several times faster, so the NPU is a power and concurrency play, never a throughput win. Route big models to Vulkan/ROCm and keep the NPU for the small resident one.

**Firmware on kernel ≥7.0 needs no DKMS.** In-tree `amdxdna` prefers `amdnpu/17f0_11/npu_7.sbin` (→ `1.1.2.65`) over the default `npu.sbin` (→ `1.0.0.166`), so FastFlowLM's ≥1.1.0.0 requirement is met out of the box. Check with `cat /sys/class/accel/accel0/device/fw_version`.


## Recommendation

- **General LLM inference (7B–26B Q4):** use **Vulkan**. On Strix Point 890M with llama.cpp b8770, Vulkan wins decode at every size tested and ties or wins prefill. The previous "ROCm for prefill-heavy" advice no longer holds now that ROCm targets gfx1150 natively (the gfx1102 Tensile arch-logic was apparently more tuned than gfx1150's is today).
- **Power-budget / idle-GPU scenarios:** use **FLM/NPU** — decode is competitive with Vulkan and offloads the GPU, but the compile-on-first-load TTFT is noticeable.
- **ROCm** is kept installed as a fallback and for ecosystem tooling (`rocminfo`, profiling, HIP apps); re-evaluate when newer rocBLAS/Tensile logic for gfx1150 lands.
- **RDNA3.5 iGPU numerics.** Stock `llamacpp:rocm` returned near-random tokens on gfx1150 and gfx1151 until upstream fixed it (`d4389a4d`, [ggml-org/llama.cpp#28604](https://github.com/ggml-org/llama.cpp/issues/28604)); this flake's llama.cpp pin (b11382) is past that fix and carries no patch. Full diagnosis and history: [rocm-gfx1151-numerics.md](rocm-gfx1151-numerics.md). Still open, tracked there: the gfx1150 ROCm benchmark rows above (Gemma-4-26B-A4B, Qwen3.5-9B) were measured through the old, broken host-memory path and want re-running against the unpatched b11382 build.

Enable all three and let lemonade pick the recipe per model.


## OpenFlowLM-Next (`oflm`) on Strix Halo

Measured on one Strix Halo host only (Ryzen AI MAX+ 395, XDNA2 NPU, 8 columns), 2026-09-28,
with the module-wrapped binary:

| check | result |
|---|---|
| `oflm validate` | ready, 8 columns, firmware OK |
| `llama3.2:1b` chat (closed kernels) | 63.5 tok/s decode, 100 tok/s prefill (43-token prompt, 128 tokens out) |
| `lfm2:1.2b` chat on sandbox-built open kernels | packaged `LFM2-1.2B-NPU2/open_kernels` set selected; coherent output; 35.9 tok/s decode, 40.6 tok/s prefill (17-token prompt, 128 tokens out) |
| `all-minilm:l6-v2` embeddings on sandbox-built BERT set | 384-dim, unit-norm, finite; cosine 0.70 for two paraphrases vs −0.03 for an unrelated pair |
| lemonade 11.9.0 via `LEMONADE_FLM_NPU_BIN` | flm backend `installed` at `v0.1.0` (not flagged for update), 44 FLM models listed, `llama3.2-1b-FLM` chat served by `oflm serve` |

These are single runs, not a benchmark, and are not comparable to the
FastFlowLM numbers elsewhere in these docs.

**Not tested:** the other 10 open-kernel models and 4 BERT sets on hardware;
any host other than that Strix Halo one (Strix Point, Krackan); `oflm add` / `q4nx-build` and
OFLM's Python utilities (not built here: `OFLM_BUILD_UTILITIES=OFF`);
lemonade's embeddings route with OFLM's BERT models.

### OpenFlowLM-Next packaging notes

Moved from the README's OpenFlowLM-Next section:

- Of the open kernel sets for 11 models (12 recipe specs), `gemma3-12b`'s set is overwritten by `gemma3-4b`'s, an upstream naming quirk.
- A model file whose size differs from OFLM's manifest is treated as missing; upstream prints that warning to stderr, keeping the `oflm list --json` stdout a single JSON document for lemonade to parse (upstream [#133](https://github.com/Atomic-Germ/OpenFlowLM-Next/issues/133)).
- `openflowlm.kernels` is a cheap join over the per-set derivations, built in parallel locally and as a per-set CI matrix (`kernel-sets.json`).
