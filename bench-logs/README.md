# Bench logs

Benchmark and probe evidence kept for provenance behind decisions made elsewhere.
Host is per-row below — not all runs are on the same machine.

Each run keeps a README with the decisive numbers and the scripts that reproduce it; raw logs are not committed.

| Run | Host | What it tested | Outcome |
| --- | --- | --- | --- |
| `rocwmma-2026-05-19` | Strix Point (gfx1150, Radeon 890M, 64 GiB DDR5-5600) | llama.cpp with the rocWMMA flash-attn build flag vs a plain ROCm baseline | **Net regression** — `pp4096` 368.50 → 213.84 t/s (−42%) at head_dim 256. Flag left off. |
| `mtp-2026-05-24` | Strix Point | `--mtp-ab` decode A/B on a 27B model | Provisional — not run on an idle GPU under the performance power profile, so the deltas are not authoritative. |
| `mtp-2026-05-31` | Strix Point | same A/B via the Go benchmark TUI | Provisional, same caveat. |
| [`llamacpp-b11207-2026-09-27`](llamacpp-b11207-2026-09-27/) | halo (gfx1151, Radeon 8060S, 123 GiB RAM) | llama.cpp b10964 (old/`main`) vs b11207 (new) A/B — Vulkan on 3 models, ROCm on the 27B, plus ROCm perplexity vs the 6.8182 reference | Vulkan pp512 **+15% to +82%** across models; one small tg128 regression on gpt-oss-120b Vulkan (**−4.0%**); ROCm perplexity unchanged (6.8311, within 0.2% of reference on both builds). |
| [`oflm-bert-npu-2026-09-27`](oflm-bert-npu-2026-09-27/) | halo (gfx1151, Radeon 8060S, 123 GiB RAM, XDNA2 NPU) | OpenFlowLM-Next BERT export patch: device-free build (single tier + full 4-tier/16-design BERT-h384-bfp16 family), byte-comparison vs the bcaee46 reference, and a hardware check loading the built xclbin via `pyxrt` | Patch upstreamed as [PR #126](https://github.com/Atomic-Germ/OpenFlowLM-Next/pull/126); 17/17 `insts*.bin` byte-identical to reference; hardware pass at kernel level (3 shapes, `ERT_CMD_STATE_COMPLETED`, correlation >0.9999 vs CPU) — full embedding-vector gate still unverified. |
| [`gptoss-tg-bisect-2026-09-27`](gptoss-tg-bisect-2026-09-27/) | halo | Re-test of the above gpt-oss-120b Vulkan tg128 −4.0% claim with **14 interleaved old/new rounds** (varied order, idle-GPU guard) | **Not reproducible** — paired Δ = −0.04% (t = −0.045); under quiet host load new is ~1.4% *faster* (ns). Run-to-run spread and host load each dwarf the claimed effect. No bisect run. |
| [`oflm-api-conformance-2026-09-27`](oflm-api-conformance-2026-09-27/) | halo (XDNA2 NPU) | OpenFlowLM-Next's stdlib-only server conformance tests against `flm serve` (FLM v1.0.6) — first time this suite has targeted FLM | **Server crashes dominate** — `POST {}` (a missing required field) kills the process outright on at least three endpoints; a malformed-UTF-8 body leaks the NPU lock forever. Model-identity substitution and embedding task-prompt validation are also non-conformant. `finish_reason`/stream-parity are fully compliant. #157's status-mapping fix could not be exercised on hardware — every request that should reach it instead crashed the server first. |
| [`oflm-api-conformance-2026-09-27-after-171`](oflm-api-conformance-2026-09-27-after-171/) | halo (XDNA2 NPU) | Rerun of PR #169's OFLM-Next server-api conformance suite against `flm serve` patched for #171 (request validation, NPU-lock RAII guard, extended error-status mapping) | `test_request_validation.py` 0→**14/14 PASS** (no more server crashes); `test_error_status.py`'s invalid-UTF-8 NPU-lock-leak case ERROR→PASS. Remaining FAILs are model-identity substitution and embedding prompt-name validation, both out of scope for #171. |
| [`oflm-api-conformance-2026-09-28-after-178`](oflm-api-conformance-2026-09-28-after-178/) | halo (XDNA2 NPU) | `GET /api/ps` red/green across seven `flm serve` states (no tag, non-chat tag, chat, `--embed 1` with and without a chat model, non-chat then load, polled during the first load), plus a rerun of OFLM-Next's server-api conformance suite on the #178 build | No chat model loaded: 400→**200 `{"models":[]}`**; a loaded `--embed` model is now listed; the loaded chat model's entry is unchanged. Conformance outcomes are identical to after-174. |
| [`oflm-api-conformance-2026-09-28-after-173`](oflm-api-conformance-2026-09-28-after-173/) | halo (XDNA2 NPU) | Model-tag substitution (#173): red/green plus a rerun of the OFLM-Next server-api suite | An unknown model tag now answers 400 `model_not_found` instead of loading another model; `/api/ps` keeps the served model. `test_error_status.py` **PASS 8**. |
| [`oflm-api-conformance-2026-09-28-after-174`](oflm-api-conformance-2026-09-28-after-174/) | halo (XDNA2 NPU) | `prompt_name`/`task_type` on `/v1/embeddings` (#174): red/green plus task-prompt probes | `test_embed_task_prompt.py` FAIL 2 → **FAIL 0, PASS 3**; the task-prompt probes go from 10 FAIL to all PASS. |
| [`oflm-api-conformance-2026-09-28-after-175`](oflm-api-conformance-2026-09-28-after-175/) | halo (XDNA2 NPU) | Error bodies without exception text (#175): red/green plus a suite rerun | A `json::exception` in a request now answers a generic 400 "Invalid request" instead of leaking the exception text (and a 500 on `stream:"yes"`); suite results unchanged. |
| [`oflm-api-conformance-2026-09-28-after-180`](oflm-api-conformance-2026-09-28-after-180/) | halo (XDNA2 NPU) | Non-streaming `/api/chat` decode faults (#180): fault-injection red/green, byte-for-byte normal-path check, suite rerun | A decode fault now answers **500** `Internal error` instead of 400 `Invalid request`; normal responses are identical between builds for both models. |
| [`oflm-api-conformance-2026-09-28-after-181`](oflm-api-conformance-2026-09-28-after-181/) | halo (XDNA2 NPU) | Malformed `details.family` in the model list (#181): red/green plus a suite rerun | Load fails as **500** `model_load_failed` instead of 400 `Invalid request`; suite results unchanged. |
| [`oflm-api-conformance-2026-09-28-after-181-audit`](oflm-api-conformance-2026-09-28-after-181-audit/) | halo (XDNA2 NPU) | Audit of #181's fix: malformed `name`/`flm_min_version` on the same load path | Both now fail as **500** `model_load_failed` (red: 400); the `details.family` case does not regress. |
| [`oflm-api-conformance-2026-09-28-after-187`](oflm-api-conformance-2026-09-28-after-187/) | halo (XDNA2 NPU) | Streaming `/api/chat` segfault (#187, double `insert()`, no `generate()`): red/green plus a suite rerun | Red: every streaming `/api/chat` request segfaulted the server, 4 passed / 8 failed; green: **12 passed, 0 failed**, streamed text equals the non-streaming reply. |
| [`flm-ps-race-2026-09-28`](flm-ps-race-2026-09-28/) | halo (XDNA2 NPU) | `GET /api/ps` races model swaps (#184, #192): ThreadSanitizer red/green, NPU-lock and disconnect probes, `/api/ps` during a swap, suite rerun | TSan red reproduces both races (PASS 2/2), green PASS 5/5 with `other=0`; `/v1/completions` and `/api/embeddings` now queue behind a chat; no stale model listed after a swap. |
| [`oflm-api-conformance-2026-09-28-after-191`](oflm-api-conformance-2026-09-28-after-191/) | halo (XDNA2 NPU) | Decode continuing after the client disconnects (#191): six-endpoint red/green plus a suite rerun | `disconnect.sh` 28 passed / 20 failed → **48 passed, 0 failed**. |
| [`oflm-api-conformance-2026-09-28-after-194`](oflm-api-conformance-2026-09-28-after-194/) | halo (XDNA2 NPU) | Connection slot released exactly once on disconnect (#194): red/green, slot-counter check, suite rerun | Final connection after 12 aborts: `Connection reset by peer` with 3 `Connection limit reached` lines → **ACCEPTED**, 0 lines. |
| [`flm-accept-reset-2026-09-28`](flm-accept-reset-2026-09-28/) | halo (XDNA2 NPU) | Accept loop after a client resets before accept (#202): red/green, slot-counter check, suite rerun | `GET /api/version` timed out after 1 cycle (red) → **200 ×15** (green). |
| [`flm-accept-error-2026-10-04`](flm-accept-error-2026-10-04/) | halo (XDNA2 NPU) | Accept loop under descriptor exhaustion (#207): red/green CPU and recovery | Exhausted CPU **296.0 % → 0.0 %**; both builds accept again once the limit is restored. |
| [`rebase-206-2026-09-29`](rebase-206-2026-09-29/) | halo (XDNA2 NPU) | `disconnect.sh` (chat, generate) on the build rebased onto main after #206 | **16 passed, 0 failed** on llama3.2:1b and gemma4-it:e4b. |

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
