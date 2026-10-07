# Strata on halo with the production Flash-Next UD-IQ4_XS (#257)

Every number is from **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT limit, kernel 7.2.9)**, measured
2026-10-06/07 with the #249 harness (`run.sh` memory gate, `probe.py`), corpus rev `4166bc4` and the same agent replay.
Nothing here transfers to gfx1150. Model: Qwen3.8-Flash-Next **UD-IQ4_XS** (unsloth, snapshot `38bb39ee`), the file halo already
serves. Engine: [Strata](https://github.com/Niko1221/Strata) (MIT) commit `82f46a8`, ggml `3cf0325`, **ROCm 7.14.1** (TheRock
tarball, sha256 `c40e8f2b…afb00`), built by the new `pkgs/strata` Nix package. The Strata arms ran with vision loaded (BF16
mmproj, CPU encoder) at `-c 131072`.

## Verdict

**Strata with its fast configuration is the fastest engine measured on halo so far, and it fits the memory budget. It should
become an opt-in lemond backend and get a soak test; it should not replace the resident model yet.** Its defaults only tie the
tuned GSQHalo config from #252.

| (halo, MTP on, 131072 context) | Vulkan b11382 (#252 same day) | GSQHalo f16 KV (#252 tuned = production) | Strata defaults | **Strata fast** |
| --- | ---: | ---: | ---: | ---: |
| Agent replay, normalized (lower is better) | 179.2 s | 116.1 s | 113.6 s | **84.1 s** |
| Replay, time to first token summed | 123.9 s | 63.6 s | 74.1 s | **47.8 s** |
| Prefill 4K / 32K / 128K (t/s) | 474 / 415 / 267 | 723 / 774 / 761 | 664 / 730 / 648 | **1052 / 1229 / 1209** |
| Decode 512 / 32K / 128K, T=0.7 (t/s) | 27.0 / 37.3 / 25.6 | 28.3 / 40.9 / 35.1 | 38.3 / 39.8 / 37.2 | 43.7 / 42.5 / 40.6 |
| GTT after load / peak | 70.8 / 74.3 GiB | 71.6 / 73.4 GiB | 66.2 / 66.3 GiB | 66.8 / 66.9 GiB |
| Correctness vs Vulkan (greedy exact, 20 prompts) | reference | 12/20 | 10/20 | 8/20 |

- **Replay: −28% vs the production GSQHalo config, −53% vs Vulkan** (fast: 84.1 s; defaults: 113.6 s, −2%). Time to first token falls
  25% and prefill is 1.45× (4K) to 1.6× (32K, 128K) GSQHalo's. The replay is the number an agent feels: 76–98% of each turn is time to first token.
- **The published prefill reproduces, the published decode does not.** Strata's docs claim 1.16–1.30K prefill and 51–54 decode;
  halo measures 1.21–1.23K prefill (fast config, 32K and 128K) and 38–46 decode with MTP. The claim's box differs (IOMMU off,
  112 GiB GTT, all experts resident, a different run harness); which of those matters here was **not tested**.
- **Decode gain over GSQHalo is small:** +4% at 32K (inside the stdev), +16% at 128K, and the 512-depth rows are noisy on every engine.
  At 128K both Strata arms beat Vulkan (+45% defaults, +59% fast; GSQHalo +37%).
- **Prompt lookup (`--lookup-chain 3`) adds nothing here.** The corpus has no repeated 64-grams by construction, so it
  cannot help; the table below shows the arms with and without it. It would inflate decode on text that repeats the context; that was not measured.
- **Memory fits the task's ≤ ~75 GiB GTT with vision at 131072 context**: 66.9 GiB peak. See the footprint section for the host side.
- **Correctness passes #249's thresholds** (sanity 10/10, no degenerate output), but diverges from Vulkan sooner than GSQHalo
  does, most in the fast config (8/20 greedy exact). The same prompts diverge at the same positions on the defaults and on
  GSQHalo (math/prose), which points at HIP-vs-Vulkan rounding. Strata's own docs say its BF16 `--compat-bf16` pack
  puts perplexity 6–9% above llama.cpp's on the same file; that was **not measured** here.

### What still blocks "resident"

1. **A lemond backend.** `pkgs/strata` ships `strata-server` (Python HTTP server that spawns the `strata` engine from a JSON config). Lemond needs a
   recipe that writes that config, starts and stops it, and reports health, with the model name and load/unload semantics
   lemond expects. That is not written.
