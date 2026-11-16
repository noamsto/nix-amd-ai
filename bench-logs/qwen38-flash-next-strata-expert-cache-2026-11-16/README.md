# Strata `--expert-cache` size on Flash-Next v31: quality, speed, footprint, reload cost (#354)

[#352](../qwen38-flash-next-strata-2bit-2026-11-15/README.md) found that `--expert-cache 5000` frees 40 GiB of GTT and
20.6 GiB of MemAvailable for −15 % decode at 512, more than any 2-bit quant freed, but it left four things unmeasured:
quality, long-context speed and agent replay, whether the GTT that leaves the GPU comes back as locked or reclaimable host
memory, and what a reload costs. This run measures them, to decide (a) whether to lower the production default, and
(b) whether reloading at 5000 is a usable memory-pressure step.

Every number is from one **Strix Halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT limit, kernel
7.3.4)** host, measured 2026-11-16 on **Strata v0.2.13** with `UD-IQ4_XS-v31` (the production file, 4 shards, Unsloth
`Qwen3.8-Flash-Next-GGUF` snapshot `d9620119`) at `--expert-cache` 20000, 10000 and 5000, through the #249 harness
(`run.sh` memory gate, `probe.py`) and the corpus of the
[2026-10-06 Strata run](../qwen38-flash-next-strata-2026-10-06/README.md). Nothing here transfers to gfx1150. Default arm
of #352: `--prefill auto --spec 4 --spec-min-p 0.5 --kv int8 --mmap-experts`, `-c 131072`, MTP drafting, BF16 mmproj
vision. One run per cell, except where a table says otherwise: differences of a few percent are not claimed.

The host is shared: another job on it kept the 1-minute load average at 14–43 for most of the A/B rows (every row
**started** below the load-4 gate, see Host load). That bears on the speed table and is the main caveat on it.

## Verdict

**(a) Lowering the default to 10000 buys 27 GiB of GTT and 8–26 GiB of MemAvailable for a decode cost this run could not
pin down (−8 % to −18 % at 512, no loss at 32K, −29 % at 128K under load). It costs no measurable quality. It is a
defensible default only if the host is short of memory in practice; the numbers do not make it free.**

- Quality: ΔKLD against the 20000 row is +0.0004 ± 0.0004 at 10000 (noise) and +0.0018 ± 0.0004 at 5000 (against a mean
  KLD of 0.074, about 2 %). The 20000 baseline is #352's stored row, not a repeat in this session, so run-to-run noise is
  not separated from a cache effect: "lossless" is neither confirmed nor refuted at 5000.
- Decode cost against the 20000 row of this session (v31, halo): 10000 is 32.0 vs 38.9 t/s at 512 (−18 %), 39.1 vs 38.6
  at 32K, 24.8 vs 35.1 at 128K (−29 %), agent replay 161.8 vs 145.0 s (+12 %). #352 measured 34.4 vs 37.4 t/s at 512 for
  10000 (−8 %). The 10000 cells are the noisiest of the run (loadavg peaks 28.8 and 38.2) and 10000 decode at 512 is no
  faster than 5000's, which a cache-size effect does not explain: read the −8 % to −18 % range, not either end.
