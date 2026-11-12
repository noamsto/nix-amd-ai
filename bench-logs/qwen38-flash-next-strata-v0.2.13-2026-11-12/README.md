# Strata v0.2.13 against v0.2.11 on Strix Halo, Flash-Next UD-IQ4_XS-v31 (#347)

Every number is from one **Strix Halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 104 GiB GTT limit)** machine, measured 2026-11-12/13
with the #249 harness (`run.sh` memory gate, `probe.py`) and the corpus of the [2026-10-06 Strata run](../qwen38-flash-next-strata-2026-10-06/README.md)
(rev `4166bc4`). Nothing here transfers to gfx1150.

Both arms run the **same file and the same pack**: Unsloth's 2026-11-04 `UD-IQ4_XS-v31` (snapshot `d9620119`, four shards) with the
pack and MTP runtime built for it, because the pack tools (`iq_pack.py`, `mtp_pack.py`, `mtp_rt.py`) are byte-identical between the two engine commits.
Only the engine changes: v0.2.11 (`c3b3f50`, built from `main` at `e11eddc`) against v0.2.13 (`d2f0964`, this branch). ggml (`3cf0325`) and
ROCm 7.14.1 are the same in both. The default arm of the earlier run: `--prefill auto --spec 4 --spec-min-p 0.5 --kv int8 --mmap-experts
--expert-cache 20000`, `-c 131072`, MTP drafting (`drafting = "mtp"`), vision loaded (BF16 mmproj, CPU encoder).

## Verdict

**v0.2.13 is a wash against v0.2.11 on this machine for the default configuration, and the bump is safe to ship on the numbers measured.**
Every difference below is inside the run-to-run spread of a single measurement; none of it was repeated, so no gain or loss is claimed.
One row, vision, needs a repeat (below).

| (Strix Halo, MTP on, 131072 context, one run each) | v0.2.11 | v0.2.13 |
| --- | ---: | ---: |
| Prefill 4K (t/s) | 477.6 | 479.5 |
| Prefill 32K (t/s) | 538.0 | 527.2 |
| Prefill 128K (t/s) | 488.9 | 493.2 |
| Decode 512 (t/s, T=0.7) | 38.4 | 38.6 |
| Decode 32K (t/s) | 40.9 | 38.3 |
| Decode 128K (t/s) | 36.9 | 37.5 |
| MTP acceptance at 512 / 128K | 0.507 / 0.576 | 0.535 / 0.571 |
| Agent replay, normalized (s, lower is better) | 137.3 | 139.5 |
| Replay, time to first token summed (s) | 96.9 | 99.0 |
| GTT after load / peak (GiB) | 61.6 / 61.6 | 61.6 / 61.6 |
| Load time (s) | 68.1 | 64.1 |
| Tool call | ok | ok |

- Decode rows carry a standard deviation of 1.5–5 t/s (3 runs); the 32K decode difference (−2.6 t/s) is about that size. Prefill rows have
  a standard deviation of 3–10 t/s.