2. **A soak.** One run per row and one request at a time. No concurrency, no long-session stability, no thinking-on
   workloads, no repeat of the replay. The project is ~2 weeks old, gfx1151 is flagged "unvalidated" in its own build, and it
   changes daily: pin `82f46a8` (or a later commit with a repeat of this bench), do not track `main`.
3. **A quality check of the fast configuration.** It turns on bit-changing switches; only the 20 + 10 prompt checks ran. No KL or perplexity.
4. **Memory caps in the packaged config.** `--expert-cache auto` sizes from MemAvailable on a unified-memory machine; the packaged
   config must pass an explicit count (these rows: 20000) and `--mmap-experts`.
5. **Closure size and toolchain.** The pinned ROCm 7.14.1 SDK adds an 8.9 GiB Nix closure beside `llama-cpp-rocm` on 7.2.3, and the build uses `-march=native`, so it is specific to the building host's CPU.
6. Images use the **CPU** encoder (Strata has no GPU encoder on AMD): a 128×128 test picture took 0.7 s to first token. Larger pictures were not measured.

## Strata arms

Four arms, each run as three `run.sh` rows through the memory gate (A: tool call, prefill 4K, decode 512 and 32K, replay, vision;
B: decode 128K; C: correctness):

| arm | engine flags | environment |
| --- | --- | --- |
| `def` (Strata defaults, MTP only) | `--prefill auto --spec 4 --spec-min-p 0.5 --kv int8 --mmap-experts --expert-profile <data/expert-profile.bin> --expert-cache 20000 --vram-reserve-mib 700 --vision` + `--mtp` (q2_0 draft layer) | `STRATA_HIPBLASLT_TUNING` (gfx1151 table) |
| `defL` | `def` + `--lookup-chain 3` | same |
| `fast` (maintainers' fast config, MTP only) | `--prefill 16384 --mtp-q4 all` instead of `--prefill auto`, rest as `def` | + `STRATA_PF_FUSED STRATA_PF_GEMM STRATA_HC_UPMIX STRATA_PA_FAST STRATA_HIP_WMMA STRATA_SELECT_WMMA STRATA_HC_Q8` = 1, `STRATA_PF_SWITCH_MIN_T=4096` |
| `fastL` | `fast` + `--lookup-chain 3` | same |

Two deviations from Strata's setup defaults, both for memory safety on a shared unified-memory host: `--mmap-experts` (no host
copy of the experts: they sit in the GPU expert cache and the page cache) and an explicit `--expert-cache 20000` instead of `auto`.
`auto` was **not run**: it sizes the cache from MemAvailable minus 6 GiB, which on halo with lemond offline is most of the machine. The cache count was chosen
with four small gated rows (8K and 128K context, on the first build, see below): 2048 → 25 t/s decode at 8K, 8192 → 34 t/s, and with `--mmap-experts` 18000 → 44 t/s at 131072 context (66.2 GiB GTT).
A count of 20000 gave the same GTT as 18000; why was not investigated. Those smoke rows are not in the tables.

Strata's speed rows go over `/v1/chat/completions` (it has no `/v1/completions` and no `ignore_eos`): the chat template wraps the prompt
and the request asks for a long essay so generation reaches `max_tokens`. The baselines used `/v1/completions`, so the prompt
token counts differ by a few tokens and Strata's speed rows include template processing. 32K and 128K prefill are the prompt phase of the decode
runs, as in #249. Strata's own `timings.prompt_per_second` reads about 5% below the client figure (first 32K run of `s-fast-A`: see the row's `server_prompt_tps` against the client figure; about 5% in the rows checked, not traced).

Decode columns are `mean ± stdev (T=0)`: three runs at temperature 0.7 (seeds 1–3) plus one at temperature 0. Acceptance is
Strata's `draft_n_accepted / draft_n`, which includes lookup drafts on the `L` arms. Each row is one run per cell.
The first request of each arm's row A ran after the previous arm's page cache was dropped (cold experts); rows B and C ran warm.

### Per-row: Speed (t/s)

