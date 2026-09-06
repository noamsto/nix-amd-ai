# llamacpp:rocm is numerically broken on gfx1151

**Do not use the `llamacpp:rocm` recipe on Strix Halo.** Use `llamacpp:vulkan`.
It is not a speed question: the ROCm backend returns wrong numbers, and a model
served through it produces near-random tokens.

Measured 2026-09-06 on **this** Halo host and nowhere else — Ryzen AI MAX+ 395,
gfx1151 (Radeon 8060S), kernel 7.2.2, `linux-firmware` 20260810, rocm-runtime
7.2.3, nixpkgs `llama-cpp` 0.3.0 (llama.cpp build b10566). Nothing here is
claimed for gfx1150, for other kernels, or for other ROCm versions.

## The measurement

`llama-perplexity` over a fixed 51 KB corpus, `-c 512 --chunks 6 --seed 42 -t 8`,
Qwen3.5-4B `UD-Q4_K_XL` (`n_layer = 32`). Same model, same corpus, same flags —
only the backend changes. Repeat runs are byte-identical, so every number below
is deterministic rather than a sample.

| Backend (as wired in `/etc/lemonade/backends`) | PPL | |
| --- | ---: | --- |
| CPU | 6.8056 | reference |
| Vulkan, `-ngl 99` | 6.8067 | 0.02% from CPU — correct |
| **ROCm, `-ngl 99`** | **1334.0014** | **196x worse — garbage** |

A perplexity of 1334 against a reference of 6.81 is not degraded output, it is
noise. That is what the reports of tool-call loops and mid-task stalls look like
from inside a harness: the logits themselves are wrong, so token selection is
effectively random.

## Two separate defects

Sweeping `-ngl` (how many layers go to the GPU) separates them.

| `-ngl` | 0 | 1 | 4 | 8 | 16 | 24 | 32 | 33 | 99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| PPL | 6.79 | 6.79 | 6.85 | 7.86 | 8.90 | 9.13 | 9.07 | **1334.00** | **1334.00** |

**Per-layer corruption.** Error accumulates with each offloaded layer: already
~15% degraded at 8 layers, which is far outside floating-point noise — Vulkan at
*full* offload stays within 0.02% of CPU.

**A catastrophic output head.** The model has 32 layers, and `-ngl 33` logs
`offloaded 33/33`: layers plus the output head. Everything from `-ngl 33` to
`-ngl 99` is byte-identical, so the entire 196x blowup is one tensor — `lm_head`
— moving to the GPU. It produces the logits directly, which is why corrupting it
randomises output instead of merely dulling it.

## It is shape-dependent

Micro-batch size moves the error by four orders of magnitude, and moves the two
defects in *opposite* directions:

| `-ub` | 64 | 128 | 256 | 512 | 1024 |
| --- | ---: | ---: | ---: | ---: | ---: |
| PPL, `-ngl 99` (head on GPU) | 229,871 | 251,392 | 38,075 | 1,334 | 14.24 |
| PPL, `-ngl 32` (head on CPU) | — | 7.15 | — | 9.07 | — |

That signature — deterministic, shape-keyed, opposite-signed — points at a
tiling/remainder bug in a kernel, not at general numerical noise.

## Ruled out

Each tested by changing one variable against the same loop. Where an env var was
used, its presence in the loaded library was verified first with `grep -a`
(`strings` is not installed on this host and silently returns nothing).

| Hypothesis | Test | Result |
| --- | --- | --- |
| Flash attention | `-fa off` / `-fa on` | both garbage (1332 / 1334) |
| SDMA copy path | `HSA_ENABLE_SDMA=0` | unchanged (var confirmed read by ROCr) |
| Kernel fusion | `GGML_CUDA_DISABLE_FUSION=1` | unchanged |
| CUDA graphs | `GGML_CUDA_DISABLE_GRAPHS=1` | unchanged |
| Wrong ISA / arch override | `HSA_OVERRIDE_GFX_VERSION` unset | not in play |
| Races, preemption, thermal | repeat runs byte-identical | deterministic, so excluded |

**Not tested, and the best remaining lead:** a quant-specific dequant/GEMM
kernel. The clean experiment is the same model in BF16 vs Q8_0 vs Q4_K; the only
non-K-quant models on this host are eagle3 speculative drafts, which cannot run
standalone (`eagle3 requires ctx_other to be set`). `GGML_CUDA_FORCE_MMQ` /
`GGML_CUDA_FORCE_CUBLAS` would have discriminated the GEMM path but no longer
exist in this llama.cpp version.