- **GTT for the v31 file: 61.6 GiB after load, unchanged at peak, at 131072 context with `--expert-cache 20000`** (the delta of
  `mem_info_gtt_used` against the machine with lemond's resident model unloaded). The model sits idle after load until the first request, so the
  loaded and idle figures are the same number; the peak over the rows is also 61.6 GiB. It is a delta over an empty GPU, not a
  total. The 2026-10-06 run reported 66.2 GiB for the September `UD-IQ4_XS` file; they are different files and were not measured side by side.
- **Vision is flaky on both pins and this run does not separate them.** The 128×128 two-colour test picture was answered
  correctly once of four times (old smoke: "Blue Red"; old A: "Red"; new smoke: "Blue"; new A: "Red"). A single-run pass/fail on this
  picture is not a regression signal for either engine; the question was **not** investigated further.
- Absolute prefill and replay here are below the 2026-10-06 defaults row (that run: 664 / 730 / 648 prefill, 113.6 s replay) on a different
  file and on a different day; why they differ was **not tested**.
- **Not measured:** the `fast` configuration, lookup chain, correctness against a reference (the `correctness` row), concurrency,
  DFlash2 drafting (upstream 0.2.10+ defaults to it where a tuned pack exists; the module pins `drafting = "mtp"` and provisions no
  DFlash2 pack), other quants (`GSQ-RCO-IQ3_S`), gfx1150, and any repeat of a row.

## Setup

- Engines: `nix build .#strata` on `main` (`e11eddc`) and on this branch, two out-links; same pack, MTP runtime and mmproj for both.
- Rows go through `run.sh`: fit check, load gate, unload of lemond's resident model, the probe, restore of the resident. Per row: the
  wrapper [`rows.sh`](rows.sh) waits for the 1-minute loadavg to fall below 4 (cap 15 min, then runs and flags), refuses while another
  bench holds the signal file, and records start and end loadavg. `run.sh` writes and removes `halo-gpu-bench.active` itself.
- Rows: `smoke` (8K context, 2048-expert cache: tool call, prefill 4K, decode 512, vision), `A` (tool call, prefill 4K, decode
  512, 32K decode, 8-turn agent replay, vision), `B` (128K decode), each once per pin, old first. Row labels `old-*` / `new-*`.

| row | loadavg at start (after lemond unloaded) | at end | peak |
| --- | ---: | ---: | ---: |
| old smoke | 1.7 | 17.8 | 19.7 |
| new smoke | 1.8 | 12.0 | 16.3 |
| old A | 1.5 | 14.9 | 18.7 |
| new A | 1.4 | 15.2 | 22.6 |
| old B | 1.5 | 16.1 | 22.9 |
| new B | 1.9 | 10.2 | 21.5 |

Every row started below 4. The end and peak loads are the engine's own threads (3–4 cores of decode and CPU expert work, the same pattern the
2026-10-06 run recorded: the load average counts runnable threads, not cores), so no row was re-run; nothing foreign was seen on the signal file.
The pre-row waits were 0–50 s.

Harness fixes this run needed, all committed with it:

1. `run.sh` took `Qwen3.8-Flash-Next-MTP` as lemond's resident model. It now reads `LEMOND_MODEL` (default unchanged); `rows.sh` sets
   `Qwen3.8-Flash-Next-Strata`, which is what the host serves now.
2. `run.sh`'s fit check refused the first attempt (need 95 GiB, 86.6 GiB free). `lemond_rss` counted only `RssAnon` of lemond's
   process tree, but `strata-host` mlocks its tables: 27 GiB of `VmLck`, 0.2 GiB of `RssAnon`. Mlocked pages are not in `MemAvailable`
   and come back on unload, so the free figure is now 114.4 GiB. It counts, per process, the larger of `RssAnon` and `VmLck`; `test_lemond_rss.sh`
   gained a case. The need (95 GiB) and the lazy-off floor (94 GiB) are unchanged.
3. `probe.py` looked for an engine process named `strata`; this engine's process is `strata-host`. Both names match now.
4. `rows.sh` points the probe at the v31 shard (`run.sh` defaults to the September file, which does not match the v31 pack: the
   first attempt died on a missing `-00002-of-00004` shard and left the resident loaded).

## Reproduce

```sh
nix build .#strata -o result-strata-new                      # this branch
nix build <main checkout>#strata -o result-strata-old        # main at e11eddc
# build the v31 pack, MTP runtime and mmproj as in the 2026-10-06 README's Reproduce, from the v31 shard
export W=<work dir> CACHE=<corpus cache.json at rev 4166bc4> PY=<python with numpy regex jinja2 pyyaml requests psutil pillow tqdm> \
  PACK=<v31 pack> MTP_RT=<mtp/rt> MMPROJ=<mmproj file> PIN_OLD=$PWD/result-strata-old PIN_NEW=$PWD/result-strata-new
D=bench-logs/qwen38-flash-next-strata-v0.2.13-2026-11-12
for pin in old new; do for s in smoke A B; do $D/rows.sh $pin $s; done; done   # rows go to $W/rows.jsonl
```