| row | loadavg start / end / max | prefill 4K | prefill 32K | prefill 128K | decode 512 (T=0) | decode 32K (T=0) | decode 128K (T=0) | acceptance 512 / 32K / 128K |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| s-def-A | 1.69 / 25.0 / 28.89 | 663.5 | 729.7 | - | 38.3 ± 3 (38) | 39.8 ± 1.8 (37.5) | - | 0.55 / 0.56 / - |
| s-def-B | 1.69 / 26.97 / 31.8 | - | - | 647.7 | - | - | 37.2 ± 1.6 (39.8) | - / - / 0.6 |
| s-def-C | 1.97 / 2.27 / 2.8 | - | - | - | - | - | - | - / - / - |
| s-defL-A | 1.69 / 20.14 / 28.86 | 662.4 | 731.2 | - | 40.3 ± 1 (37.6) | 39.1 ± 1.3 (39.4) | - | 0.56 / 0.58 / - |
| s-defL-B | 1.95 / 29.0 / 33.81 | - | - | 633.2 | - | - | 37.6 ± 1.7 (34.5) | - / - / 0.56 |
| s-defL-C | 1.93 / 2.23 / 2.46 | - | - | - | - | - | - | - / - / - |
| s-fast-A | 1.76 / 29.56 / 29.09 | 1051.8 | 1228.8 | - | 43.7 ± 4.8 (40) | 42.5 ± 1.3 (44) | - | 0.52 / 0.6 / - |
| s-fast-B | 1.62 / 30.55 / 34.0 | - | - | 1209.2 | - | - | 40.6 ± 2 (40) | - / - / 0.59 |
| s-fast-C | 1.71 / 2.45 / 2.8 | - | - | - | - | - | - | - / - / - |
| s-fastL-A | 1.92 / 19.31 / 26.22 | 1072.5 | 1232.1 | - | 46.3 ± 4.1 (44.1) | 41.5 ± 3 (41.9) | - | 0.56 / 0.57 / - |
| s-fastL-B | 1.99 / 31.43 / 34.66 | - | - | 1201.5 | - | - | 41.4 ± 3.1 (42.2) | - / - / 0.63 |
| s-fastL-C | 1.67 / 2.2 / 2.32 | - | - | - | - | - | - | - / - / - |

### Per-row: Replay, tool call, vision, memory

| row | replay normalized / TTFT sum (s) | tool call | vision | GTT after load / peak (GiB) | RSS after load / engine peak / tree peak (GiB) | MemAvailable after load (GiB) | page cache before / after evict (GiB) | cores busy: system / engine |
| --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
| s-def-A | 113.6 / 74.1 | pass | pass | 66.2 / 66.3 | 44.1 / 46.3 / 47.5 | 47.5 | - / - | 2.49 / 1.95 |
| s-def-B | - | - | - | 66.2 / 66.3 | 46 / 48.3 / 49.4 | 47.6 | - / - | 2.39 / 2.01 |
| s-def-C | - | - | - | 66.2 / 66.3 | 47.2 / 49.7 / 50.8 | 48.4 | 46.6 / 2.3 | 2.29 / 1.95 |
| s-defL-A | 117.1 / 78 | pass | pass | 66.3 / 66.3 | 46.4 / 47.8 / 48.9 | 48.5 | - / - | 2.28 / 1.94 |
| s-defL-B | - | - | - | 66.3 / 66.3 | 48.8 / 50.7 / 51.9 | 48.1 | - / - | 2.38 / 2.01 |
| s-defL-C | - | - | - | 66.3 / 66.3 | 48.3 / 50.6 / 51.8 | 48 | 45.4 / 1.5 | 2.28 / 1.95 |
| s-fast-A | 84.1 / 47.8 | pass | pass | 66.8 / 66.9 | 48 / 49.6 / 50.8 | 47.8 | - / - | 2.27 / 1.92 |
| s-fast-B | - | - | - | 66.8 / 66.8 | 47.7 / 49.8 / 51 | 47.8 | - / - | 2.47 / 2.01 |
| s-fast-C | - | - | - | 66.8 / 66.8 | 48.3 / 49.9 / 51 | 47.7 | 46.5 / 1.2 | 2.25 / 1.95 |
| s-fastL-A | 82.7 / 47.2 | pass | pass | 66.8 / 66.9 | 46.6 / 48.2 / 49.4 | 47.7 | - / - | 2.26 / 1.91 |
| s-fastL-B | - | - | - | 66.8 / 66.9 | 47.7 / 50.4 / 51.6 | 47.9 | - / - | 2.48 / 2.01 |
| s-fastL-C | - | - | - | 66.8 / 66.9 | 47.5 / 49.9 / 51.1 | 47.9 | 42.5 / 1.1 | 2.32 / 1.96 |

### Reading the loadavg columns

