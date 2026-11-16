# Strata v0.2.15 against v0.2.13 on Strix Halo, Flash-Next UD-IQ4_XS-v31 (#356)

Every number is from one **Strix Halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT limit, kernel
7.3.4)** machine, measured 2026-11-16 with the #249 harness (`run.sh` memory gate, `probe.py`) and the corpus of the
[2026-10-06 Strata run](../qwen38-flash-next-strata-2026-10-06/README.md) (rev `4166bc4`). Nothing here transfers to gfx1150.
One run per cell: no cell was repeated, so differences of a few percent are not claimed.

Upstream 0.2.14 moved the prompt path on AMD from llama.cpp's MMQ kernels to Strata's own prompt kernels and says answers can
differ; 0.2.15 changes only the app, Terminal and Control. Upstream's own Strix Halo figures are Windows and `UD-Q4_K_XL`, so
none of them transfer; this run measures the Linux engine on the production file.

Both arms run the **same file and the same pack**: Unsloth's 2026-11-04 `UD-IQ4_XS-v31` (snapshot `d9620119`, four shards)
with the pack and MTP runtime the module built for it under v0.2.13 (stamped with that package; neither was rebuilt for the new
engine). Only the engine changes: v0.2.13 (`d2f0964`, the `main` build) against v0.2.15 (`c775728`, this branch). ggml
(`3cf0325`), ROCm 7.14.1 and hipBLASLt 100401 are the same in both. Configuration, both arms: `--prefill auto --spec 4
--spec-min-p 0.5 --kv int8 --mmap-experts --expert-cache 20000`, `-c 131072`, MTP drafting, vision loaded (BF16 mmproj, CPU
encoder). The new engine opened the existing pack and MTP runtime without a rebuild and ran all nine rows (smoke, footprint, A,
B, KL), so the pack format did not change in a way this file exercises. `bin/strata --version` prints 0.1.59 for the old build
and 0.1.61 for the new one (upstream's tag names the engine package 0.1.60; the CMake project version is 0.1.61).

## Verdict

**v0.2.15 prefills about 35-50 % faster than v0.2.13 on this machine with unchanged decode, memory and quality, and the bump is
worth shipping on the numbers measured.** Prefill is 665.6 against 452.1 t/s at 4K (+47 %), 705.7 against 478.2 at 32K (+48 %)
and 660.5 against 471.6 at 128K (+40 %); the 8-turn agent replay, which is prefill-dominated, normalizes from 193.0 s to 115.2 s
(-40 %). Against the v0.2.13 cells of the 2026-11-12 bench, whose old-pin prefill ran 4-9 % higher than this session's old row, the prefill gain is +34 % to +39 % and the replay gain -17 %, so read the gain as about 35-50 % depending on which old row is the baseline. Decode is within the spread of its row. GTT and process memory are the same. The paired KL against the Q8_0 reference
moves by +0.0004 +- 0.0003 nats (mean KLD 0.0745 against 0.0741), which is within about 1.6 standard errors of zero and about 0.5 %
of the KLD itself. The two pins still pick a different top token at 2.5 % of the scored positions, which is the "answers can
differ" upstream warns about; the scored quality is unchanged.

| (Strix Halo, MTP on, 131072 context, one run each, UD-IQ4_XS-v31) | v0.2.13 | v0.2.15 |
| --- | ---: | ---: |
| Prefill 4K (t/s) | 452.1 | 665.6 |
| Prefill 32K (t/s) | 478.2 | 705.7 |
| Prefill 128K (t/s) | 471.6 | 660.5 |
| Decode 512 (t/s, T=0.7) | 41.0 | 40.5 |
| Decode 32K (t/s) | 36.6 | 39.6 |
| Decode 128K (t/s) | 36.7 | 36.6 |
| MTP acceptance at 512 / 32K / 128K | 0.545 / 0.592 / 0.571 | 0.539 / 0.599 / 0.589 |
| Agent replay, normalized (s, lower is better) | 193.0 | 115.2 |
| Replay, wall / time to first token summed (s) | 127.2 / 113.8 | 78.2 / 70.9 |
| GTT peak (GiB, footprint row) | 61.6 | 61.6 |
| Process RSS peak (GiB, footprint row) | 49.8 | 49.3 |
| Lowest MemAvailable (GiB, footprint row) | 17.0 | 20.7 |
| Load time, rows A / B (s) | 92.1 / 58.0 | 82.1 / 68.1 |
| Tool call | ok | ok |

- Each throughput cell is the mean of the probe's iterations inside one row run (3 for decode, 3-4 for prefill). The spread
  inside the row is a standard deviation of 4-53 t/s for prefill (the new 4K cell is 665.6 +- 52.7, the old one 452.1 +- 3.9) and
  1.3-5.7 t/s for decode. Replay, load time and the footprint cells are one run each and have no spread. The decode differences
  (-0.5, +3.0, -0.1 t/s) are inside those spreads; the 32K decode difference is about the old cell's own +- 5.7 and is not claimed.
- Prefill confirms across rows: the same 4K prompt in the footprint row gives 406.2 against 702.5 t/s, and in the 8K-context
  smoke row (2048-expert cache) 378.6 against 454.7 t/s. Every row shows the new pin faster; the size of the gain varies from
  +20 % to +73 % between rows, so read "40-50 %" as the 131072-context A and B rows' figure against this session's old row, not a constant.
- **The old pin's replay is slower here than in the v0.2.13 bench** (193.0 s normalized, against 139.5 s for the same engine
  and file on 2026-11-12), and its prefill cells are 4-9 % below that run's. Why was **not investigated**. The replay ratio (-40 %) therefore compares against this run's old row; against the 2026-11-12
  figure the new pin's 115.2 s is -17 %.
