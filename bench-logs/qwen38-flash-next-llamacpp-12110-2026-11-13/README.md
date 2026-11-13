# llama.cpp: b11382 pin vs nixpkgs' build 12110, MTP A/B — Strix Halo, gfx1151

Question (#348): drop the flake's `b11382` llama.cpp pin for nixpkgs' `llama-cpp`, or bump the
pin to Lemonade's `b11846`, whichever keeps the measured Qwen3.8-Flash-Next MTP decode win.

Every number is Strix Halo (Ryzen AI MAX+ 395, Radeon 8060S, gfx1151, 123 GiB RAM); none of it
transfers to other GPU targets.

## What nixpkgs ships

nixpkgs' `llama-cpp` is upstream release `v0.9.0`, which its package bakes in as build **12110**
(commit `cd959ba`): 728 commits past b11382 and 264 past b11846. `llama-server --version` on the
built binary reports `0.9.0 (build 12110, commit cd959ba)`; the old pin reports
`0.5.0 (build 11382, commit 11fe021)`. Since 12110 is past both candidates and contains MTP
(ggml-org/llama.cpp#29761 landed before b11382), the bench is old pin vs nixpkgs as-is.

## Setup

- Arms: the previous flake revision (pin b11382) vs this branch (no pin, nixpkgs build 12110),
  `llama-cpp-vulkan` and `llama-cpp-rocm` from each, built through the flake.
- Same files and flags as `qwen38-flash-next-mtp-2026-10-04`: target
  `unsloth/Qwen3.8-Flash-Next-GGUF` UD-IQ4_XS (3-shard), ggml-org MTP head, `mtp-ab.sh`
  (`benchmark --mtp-ab`), `--spec-draft-n-max 3`, ctx 2048, prompt 512, generate 128,
  1 warmup + 3 measured, fresh `llama-server` per arm.
- Rows ran one at a time through `bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/run.sh
  exec` (fit check, host-load gate, signal file, lemond hand-off and reload); `rows.sh` here is
  the wrapper. Order: old Vulkan, new Vulkan, old ROCm, new ROCm. Load at row start, as gated
  by `run.sh`: 1.30, 1.97, 1.81, 1.62 (all < 4). Single pass, no repeats.
- The resident lemond model was unloaded for each row and reloaded after; lemond was serving it
  again at the end.

## Result

| Backend | Build | MTP off (t/s) | MTP on (t/s) | Speedup |
| --- | --- | ---: | ---: | ---: |
| Vulkan | b11382 (old pin) | 27.5 | 42.9 | **1.56×** |
| Vulkan | 12110 (nixpkgs) | 27.4 | 42.1 | **1.53×** |
| ROCm | b11382 (old pin) | 23.2 | 39.7 | **1.71×** |
| ROCm | 12110 (nixpkgs) | 24.0 | 40.4 | **1.68×** |

Differences between builds are at most 2% on MTP-on decode (Vulkan −1.9%, ROCm +1.8%), with
opposite signs on the two backends. No repeats were run, so run-to-run noise is not quantified;
the call that this is "within noise" rests on that sign flip and the small size. **MTP works on
12110 and shows no slowdown beyond that, so the pin is dropped.**

For comparison, the 2026-10-04 bench on b11382 recorded Vulkan 26.7 → 40.2 (1.51×) and ROCm
19.0 → 33.0 (1.74×). The old-pin rows here, re-run today, are higher (notably ROCm MTP-off,
23.2 vs 19.0); why was not investigated, which is why the old pin was re-measured in the same
session rather than compared to the earlier README.

## Observations and caveats

- On both 12110 rows the MTP-off arm logged `WARNING: iteration 1 produced no tokens` (the
  warmup iteration); the three measured iterations produced tokens, and neither b11382 row
  logged it. Cause not investigated.
- The harness preflight warned `on battery; TLP throttles to powersave` on every row, old and
  new alike, so the arms are comparable but absolute figures may be power-profile limited.
- Quality was not measured here (no perplexity run on 12110); only decode throughput.
- Prefill, depth curve and the n-max sweep were not re-run.
- The gating issue's other option, bumping to b11846, was not benchmarked: 12110 met the bar.

## Reproduce

```
OUT_DIR=<scratch dir> LEMOND_MODEL=<resident lemond model> \
OLD_VULKAN=<old llama-cpp-vulkan> OLD_ROCM=<old llama-cpp-rocm> \
NEW_VULKAN=<new llama-cpp-vulkan> NEW_ROCM=<new llama-cpp-rocm> \
  bench-logs/qwen38-flash-next-llamacpp-12110-2026-11-13/rows.sh <old|new> <vulkan|rocm>
```
