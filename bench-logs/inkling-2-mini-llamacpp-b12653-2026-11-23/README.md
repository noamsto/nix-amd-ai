# llama.cpp b12653 pin: Flash-Next MTP regression check and Inkling-2-Mini smoke — Strix Halo, gfx1151

Question (#367): pin llama.cpp past nixpkgs' build 12110 so Inkling-2-Mini loads
(ggml-org/llama.cpp#32694 and #32704, both in b12653, neither in 12110), and check the pin does
not cost the Qwen3.8-Flash-Next MTP decode win.

Every number is Strix Halo (Ryzen AI MAX+ 395, Radeon 8060S, gfx1151); none of it transfers to
other GPU targets. Build under test: llama.cpp b12653, commit `7d9b931`, from the flake pin.
Baseline: nixpkgs' llama.cpp build 12110.

## Method

- Part 1: Flash-Next UD-IQ4_XS, `mtp-ab.sh` (prompt 512, generate 128, 1 warmup + 3 measured),
  same files and flags as `qwen38-flash-next-llamacpp-12110-2026-11-13`, run through that
  directory's gated `rows.sh`.
- Part 2: `smoke.sh` (this directory) against `llama-server` loaded directly
  (`-ngl 99 -c 8192 --jinja`) behind the same gated harness hand-off, **not** through lemond:
  loading through lemond would have meant registering the model in the host's running service,
  which was out of bounds.
- The committed `smoke.sh` was hardened (cleanup, port and backend checks) after the measured runs;
  the request and measurement logic is unchanged.

## 1. Flash-Next MTP regression check

Vulkan, one pass each:

| Build | MTP off (t/s) | MTP on (t/s) | Speedup |
| --- | ---: | ---: | ---: |
| 12110 | 28.0 | 39.2 | 1.40× |
| b12653 | 28.2 | 40.7 | 1.44× |

ROCm, every run in order of execution (MTP off / MTP on, t/s):

| Run | 12110 | b12653 |
| --- | ---: | ---: |
| 1 | 23.6 / 43.0 | |
| 2 | | 23.8 / 37.2 |
| 3 | | 23.6 / 41.9 |
| 4 | 23.7 / 47.3 | |
| 5 | 23.8 / 40.9 | |
| 6 | | 23.7 / 41.3 |
| 7 | 22.9 / 38.6 | |

Runs 1-2 and 3-4 were back-to-back pairs (old then new, then new then old). The third series
was meant to be six interleaved rows but was cut short after three (runs 5-7: 12110, b12653,
12110) by a memory-pressure kill of the runner; the remaining rows have no results.

MTP-on mean: 12110 **42.5** t/s (range 38.6-47.3, four runs), b12653 **40.1** t/s (range
37.2-41.9, three runs). The mean gap is -5.5%, but the ranges overlap heavily.
b12653 was slower in two of three adjacent ROCm pairs (12110 43.0 vs b12653 37.2, -13.5%;
b12653 41.9 vs 12110 47.3, -11.4%) and level in the third (12110 40.9 vs b12653 41.3, +1.0%);
with 12110 alone spanning 38.6-47.3, three runs cannot separate this from noise. MTP-off is
level (mean 23.5 on 12110 vs 23.7 on b12653). **The ROCm gap is within run-to-run
noise and not proven either way.** Vulkan shows no regression.

The 24.0 / 40.4 ROCm and 27.4 / 42.1 Vulkan figures in
`qwen38-flash-next-llamacpp-12110-2026-11-13` are a different session.

## 2. Inkling-2-Mini smoke

`ggml-org/Inkling-2-Mini-GGUF` IQ4_NL (17.6 GB) with its Q8_0 mmproj. Architecture
`general.architecture = inkling2_loop`. The model emits `reasoning_content` before `content`.
Single runs, one request each; 216 generated tokens (text) and 43 (image).

| Prompt | Answer | Vulkan decode (t/s) | ROCm decode (t/s) |
| --- | --- | ---: | ---: |
| Text: "In two sentences, what is the capital of France and why is it famous?" | "The capital of France is Paris. It is famous as a global center of art, fashion, gastronomy, and culture, home to landmarks such as the Eiffel Tower, the Louvre, and Notre-Dame." | 35.2 (prompt 109.6) | 24.2 (prompt 79.3) |
| Image: 64x64 solid red PNG, "What colour is this image? One word." (via the mmproj) | "Red" | 36.0 | 24.6 |

### Lemonade's architecture allowlist

lemonade's HF-variant pull path checks GGUF architectures against a static allowlist
(`llamacpp_architectures_generated.h`) that has no `inkling2_loop`, so it would refuse this model
as incompatible with llama.cpp even though b12653 loads it. This PR adds the entry in
`pkgs/lemonade`. Verified by build only, not by pulling the model.

## Not measured

- End-to-end through lemond.
- gfx1150.
- The Q8_0 quant of the model.
- Whether #32704 (the loop-architecture fix) is needed: only b12653, which has both PRs, was
  tested; whether pre-#32704 output differs is untested.
- Prefill, depth and quality for Flash-Next on b12653.
