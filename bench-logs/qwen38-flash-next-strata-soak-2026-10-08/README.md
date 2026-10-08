# Strata soak, concurrency, 256K and two-session rows on halo (#282)

Every number is from **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT limit, kernel 7.2.9)**,
measured 2026-10-08, one benchmark at a time with lemond's resident model unloaded for the row and restored afterwards.
Nothing here transfers to gfx1150. Model: Qwen3.8-Flash-Next **UD-IQ4_XS** (unsloth), Strata fast configuration (#279).

## Verdict

1. **Move the single-agent lane to Strata: yes, with the concurrency caveat below.** On one session it is faster than the
   resident GSQHalo at every depth tried (prefill 1.3-1.4x, decode about +25-35 %), uses 7-10 GiB less GTT, accepts a
   262144 context, and a 60-minute mixed soak had no errors, no engine restart and a flat canary.
2. **Local agent lane: 1x256K, not 2x128K.** One Strata session at 256K decodes about 36-40 tok/s with an agent turn
   on the cached prefix in about 3 s and 68.8 GiB peak GTT (35 GiB headroom). Two sessions at once do not scale on
   either engine: Strata `--batch 2` yields about 15 tok/s combined (a single stream gets about 40), GSQHalo `-np 2`
   about 30 combined (a single stream gets about 31), at 16 GiB GTT headroom. Two sessions *taking turns* work only if the
   first one's cache survives (see 4).
3. **60-minute soak: no correctness or stability problem.** 266 requests, 0 errors, 0 engine restarts, the canary's
   temperature-0 decode at 38.6-40.0 tok/s (11 of 13 readings at 39.9-40.0) and prefill at 1,021-1,065 tok/s after the first reading (953), GTT constant.
   One thing to watch: the engine's anonymous memory grew 1.3 GiB over the hour (1.26 to 2.55 GiB, max 2.86).
4. **Cache affinity and the concurrent-decode collapse are separate problems.** Affinity: Strata keeps one resident
   conversation (a second session's prefill evicts the first: 96 s to re-prefill 110K tokens); `--conversation-cache-mib 8192`
   fixes that at 110K but did not hold at 238K. llama-server keeps both sessions by default. The collapse looks like
   Strata's batch path: llama.cpp with two slots holds its combined rate level with one stream, Strata's falls to about 40 % of one.

## Pins

- Repo `29202b4` plus this PR's harness changes. Corpus cache at corpus rev `4166bc4` (#249/#252); the depth and
  two-session groups use the repo's tracked text at `29202b4`, never repeated within a session.
- Strata **v0.1.40.2** (ROCm 7.14.1, `pkgs/strata`), the build lemond now deploys; it carries the sampling-defaults fix of #284
  (its run-config schema has the `sampling` block and the deployed settings set temperature 0.6, top_k 20, top_p 0.95). The
  `quirks` group was not re-run, so this is confirmed from the build, not by a behaviour test. Pack, MTP runtime and mmproj are
  #257's, made from the same GGUF; `/var/lib/models/strata` is still empty, so the rows read them from the bench work dir.
- Strata flags (the `strata-fast` preset of `run.sh`): `--prefill 16384 --spec 4 --spec-min-p 0.5 --mtp-q4 all --kv int8
  --mmap-experts --expert-profile <data/expert-profile.bin> --expert-cache 20000 --vram-reserve-mib 700`, `--max-context` as
  the row's `ctx`, vision on; variables `STRATA_PF_FUSED=1 STRATA_PF_GEMM=1 STRATA_HC_UPMIX=1 STRATA_PA_FAST=1
  STRATA_HIP_WMMA=1 STRATA_SELECT_WMMA=1 STRATA_HC_Q8=1 STRATA_PF_SWITCH_MIN_T=4096`. **KV is int8** on every Strata row.
  Rows add `--batch N`, `--batch-mtp`, `--conversation-cache-mib 8192` as named.
- GSQHalo.cpp `b0-5fc881b`, the `gsq-hip` preset of `run.sh` (`-lzm on-direct -ub 8192 -b 8192 --spec-draft-p-min 0.3`,
  MTP draft) with **f16 KV** as lemond's resident launch line has it (the probe's default q8_0 is overridden). Run by the
  harness's own llama-server with `-c 196608`, `-c 262144` and `-c 262144 -np 2` (two slots of 131072): no lemond change was
  needed to *measure* these shapes; the resident model runs `--ctx-size 131072 --parallel 1`, so serving them would need one.
- Every row: `load_flag` false at start (loadavg 0.4-2.0). The large `load max` column is the engine's own threads (1.9
  cores of engine CPU, 2.2-3.8 system-wide in the Strata rows), not other work; no row was re-run for it.

## Rows

All rows ran; none was skipped, none needed a download. `peak GTT` is the maximum over the row (0.5 s sampling), `RSS HWM` the
engine's VmHWM (mostly file-backed page cache of the experts), `anon RSS` its anonymous memory at the end.

| row | result | peak GTT GiB | RSS HWM GiB | anon RSS end GiB | load start | load max | ctx | errors | load s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| soak | ran | 66.9 | 30.7 | 1.6 | 0.77 | 24.1 | 131072 | 0 | 42.5 |
| soak-batch | ran | 74.4 | 25.4 | 2.0 | 1.72 | 20.1 | 131072 | 0 | 48.0 |
| bigimage | ran | 66.9 | 36.2 | 1.4 | 1.97 | 6.2 | 131072 | 0 | 40.1 |
| depth192 | ran | 67.8 | 37.3 | 2.3 | 1.91 | 26.9 | 196608 | 0 | 42.1 |
| depth256 | ran | 68.8 | 41.6 | 2.4 | 1.69 | 29.4 | 262144 | 0 | 42.1 |
| two128 | ran | 70.6 | 44.8 | 2.7 | 0.36 | 34.1 | 131072 | 0 | 34.0 |
| two128-mtp | ran | 71.0 | 44.6 | 2.7 | 1.65 | 34.2 | 131072 | 0 | 38.0 |
| gsq-depth192 | ran | 75.4 | 7.5 | 7.4 | 1.81 | 4.5 | 196608 | 0 | 26.0 |
| gsq-depth256 | ran | 78.5 | 8.3 | 8.0 | 1.96 | 7.3 | 262144 | 0 | 29.0 |
| gsq-two128 | ran | 88.3 | 16.9 | 13.7 | 1.84 | 12.8 | 262144 | 0 | 46.9 |
| longsoak | ran | 66.9 | 49.5 | 2.2 | 1.81 | 29.8 | 131072 | 0 | 40.1 |
| two128-park | ran | 70.6 | 44.4 | 8.1 | 0.49 | 28.4 | 131072 | 0 | 32.0 |
| two128-nobatch | ran | 66.9 | 49.0 | 2.6 | 1.73 | 37.1 | 131072 | 0 | 28.0 |
| nomtp-depth128 | ran | 65.7 | 49.7 | 2.2 | 1.65 | 24.5 | 131072 | 0 | 26.0 |
| two256-park | ran | 76.1 | 38.3 | 7.1 | 1.81 | 34.1 | 262144 | 0 | 34.0 |

Rows are in `rows.sh`. `two128-nobatch` ran by accident when an edit to `rows.sh` made a running shell repeat its loop with no
flags; it is kept as a control (one slot, two sessions in turn) and added to `rows.sh`. `ctx` for the GSQ two-session row is
the total across its two slots. Rows were re-run after harness fixes (two-session fill sizing, llama prefill budget); the
tables use each row's last run.

### 1. #282 as written (Strata fast config)

Agent replay (8 turns, thinking off, temperature 0), three repetitions, then 2 and 4 concurrent requests (half long-context
decode, half tool-call), without and with `--batch 4` (all four slots came up at 131072 each):

| row | rep | errors | ttft total s | wall total s | decode tok/s median |
|---|---:|---:|---:|---:|---:|
| soak | 1 | 0 | 52.3 | 59.1 | 69.8 |
| soak | 2 | 0 | 40.4 | 46.6 | 77.6 |
| soak | 3 | 0 | 41.4 | 47.9 | 74.3 |
| soak-batch | 1 | 0 | 54.6 | 61.0 | 77.2 |
| soak-batch | 2 | 0 | 40.1 | 46.4 | 74.4 |
| soak-batch | 3 | 0 | 40.4 | 46.7 | 75.3 |

| row | requests | errors | wall s | aggregate tok/s | long-context decode tok/s | tool-call decode tok/s | tool calls ok |
|---|---:|---:|---:|---:|---:|---:|---:|
| soak | 2 | 0 | 6.16 | 25.0 | 47.9 | 113.9 | 1 |
| soak | 4 | 0 | 11.76 | 26.2 | 44.0/42.3 | 72.3/107.7 | 2 |
| soak-batch | 2 | 0 | 7.23 | 21.3 | 23.9 | 34.4 | 1 |
| soak-batch | 4 | 0 | 10.40 | 29.6 | 15.6/20.3 | 24.9/24.9 | 2 |

Without `--batch` the server serialises: four requests finish in 11.8 s, each stream at full speed but later ones queued
(time to first token 1.5-8.9 s). With `--batch 4` the same four take 10.4 s (aggregate 29.6 vs 26.2 tok/s, +13 %) and each
stream runs at 16-25 tok/s, +7.5 GiB peak GTT (74.4 vs 66.9). Two requests: 7.2 s batched vs 6.2 s serial. Batching buys
little throughput and costs memory.

**Image / text behind encode** (1,024-token screenshot, 185 KB PNG, `--vision-max-tokens 1024`, peak GTT 66.9 GiB):
encode window 4.39 s cold (69 CPU-seconds), the same image again 1.7 s to first token (encoder cache hit); a text request
already decoding finished before the image reached the encoder (the server runs the encode after it), and a text request sent
3 s after an image waited 2.0 s for first token and then decoded at 44.8-47.3 tok/s, level with the 44.4-46.1 of text alone.
#279 measured a 19.7 s encode of a similar image on v0.1.40.1; this build's 4.4 s was not diagnosed.

**60-minute soak** (`SOAK_MINUTES=60`, thinking on, canary every 5 minutes, 30 s sampler; 266 requests: 81 replay turns, 104
burst requests (52 pairs), 27 each of tool call, reasoning and 32K-context prompts; 0 errors, engine pid unchanged, 0 restarts, GTT
66.9 GiB throughout, MemAvailable 45.6-47.4 GiB):

| minute | requests | decode tok/s median |
|---|---:|---:|
| 0 | 34 | 52.5 |
| 10 | 25 | 55.0 |
| 20 | 33 | 55.0 |
| 30 | 29 | 55.8 |
| 40 | 28 | 55.9 |
| 50 | 34 | 54.1 |
| 60 | 1 | 45.5 |

| kind | n | errors | ttft median s | decode tok/s median |
|---|---:|---:|---:|---:|
| burst_think | 104 | 0 | 8.39 | 59.4 |
| ctx32k | 27 | 0 | 28.47 | 43.1 |
| reason | 27 | 0 | 0.74 | 58.8 |
| replay_think | 81 | 0 | 5.15 | 52.6 |
| toolcall_think | 27 | 0 | 1.49 | 64.8 |

| t s | canary decode tok/s | canary prefill tok/s | errors |
|---|---:|---:|---:|
| 9.3 | 39.2 | 953 | 0 |
| 351.6 | 40.0 | 1065 | 0 |
| 670.3 | 38.6 | 1039 | 0 |
| 987.6 | 40.0 | 1034 | 0 |
| 1329.9 | 40.0 | 1027 | 0 |
| 1644.9 | 40.0 | 1028 | 0 |
| 1961.5 | 40.0 | 1028 | 0 |
| 2274.1 | 39.9 | 1027 | 0 |
| 2590.9 | 40.0 | 1028 | 0 |
| 2917.2 | 40.0 | 1021 | 0 |
| 3258.5 | 39.9 | 1025 | 0 |
| 3568.7 | 40.0 | 1026 | 0 |
| 3618.6 | 39.9 | 1026 | 0 |

### 2. Long context, one session (Strata int8 KV vs GSQHalo f16 KV)

One agent conversation (the replay's system prompt and tools, then tool turns of unseen text) grown stage by stage to the end
of the context. Per stage: the prefill rate of the tokens added (`fill`), an agent turn of 1,500 new tokens on the cached
prefix (time to first token), and a 256-token essay (decode rate, MTP/draft acceptance). **The server accepts a 262144
context** (Strata: one slot of 262144, the session reached 257K tokens; GSQHalo likewise). The decode column swings with the
text the model writes (acceptance 0.45-0.6 on most stages, 0.87-1.0 on a few where the essay quoted the file), so read the
typical value, not single stages: Strata about 36-42 tok/s, GSQHalo about 26-34, at every depth. `nomtp-depth128` is Strata
without the MTP draft layer (suffix lookup stays on, hence the nonzero acceptance), the one-stream control for section 3.

| row | depth (prompt tokens) | prefill tok/s | agent-turn ttft s | decode tok/s | MTP acceptance | turn cached tokens | GTT GiB |
|---|---:|---:|---:|---:|---:|---:|---:|
| depth192 | 8474 | 735 | 2.2 | 69.2 | 0.82 | 8467 | 67.8 |
| depth192 | 29623 | 1069 | 2.9 | 41.8 | 0.51 | 29631 | 67.8 |
| depth192 | 68140 | 1081 | 2.7 | 38.7 | 0.46 | 68149 | 67.8 |
| depth192 | 105140 | 1057 | 2.6 | 39.5 | 0.45 | 105150 | 67.8 |
| depth192 | 130461 | 992 | 3.1 | 39.5 | 0.49 | 130471 | 67.8 |
| depth192 | 163490 | 940 | 3.0 | 41.6 | 0.53 | 163500 | 67.8 |
| depth192 | 190096 | 926 | 2.7 | 38.0 | 0.50 | 190106 | 67.8 |
| depth256 | 8479 | 738 | 2.0 | 54.2 | 0.65 | 8472 | 68.8 |
| depth256 | 29594 | 1040 | 2.9 | 40.6 | 0.49 | 29603 | 68.8 |
| depth256 | 68102 | 1076 | 2.8 | 37.5 | 0.44 | 68111 | 68.8 |
| depth256 | 105117 | 1055 | 2.5 | 36.2 | 0.45 | 105127 | 68.8 |
| depth256 | 130456 | 989 | 3.3 | 36.1 | 0.45 | 130466 | 68.8 |
| depth256 | 163491 | 988 | 3.0 | 65.8 | 0.88 | 163501 | 68.8 |
| depth256 | 194789 | 932 | 3.2 | 39.1 | 0.57 | 194799 | 68.8 |
| depth256 | 227696 | 909 | 3.4 | 36.7 | 0.48 | 227706 | 68.8 |
| depth256 | 256860 | 846 | 3.2 | 68.1 | 0.87 | 256870 | 68.8 |
| nomtp-depth128 | 8479 | 760 | 2.0 | 48.2 | 0.94 | 8472 | 65.7 |
| nomtp-depth128 | 29593 | 1078 | 2.7 | 30.9 | 0.32 | 29600 | 65.7 |
| nomtp-depth128 | 68100 | 1091 | 2.6 | 29.1 | 0.12 | 68107 | 65.7 |
| nomtp-depth128 | 105121 | 1066 | 2.6 | 30.2 | 0.29 | 105128 | 65.7 |
| nomtp-depth128 | 124988 | 946 | 2.8 | 29.7 | 0.27 | 124995 | 65.7 |
| gsq-depth192 | 8481 | 591 | 2.5 | 30.4 | 0.50 | 8477 | 75.2 |
| gsq-depth192 | 29536 | 738 | 3.0 | 25.9 | 0.41 | 29532 | 75.2 |
| gsq-depth192 | 68102 | 745 | 2.8 | 32.3 | 0.60 | 68141 | 75.2 |
| gsq-depth192 | 105118 | 726 | 2.6 | 29.6 | 0.54 | 105158 | 75.2 |
| gsq-depth192 | 130447 | 715 | 3.1 | 30.6 | 0.55 | 130487 | 75.2 |
| gsq-depth192 | 163499 | 718 | 2.9 | 27.6 | 0.47 | 163539 | 75.2 |
| gsq-depth192 | 190093 | 704 | 2.6 | 31.3 | 0.60 | 190133 | 75.4 |
| gsq-depth256 | 8482 | 612 | 2.5 | 50.8 | 0.97 | 8478 | 77.1 |
| gsq-depth256 | 29534 | 734 | 2.9 | 28.6 | 0.45 | 29530 | 77.1 |
| gsq-depth256 | 68099 | 730 | 2.9 | 27.8 | 0.51 | 68138 | 77.1 |
| gsq-depth256 | 105120 | 719 | 2.6 | 34.2 | 0.65 | 105160 | 77.1 |
| gsq-depth256 | 130446 | 709 | 3.1 | 32.0 | 0.61 | 130486 | 77.1 |
| gsq-depth256 | 163500 | 713 | 2.9 | 43.6 | 1.00 | 163540 | 77.1 |
| gsq-depth256 | 194786 | 702 | 3.1 | 29.7 | 0.55 | 194826 | 77.3 |
| gsq-depth256 | 227689 | 695 | 3.2 | 27.3 | 0.49 | 227729 | 77.7 |
| gsq-depth256 | 256867 | 676 | 2.8 | 42.4 | 0.91 | 256907 | 78.5 |

Strata prefill is about 1,050 tok/s at 30-100K falling to 850 at 257K (GSQHalo 735 to 676); an agent turn on the cached prefix
takes about 3 s to first token on both. Peak GTT: Strata 67.8 / 68.8 GiB at 192K / 256K, GSQHalo 75.4 / 78.5.

### 3. Two sessions

Two conversations filled to `limit - 24,000` tokens each (about 107K at 131072, about 238K at 262144), one after the other,
then: the identical request again for B (just filled) and A (filled before B); one agent turn each in turn (A, B, A);
three rounds of simultaneous turns; a third 26K-token session; then A and B again. Cells are cached/prompt tokens (time to
first token).

| row | repeat B (just filled) | repeat A (B filled after) | A turn | B turn | A after 3rd session | B after 3rd session |
|---|---:|---:|---:|---:|---:|---:|
| two128 | 106524/106548 (0.5 s) | 6362/110048 (96.1 s) | 110041/111397 (2.6 s) | 6362/108089 (95.5 s) | 115851/119092 (5.1 s) | 111284/114275 (4.7 s) |
| two128-nobatch | 106494/106518 (0.7 s) | 6362/110027 (89.2 s) | 110020/111368 (2.6 s) | 6362/108056 (87.9 s) | 6362/119060 (100.3 s) | 6362/114297 (96.1 s) |
| two128-mtp | 106451/106458 (0.5 s) | 6362/109990 (96.6 s) | 109983/111326 (2.5 s) | 6362/107987 (96.0 s) | 117571/119265 (3.4 s) | 112678/114193 (3.1 s) |
| two128-park | 106457/106481 (1.6 s) | 109974/109998 (1.1 s) | 109991/111334 (2.8 s) | 106474/108021 (3.1 s) | 117590/119263 (2.9 s) | 112713/114221 (2.9 s) |
| two256-park | 238527/238551 (1.2 s) | 6362/241116 (245.0 s) | 241109/243115 (4.3 s) | 6362/240348 (249.1 s) | 249659/250994 (4.2 s) | 245713/247415 (5.1 s) |
| gsq-two128 | 106542/106556 (0.4 s) | 110048/110062 (1.0 s) | 110058/111416 (2.9 s) | 106552/108108 (4.1 s) | 6389/119107 (161.2 s) | 112544/114056 (4.1 s) |

- **Strata evicts.** After B's prefill, A's next request found only the shared 6K system prompt cached and re-prefilled in 96 s
  (89 s without `--batch`). Turn-by-turn alternation re-prefills every time. With both sessions already decoding in `--batch`
  slots they stayed cached through a third session; without `--batch` the third session evicted both. `--batch-mtp` makes no
  difference to affinity.
- **`--conversation-cache-mib 8192` fixes it at 110K tokens**: A's prefix survived B (1.1 s), alternating turns took 2.8-3.1 s,
  at the price of about +5.5 GiB of anonymous host memory (2.7 to 8.1 GiB). **At 238K it did not**: A re-prefilled 241K
  tokens in 245 s, anonymous memory 7.1 GiB. A larger budget was not tested, so whether 8192 MiB is simply too small for two
  238K sessions is unknown.
- **GSQHalo holds both by default** (`--slot-prompt-similarity` 0.10, `--cache-ram` 8192 MiB, `--ctx-checkpoints` 32 all exist
  in this build and were left at default): repeats hit in 0.4-1.0 s, alternating turns 2.9-4.1 s. A *third* session took the
  least recently used slot and A re-prefilled in 161 s. No tuned llama row was run because the defaults already kept both.

Decode with both sessions generating at once (400-token replies). Only the second round, with both caches warm and both first
tokens within 7 s, is clean: the first round carries a re-prefill and the staggered round a 3 s offset and a 64-token reply.
Combined tok/s is tokens over the span from the first first-token to the last token.

| row | round | stream A: decode tok/s | stream B: decode tok/s | combined tok/s |
|---|---:|---:|---:|---:|
| two128 | concurrent | 2.4 (ttft 3.3 s) | 26.7 (ttft 103.8 s) | 0.8 |
| two128 | concurrent | 20.0 (ttft 6.7 s) | 7.5 (ttft 3.3 s) | 15.1 |
| two128 | staggered | 50.3 (ttft 2.9 s) | 83.3 (ttft 3.1 s) | 75.3 |
| two128-nobatch | concurrent | 77.0 (ttft 191.3 s) | 46.0 (ttft 92.4 s) | 1.8 |
| two128-nobatch | concurrent | 75.5 (ttft 191.1 s) | 53.7 (ttft 93.4 s) | 0.8 |
| two128-nobatch | staggered | 78.9 (ttft 2.9 s) | 57.7 (ttft 94.7 s) | 0.2 |
| two128-mtp | concurrent | 29.2 (ttft 206.3 s) | 2.8 (ttft 99.6 s) | 0.8 |
| two128-mtp | concurrent | 25.9 (ttft 6.9 s) | 8.3 (ttft 3.5 s) | 16.6 |
| two128-mtp | staggered | 1.8 (ttft 3.1 s) | 29.1 (ttft 109.4 s) | 0.7 |
| two128-park | concurrent | 8.2 (ttft 3.2 s) | 22.9 (ttft 6.3 s) | 16.4 |
| two128-park | concurrent | 19.3 (ttft 5.8 s) | 9.1 (ttft 2.9 s) | 11.8 |
| two128-park | staggered | 8.7 (ttft 3.5 s) | 19.1 (ttft 3.7 s) | 11.4 |
| two256-park | concurrent | 18.7 (ttft 252.2 s) | 6.5 (ttft 248.1 s) | 13.1 |
| two256-park | concurrent | 9.4 (ttft 8.9 s) | 6.3 (ttft 5.1 s) | 8.2 |
| two256-park | staggered | 5.7 (ttft 3.8 s) | 8.1 (ttft 6.6 s) | 7.4 |
| gsq-two128 | concurrent | 2.7 (ttft 15.3 s) | 6.8 (ttft 15.3 s) | 9.1 |
| gsq-two128 | concurrent | 12.6 (ttft 7.5 s) | 27.0 (ttft 7.7 s) | 29.7 |
| gsq-two128 | staggered | 8.7 (ttft 4.6 s) | 12.8 (ttft 4.8 s) | 11.4 |

A single stream on the same engine at the same depth: Strata 38.8-41.0 (about 40), GSQHalo 28.2-37.0 (about 31).

| clean concurrent round | per stream tok/s | combined tok/s | peak GTT | combined vs one stream |
| --- | --- | ---: | ---: | ---: |
| Strata `--batch 2`, 2x107K | 20.0 / 7.5 | 15.1 | 70.6 GiB | 38 % |
| Strata `--batch 2 --batch-mtp`, 2x107K | 25.9 / 8.3 | 16.6 | 71.0 GiB | 42 % |
| Strata `--batch 2` + park, 2x107K | 19.3 / 9.1 | 11.9 | 70.6 GiB | 30 % |
| Strata `--batch 2` + park, 2x238K | 9.4 / 6.3 | 8.3 | 76.1 GiB | 21 % |
| GSQHalo `-np 2`, 2x107K | 12.6 / 27.0 | 29.7 | 88.3 GiB | 96 % |

2x238K was accepted: both slots came up at 262144, no error, the memory gate did not trip (peak GTT 76.1 GiB of 104,
MemAvailable about 33 GiB, 1.7 GiB of swap in use).

**Why the collapse.** MTP: Strata's help says plain `--batch` slots do not verify MTP drafts (that is `--batch-mtp`), and its
server reports no draft counts for batch-slot requests, so acceptance is blank in the rounds and I could not measure it. It is
not the main cause: `--batch-mtp` moved the combined rate only from 15.1 to 16.6. The one-stream control without the MTP draft
layer decodes 29-31 tok/s at 30-125K, so even a no-MTP stream is twice the combined rate of two batched ones. Bandwidth:
llama.cpp with two slots holds its combined rate level with one stream (29.7 vs about 31), which fits a decode bound by MoE
expert reads (two streams read about the union of their experts), so batching should not be expected to *add* throughput here;
Strata's batch path then loses most of that. This reads as a Strata batch-path cost; I did not profile it.

## Recommendation

**Should halo's resident Flash-Next move to Strata?** For one agent at a time, yes: measured faster at every depth (prefill
1.3-1.4x, decode about +25-35 %), 7-10 GiB lighter, 256K accepted, a clean hour. Conditions: the lemond shim keeps sampling
defaults (done, #284); a fresh screenshot blocks the queue for about 4 s; Strata serialises concurrent requests unless `--batch`
is on, and with `--batch` loses most of its speed. If the lane must run two agents decoding at the same time, GSQHalo `-np 2`
is the only measured option that keeps combined throughput, and it costs the most GTT.

**Local agent lane: 1x256K or 2x128K (`--batch`)?**

| | 1x256K, Strata | 2x128K, Strata `--batch 2` (+ park) | 2x128K, GSQHalo `-np 2` |
| --- | --- | --- | --- |
| per-session decode | 36-40 tok/s | 7-20 tok/s while both decode; about 40 one at a time | 13-27 tok/s while both decode; 28-37 alone |
| combined decode | 36-40 | 15 (12 with park) | 30 |
| peak GTT (limit 104) | 68.8 GiB, **35 GiB headroom** | 70.6 GiB, 33 GiB | 88.3 GiB, **16 GiB** |
| second session arrives | waits behind the first (serialised) | evicts the first's cache unless parked; parked: 3 s | both kept; a third evicts one (161 s) |

Take **1x256K**: it gives the longest sessions (the observed 131K compaction point moves out of reach), the highest per-session
rate, and the most headroom for a second model or a build. If two agents must overlap, run them as separate turns on one Strata
server with `--conversation-cache-mib` so a returning session costs about 3 s, not 96 s; do not rely on `--batch`. GSQHalo
`-np 2` is the alternative if simultaneous decode matters more than the 16 GiB left for builds and a second model.

**Is 2x256K with cache tuning viable for two local agents?** No, on both counts. Memory fits (76.1 GiB peak, 27 GiB headroom,
host MemAvailable about 33 GiB), but the cache did not survive (245 s to re-prefill 241K tokens after the other session's turn)
and two simultaneous streams decode 9.4 + 6.3 tok/s, 8.3 combined, a fifth of one stream. A larger park budget might fix the
cache; nothing measured fixes the decode.

**Any correctness or stability problem from the soak?** None found: no errors in 266 requests, no restart, canary without drift, every tool-call turn ended `tool_calls`. Watch item: anonymous memory +1.3 GiB over the hour (cache warm-up or a slow
leak; one hour cannot tell). The loadavg of 17-30 during Strata rows is the engine's own threads, not a stall.

## Not measured

- A park budget above 8192 MiB, `--conversation-cache-slots`, or llama `-np 3` / `--cache-ram` changes.
- Thinking-on decode at 256K; the real pi agents' reasoning share; more than one soak hour; behaviour after days.
- MTP acceptance inside batch slots (the server does not report it); a Strata batch-path profile.
- Strata with f16 KV at 256K; `--batch` above 4 slots; anything on gfx1150.
- Whether the 4.4 s image encode (vs 19.7 s in #279) is the build, the image or the load.

## Reproduce

From the repo root with `W` (work dir), `CACHE` (the #249 corpus cache), `IQ4` (shard 1 of the UD-IQ4_XS file), the `STRATA_*`
variables of `run.sh` (`STRATA_PY STRATA_REPO STRATA_ENGINE STRATA_VISION_BIN STRATA_PACK STRATA_MTP_RT STRATA_MMPROJ
STRATA_EXPERT_CACHE`), `GSQ_BIN` and `SCREENSHOT_PNG` set:

```sh
D=bench-logs/qwen38-flash-next-strata-soak-2026-10-08
$D/rows.sh list
$D/rows.sh soak soak-batch bigimage depth192 depth256 nomtp-depth128 two128 two128-nobatch two128-mtp two128-park two256-park \
    gsq-depth192 gsq-depth256 gsq-two128 longsoak          # lemond is restored after the last
python3 $D/tables.py "$W/rows.jsonl"                       # the tables above
python3 $D/test_depth.py                                   # offline tests of depth.py
```

`depth.py` adds the `depth` and `twosession` groups to `probe.py` (for both engines); `probe.py` also records the server's `/slots`,
and `run.sh` takes `LLAMA_CTX` / `LLAMA_SLOTS`. The `soak`, `longsoak` and `bigimage` groups are #279's, run unchanged.
