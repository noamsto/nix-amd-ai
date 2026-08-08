# Bench logs

Raw `llama-bench` output kept for provenance behind decisions made elsewhere.
All runs on Strix Point (gfx1150, Radeon 890M, 64 GiB DDR5-5600).

| Run | What it tested | Outcome |
| --- | --- | --- |
| `rocwmma-2026-05-19` | llama.cpp with the rocWMMA flash-attn build flag vs a plain ROCm baseline | **Net regression** — `pp4096` 368.50 → 213.84 t/s (−42%) at head_dim 256. Flag left off. |
| `mtp-2026-05-24` | `--mtp-ab` decode A/B on a 27B model | Provisional — not run on an idle GPU under the performance power profile, so the deltas are not authoritative. |
| `mtp-2026-05-31` | same A/B via the Go benchmark TUI | Provisional, same caveat. |

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