- **Memory is a delta over an empty GPU.** The footprint row (tool call, 4K prefill, 512 decode, sampler running, 131072
  context, 20000-expert cache) reads GTT 61.6 GiB at peak and 61.6 / 61.1 GiB loaded (old / new), unchanged to the figure the
  v0.2.13 bench reported. The lowest-MemAvailable cell differs by 3.7 GiB in the new pin's favour in this row, but the drop from the starting level (99.0 against 91.2 GiB here) is 91.6 against 98.8 GiB in row A and 92.7 against 91.3 GiB in row B, so a single-run drop varies by about 8 GiB in either direction and the difference is not attributed to the engine.
- **Vision is flaky on both pins and this run does not separate them.** The two-colour test picture was answered correctly in
  one of two rows on each pin (old smoke "Blue Red", old A "Blue"; new smoke "Red", new A "Blue Red"), the same flakiness the
  v0.2.13 bench saw. Not investigated.
- **Not measured:** the `fast` configuration, lookup chain, DFlash2 drafting (the module pins `drafting = "mtp"`), other
  quants, gfx1150, the `correctness` row, concurrency, the old pin's own KL (the #352 row is used), a pack rebuilt for 0.2.15, and any
  repeat of a row.

## Quality

KL against #260's Q8_0 reference logits (the stored file; not regenerated), `kl_strata.py` `def` arm, 64 chunks of 2048 tokens,
65,472 scored positions, top-256 log-probabilities plus one bucket for the rest, expert cache 20000 and 131072 context. The
v0.2.13 row is [#352's `UD-IQ4_XS-v31` base run](../qwen38-flash-next-strata-2bit-2026-11-15/README.md) with the same file,
corpus and positions, run with the same build as this bench's old pin (store path checked); it is not re-run.

| (Strix Halo, UD-IQ4_XS-v31, Q8_0 reference) | v0.2.13 | v0.2.15 |
| --- | ---: | ---: |
| Mean KLD (nats) | 0.0741 (se 0.00096) | 0.0745 (se 0.00098) |
| Same top token as the reference | 92.12 % | 92.09 % |
| Perplexity / reference | 0.9700 | 0.9698 |
| KLD p99 / max | 0.985 / 12.97 | 0.974 / 12.50 |
| Paired ΔKLD, v0.2.15 - v0.2.13 | | +0.00041 (se 0.00026) |
| Paired ΔNLL | | -0.00014 (se 0.00058) |
| Top token differs between the two pins | | 2.52 % of positions |

The paired difference is on the same positions, so it carries far less noise than either KLD. +0.0004 is 1.6 standard errors:
no quality change is detected. The standard error treats the 65,472 positions as independent, but positions inside a chunk are
correlated, so the true error is larger; no chunk-level error was computed. This is one corpus and one quant file, scored on the verify-window half of each chunk; it
says nothing about long-context answers or tool use beyond the probe's tool-call row.

## Setup

- Engines: `nix build .#strata` on `main` (v0.2.13) and on this branch, two out-links; same pack, MTP runtime and mmproj.
- Rows go through `run.sh`: fit check, load gate, unload of lemond's resident model, the probe, restore of the resident. The
  wrapper [`rows.sh`](rows.sh) selects the build and runs the [2-bit bench's `rows.sh`](../qwen38-flash-next-strata-2bit-2026-11-15/rows.sh)
  `base` candidate for it, which holds the loadavg wait (below 4, cap 15 min), the foreign signal-file refusal, the footprint
  sampler, the amdgpu kernel-log check and `load.jsonl`. Row labels are `base-<stage>` for both pins; the pin is the work dir.
- Rows: `smoke` (8K context, 2048-expert cache), `foot` (tool call, 4K prefill, 512 decode, sampler), `A` (tool call, 4K prefill,
  512 decode, 32K decode, 8-turn replay, vision), `B` (128K decode), `kl` (new pin only). Each once, old first; every row exited
  0 with no amdgpu kernel-log hits and no signal file left behind.
- Loadavg at the gate was 2.5-4.0 after waits of 0-230 s; end loads reach 6-40 because Strata's own threads count as runnable.
- **Two disturbances.** The first old-pin smoke attempt used a pack built for the September file and died on a missing shard
  (exit 1, the resident was restored); its output is discarded and the paths were corrected. A host-side low-memory guard then
  stopped the row driver during the old pin's B row, before it had unloaded the resident; the three unfinished rows (old B, new
  B, new KL) were re-run from the start once the host was released for them, and every row reported above is the complete run.
- Not part of this PR's result: `kl_strata.py` and the footprint sampler are the committed scripts of the earlier benches; no
  harness code changed.

## Reproduce

```sh
nix build .#strata -o result-strata-new                      # this branch
nix build <main checkout>#strata -o result-strata-old        # main at f72e5c8 (v0.2.13)
export WORK=<work dir> CACHE=<corpus cache.json at rev 4166bc4> PY=<python with numpy regex jinja2 pyyaml requests psutil pillow tqdm> \
  MTP_RT=<mtp/rt> MMPROJ=<mmproj file> REF=<Q8_0 reference logits> BASE_PACK=<v31 pack> BASE_SHARD=<v31 shard 1> \
  PIN_OLD=$PWD/result-strata-old PIN_NEW=$PWD/result-strata-new
D=bench-logs/qwen38-flash-next-strata-v0.2.15-2026-11-16
for pin in old new; do for s in smoke foot A B; do $D/rows.sh $pin $s || break 2; done; done   # rows go to $WORK/<pin>/base/; exit 9 means a suspected amdgpu wedge: stop, do not reboot
$D/rows.sh new kl                                            # KL; the v0.2.13 row is #352's base run
python bench-logs/qwen38-flash-next-strata-quality-2026-10-07/kl_strata.py compare --ref "$REF" --chunks 64 \
  v0.2.13=<#352 base kl run dir> v0.2.15=$WORK/new/base/kl/kl-def-64
```