- Headroom at 10000 against 20000: GTT −26.7 GiB, GTT + process RSS −12.2 GiB (113.1 → 100.9), MemAvailable after load
  +26.2 GiB here (+7.7 GiB in #352; the two 20000 rows disagree, see Footprint). Locked memory (`VmLck`, 26.8 GiB) does
  not move at any cache size.

**(b) A reload at 5000 looks safe on the transient that was measured, and it is untested under real memory pressure.**

- Nothing overshoots: on the 5000 reload the GTT peak is the steady state (21.6 GiB), the process RSS peak is 47.5–47.8
  GiB, and the lowest MemAvailable is 52.1–52.5 GiB below idle. The 20000 reload on the same host peaks at 61.6 GiB of
  GTT and 89.7–95.6 GiB below idle, so the 5000 transient is the smaller of the two.
- The outage window is shorter too: spawn to first token is 22.8 s (warm page cache) to 37.4 s (partly evicted) at 5000
  against 65.9–78.9 s at 20000. The first token itself is slower at 5000 (4.8–5.3 s against 0.8–1.8 s) because the cache
  starts small and experts page in.
- The risk figure is not measured. A pressure step unloads the 20000 engine and then loads at 5000 while memory is short;
  every reload row here started with the previous engine gone and no memory pressure, so how long the unload takes,
  and how the load behaves when MemAvailable is already near zero, are **unmeasured** (no synthetic pressure test was
  run, as specified).
- Steady state after the reload is not free: at 5000 the decode cost is −18 % at 512, −12 % at 32K and −20 % at 128K,
  prefill 4K −11 %, replay +7 % (host load caveat applies).
- What the dips say about the 20000 engine: while it was resident, MemAvailable fell to 0.3–1.0 GiB for 62 s before
  the first row, and to 0.6–2.2 GiB for 338 s during a later load-gate wait, when the kernel OOM-killed another job's
  process. The 20000 restore reload at the end of a row bottomed at 2.0 GiB once (6 s under 5 GiB) and at 9–29 GiB in
  the other 11 restores. That is pressure observed at 20000. No smaller cache was ever resident across a window like
  those, so it is no evidence that a smaller cache avoids it. See Host load and memory dips.

## Quality

Top-256 KL against the stored Q8_0 reference logits, `def` arm, 64 chunks, 65,472 positions, v31 file, halo. The 20000 row
is #352's (`def` arm, same corpus and chunks, same engine build); the 10000 and 5000 rows are from this run. A 20000 row
of this run was queued last and **not run**: `run.sh` paused it on host load without loading anything. Paired against
the 20000 row (same positions):

| row | chunks | positions | mean KLD | median | p99 | same top token | PPL (ratio to ref) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 20000 (#352) | 64 | 65472 | 0.0741 ± 0.0010 | 0.0039 | 0.99 | 92.12 ± 0.11 % | 2.5256 (0.9700 ± 0.0019) |
| 10000 | 64 | 65472 | 0.0746 ± 0.0010 | 0.0040 | 0.97 | 92.09 ± 0.11 % | 2.5221 (0.9686 ± 0.0019) |
| 5000 | 64 | 65472 | 0.0759 ± 0.0011 | 0.0040 | 0.97 | 92.12 ± 0.11 % | 2.5246 (0.9696 ± 0.0020) |

| paired against 20000 (#352) | positions | ΔKLD | ΔNLL per token | top-1 differs |
| --- | ---: | ---: | ---: | ---: |
| 10000 | 65472 | +0.0004 ± 0.0004 | −0.0014 ± 0.0007 | 3.2 % |
| 5000 | 65472 | +0.0018 ± 0.0004 | −0.0004 ± 0.0008 | 3.2 % |

The top token differs at 3.2 % of positions between every pair of rows (5000 against 10000: 3.2 %, too), so that
fraction does not grow as the cache shrinks. No size was repeated, so how much of it is run-to-run variation is
**unmeasured**. ΔKLD at 5000 is about 4 standard errors from zero and 2 % of the mean KLD; at 10000 it is within noise.

## Speed

Default arm, 131072 context, MTP on, v31 file, halo. Rows are `A` (tool call, prefill 4K, decode 512, decode 32K, 8-turn
agent replay, vision) and `B` (decode 128K, whose prefill gives the 128K cell), as in #352, one run per cell; ± is the
standard deviation of the 3–4 iterations inside the cell. The 10000 `B` row is the re-run of a row that overlapped
another job's CPU-heavy run.

| halo, v31 | --expert-cache 20000 | --expert-cache 10000 | --expert-cache 5000 |
| --- | ---: | ---: | ---: |
| Prefill 4K (t/s) | 442.2 | 426.8 | 395.6 |
| Prefill 32K (t/s) | 512.9 | 522.2 | 506.2 |
| Prefill 128K (t/s) | 459.0 | 353.3 | 463.5 |
| Decode 512 (t/s, T=0.7) | 38.9 ± 1.9 | 32.0 ± 1.7 | 31.8 ± 3.7 |
| Decode 32K (t/s) | 38.6 ± 2.2 | 39.1 ± 4.0 | 33.8 ± 2.5 |
| Decode 128K (t/s) | 35.1 ± 3.5 | 24.8 ± 4.5 | 28.1 ± 1.7 |
| MTP acceptance at 512 / 32K / 128K | 0.499 / 0.584 / 0.579 | 0.471 / 0.645 / 0.630 | 0.497 / 0.616 / 0.582 |
| Agent replay, normalized (s, lower is better) | 145.0 | 161.8 | 155.1 |
| Replay, time to first token summed (s) | 104.3 | 108.1 | 105.1 |
| Load time, spawn to ready (s) | 72.1 | 30.0 | 24.0 |
| Peak 1-minute loadavg during the A / B rows | 21.3 / 28.1 | 28.8 / 38.2 | 27.6 / 34.9 |

Against #352's lever table (decode 512: 37.4 / 34.4 / 31.9 t/s at 20000 / 10000 / 5000): 20000 here is 38.9 and 5000 is
31.8, close; 10000 here is 32.0 against 34.4. Load time at 10000 and 5000 matches the 30 / 24 s of #352; at 20000 it is
72 s against #352's 86 s.

Two things hold across the table despite the noise: decode at 512 and replay are slower at both smaller caches, and the
loss is not monotone in cache size (10000 is slower than its neighbours at 512 and 128K). The ranking between 10000 and
5000 is not claimed. Tool call and vision passed on every row.

## Footprint

v31 file, halo, one `foot` row per size (tool call, prefill 4K, decode 512), sampled by `footprint.py`; all values GiB.
"Baseline" is MemAvailable idle before the load; the 20000 baseline here (116.3) is within 1.2 GiB of the others.

| --expert-cache | GTT loaded | process RSS loaded (file / anon) | GTT + RSS | RSS peak | VmLck | system Mlocked delta | Active(file) delta | Inactive(file) delta | MemAvailable baseline | MemAvailable drop, loaded | MemAvailable drop, lowest |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 20000 | 61.6 | 51.5 (47.6 / 2.3) | 113.1 | 52.7 | 26.8 | +26.5 | +1.5 | −15.3 | 116.3 | 91.6 | 92.8 |
| 10000 | 34.9 | 66.0 (62.4 / 2.6) | 100.9 | 77.1 | 26.8 | +26.8 | +1.4 | +10.8 | 115.8 | 65.4 | 66.5 |
| 5000 | 21.6 | 81.2 (77.7 / 2.6) | 102.8 | 87.5 | 26.8 | +26.8 | −1.4 | +50.0 | 115.1 | 52.0 | 53.6 |

Where the freed GTT went, against the 20000 row (GiB; freed GTT = GTT(20000) − GTT(S), host figures are S − 20000):

| split of freed GTT | freed GTT | locked (ΔVmLck) | reclaimable file (ΔRssFile − ΔVmLck) | anon (ΔRssAnon) | rest = freed − (locked + file + anon) | ΔMemAvailable drop |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 10000 | 26.7 | 0.0 | 14.8 | 0.3 | 11.6 | −26.2 |
| 5000 | 40.0 | 0.0 | 30.1 | 0.3 | 9.6 | −39.6 |

- **None of it comes back locked.** `VmLck` is 26.8 GiB at all three sizes (the same as production's 26.8 GiB) and the
  system `Mlocked` delta moves by 0.3 GiB: the 26.8 GiB is a fixed cost independent of the cache, so a smaller cache
  cannot free it.
- **Reclaimable file pages take 14.8 GiB (10000) and 30.1 GiB (5000) of it** (RSS file minus locked); about 10 GiB
  (`rest`) reappears as neither locked, file nor anon in the process and is not explained here. Because the file pages
  are reclaimable, MemAvailable counts them and the drop shrinks by 26.2 / 39.6 GiB, while GTT + process RSS falls by only
  12.2 / 10.3 GiB (113.1 → 100.9 / 102.8): a watchdog reading GTT + RSS sees about a third of what one reading
  MemAvailable sees, and one reading GTT alone sees all of it.
- Whether those pages are reclaimed *fast enough* under real pressure is **unmeasured** (no synthetic pressure test).
  `Inactive(file)` growing by 10.8 / 50.0 GiB (and shrinking by 15.3 GiB at 20000) says the kernel files them as
  inactive.
- The 20000 row here disagrees with #352's: MemAvailable drop 91.6 against 73.1 GiB (10000: 65.4 against 65.4, 5000:
  52.0 against 52.5). The two other sizes reproduce; the 20000 gap of 18.5 GiB is not isolated (the page-cache state at
  the start of each row differed, 12.8–42.0 GiB across the rows). Taking #352's row as the reference, the MemAvailable
  headroom is +7.7 GiB at 10000 and +20.6 GiB at 5000, which is why the verdict gives a range.

## Reload cost

Time from the start of the load request to the first token served, and the whole-row peaks of a dedicated reload row
(`--do firsttoken`, nothing else run in the row), v31 file, halo. `cold` evicts the page cache before the load, `warm`
does not. 10000 was not asked for and is **unmeasured**.

| --expert-cache | reload | since spawn (s) | load_s | ttft_s | GTT peak (GiB) | RSS peak (GiB) | MemAvailable drop, lowest (GiB) | page cache at start (GiB) | page cache dropped (GiB) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 20000 | cold | 78.9 | 78.1 | 0.8 | 61.6 | 50.4 | 89.7 | 30.3 | 27.9 |
| 20000 | warm | 65.9 | 64.1 | 1.8 | 61.6 | 50.3 | 95.6 | 32.2 | – |
| 5000 | cold | 37.4 | 32.0 | 5.3 | 21.6 | 47.5 | 52.5 | 19.5 | 5.4 |
| 5000 | warm | 22.8 | 18.0 | 4.8 | 21.6 | 47.8 | 52.1 | 38.3 | – |

- The "cold" rows are partly cold. The eviction dropped 27.9 GiB at 20000 and only 5.4 GiB at 5000, and 19.5–30.3 GiB
  of page cache was still present when the load started (file pages of other processes, or the file itself; not told
  apart). A fully cold start would be slower.
- `RSS peak` here is the peak during the load row, which stops after the first token. The 77–88 GiB RSS of the
  footprint table is reached later, as decode pages the experts in.
- The spawn-to-first-token times include the harness's own wait for the model to report ready.

## Host load and memory dips

- Gate: `run.sh` starts a row only when the 1-minute load average is below 4 (30-minute cap in this harness); every
  row that ran started at 1.6–2.0 (the load average `probe.py` read) and none was flagged at start, with waits of 0–260 s
  (180 s for the re-run). The kernel log had no amdgpu errors after any row. By the end of the A and B rows the load
  average was 14–43, partly the engine itself (5–7 cores) and partly another job on the host (a CPU-heavy benchmark that held it at 24–37 for
  hours): the peak per row is in the speed table. The 10000 `B` row was run twice; the table uses the second run.
- The 20000 `kl` row never ran (load pause), see Quality.
- A 2 s timeline of MemAvailable and GTT was recorded from the foot 5000 row onwards, with the 20000 engine resident
  between rows (GTT about 70 GiB). MemAvailable fell below 4 GiB in these windows:
  - While the 20000 engine sat resident waiting for the load gate: 10:51:29–10:52:29 (62 s, minimum 0.3 GiB, and 10 s at
    1.0 GiB), and during the `kl` 20000 row's wait, 338 s at 0.6–2.2 GiB plus several 2–6 s dips. The kernel OOM killer
    ended an unrelated process of another job inside the second window. The allocations were not identified.
  - After one restore reload of the 20000 engine (the end of foot 5000): the load finished at GTT 70.4 GiB with
    MemAvailable 21.2 GiB, which then fell to 2.0 GiB over 45 s and recovered within 6 s to 25 GiB. Of the 12 restore
    reloads recorded, this was the only one under 5 GiB; the others bottomed at 9.4–28.7 GiB. So the restore reload is
    not the usual source of the 1–2 GiB dips, but it is not always clear of them either.
  These are observations of the resident 20000 engine on a shared host, not an effect of any cache size.
- The footprint table's `Mlocked` and the timeline disagree on how much the resident engine locks (8–25 GiB across the
  day); not examined.

## Not measured

- Reload and steady state under real memory pressure (no synthetic pressure test), including the unload time of the 20000
  engine and the behaviour of the pressure watchdog during a swap to 5000.
- A same-session 20000 KL row and any repeat of a size (single run per cell, so noise is not separated).
- Reload at 10000; a fully cold reload.
- The 20000 MemAvailable discrepancy with #352 (18.5 GiB).
- The ~10 GiB of freed GTT that does not show up as locked, file or anon.

## Reproduce

```sh
nix build .#strata -o result-strata --max-jobs 2 --cores 12
export WORK=<work dir> CACHE=<corpus cache.json at rev 4166bc4> PY=<python with numpy regex jinja2 pyyaml requests psutil pillow tqdm> \
  STRATA_OUT=$PWD/result-strata MTP_RT=<mtp/rt> MMPROJ=<mmproj file> REF=<Q8_0 reference logits> \
  BASE_PACK=<v31 pack> BASE_SHARD=<v31 shard 1>
R=bench-logs/qwen38-flash-next-strata-2bit-2026-11-15/rows.sh
D=bench-logs/qwen38-flash-next-strata-expert-cache-2026-11-16
for r in "reload 5000 cold" "reload 5000 warm" "reload 20000 cold" "reload 20000 warm"; do $R base $r || break; done
for n in 5000 10000 20000; do for s in foot A B kl; do $R base $s $n || break 2; done; done   # stop on a non-zero exit
$PY bench-logs/qwen38-flash-next-strata-quality-2026-10-07/kl_strata.py compare --ref "$REF" --chunks 64 --json cmp.json \
  def20000=<20000 kl run dir> c10000=$WORK/base/kl/kl-def-64-c10000 c5000=$WORK/base/kl/kl-def-64-c5000
$PY bench-logs/qwen38-flash-next-strata-quality-2026-10-07/tables.py kl cmp.json
python3 $D/tables.py footprint --dir $WORK/base
python3 $D/tables.py reload --dir $WORK/base --rows $WORK/base/rows.jsonl
python3 $D/tables.py speed --rows $WORK/base/rows.jsonl
python3 bench-logs/qwen38-flash-next-strata-2bit-2026-11-15/test_footprint.py    # sampler tests, no GPU
python3 $D/test_tables.py && bash $D/test_rows.sh                                  # table and row-argument tests, no GPU
```

`rows.sh` takes `<candidate> <stage> [cache]` and `reload <cache> cold|warm`; the cache size is part of the row label from
any size other than 20000 (`-c<N>`). Each GPU stage is one gated `run.sh` row and the script restores lemond's resident
model on every exit path. `ROWS_DRY_RUN=1` prints a row's resolved configuration without starting anything (used by
`test_rows.sh`). `footprint.py` (in the #352 directory) samples GTT, process RSS, `VmLck`, `Mlocked`, `Active(file)` and
`Inactive(file)`, and MemAvailable at about 1 Hz while a row runs.

The `firsttoken` group in `probe.py` (`--do firsttoken`) is the reload row: it sends one chat request right after the
load and records `ttft_s` and `since_spawn_s` on the load-time clock. `--evict-before` evicts the page cache of the model
file first and records the page cache before and after; the eviction suppresses its errors, so a failed eviction shows
as a small "page cache dropped" figure.
