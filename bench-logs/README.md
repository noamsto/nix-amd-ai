# Bench logs

Raw `llama-bench` output kept for provenance behind decisions made elsewhere.
Host is per-row below — not all runs are on the same machine.

| Run | Host | What it tested | Outcome |
| --- | --- | --- | --- |
| `rocwmma-2026-05-19` | Strix Point (gfx1150, Radeon 890M, 64 GiB DDR5-5600) | llama.cpp with the rocWMMA flash-attn build flag vs a plain ROCm baseline | **Net regression** — `pp4096` 368.50 → 213.84 t/s (−42%) at head_dim 256. Flag left off. |
| `mtp-2026-05-24` | Strix Point | `--mtp-ab` decode A/B on a 27B model | Provisional — not run on an idle GPU under the performance power profile, so the deltas are not authoritative. |
| `mtp-2026-05-31` | Strix Point | same A/B via the Go benchmark TUI | Provisional, same caveat. |
| [`llamacpp-b11207-2026-09-27`](llamacpp-b11207-2026-09-27/) | halo (gfx1151, Radeon 8060S, 123 GiB RAM) | llama.cpp b10964 (old/`main`) vs b11207 (new) A/B — Vulkan on 3 models, ROCm on the 27B, plus ROCm perplexity vs the 6.8182 reference | Vulkan pp512 **+15% to +82%** across models; one small tg128 regression on gpt-oss-120b Vulkan (**−4.0%**); ROCm perplexity unchanged (6.8311, within 0.2% of reference on both builds). |
| [`oflm-bert-npu-2026-09-27`](oflm-bert-npu-2026-09-27/) | halo (gfx1151, Radeon 8060S, 123 GiB RAM, XDNA2 NPU) | OpenFlowLM-Next BERT export patch: device-free build (single tier + full 4-tier/16-design BERT-h384-bfp16 family), byte-comparison vs the bcaee46 reference, and a hardware check loading the built xclbin via `pyxrt` | Patch upstreamed as [PR #126](https://github.com/Atomic-Germ/OpenFlowLM-Next/pull/126); 17/17 `insts*.bin` byte-identical to reference; hardware pass at kernel level (3 shapes, `ERT_CMD_STATE_COMPLETED`, correlation >0.9999 vs CPU) — full embedding-vector gate still unverified. |
| [`gptoss-tg-bisect-2026-09-27`](gptoss-tg-bisect-2026-09-27/) | halo | Re-test of the above gpt-oss-120b Vulkan tg128 −4.0% claim with **14 interleaved old/new rounds** (varied order, idle-GPU guard) | **Not reproducible** — paired Δ = −0.04% (t = −0.045); under quiet host load new is ~1.4% *faster* (ns). Run-to-run spread and host load each dwarf the claimed effect. No bisect run. |
| [`oflm-api-conformance-2026-09-27`](oflm-api-conformance-2026-09-27/) | halo (XDNA2 NPU) | OpenFlowLM-Next's stdlib-only server conformance tests against `flm serve` (FLM v1.0.6) — first time this suite has targeted FLM | **Server crashes dominate** — `POST {}` (a missing required field) kills the process outright on at least three endpoints; a malformed-UTF-8 body leaks the NPU lock forever. Model-identity substitution and embedding task-prompt validation are also non-conformant. `finish_reason`/stream-parity are fully compliant. #157's status-mapping fix could not be exercised on hardware — every request that should reach it instead crashed the server first. |

The rocWMMA result is why `llama-cpp-rocm` ships plain; see
`docs/therock-eval-results.md`, which argues rocWMMA should be **on** for
gfx1151 even though it loses here on gfx1150.

## Building llama.cpp with rocWMMA

Distilled from the four build logs of the 2026-05-19 run, which are not tracked
(3.6K lines of compiler output). Needed if the gfx1151 case is ever revisited,
since the flake ships with the flag off and records no working recipe.

`-DGGML_HIP_ROCWMMA_FATTN=TRUE` alone fails: `ggml-cuda/vendors/hip.h` cannot
find `rocwmma/rocwmma-version.hpp`, because rocWMMA is a separate output that
llama.cpp's HIP path never adds to the include search. Passing it via
`-isystem` still fails — the header resolves only with a plain `-I`:

    -DCMAKE_HIP_FLAGS:STRING=-I${rocwmma}/include

Build was `llama-cpp-mtp` 9213 against ROCm 7.2.2 / rocWMMA 7.2.2, all fourteen
`gfx*` targets. With that flag the build completes (loop-unroll warnings from
`fattn-tile.cuh` only) — and then loses 42% of `pp4096`.