`run.sh` waited for the 1-min loadavg to drop below 2 before every row, so every row *started* at 1.6–1.9. The end and max
columns are **not** a measure of foreign load for this engine: its own threads push the 1-min loadavg to 20–36 during the speed, replay and 128K rows
(a thread pool and uninterruptible reads of the memory-mapped experts; the split was not traced). The probe therefore also
records the busy cores system-wide and in the engine process: the difference is the other work on the host, 0.3–0.5 cores
(of 32 threads; highest `s-def-A` 0.5). The "re-run a row if load goes above 4 mid-row" rule could not be applied literally and no row was re-run.

## Footprint

| | Strata (all four arms) | GSQHalo f16 (#252) | Vulkan (#252) |
| --- | ---: | ---: | ---: |
| GTT after load / peak | 66.2–66.8 / 66.3–66.9 GiB | 71.6 / 73.4 GiB | 70.8 / 74.3 GiB |
| Engine RSS after load (almost all file-backed mmap) | 44–49 GiB (anon 1.2–1.7) | 2.6 GiB | 0.4 GiB |
| Peak engine RSS (VmHWM) / process tree | 46–51 / 47–52 GiB | 12 GiB | 11 GiB |
| MemAvailable after load (lemond offline) | 47.5–48.5 GiB | 42.7 GiB | 43.7 GiB |
| Load time (server ready) | 26–64 s | – | – |

RSS counts the mapped expert pages, which are reclaimable page cache rather than anonymous memory; MemAvailable is the
comparable figure. The page cache was 42–47 GiB at the end of each arm's last row, and `probe.py --evict-after` dropped it
(`posix_fadvise(DONTNEED)` on the GGUF shards, no privilege) to 1–2 GiB before `run.sh` reloaded lemond, because the 2026-10-05 wedge followed a lemond
reload after a heavy mmap pass. All eight lemond reloads of the first pass (four smoke stages, four arms) and the four of the final pass came back `ready`, and the kernel journal shows no amdgpu, `BO_VA` or hung-task messages across the session. Peak GTT sampling is every 0.5 s.

Extra disk: pack 1.4 GiB (built from halo's existing GGUF in 8 s, no weight download), MTP draft layer 6.5 GiB while building
(4.9 GiB raw tensors that can be deleted afterwards, 0.8 GiB GGUF, 0.8 GiB runtime files), mmproj 0.85 GiB, Nix store: 8.9 GiB (the SDK is 8.2 GiB of it; closure of `.#strata`).

## What was downloaded

- **MTP tensors, 4.9 GiB**, by Strata's `tools/mtp_fetch.py` (HTTP range reads of 31 `mtp.*` tensors from the original Qwen3.8-Flash-Next
  BF16 checkpoint at its pinned revision, SHA-256-verified). Strata does **not** read the ggml-org / unsloth Q8_0 MTP GGUFs halo has; its
  draft layer is rebuilt from those BF16 tensors (`mtp_pack.py --experts q2_0`, `mtp_rt.py`). The owner approved this download after the load check.
- **mmproj-Qwen3.8-Flash-Next-BF16.gguf, 0.85 GiB** (907 MB) from the repository Strata's setup uses, at its pinned revision.
- The UD-IQ4_XS GGUF loaded unchanged: `iq_pack.py --compat-bf16` wrote a 1.4 GiB pack next to it, the experts are read from the GGUF in place.

## Build

`nix build .#strata` (new, opt-in; not in the overlay or the NixOS module). It builds Strata at the pinned commit with ggml pinned as
`STRATA_GGML_DIR` (CMake fetches nothing) against `pkgs/strata/therock-sdk.nix`, the TheRock ROCm 7.14.1 tarball repackaged for the Nix
store. TheRock's clang is not the Nix cc wrapper, so the package spells out its host C and C++ locations. The engine, the
CPU image encoder `strata-vision` and `strata-server` come out of one build (a few minutes on halo, after the one-time 1.7 GB SDK download). The Nix cc-wrapper silently drops `-march=native`, which upstream's ggml CPU backend
relies on, so the package sets `NIX_ENFORCE_NO_NATIVE=0`; the package is therefore specific to the building host's CPU. The bench ran the engine from this package. Only the executables of the SDK are patched; patching its
shared objects with `patchelf` broke `libhipblaslt`.

## A first pass on a build without AVX

The first full pass of these four arms (same flags, same host, 2026-10-06) ran an engine built by the package before it kept `-march=native`: its
ggml CPU backend, which computes the experts the GPU cache misses and runs the image encoder, was compiled for plain x86-64. A review of the package
found it. The speed rows moved little (replay 113.9 / 113.5 / 82.7 / 91.2 s for defaults, defaults + lookup, fast, fast + lookup; decode within noise; 4K
prefill of the fast arm 898 against 1052 t/s now) and the image test picture took 1.5 s to first token against 0.7 s now. All figures in this README are from the rebuilt package.

## Not measured

- Strata with `--expert-cache auto` or its default resident-budget topology (unsafe on this host, above).
- Anything on gfx1150; UD-Q4_K_XL; other quants; the GPU image encoder (none on AMD); images larger than the 128×128 test picture.
- Concurrency, soak and repeat runs; correctness under load; thinking-on workloads; perplexity and KL for the fast config.
- Why decode lands at 38–46 rather than the claimed 51–54; the effect of IOMMU mode and power envelope on this engine.
- Lookup on text that repeats the context.
- Fresh same-session Vulkan and GSQHalo rows: the baselines are #252's same-day rows (2026-10-06, earlier in the day) and #249's tables, not re-run.

## Reproduce

From the repo root, on a gfx1151 host with lemond running Qwen3.8-Flash-Next-MTP:

```sh
nix build .#strata -o result-strata
nix build .#llama-cpp-vulkan -o result-vulkan             # tokenizer for the correctness comparison
W=<work dir>; mkdir -p "$W"
GGUF=<UD-IQ4_XS shard 1 (unsloth, 38bb39ee)>
PYENV=<python with numpy regex jinja2 pyyaml requests psutil pillow tqdm>
GGML=$(nix eval --raw .#strata.ggml.outPath); S=$PWD/result-strata/share/strata
STRATA_GGUF_PY=$GGML/gguf-py $PYENV/bin/python $S/tools/iq_pack.py --gguf "$GGUF" --out "$W/pack" --compat-bf16
export STRATA_GGUF_PY=$GGML/gguf-py
$PYENV/bin/python $S/tools/mtp_fetch.py fetch --out "$W/mtp"                      # 4.9 GiB download
$PYENV/bin/python $S/tools/mtp_pack.py --src "$W/mtp" --experts q2_0 --out "$W/mtp/mtp-q2_0.gguf"
$PYENV/bin/python $S/tools/mtp_rt.py --gguf "$W/mtp/mtp-q2_0.gguf" --out "$W/mtp/rt"
cp $S/data/draft_vocab.bin "$W/mtp/rt/"
# mmproj-Qwen3.8-Flash-Next-BF16.gguf from ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF at ed59f92 (sha256 b1a82259…49bd0)

export W CACHE=<#249/#252 corpus cache.json built at CORPUS_REV 4166bc4> STRATA_PY=$PYENV/bin/python STRATA_REPO=$S \
  STRATA_ENGINE=$PWD/result-strata/bin/strata STRATA_VISION_BIN=$PWD/result-strata/bin/strata-vision \
  STRATA_PACK=$W/pack STRATA_MTP_RT=$W/mtp/rt STRATA_MMPROJ=<mmproj file> STRATA_EXPERT_CACHE=20000 STRATA_CTX=131072
D=bench-logs/qwen38-flash-next-strata-2026-10-06
$D/rows.sh smoke                       # one small gated load first (8K context, 2048-expert cache); SMOKE_EXPERT_CACHE=8192 etc. to scale up
for arm in def defL fast fastL; do $D/rows.sh arm "$arm"; done   # rows go to $W/rows.jsonl
$D/tables.sh "$W/rows.jsonl" s-                              # the tables above
python3 bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/probe.py analyze --rows <rows with a vulkan-C row from #252 + the s-*-C rows> \
  --ref vulkan-C --tokenizer-bin result-vulkan/bin/llama-tokenize --vocab "$GGUF"
```

`run.sh` gained the `strata` and `strata-fast` presets (they also hold `$XDG_RUNTIME_DIR/halo-gpu-bench.active` while a row runs, so other
work on the host can defer CPU-heavy steps). `probe.py` gained the `strata` subcommand (starts `serve.server` in its own process group
and tears the whole group down without a timeout, so lemond is never reloaded over a stuck engine), the `vision` group, per-row
`loadavg_end`/`loadavg_max`, `cpu_cores_system`/`cpu_cores_engine`, engine-only and process-tree memory fields, and `--evict-after`. Existing
`llama` and `gufo` behaviour is unchanged.
