# Inkling-2-Mini ROCm compute-buffer blowup — Strix Halo, gfx1151

Question (#378, from the report in #377): loading Unsloth's `Inkling-2-Mini-UD-Q4_K_XL.gguf` through
`lemond` on the ROCm llama.cpp backend fails after the weights load, with `allocating 102253.34 MiB on
device 0` / `failed to allocate compute pp buffers`. Why is the compute (prompt-processing) buffer that
large, and which settings bring it down?

Every number is Strix Halo (Ryzen AI MAX+ 395, Radeon 8060S, gfx1151, 104 GiB GTT); nothing here is
shown to transfer to other GPU targets. Build under test: llama.cpp b12653 (`7d9b931`) from this flake's
pin, ROCm and Vulkan builds; Lemonade 2026.47.1. File: `unsloth/Inkling-2-Mini-GGUF`
`Inkling-2-Mini-UD-Q4_K_XL.gguf` at HF snapshot `8078d149286eec7193795413b9e0643da6d11fa1`
(17,629,760,736 bytes, sha256 matches the HF LFS oid), plus its `mmproj-F16.gguf` for one row.

## Short answer

The compute buffer grows **linearly with context and with `-ub`**, and for `inkling2_loop` it is huge per
token: with flash attention on and `-ub 512` it is **99.0 KiB per context token**. Extrapolated to the
model's trained context (1,048,576 tokens) that is **101,564 MiB, within 0.7% of the reported 102,253 MiB**.
So the report matches: flash attention on (the llama.cpp default, `-fa auto` resolves to on for this
model on both backends), `-ub` at its default 512, and a context at the model's full trained window.
lemond's default `ctx_size` is `-1` (auto), which resolves to as many tokens as free memory allows, capped
at the trained window; its sizing reserves a few GiB for the compute buffer that does not grow with
context, so on a machine with enough free memory auto picks the full window. Setting an explicit
`ctx_size` (for example 131072) brings the buffer to about 12.6 GiB; no lemond or module change is
needed to avoid the failure, though a change could keep auto from picking an unusable size (see
Findings).

## Method

- `probe.sh` (this directory): one `llama-server` per row, `-ngl 99 -c <ctx> -ub <ub> -fa <on|off|auto>
  --fit off --parallel 1 --jinja -lv 4`, stopped as soon as the context's compute buffer is logged. `-lv 4`
  is needed: at the default level 3 this build does not log buffer sizes. The script prints only parsed
  sizes (device and host-pinned compute buffer, KV, weights). It runs a series in ascending context and
  skips the rest of a series when the extrapolated next compute buffer, or the last measured one, exceeds
  24 GiB (`GUARD_MIB`); no context above 32768 is allowed. Nothing near the reported 102 GiB was ever
  allocated.
- Every GPU process ran through the repository's gated harness
  (`bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/run.sh exec`), which unloads the resident model,
  holds the GPU signal file and restores the resident model afterwards. `NEED_GIB` was weights + 24 GiB
  compute cap + KV at the largest context of the call + 4 GiB margin (48 for this file).
- `lemond-argv.sh` (this directory): a scratch `lemond` on a loopback port with its own cache and config
  directories, a hub cache holding the file, `llamacpp.args` set as the NixOS module sets it
  (`--flash-attn on`), the model pulled with `POST /api/v1/pull`, its options read with
  `GET /api/v1/models/<id>/options`, then one load at an explicit `ctx_size` 4096 on ROCm to read the
  spawned `llama-server`'s argv. It never loads at the auto size.
- To reproduce a single row outside this harness (needs the file and a llama.cpp build for the backend):
  `llama-server -m Inkling-2-Mini-UD-Q4_K_XL.gguf -ngl 99 -c 8192 -ub 512 -fa on -lv 4`, then read the
  `compute buffer size` line for the device.

## Scaling table (measured)

Device compute buffer in MiB at context 4096 / 8192 / 16384 / 32768, UD-Q4_K_XL, one run per cell:

| Backend | ub | FA | 4096 | 8192 | 16384 | 32768 |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| rocm | 512 | on | 584 | 980 | 1,772 | 3,356 |
| rocm | 512 | off | 790 | 1,382 | 2,566 | 4,934 |
| rocm | 2048 | on | 2,355 | 3,939 | 7,107 | 13,443 |
| rocm | 2048 | off | 3,183 | 5,551 | 10,287 | 19,759 |
| vulkan | 512 | on | 597 | 993 | 1,880 | 3,377 |
| vulkan | 512 | off | 803 | 1,425 | 2,665 | 5,024 |
| vulkan | 2048 | on | 2,668 | 4,618 | 7,786 | 4,522 (+12,918 host) |
| vulkan | 2048 | off | 3,534 | 7,105 | 11,412 | 2,657 (+19,234 host) |

Other measured rows:

- Weights: 16,332 MiB on the device (ROCm and Vulkan) plus 469 MiB host-pinned. KV: 368 / 496 / 752 /
  1,264 MiB at 4096 / 8192 / 16384 / 32768 for `-ub 512` (0.031 MiB per token above 8192; the sliding-window
  half of the cache is sized by window plus `-ub`, so it is 608 / 736 / 992 / 1,504 MiB at `-ub 2048`).
  KV is the same with FA on and off and on both backends.
- `-fa auto` at ctx 8192, `-ub 512`: ROCm 980 MiB, Vulkan 993 MiB, the same as FA on (the log reports
  "Flash Attention enabled").
- ROCm with the mmproj (`--mmproj mmproj-F16.gguf`, ctx 8192, `-ub 512`, FA on): the language-model buffers
  are unchanged (980 MiB compute); the projector adds its own 99 MiB device compute buffer.
- ROCm `--fit on` (the llama-server default), ctx 4096: the fit pass projected 17,288 MiB for the device
  against 106,349 MiB free and changed nothing; the real run then used 16,332 + 371 + 584 = 17,287 MiB.
  Only measured at ctx 4096: `--fit on` at a large context was deliberately not run.
- The Vulkan `-ub 2048` cells at 32768 are not comparable to their row: the scheduler split the graph
  into 34 pieces instead of 2 and placed 12.9 / 19.2 GiB of the compute buffer in host-pinned memory.
  Device plus host is 17,440 / 21,891 MiB there, against ROCm's 13,443 + 456 / 19,759 + 628. Cause of the
  split not measured.

## Fit and extrapolation (extrapolated, not measured)

Least squares over the four contexts per ROCm series; the maximum residual is 0 MiB, so the relation is
exactly linear in this range. Compute buffer in MiB ≈ intercept + slope × context tokens:

| ROCm series | Slope (KiB per token) | Intercept (MiB) | At 131,072 | At 869,891 | At 1,048,576 (trained) |
| --- | ---: | ---: | ---: | ---: | ---: |
| ub 512, FA on | 99.0 | 188 | 12,860 MiB (12.6 GiB) | 84,286 MiB (82.3 GiB) | **101,564 MiB (99.2 GiB)** |
| ub 512, FA off | 148.0 | 198 | 19,142 MiB | 125.9k MiB | 151,750 MiB (148 GiB) |
| ub 2048, FA on | 396.0 | 771 | 51.5k MiB | 337k MiB | 406,275 MiB |
| ub 2048, FA off | 592.0 | 815 | 76.6k MiB | 504k MiB | 607,023 MiB |

- The slope is proportional to `-ub` (ratio 4.00 between `-ub` 512 and 2048 in both FA modes), so the
  buffer is proportional to context × `-ub`: about 198 bytes per cell with FA on, 296 with FA off. Which
  tensor that is was not identified.
- Nothing above ctx 32768 was run; every value in the last three columns is extrapolated from the linear
  fit, including the match to the report. The 0.7% gap (101,564 vs 102,253 MiB) is unexplained; the
  reporter's llama.cpp build and exact arguments are unknown.
- Only FA on with `-ub` 512 lands near the report. FA off at the trained window would be 148 GiB; larger
  `-ub` is far above it.

## Answers

1. **What argv does lemond build?** Read from `llamacpp_server.cpp` and confirmed from the spawned process
   (explicit `ctx_size` 4096, mmproj present, module-style `llamacpp.args`):
   `llama-server -m <gguf> --ctx-size 4096 --port <port> --jinja --metrics --mmproj <mmproj>
   --flash-attn on --parallel 1`. lemond adds `--parallel 1` itself and `-b/-ub 2048` only for the
   `nathanw` and `halobox` backends; it never passes `-ub`, `--no-mmap` or anything model-specific for
   this model, so `-ub` is llama-server's 512. `--flash-attn on` comes from `llamacpp.args`, which the
   NixOS module sets; without it llama-server's own `-fa auto` also enables flash attention for this model
   (measured above). `ctx_size` defaults to `-1`, which lemond resolves itself (below).
2. **How does the buffer scale?** Linearly in context and in `-ub`, table above. FA off costs 1.5× the
   buffer of FA on at the same `-ub`.
3. **Which configuration reproduces ~102 GiB?** Extrapolated, not measured: FA on, `-ub` 512, context
   1,048,576 (the trained window) gives 101,564 MiB, 0.7% below the report. lemond's auto size is what
   gets there without a user setting: `resolved_ctx_size` for this model on this host, with the resident
   model unloaded and ROCm selected, is **869,891** (the earlier Vulkan IQ4_NL load in
   the scratch-lemond IQ4_NL load in the #367 session, whose logs were not committed, resolved 876,675). That is read from lemond's options
   endpoint, not loaded. At that size the extrapolated ROCm compute buffer is 82.3 GiB, with about 26.5
   GiB of KV and 16 GiB of weights on top, so it would also fail on this host (104 GiB GTT). The
   reporter's free memory is unknown; auto is `min(memory budget, trained window)`, and a larger budget
   gives exactly the 1,048,576 that matches their number. Read from source, not measured: lemond's budget
   (`auto_context_budget.h`) reserves compute workspace as 4% of the weights clamped to 0.5-3 GiB on a
   unified-memory GPU, a constant that does not grow with context, so it does not account for this
   model's 99 KiB per token.
4. **Is it specific to `inkling2_loop`?** Yes. ggml-org's IQ4_NL of the same model gives identical
   buffers to the Unsloth file to the hundredth of a MiB (584.22 / 1,772.22 MiB at 4096 / 16384 FA on,
   789.71 / 2,565.71 FA off, `-ub` 512, ROCm), so the quant does not matter. Qwen3.8-27B UD-Q4_K_XL
   (ordinary 27B, similar file size, ROCm, `-ub` 512) needs 146 / 158 MiB at 4096 / 16384 with FA on
   (about 1 KiB per token) and 280 / 880 MiB with FA off (about 49 KiB per token): about 100× less with FA
   on and 3× less with FA off than Inkling-2-Mini.
5. **Does Vulkan allocate the same buffer?** At `-ub` 512 yes, within 6% of ROCm in every cell (table),
   with the same linear growth (99.5 KiB per token FA on). The Vulkan `-ub 2048` rows are irregular at
   32768 (split graph, above). So the size is not ROCm-specific; what differs at scale is not measured.
   One unreconciled prior observation (from that same uncommitted #367 run): the Vulkan IQ4_NL load through lemond at auto context
   876,675 with `--flash-attn on` succeeded with a GTT peak growth of about 49 GiB, far below the
   extrapolated ~82 GiB compute buffer plus ~27 GiB KV. Why (for example Vulkan committing the buffer
   lazily) was not tested.

## Findings

- Cause: ctx × `-ub` times a large per-cell constant for `inkling2_loop`, at a context of the full
  trained window.
- Settings that work (extrapolated beyond ctx 32768, measured at and below it): set `ctx_size` explicitly.
  FA on, `-ub` 512 (the defaults) at ctx 65,536 / 131,072 / 262,144 gives a compute buffer of about 6.4 /
  12.6 / 24.9 GiB plus KV of about 2 / 4 / 8 GiB. Lowering `-ub` shrinks the buffer in proportion at the
  cost of prefill speed (the effect on speed was not measured). Do not raise `-ub` (the `nathanw` and
  `halobox` backends' default 2048 would be 4× larger).
- Possible lemond change, described, not applied: make the auto-context budget include a compute buffer
  term proportional to context and `-ub`, or cap auto for architectures whose compute buffer is not
  constant. A module-side alternative is a default `ctx_size` for `llamacpp`.

## Not measured

- Any context above 32768, and any allocation near the reported size (deliberately; hardware-safety rule).
  Everything at 131,072 and above is extrapolated.
- `--fit on` at a large context, `-ub` below 512, `-ub` 1024, other quants, gfx1150.
- Vulkan for the comparison model, Vulkan with the mmproj, and what lemond resolves on the reporter's
  hardware.
- Which tensor carries the 99 KiB per token, why Vulkan splits the `-ub 2048` / ctx 32768 graph, and the
  0.7% gap to the report.
- Prefill or decode speed at any setting here.