## Prior art upstream

"ROCm produces garbage on gfx1151 while Vulkan is fine on the same box" is a
known, recurring class of bug in llama.cpp — not one bug, a family of them, each
found and fixed per model architecture or per kernel:

| Upstream | Symptom | State |
| --- | --- | --- |
| [llama.cpp#17797](https://github.com/ggml-org/llama.cpp/issues/17797) | gfx1151 ROCm gibberish, Vulkan unaffected | **closed** by [#17817](https://github.com/ggml-org/llama.cpp/pull/17817), merged 2025-12-06 — MMF fp16/bf16 matmul was being used on RDNA3 where it computes wrong results; fix restricts MMF to RDNA4 |
| [llama.cpp#21416](https://github.com/ggml-org/llama.cpp/issues/21416) | gfx1151 ROCm endless loop of garbage tokens on gemma-4-26B-A4B; Vulkan *and* CUDA correct | **open** |
| [llama.cpp#27856](https://github.com/ggml-org/llama.cpp/issues/27856) / [#27941](https://github.com/ggml-org/llama.cpp/pull/27941) | qwen4exp garbage on gfx1151 over ROCm 7.x, traced to the KV/QSA indexer | fixed ~2026-08-31 |
| [TheRock#7714](https://github.com/ROCm/TheRock/issues/7714) | Gemma-4-E4B emits only `<unused49>` past ~7k ctx on gfx1151, ROCm 10.1.0a nightly; the 7.14 release build is correct | open |

Two things follow for this host. The #17797 fix predates our build by eight
months, so this is **not** that bug. And our build is llama.cpp `bb4caa7`
(2026-08-21), which **predates** the qwen4exp fix — though that one is specific
to a different architecture than the qwen35 model measured here.

So the finding above is not a novel class. What it adds is the part the upstream
reports do not have: a deterministic numeric metric instead of "looks like
gibberish", the offload boundary that localises the blowup to the output head,
and the `-ub` dependence. If this is filed upstream, those are the parts worth
carrying.

## Current master still reproduces it — and the per-layer defect is worse

Built llama.cpp master `465e49b9` (build 10830, 2026-09-06) against the same
ROCm 7.2.3, `CMAKE_HIP_ARCHITECTURES=gfx1151`, and ran the identical loop. That
is 264 commits ahead of the shipped build; nothing else changed.

| `-ngl` | b10566 (shipped, 2026-08-21) | **b10830 (master, 2026-09-06)** |
| --- | ---: | ---: |
| 0 (CPU) | 6.7926 | 6.8024 |
| 32 (layers, head on CPU) | 9.0662 | **15.6257** |
| 99 (head on GPU) | 1334.0014 | **1326.8934** |

The output-head blowup is unchanged. The per-layer corruption has **regressed**,
from 9.07 to 15.63 — 2.3x the CPU reference where it used to be 1.3x. So this is
a live bug on current master, not something already fixed and merely absent from
our pin, and bumping llama.cpp would make one half of it worse.

That makes it worth filing upstream. The open reports
([llama.cpp#21416](https://github.com/ggml-org/llama.cpp/issues/21416) in
particular) describe the same "ROCm garbage on gfx1151, Vulkan fine" shape but
carry no numeric metric, no offload boundary, and no shape sweep.

## What this says about #105

[#105](https://github.com/noamsto/nix-amd-ai/issues/105) reports models
misbehaving on this exact kernel + firmware pair and recommends pinning
`linux-firmware` to 20260622 and the kernel to 7.1.8. The symptom is real and the
report was worth filing — it is what led here. The proposed cause is not
supported by these measurements:

- Firmware and kernel are shared by all three backends, and **two of the three
  are numerically perfect** on the suspect firmware. A shared cause cannot
  produce a backend-specific failure.
- The one firmware-carried path that Vulkan never exercises is SDMA, and
  disabling it changes nothing.

So the firmware downgrade is an expensive remedy — it rebuilds a large part of
the system — for a fault it probably does not touch, and it leaves the actual
broken path in place. Switching the recipe to `llamacpp:vulkan` costs nothing
and is measurably correct.

This does **not** prove firmware is irrelevant: the A/B against 20260622 has not
been run, and it is now cheap to run, because the loop above is a ~25 s
red/green signal. `scripts/` carries no harness for this; the commands are all in
this document.

Symptom reported by [@rabejens](https://github.com/rabejens) in #105.
