# Tuning GSQHalo.cpp for Flash-Next on halo — f16 KV, rocWMMA, a smaller quant, the 128K decode gap (#252)

Every number is from **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT)**, measured
2026-10-06 with the #249 harness (`run.sh` memory gate, `probe.py`), the same corpus rev `4166bc4` and replay, GSQHalo.cpp
`5fc881b` built by `strix-rocm.nix` unchanged, and the ggml-org MTP Q8_0 head at n-max 3. Nothing here transfers to
gfx1150. Baselines are #249's tables ([bake-off README](../qwen38-flash-next-engine-bakeoff-2026-10-05/README.md)) plus
**same-day Vulkan and GSQHalo q8_0 rows**, because #249's were taken on a different day. An Android emulator ran on halo
during part of the session (loadavg 3–5 between rows); `run.sh` waited for the 1-min loadavg to drop below 2 before every
row, so no row carries `load_flag`. Each row is one run per cell, as in #249; the ± is the stdev of the seeded decode runs.

## Verdict

**Run GSQHalo with f16 KV (`-ctk f16 -ctv f16`). With it GSQHalo beats Vulkan on agent replay *and* on 128K decode.**
It is the one lever that mattered; the others did nothing or are not available.

| (halo, same-day rows) | Vulkan b11382 | GSQHalo q8_0 KV (#249 flags) | **GSQHalo f16 KV** | GSQHalo f16 KV, UD-IQ3_XXS |
| --- | ---: | ---: | ---: | ---: |
| Agent replay, normalized (lower is better) | 179.2 s | not re-run (#249: 144.4 s) | **116.1 s** | 94.9 s |
| Replay, time to first token summed | 123.9 s | (#249: 83.5 s) | 63.6 s | 44.5 s |
| Prefill 4K / 32K / 128K (t/s) | 474 / 415 / 267 | 665 / 594 / 306 | **723 / 774 / 761** | 1043 / 1161 / 1135 |
| Decode 512 / 32K / 128K, T=0.7 (t/s) | 27.0 / 37.3 / 25.6 | – / 34.1 / 21.9 | 28.3 / 40.9 / **35.1** | 29.7 / 42.1 / 36.1 |
| Decode 32K / 128K, T=0 (t/s) | 34.0 / 25.0 | 35.6 / 21.9 | 42.7 / **36.8** | 43.9 / 36.6 |
| GTT after load / peak | 70.8 / 74.3 GiB | 77.8 / 79.5 GiB | 71.6 / 73.4 GiB | 60.9 / 62.5 GiB |
| Correctness vs Vulkan | reference | pass (#249) | pass | pass, but see quant caveat |

- **Replay: −35% vs same-day Vulkan** (116.1 vs 179.2 s); #249 measured −22% with q8_0 KV. Time to first token is
  roughly halved.
- **128K decode: +37% vs Vulkan** (35.1 vs 25.6 t/s mean, 36.8 vs 25.0 at T=0). With q8_0 KV GSQHalo lost to Vulkan
  here (21.9). The loss was the quantized KV cache, not the engine.
- **Best configuration: GSQHalo `5fc881b`, UD-IQ4_XS, f16 KV, `-lzm on-direct -ub 8192 -b 8192
  --spec-draft-p-min 0.3`, MTP n-max 3.** It costs about the same GTT as Vulkan (71.6 vs 70.8 GiB after load).
- **UD-IQ3_XXS is faster still and 11 GiB lighter, but I would not promote it without a quality check.** Replay is
  another −18% and GTT peaks at 62.5 GiB. Only the 20-prompt greedy comparison and 10-question sanity set ran: sanity
  10/10, no degenerate output, but 6/20 greedy outputs equal the IQ4_XS Vulkan reference with a median first
  divergence of 11 tokens (12/20 and 43 for IQ4_XS f16). Some of that is plain quantisation; no perplexity or task-quality
  run was done. IQ3_XXS here is unsloth's UD-IQ3_XXS (76.3 GiB), the same tile type the fork's own figures use, not the
  fork's GSQ-RCO file.

## Levers, one row each

All rows `gsq-hip` preset flags plus the listed change; same-day control rows in bold. loadavg is the 1-min value at row
start (host halo in every row).

| lever (label) | loadavg | prefill 4K | prefill 32K | prefill 128K | decode 32K, T=0.7 (T=0) | decode 128K, T=0.7 (T=0) | acceptance 32K / 128K | replay normalized | GTT load / peak (GiB) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Vulkan, same day (`vulkan-A/B`) | 1.95 / 1.35 | 474 | 415 | 267 | 37.3 (34.0) | 25.6 ± 2.9 (25.0) | 0.74 / 0.68 | 179.2 s | 70.8 / 74.3 |
| **q8_0 KV control** (`gsq-q8-peak`) | 0.31 | 665 | 594 | 306 | 34.1 (35.6) | 21.9 ± 0.8 (21.9) | 0.76 / 0.76 | – | 77.8 / 79.5 |
| **1. f16 KV** (`gsq-f16-A/B`) | 0.25 / 1.69 | 723 | 774 | 761 | 40.9 (42.7) | 35.1 ± 1.1 (36.8) | 0.80 / 0.73 | **116.1 s** | 71.6 / 73.4 |
| 2. rocWMMA FA | – | not buildable on this source (below) | | | | | | | |
| 3. UD-IQ3_XXS, f16 KV (`gsq-iq3-A/B`) | 1.66 / 1.71 | 1043 | 1161 | 1135 | 42.1 (43.9) | 36.1 ± 2.6 (36.6) | 0.79 / 0.73 | 94.9 s | 60.9 / 62.5 |
| 4a. f16, `-ub 4096` (`gsq-ub4096`) | 1.61 | – | – | 737 | – | 33.7 ± 1.4 (35.6) | – / 0.70 | – | 70.1 / 71.9 |
| 4b. f16, `-ub 2048` (`gsq-ub2048`) | 1.82 | – | – | 677 | – | 33.7 ± 4.4 (34.8) | – / 0.69 | – | 69.5 / 72.7 |
| 4c. f16, n-max 2 (`gsq-nmax2`) | 1.80 | – | – | 748 | – | 32.8 ± 1.2 (35.1) | – / 0.79 | – | 71.5 / 73.0 |
| 4d. f16, n-max 4 (`gsq-nmax4`) | 2.00 | – | – | 748 | – | 33.5 ± 2.8 (34.8) | – / 0.70 | – | 71.7 / 73.2 |

#249's own GSQHalo q8_0 numbers (702 / 613 / 316 prefill, decode 30.3 / 35.7 / 21.8, replay 144.4 s) agree with the
same-day control within a few percent on prefill and 128K decode; the control's 128K decode (21.9) is the figure to
compare. The control row ran `prefill4k,decode32k,decode128k`, so it has no replay or decode-512 cell.

### 1. f16 KV, full rows

Row groups run: `toolcall,prefill4k,decode512,decode32k,replay` (A), `decode128k` (B), `correctness` (C).

- **Tool call:** pass. **Correctness:** pass: sanity 10/10, 12/20 greedy exact vs the Vulkan IQ4_XS reference (same as
  q8_0 in #249), median first divergence 43 tokens, no degenerate output.
- **Replay detail:** normalized 116.1 s, wall 74.8 s, time to first token 63.6 s (Vulkan same day: 179.2 / 133.9 /
  123.9 s). The 128K prefill jump (306 → 761 t/s) is why: the quantized KV path is slow at long depth on HIP. The cause
  inside the kernel was not traced.
- **GTT: why f16 reads lower than q8_0, and when it was read.** "After load" is the amdgpu `mem_info_gtt_used` delta read
  as soon as `/health` answers, which is after the weights (lazy-direct), KV cache and compute buffers are sized.
  `probe.py` now also samples GTT every 0.5 s for the whole row and reports the peak. The peak is only 1.7–1.8 GiB above the
  after-load reading for both KV types (q8_0 77.8 → 79.5, f16 71.6 → 73.4), and f16's *peak* (73.4, 73.1 in the 128K row)
  is still 6 GiB below q8_0's. So #249's lower f16 figure was a real difference and not a read-time artifact, and nothing
  large is allocated lazily after load. Why a bigger KV cache needs less GTT is not measured; a likely cause is
  scratch for dequantizing q8_0 KV in the attention path, but no buffer breakdown was captured.
- Peak RSS-side numbers: f16 server RSS ended rows at 9.9–12.0 GiB, q8_0 at 14.1 GiB; MemAvailable after the rows was
  32–36 GiB for f16 and 23.7 GiB for q8_0.

### 2. rocWMMA flash attention: not available in this build

`GGML_HIP_ROCWMMA_FATTN` no longer exists in GSQHalo `5fc881b`, and not in the packaged llama.cpp b11382 either: `grep -rn
GGML_HIP_ROCWMMA` over both source trees finds only the fork's upstream CI workflow, which passes `-DGGML_HIP_ROCWMMA_FATTN=OFF`
(a flag CMake ignores). The option existed on the older llama.cpp this repo measured on gfx1150 (`bench-logs/rocwmma-2026-05-19`).
In these sources the gfx11 flash-attention path already uses native AMD WMMA (`amd_wmma_available`,
`fattn-mma-f16.cuh`), so there is nothing to toggle and no "both ways" build. The packaged `llama-cpp-rocm` is untouched.
rocWMMA on gfx1151 therefore remains unmeasured. `-fa on` was already in the shared flags.

### 3. Kernel-matched quant: UD-IQ3_XXS

- Quant: unsloth `UD-IQ3_XXS`, 76.3 GiB on disk, three shards, same MTP head. The fork's published figures come from its own
  GSQ-RCO IQ3_XXS file, which was not used. UD-Q4_K_XL (103.7 GiB) stayed excluded after the #249 wedge, and nothing above
  100 GiB was loaded.
- Gate: `NEED_GIB=85` with `FIT_CHECK_ONLY=1` passed before the rows (117.6 GiB free once lemond's model is unloaded). Measured
  GTT 60.9 after load, 62.5 peak: 11 GiB below the IQ4_XS f16 build, which leaves room for a second model or builds
  next to the resident one.
- Speed: prefill 1043 / 1161 / 1135 t/s, decode 42.1 at 32K and 36.1 at 128K, replay 94.9 s (−18% vs IQ4_XS f16).
- Correctness vs Vulkan IQ4_XS: sanity 10/10, 6/20 exact, median first divergence 11 tokens, no degenerate output.
  Verdict `pass` by #249's thresholds, which were built for same-quant comparison; a different quant diverges sooner
  by construction. Not a quality result.
- **Vision:** the unsloth repo ships `mmproj-F16.gguf` / `mmproj-BF16.gguf` separately from the text quants, so a quant swap does not change
  the projector. The bake-off harness never loads `--mmproj`, so vision on this engine/quant was **not exercised**.
  Check it before making any candidate resident.

### 4. The 128K decode gap

At q8_0 KV the gap was real (GSQHalo 21.9 vs Vulkan 25.6). **f16 KV closed it (35.1) and nothing else moved it.**
On top of f16: `-ub 4096` 33.7, `-ub 2048` 33.7, n-max 2 32.8, n-max 4 33.5 (T=0.7 means), against 35.1 for the preset. These
are all within one stdev of each other (stdev 1–4 t/s, 3 runs), so none is a win and none a clear loss; the preset's
8192 and n-max 3 stay. `-ub` only changed prefill (677–748 vs 761). `-b` stayed 8192. `-fa` is already on. Acceptance at
128K ranged 0.69–0.79, which tracks n-max (0.79 at n-max 2) but not decode speed.

## Not measured

- Quality of UD-IQ3_XXS beyond the 20+10 prompt checks (no perplexity, no long-context task quality); rocWMMA on gfx1151;
  vision on GSQHalo; concurrency and `HIP_LAUNCH_BLOCKING` with f16 KV; repeat runs of replay and correctness rows; the kernel
  reason f16 KV prefills 2.5× faster at 128K; what makes q8_0 KV need more GTT.
- No q8_0 control for decode 512 or replay (the control stopped at 128K); #249's q8_0 numbers stand for those.

## Reproduce

Builds as in the bake-off README (Vulkan b11382 and GSQHalo `5fc881b`). The IQ3 quant is `UD-IQ3_XXS` from `unsloth/Qwen3.8-Flash-Next-GGUF`.
From the repo root, `rows.sh` stages (each through `run.sh`'s gate, lemond restored after each stage):

```sh
D=bench-logs/qwen38-flash-next-gsq-tuning-2026-10-06
$D/rows.sh vulkan                                  # corpus, vulkan-A/B/C
NEED_GIB=95 $D/rows.sh f16                         # gsq-f16-A/B/C
NEED_GIB=95 $D/rows.sh q8ctl                       # q8_0 control with peak GTT
IQ3=<path to ...UD-IQ3_XXS-00001-of-00003.gguf> EXTRA_ARGS="-ctk f16 -ctv f16" $D/rows.sh iq3
NEED_GIB=95 $D/rows.sh decode128k-variants
$D/tables.sh "$OUT"
python3 bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/probe.py analyze --rows "$OUT" --ref vulkan-C \
  --tokenizer-bin <vulkan>/bin/llama-tokenize --vocab <UD-IQ4_XS first shard>
```

`probe.py` gained a peak-GTT sampler (`gtt_peak_delta_bytes` in each row) for this work; nothing else in the #249 harness changed.
