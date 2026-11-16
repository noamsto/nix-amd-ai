# 2-bit Flash-Next on Strata: footprint, quality and speed against UD-IQ4_XS-v31 (#352)

A memory watchdog wants a smaller Flash-Next step to switch to under moderate pressure, before it falls back to a small
model. That step is worth adding only if a 2-bit quant loads on Strata, frees about 20 GiB or more, and stays close to the
Q8_0 reference. This measures three 2-bit candidates and, because it may be a cheaper step, the expert-cache size of the
current quant.

Every number is from one **Strix Halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT limit, kernel
7.3.4)** machine, measured 2026-11-15/16 with the #249 harness (`run.sh` memory gate, `probe.py`) and the corpus of the
[2026-10-06 Strata run](../qwen38-flash-next-strata-2026-10-06/README.md) (rev `4166bc4`). Nothing here transfers to gfx1150.
One run per cell: no cell was repeated, so differences of a few percent are not claimed.

Engine: Strata v0.2.13 (`d2f0964`, ggml `3cf0325`, ROCm 7.14.1), built by `pkgs/strata`. Default arm of the
[2026-11-12 run](../qwen38-flash-next-strata-v0.2.13-2026-11-12/README.md): `--prefill auto --spec 4 --spec-min-p 0.5
--kv int8 --mmap-experts --expert-cache 20000`, `-c 131072`, MTP drafting, BF16 mmproj vision.

| label | file | snapshot |
| --- | --- | --- |
| `base` | Unsloth `UD-IQ4_XS-v31`, 4 shards (production) | `unsloth/Qwen3.8-Flash-Next-GGUF` `d9620119` |
| `q2_0` | `Q2_0/Qwen3.8-Flash-Next-GSQ-RCO-Q2_0-0000{1,2}-of-00002.gguf`, 61.9 GiB | `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF` `ed59f920` |
| `iq2_xs` | `IQ2_XS/…-GSQ-RCO-IQ2_XS-0000{1,2}-of-00002.gguf`, 63.4 GiB | `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF` `ed59f920` |
| `ud_q2_0` | `UD-Q2_0/Qwen3.8-Flash-Next-UD-Q2_0-0000{1,2,3}-of-00003.gguf`, 65.7 GiB | `unsloth/Qwen3.8-Flash-Next-GGUF` `f5d175de` |

The IQ1 quants were skipped, as asked.

## Verdict

**No 2-bit quant is a viable "level 1" step on the numbers measured. A smaller expert cache is the cheaper step, and
whether it counts depends on which memory figure the watchdog reads.**

1. **All three 2-bit quants pack and load on Strata at the default configuration** (tool call ok, vision answered on the
   A rows, no kernel log hit on any row). Unsloth's `UD-Q2_0` loads too, unlike its `UD-IQ3_XXS` in the 2026-10-06 run.
2. **They are not close to the reference.** Against #260's Q8_0 logits on the same 65,472 positions, mean KLD is 0.0741 for
   the v31 baseline, **0.284 for Q2_0, 0.252 for IQ2_XS and 0.156 for UD-Q2_0**; top-token agreement is 92.1 % against
   85.5 %, 85.9 % and 88.6 %. Paired against v31, the two ISTA quants add +0.21 / +0.18 KLD with 13.7–13.9 % of top tokens
   flipping. `UD-Q2_0` is the closest (+0.082 ± 0.001), and it frees almost nothing by the pressure figure (below).
3. **They do not free 20 GiB by every measure.** Against the same-session v31 row, GTT drops by 29.7 / 27.3 / 18.8 GiB
   (Q2_0 / IQ2_XS / UD-Q2_0) but the host side grows (process RSS, almost all mapped file pages, is 47–59 GiB against 44.7
   for v31; why was not tested): GTT plus process RSS drops by 15.7 / 17.9 / 16.2 GiB, and the MemAvailable drop by 12.6 /
   16.1 / 0.7 GiB. None reaches 20 GiB on either of those two; on GTT alone the two GSQ-RCO files do.
4. **Expert cache is the cheaper lever, with no new quant file.** `--expert-cache 5000` on
   the v31 file cuts GTT by 40.0 GiB and the MemAvailable drop by 20.6 GiB, for −15 % decode at 512 (37.4 → 31.9 t/s). But
   GTT plus process RSS does not move (+2.4 GiB): what leaves the GPU lands in mapped file pages of the same process. Whether
   those pages count as freed memory depends on the watchdog's signal, which this run did not read. Output quality at the
   smaller cache was **not measured**.
