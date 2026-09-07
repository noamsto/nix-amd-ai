# llamacpp:rocm was numerically broken on gfx1151 — fixed, patch carried here

**Status (2026-09-07): fixed.** This flake patches `llama-cpp-rocm` with
`865374bb` from [ggml-org/llama.cpp#28211](https://github.com/ggml-org/llama.cpp/issues/28211)
— *"hip: disable direct host access on gfx1151"* — and ROCm now agrees with CPU
and Vulkan to 0.2%. `llamacpp:rocm` is usable again on Strix Halo.

**Root cause.** gfx1151 reports as an integrated GPU, so ggml allowed tensors to
live in *host* memory for the GPU to read directly. On this chip that hands back
wrong data. Nothing downstream can recover from it — which is why the corruption
was independent of quantization, of the matmul path, and of the ROCm version.

| | before | after |
| --- | ---: | ---: |
| `-ngl 0` | 6.8024 | 6.8182 |
| `-ngl 32` | 15.6257 | **6.8182** |
| `-ngl 99` | 1326.89 | **6.8182** |

Identical at every offload depth, as a correct backend must be. The `-ub` shape
dependence below — four orders of magnitude — also collapses, to
6.8171/6.8171/6.8298/6.8182, i.e. ordinary floating-point noise.

The rest of this document is the diagnosis that led there. It is kept because
the eliminations are what make the conclusion trustworthy, and because the same
loop re-runs in ~25 s if this ever regresses.

## Post-fix throughput (gfx1151, patched ROCm vs Vulkan)

The patch moves tensors out of host memory into device memory, and upstream
framed that as avoiding *"UMA prefill latency regressions"* — so it is worth
knowing what it costs. `llama-bench`, Qwen3.5-4B `UD-Q4_K_XL`, `-ngl 99 -r 3`,
on this Halo host (Ryzen AI MAX+ 395, gfx1151, kernel 7.2.2, ROCm 7.2.3,
nixpkgs llama.cpp 0.3.0 **with the patch**):

| Backend | pp512 | tg128 |
| --- | ---: | ---: |
| ROCm (patched) | 1900.72 ± 33.74 t/s | 58.38 ± 0.11 t/s |
| Vulkan | 2001.00 ± 2.60 t/s | 62.39 ± 0.04 t/s |
| | Vulkan +5.3% | Vulkan +6.9% |

**Vulkan still wins, but now for the ordinary reason.** The old advice to prefer
Vulkan on this part stands; what changed is that it rests on a few percent of
throughput rather than on ROCm being wrong.

**The patch shows no prefill blow-up.** ROCm prefill sits 5% behind Vulkan, in
the same range as the gfx1150 tables in the README. Note there is no meaningful
"before" to difference against: pre-patch throughput was the speed of a backend
computing garbage, so it is not a baseline. ROCm's prefill variance is ~13x
Vulkan's (±33.74 vs ±2.60), which is worth remembering before leaning on a
single ROCm prefill figure.

Different model and host from the README's benchmark tables, so this is recorded
here rather than substituted into them.

## Follow-ups this opens

- **Re-measure the gfx1151 ROCm benchmarks.** Partly done — "Post-fix
  throughput" above covers a 4B `llama-bench` run on a patched build, and shows
  no prefill regression. Still open: the `NPU 1B + iGPU ROCm 7B concurrently`
  row in the README and the conclusion drawn from it. That was measured through
  the old host-memory path on the *other* Halo host (ASUS ROG Flow Z13, kernel
  7.1.0), so it needs that machine and the NPU workload to redo — it cannot be
  regenerated from this box.
- **Check gfx1150.** The broken condition was `integrated && is_cuda_host(buft)`,
  which applies to *any* integrated GPU; the fix exempts gfx1151 by name only.
  Strix Point is also integrated and also RDNA3.5, so it may be affected and
  unpatched. The README's main ROCm-vs-Vulkan tables are gfx1150 and are
  throughput-only, so their correctness half has never been checked. One
  `llama-perplexity` run (CPU vs Vulkan vs ROCm) on that host settles it; if it
  is also broken, `ggml_cuda_is_gfx1151` needs widening to RDNA3.5 upstream.

## What was measured

Measured 2026-09-06/07 on **this** Halo host and nowhere else — Ryzen AI MAX+ 395,
gfx1151 (Radeon 8060S), kernel 7.2.2, `linux-firmware` 20260810, rocm-runtime
7.2.3, nixpkgs `llama-cpp` 0.3.0 (llama.cpp build b10566, plus master b10830).
Nothing here is claimed for gfx1150, for other kernels, or for other ROCm
versions. Every number below is the **pre-fix** state.

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
`-ngl 99` is byte-identical, so the entire 196x blowup is **one tensor** moving
to the GPU. Qwen3.5 ties its embeddings, so that tensor is `token_embd.weight`
(`Q6_K`, `2560 x 248320`) doing double duty as the head — not a separate
`output.weight`. It produces the logits directly, which is why corrupting it
randomises token choice instead of merely dulling output.

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
| hipBLASLt | `ROCBLAS_USE_HIPBLASLT=0` vs `=1` | 1326.89 vs 1310.89 -- path changed, both garbage |
| Our packaging / ROCm version | AMD lemonade prebuilt gfx1151, ROCm 10.1.0a | reproduces both defects |
| Kernel fusion | `GGML_CUDA_DISABLE_FUSION=1` | unchanged |
| CUDA graphs | `GGML_CUDA_DISABLE_GRAPHS=1` | unchanged |
| Quant-specific kernel | uniform Q8_0 and Q4_0 requants | both equally broken; Q8_0 worst |
| Wrong ISA / arch override | `HSA_OVERRIDE_GFX_VERSION` unset | not in play |
| Races, preemption, thermal | repeat runs byte-identical | deterministic, so excluded |

**Quantization is not the cause.** `llama-quantize --allow-requantize` turned the
mixed UD quant into uniform `Q8_0` and uniform `Q4_0`, sidestepping the K-quant
family entirely. Each model is compared against its *own* CPU run, so the lossy
requantization cancels and only the CPU-to-GPU gap is read. All rows on master
b10830:

| Model | CPU | `-ngl 32` | `-ngl 99` |
| --- | ---: | ---: | ---: |
| UD-Q4_K_XL (mixed; Q6_K head) | 6.8024 | 15.6257 | 1326.89 |
| **uniform Q8_0** | 6.8149 | 15.6392 | **1615.93** |
| **uniform Q4_0** | 7.2878 | 18.8125 | **1337.73** |

Every quant is healthy on CPU and equally broken on GPU, and `Q8_0` — the
highest-precision and a completely different dequant path from the K-quants — is
the *worst* of the three at full offload. So this is not a K-quant kernel, not a
precision effect, and not specific to the head's `Q6_K`.

Note what the head actually is: Qwen3.5-4B ties its embeddings, so there is no
separate `output.weight`. The head is `token_embd.weight`, `Q6_K`,
`2560 x 248320` — a 635M-parameter tensor, by far the largest matmul in the model
and a shape unlike any layer GEMM. With quantization eliminated, **size/shape is
the remaining suspect**, which is exactly what the `-ub` sweep already implied.

`GGML_CUDA_FORCE_MMQ` / `GGML_CUDA_FORCE_CUBLAS` would have discriminated the
GEMM path directly, but no longer exist in this llama.cpp version.

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

## It is not our packaging: AMD's own gfx1151 build reproduces it

[`lemonade-sdk/llamacpp-rocm`](https://github.com/lemonade-sdk/llamacpp-rocm)
publishes daily prebuilt ROCm binaries per GPU target, including a dedicated
`gfx1151` one. Release `b1325` bundles its own ROCm runtime
(`libamdhip64.so.7.16.26332`, ROCm **10.1.0a20260822**) and builds llama.cpp
`3ad1b`. Run under `steam-run` with the same model, corpus and flags:

| `-ngl` | ours (nixpkgs, ROCm 7.2.3, b10830) | lemonade b1325 (ROCm 10.1.0a, `3ad1b`) |
| --- | ---: | ---: |
| 0 | 6.8024 | 6.8288 |
| 32 | 15.6257 | **15.6608** |
| 99 | 1326.89 | **1334.57** |

Both defects reproduce at near-identical magnitude across **two ROCm major
versions**, a different llama.cpp commit, and a vendor-produced binary. That
rules out our nixpkgs derivation, our build flags, and ROCm 7.2.3 specifically.

It also closes off the obvious escape hatch: the `llamacpp:system` recipe wired
through `LEMONADE_GGML_HIP_PATH` points at exactly this build, so switching to it
does not help.

Their `-ngl 32` figure matches our *master* (15.63), not our shipped b10566
(9.07) — independent corroboration of the regression recorded below.

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