5. For scale, [#276](../qwen38-flash-next-strata-quality-2026-10-07/README.md) measured Strata `def` on the earlier
   UD-IQ4_XS file at 0.0920 KLD / 91.4 %, and the [IQ3_XXS run](../qwen38-flash-next-iq3-quality-2026-10-06/README.md)
   measured 0.158 KLD / 89.2 % on GSQHalo with the full-vocabulary estimator, a result the project kept opt-in only. That
   estimator differs from the top-256 one here, so 0.158 against 0.156 is not a like-for-like comparison. By the same
   yardstick `UD-Q2_0` sits near IQ3_XXS and the two GSQ-RCO quants are well below it. **Whether any of them is worth an
   opt-in profile is the owner's call**, not a result of this run.

## Footprint

Idle MemAvailable with lemond's resident model unloaded was 110.2–117.4 GiB before each row and GTT was 0.0 GiB, so every
GTT figure is a delta over an empty GPU. The v31 baseline is **re-measured in this session**, not taken from the 2026-11-12
figures. Process RSS is the sum over the `strata*` processes under the harness job only (the sampler never reads lemond's
resident engine); "loaded" values are medians over the window where GTT was within 10 % of its peak, sampled every 0.2 s
(row = tool call, prefill 4K, decode 512). The per-row summaries come from [`footprint.py`](footprint.py).

| (Strix Halo, 131072 ctx, one run each) | `--expert-cache` | GTT after load = peak | process RSS loaded (file / anon) | GTT + RSS | RSS peak | MemAvailable drop, loaded (lowest) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| v31 baseline (UD-IQ4_XS-v31) | 20000 | 61.6 | 44.7 (41.5 / 1.9) | 106.3 | 47.2 | 73.1 (74.9) |
| Q2_0 (GSQ-RCO) | 20000 | 31.9 | 58.7 (56.1 / 1.9) | 90.6 | 62.2 | 60.5 (63.5) |
| IQ2_XS (GSQ-RCO) | 20000 | 34.3 | 54.1 (51.3 / 2.0) | 88.4 | 57.4 | 57.0 (60.3) |
| UD-Q2_0 (Unsloth) | 20000 | 42.8 | 47.3 (44.4 / 2.1) | 90.1 | 48.8 | 72.4 (73.4) |
| v31 baseline, cache lever | 10000 | 34.9 | 69.0 (65.4 / 2.6) | 103.9 | 80.1 | 65.4 (66.2) |
| v31 baseline, cache lever | 5000 | 21.6 | 87.1 (83.2 / 2.9) | 108.7 | 87.5 | 52.5 (53.0) |

| freed against the 20000-cache v31 row (GiB) | GTT | GTT + RSS | MemAvailable drop |
| --- | ---: | ---: | ---: |
| Q2_0 | 29.7 | 15.7 | 12.6 |
| IQ2_XS | 27.3 | 17.9 | 16.1 |
| UD-Q2_0 | 18.8 | 16.2 | 0.7 |
| v31 at cache 10000 | 26.7 | 2.4 | 7.7 |
| v31 at cache 5000 | 40.0 | −2.4 | 20.6 |

- **Load peak.** GTT never exceeds its loaded figure, so the transient peak of a load is on the host side: the lowest
  MemAvailable during a row is 0.5–3.3 GiB below the loaded median, and the RSS peak is 0.4–11.1 GiB above the loaded
  RSS (11.1 GiB at cache 10000, 3.5 GiB at most for the others).
- **`VmLck`** of `strata-host` (its mlocked tables) is 26.8 GiB in every row; mlocked pages are not in MemAvailable.
- The MemAvailable drop is not the process's footprint: it also moves with whatever page cache the kernel had given up.
  It is reported because it is the figure a pressure watchdog is most likely to read; which figure that is was not
  checked.
- GTT of the v31 file at cache 20000 (61.6 GiB) matches the 2026-11-12 run's 61.6 GiB. The baseline's idle MemAvailable
  (110.2 GiB) was 3–7 GiB below the other rows' (113.4–117.4), so compare the drops, not the absolute values.

## Expert-cache lever (v31 file only)

| `--expert-cache` | GTT (GiB) | MemAvailable drop (GiB) | prefill 4K (t/s) | decode 512 (t/s) | MTP acceptance |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 20000 | 61.6 | 73.1 | 456.1 | 37.4 | 0.518 |
| 10000 | 34.9 | 65.4 | 430.4 | 34.4 (−8 %) | 0.506 |
| 5000 | 21.6 | 52.5 | 427.4 | 31.9 (−15 %) | 0.500 |

Decode at 32K and 128K and the agent replay were **not measured** at the smaller caches, and neither was KLD. The
smoke rows used a 2048 cache at 8K context: GTT was 7.5 GiB for Q2_0, 7.2 GiB for IQ2_XS and 10.0 GiB for UD-Q2_0
(IQ2_XS at cache 20000 and 131072 context: 34.3 GiB), so most of the GTT here scales with the cache or the context.

## Quality

`kl_strata.py` from [the 2026-10-07 run](../qwen38-flash-next-strata-quality-2026-10-07/), arm `def`, 64 chunks of the
same corpus and positions as #276, top-256 estimator, against the stored Q8_0 reference logits (not regenerated). Strata
ran at the production cache of 20000.

| row | chunks | positions | mean KLD | median | p99 | same top token | PPL (ratio to ref) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| base (v31) | 64 | 65472 | 0.0741 ± 0.0010 | 0.0039 | 0.99 | 92.12 ± 0.11 % | 2.5256 (0.9700 ± 0.0019) |
| q2_0 | 64 | 65472 | 0.2838 ± 0.0029 | 0.0158 | 3.34 | 85.51 ± 0.14 % | 2.7371 (1.0512 ± 0.0041) |
| iq2_xs | 64 | 65472 | 0.2517 ± 0.0027 | 0.0139 | 2.89 | 85.94 ± 0.14 % | 2.7155 (1.0429 ± 0.0037) |
| ud_q2_0 | 64 | 65472 | 0.1562 ± 0.0017 | 0.0112 | 1.85 | 88.57 ± 0.12 % | 2.4892 (0.9560 ± 0.0028) |

| paired against v31 | positions | ΔKLD | ΔNLL per token | top-1 differs |
| --- | ---: | ---: | ---: | ---: |
| q2_0 − base | 65472 | +0.2097 ± 0.0025 | +0.0804 ± 0.0036 | 13.9 % |
| iq2_xs − base | 65472 | +0.1776 ± 0.0022 | +0.0725 ± 0.0033 | 13.7 % |
| ud_q2_0 − base | 65472 | +0.0821 ± 0.0013 | −0.0145 ± 0.0025 | 10.7 % |

The v31 baseline's 0.0741 is below #276's 0.0920 for the earlier UD-IQ4_XS file; they are different files and not
compared further. The perplexity ratio of `ud_q2_0` and the baseline (both below 1) is a perplexity on the corpus text,
not a quality claim: KLD against the reference is the measure used above.

## Speed

Default arm, 131072 context, MTP on. The candidates are from the `A` and `B` rows (`A`: tool call, prefill 4K, decode
512, decode 32K, 8-turn agent replay, vision; `B`: decode 128K). The v31 column is the [2026-11-12 v0.2.13
row](../qwen38-flash-next-strata-v0.2.13-2026-11-12/README.md), same engine commit and same file; this session's v31 row
only covered tool call, prefill 4K and decode 512 (second column), so its other cells are **unmeasured**.

| (Strix Halo, one run each) | v31, 2026-11-12 | v31, this session | Q2_0 | IQ2_XS | UD-Q2_0 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Prefill 4K (t/s) | 479.5 | 456.1 | 713.1 | 603.1 | 651.8 |
| Prefill 32K (t/s) | 527.2 | unmeasured | 764.9 | 654.9 | 711.7 |
| Prefill 128K (t/s) | 493.2 | unmeasured | 679.5 | 628.5 | 625.9 |
| Decode 512 (t/s, T=0.7) | 38.6 | 37.4 | 46.5 | 43.4 | 42.7 |
| Decode 32K (t/s) | 38.3 | unmeasured | 43.8 | 45.8 | 45.2 |
| Decode 128K (t/s) | 37.5 | unmeasured | 41.1 | 42.3 | 43.7 |
| MTP acceptance at 512 / 32K / 128K | 0.535 / — / 0.571 | 0.518 / — / — | 0.529 / 0.555 / 0.554 | 0.444 / 0.646 / 0.638 | 0.509 / 0.571 / 0.603 |
| Agent replay, normalized (s, lower is better) | 139.5 | unmeasured | 101.4 | 117.5 | 108.5 |
| Replay, time to first token summed (s) | 99.0 | unmeasured | 66.8 | 79.0 | 72.7 |
| Tool call | ok | ok | ok | ok | ok |
| Vision (128×128 two-colour picture) | 1 of 4 correct (both pins) | not run | "Red, Blue" | "red, blue" | "Red Blue" |

The 2-bit files are faster (decode 512 +11 % to +20 %, replay −16 % to −27 % against the 2026-11-12 row). The
2026-11-12 run's iterations within a row spread 1.5–5 t/s in decode and 3–10 t/s in prefill and this run repeated no row,
so the ranking among the three 2-bit files is not claimed. Speed at the 5000 and 10000 caches is in the lever table. The
vision picture was answered on all three candidates and on 1 of 4 v31 runs in 2026-11-12; each is a single run and no
signal either way.

## Setup and the load rule

- **Pack and MTP runtime** per candidate with the tools of the 2026-11-12 run: `iq_pack.py --compat-bf16` per quant file
  (Q2_0: 303 tensors served natively, 0 in `extra.bin`; IQ2_XS and UD-Q2_0: 302 native, 0 in `extra.bin`; each pack
  1.4–1.5 GiB). No candidate was rejected by `iq_pack.py` or by the engine at load, so there is **no rejection text to
  quote**. The MTP runtime and the projector are shared with v31: its stamp has no model input.
- **Every GPU row went through `run.sh`** (fit check, load gate, unload of lemond's resident model, the probe, restore of
  the resident), one model loaded at a time, one row per call, via [`rows.sh`](rows.sh). `rows.sh` waits for the 1-minute
  loadavg to fall below 4 (cap 15 min, then runs and flags), refuses while another bench holds the signal file
  (`halo-gpu-bench.active`, which `run.sh` writes and removes itself; the `.lock` file beside it is a persistent flock
  file, not the signal), samples the footprint, and after each row greps the kernel log for amdgpu errors.
- **Load rule, judged by start and end load.** Every gate passed below 4 (1.4–3.98 at the gate with lemond still loaded,
  all but one at 3.1 or above; 1.3–2.0 at the probe's start once lemond was unloaded, from `rows.jsonl`); waits before a
  row were 0–270 s, none hit the cap, no row was refused for a foreign signal file, and none was flagged. Strata's own
  threads raise the load average to 4.7–25 by the end of a row (as the 2026-11-12 run recorded, the average counts
  runnable threads), so a row cannot be judged by its peak and none was re-run. A foreign process during a row cannot be
  separated from that and was not looked for beyond the signal file.
- **Kernel log:** 0 amdgpu hits on every row. The kernel log before the run had none either.
- **`kl` stage:** run through `run.sh exec` rather than the quality `rows.sh`, whose pre-check refuses while lemond's resident
  `strata` engine is up.
- **The resident was killed mid-session.** An unrelated process on the host killed lemond's resident engine at about 22:10 on
  2026-11-15, a minute before the v31 baseline row. Every row, that one included, started with GTT at 0.0 GiB and
  MemAvailable of 110–117 GiB, so no second resident engine sat beside a row.
- **Downloads:** all three candidates lost and were deleted after the run (137 GiB freed from the HF cache, so none is
  kept). The GSQ-RCO IQ3_S files already in the cache, the v31 files, the Q8_0 reference logits and the production pack
  were not touched (IQ2_XS and Q2_0 share their second shard with IQ3_S, so that blob stayed). The measurements were kept
  (footprint series, row JSON, KLD logs) on the host; they are not committed.

## Reproduce

```sh
nix build .#strata -o result-strata --max-jobs 2 --cores 12
# download the candidate shards at the snapshots above (explicit file names; the --include glob form did not match)
export WORK=<work dir> CACHE=<corpus cache.json at rev 4166bc4> PY=<python with numpy regex jinja2 pyyaml requests psutil pillow tqdm> \
  STRATA_OUT=$PWD/result-strata MTP_RT=<mtp/rt> MMPROJ=<mmproj file> REF=<Q8_0 reference logits> \
  BASE_PACK=<v31 pack> BASE_SHARD=<v31 shard 1> Q2_0_SHARD=<shard 1> IQ2_XS_SHARD=<shard 1> UD_Q2_0_SHARD=<shard 1>
D=bench-logs/qwen38-flash-next-strata-2bit-2026-11-15
for c in q2_0 iq2_xs ud_q2_0; do $D/rows.sh $c pack; done                 # CPU only, niced
for c in q2_0 iq2_xs ud_q2_0; do for s in smoke "foot 20000" A B kl; do $D/rows.sh $c $s; done; done
for s in "foot 20000" "foot 10000" "foot 5000" kl; do $D/rows.sh base $s; done
$PY bench-logs/qwen38-flash-next-strata-quality-2026-10-07/kl_strata.py compare --ref "$REF" --json cmp.json \
  base=$WORK/base/kl/kl-def-64 q2_0=$WORK/q2_0/kl/kl-def-64 iq2_xs=$WORK/iq2_xs/kl/kl-def-64 ud_q2_0=$WORK/ud_q2_0/kl/kl-def-64
$PY bench-logs/qwen38-flash-next-strata-quality-2026-10-07/tables.py kl cmp.json
python3 $D/test_footprint.py                                              # sampler tests, no GPU
```

`rows.sh` takes the candidate and stage; each GPU stage is one gated `run.sh` row. `footprint.py summarise --raw <series>`
recomputes a row's footprint summary from its raw sample series.
