# Strata soak, concurrency, 256K and two-session rows on halo (#282)

Every number is from **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT limit, kernel 7.2.9)**,
measured 2026-10-08, one benchmark at a time with lemond's resident model unloaded for the row and restored afterwards.
Nothing here transfers to gfx1150. Model: Qwen3.8-Flash-Next **UD-IQ4_XS** (unsloth), Strata fast configuration (#279).

## Verdict

1. **Move the resident model to Strata: yes.** On one session it is faster than the resident GSQHalo at every depth tried
   (prefill 1.3-1.4x, decode +27-31 % at 192K-256K), uses 7-10 GiB less GTT, accepts a 262144 context, and a 60-minute mixed
   soak had no errors, no engine restart and no drift. With two sessions at once it is about twice as fast as GSQHalo `-np 2`
   (21 + 18 against 9.5 + 9.8 tok/s at ~107K each) and 17.7 GiB lighter.
2. **Local agent lane: 2x128K with `--batch 2` for two overlapping agents, 1x256K only for one agent that needs more than
   ~128K.** Two sessions decoding at once each get about half of a single stream (21 + 18 tok/s vs ~40), so combined throughput
   stays at ~89 % of one stream on Strata and ~86 % on GSQHalo: batching shares the engine, it does not add to it. Peak GTT
   is 70.6 GiB for 2x128K (33 GiB headroom) and 68.8 GiB for 1x256K (35 GiB).
3. **The catch is cache affinity, not speed.** Strata holds one resident conversation: when two sessions take turns, every
   switch re-prefills the other session (96 s at 110K tokens, 245 s at 238K). `--conversation-cache-mib 8192` fixed it at 110K
   (seen in a row run on the earlier version of the harness, below) and did not at 238K. llama-server keeps both sessions by default.
4. **60-minute soak: no correctness or stability problem.** 266 requests, 0 errors, 0 engine restarts, the canary's
   temperature-0 decode at 38.6-40.0 tok/s (11 of 13 readings at 39.9-40.0) and prefill at 1,021-1,065 tok/s after the first
   reading (953), GTT constant. One thing to watch: the engine's anonymous memory grew 1.3 GiB over the hour (1.26 to 2.55 GiB,
   max 2.86).

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

All rows ran; none was skipped for memory and none needed a download. `peak GTT` is the maximum over the row (0.5 s sampling),
`RSS HWM` the engine's VmHWM (mostly file-backed page cache of the experts), `anon RSS` its anonymous memory at the end.

| row | result | peak GTT GiB | RSS HWM GiB | anon RSS end GiB | load start | load max | ctx | errors | load s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| soak | ran | 66.9 | 30.7 | 1.6 | 0.77 | 24.1 | 131072 | 0 | 42.5 |
| soak-batch | ran | 74.4 | 25.4 | 2.0 | 1.72 | 20.1 | 131072 | 0 | 48.0 |
| bigimage | ran | 66.9 | 36.2 | 1.4 | 1.97 | 6.2 | 131072 | 0 | 40.1 |
| depth192 | ran | 67.8 | 37.3 | 2.3 | 1.91 | 26.9 | 196608 | 0 | 42.1 |
| depth256 | ran | 68.8 | 41.6 | 2.4 | 1.69 | 29.4 | 262144 | 0 | 42.1 |
| two128 | ran | 70.6 | 44.9 | 2.6 | 0.31 | 34.6 | 131072 | 0 | 46.1 |
| two128-mtp | ran | 71.0 | 44.6 | 2.7 | 1.65 | 34.2 | 131072 | 0 | 38.0 |
| gsq-depth192 | ran | 75.4 | 7.5 | 7.4 | 1.81 | 4.5 | 196608 | 0 | 26.0 |
| gsq-depth256 | ran | 78.5 | 8.3 | 8.0 | 1.96 | 7.3 | 262144 | 0 | 29.0 |
| gsq-two128 | ran | 88.3 | 16.4 | 14.4 | 1.82 | 11.9 | 262144 | 0 | 44.3 |
| longsoak | ran | 66.9 | 49.5 | 2.2 | 1.81 | 29.8 | 131072 | 0 | 40.1 |
| two128-park | ran | 70.6 | 44.4 | 8.1 | 0.49 | 28.4 | 131072 | 0 | 32.0 |
| two128-nobatch | ran | 66.9 | 49.0 | 2.6 | 1.73 | 37.1 | 131072 | 0 | 28.0 |
| nomtp-depth128 | ran | 65.7 | 49.7 | 2.2 | 1.65 | 24.5 | 131072 | 0 | 26.0 |
| two256-park | ran | 76.1 | 39.8 | 9.7 | 1.88 | 32.9 | 262144 | 0 | 58.1 |

Rows are in `rows.sh`. `two128-nobatch` ran by accident when an edit to `rows.sh` made a running shell repeat its loop with no
flags; it is kept as a control (one slot, two sessions in turn). `ctx` for the GSQ two-session row is the total across its
two slots.

**Re-runs.** A review of this harness found that the first two-session runs asked for a long reply inside a tool result, so the
model mostly answered with a 40-token tool call: their "concurrent decode" rates were not sustained decode, and an earlier draft
of this README drew conclusions from them (a "collapse" to 15 tok/s combined) that were wrong. The group now asks for the essay
as a separate user message, reports a decode rate only for a request that ran to its token limit, and times concurrent
requests on one clock. `two128`, `gsq-two128` and `two256-park` were re-run with it. `two128-mtp`, `two128-park` and
`two128-nobatch` were **not re-run (owner cut)**: their decode numbers are dropped, and only their cache cells (cached tokens
and time to first token, which the short replies do not affect) are kept and marked. Depth rows keep every stage whose essay ran
to 256 tokens; the stages that ended as tool calls show `-`.

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
stream runs at 16-25 tok/s, +7.5 GiB peak GTT (74.4 vs 66.9). Two requests: 7.2 s batched vs 6.2 s serial. These requests
are 128-token answers and tool calls, so the rates are short-run; the sustained two-session rates are in section 3.

**Image / text behind encode** (1,024-token screenshot, 185 KB PNG, `--vision-max-tokens 1024`, peak GTT 66.9 GiB):
encode window 4.39 s cold (69 CPU-seconds), the same image again 1.7 s to first token (encoder cache hit); a text request
already decoding finished before the image reached the encoder (the server runs the encode after it), and a text request sent
3 s after an image waited 2.0 s for first token and then decoded at 44.8-47.3 tok/s, level with the 44.4-46.1 of text alone.
#279 measured a 19.7 s encode of a similar image on v0.1.40.1; this build's 4.4 s was not diagnosed.

**60-minute soak** (`SOAK_MINUTES=60`, thinking on, canary every 5 minutes, 30 s sampler; 266 requests: 81 replay turns, 104
burst requests (52 pairs), 27 each of tool call, reasoning and 32K-context prompts; 0 errors, engine pid unchanged, 0 restarts,
GTT 66.9 GiB throughout, MemAvailable 45.6-47.4 GiB):

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
of the context. Per stage: the prefill rate of the tokens added, an agent turn of 1,500 new tokens on the cached prefix (time to
first token), and a 256-token essay (decode rate, draft acceptance). **The server accepts a 262144 context** (Strata: one slot
of 262144, the session reached 257K tokens; GSQHalo likewise). `-` in the decode column is a stage whose essay ended as a
tool call, so it says nothing about decode. `nomtp-depth128` is Strata without the MTP draft layer (suffix lookup stays on,
hence the nonzero acceptance).

| row | depth (prompt tokens) | prefill tok/s | agent-turn ttft s | decode tok/s (essays run to 256 tokens) | draft acceptance | turn cached tokens | GTT GiB |
|---|---:|---:|---:|---:|---:|---:|---:|
| depth192 | 8474 | 735 | 2.2 | - | - | 8467 | 67.8 |
| depth192 | 29623 | 1069 | 2.9 | 41.8 | 0.51 | 29631 | 67.8 |
| depth192 | 68140 | 1081 | 2.7 | 38.7 | 0.46 | 68149 | 67.8 |
| depth192 | 105140 | 1057 | 2.6 | 39.5 | 0.45 | 105150 | 67.8 |
| depth192 | 130461 | 992 | 3.1 | 39.5 | 0.49 | 130471 | 67.8 |
| depth192 | 163490 | 940 | 3.0 | 41.6 | 0.53 | 163500 | 67.8 |
| depth192 | 190096 | 926 | 2.7 | 38.0 | 0.50 | 190106 | 67.8 |
| depth256 | 8479 | 738 | 2.0 | - | - | 8472 | 68.8 |
| depth256 | 29594 | 1040 | 2.9 | 40.6 | 0.49 | 29603 | 68.8 |
| depth256 | 68102 | 1076 | 2.8 | 37.5 | 0.44 | 68111 | 68.8 |
| depth256 | 105117 | 1055 | 2.5 | 36.2 | 0.45 | 105127 | 68.8 |
| depth256 | 130456 | 989 | 3.3 | 36.1 | 0.45 | 130466 | 68.8 |
| depth256 | 163491 | 988 | 3.0 | - | - | 163501 | 68.8 |
| depth256 | 194789 | 932 | 3.2 | 39.1 | 0.57 | 194799 | 68.8 |
| depth256 | 227696 | 909 | 3.4 | 36.7 | 0.48 | 227706 | 68.8 |
| depth256 | 256860 | 846 | 3.2 | - | - | 256870 | 68.8 |
| nomtp-depth128 | 8479 | 760 | 2.0 | - | - | 8472 | 65.7 |
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
| gsq-depth256 | 8482 | 612 | 2.5 | - | - | 8478 | 77.1 |
| gsq-depth256 | 29534 | 734 | 2.9 | 28.6 | 0.45 | 29530 | 77.1 |
| gsq-depth256 | 68099 | 730 | 2.9 | 27.8 | 0.51 | 68138 | 77.1 |
| gsq-depth256 | 105120 | 719 | 2.6 | 34.2 | 0.65 | 105160 | 77.1 |
| gsq-depth256 | 130446 | 709 | 3.1 | 32.0 | 0.61 | 130486 | 77.1 |
| gsq-depth256 | 163500 | 713 | 2.9 | - | - | 163540 | 77.1 |
| gsq-depth256 | 194786 | 702 | 3.1 | 29.7 | 0.55 | 194826 | 77.3 |
| gsq-depth256 | 227689 | 695 | 3.2 | 27.3 | 0.49 | 227729 | 77.7 |
| gsq-depth256 | 256867 | 676 | 2.8 | - | - | 256907 | 78.5 |

Median decode from 30K up over the stages that ran 256 tokens: Strata 39.5 (192K row) and 37.1 (256K row) tok/s, GSQHalo 30.1
and 29.1, Strata without the MTP layer 30.0. Strata prefill is about 1,050 tok/s at 30-100K falling to 850 at 257K (GSQHalo 735
to 676); an agent turn on the cached prefix takes about 3 s to first token on both. Peak GTT: Strata 67.8 / 68.8 GiB at 192K /
256K, GSQHalo 75.4 / 78.5.

### 3. Two sessions

Two conversations filled to `limit - 24,000` tokens each (about 107K at 131072, about 238K at 262144), one after the other,
then: the last fill request again for B (just filled) and A (filled before B); one agent turn each in turn (A, B, A); three rounds
of simultaneous turns; a third 26K-token session; then A and B again. Cells are cached/prompt tokens (time to first token).

| row | harness | repeat B (just filled) | repeat A (B filled after) | A turn | B turn | A after 3rd session | B after 3rd session |
|---|---:|---:|---:|---:|---:|---:|---:|
| two128 | re-run | 106496/106520 (0.7 s) | 6362/110023 (95.8 s) | 110016/111376 (2.6 s) | 6362/108070 (94.8 s) | 118815/120626 (3.4 s) | 113623/115143 (3.1 s) |
| two128-nobatch | earlier harness (not re-run, owner cut) | 106494/106518 (0.7 s) | 6362/110027 (89.2 s) | 110020/111368 (2.6 s) | 6362/108056 (87.9 s) | 6362/119060 (100.3 s) | 6362/114297 (96.1 s) |
| two128-mtp | earlier harness (not re-run, owner cut) | 106451/106458 (0.5 s) | 6362/109990 (96.6 s) | 109983/111326 (2.5 s) | 6362/107987 (96.0 s) | 117571/119265 (3.4 s) | 112678/114193 (3.1 s) |
| two128-park | earlier harness (not re-run, owner cut) | 106457/106481 (1.6 s) | 109974/109998 (1.1 s) | 109991/111334 (2.8 s) | 106474/108021 (3.1 s) | 117590/119263 (2.9 s) | 112713/114221 (2.9 s) |
| two256-park | re-run | 238528/238552 (1.2 s) | 6362/241113 (245.5 s) | 241106/243124 (4.3 s) | 6362/240359 (249.2 s) | 251149/252467 (3.2 s) | 246546/248247 (4.0 s) |
| gsq-two128 | re-run | 106488/106502 (0.5 s) | 109997/110011 (1.0 s) | 110007/111370 (3.0 s) | 106498/108062 (4.4 s) | 6389/120723 (163.3 s) | 113625/115134 (4.2 s) |

- **Strata evicts.** After B's prefill, A's next request found only the shared 6K system prompt cached and re-prefilled in 96 s
  at 107K and 245 s at 238K (89 s without `--batch`). Turn-by-turn alternation re-prefills every time. Once both sessions have
  decoded together in `--batch` slots they stay cached through a third session; without `--batch` the third session evicted both.
- **`--conversation-cache-mib 8192` fixes it at 110K tokens** (row `two128-park`, earlier harness): A's prefix survived B (1.1 s),
  alternating turns took 2.8-3.1 s, at the price of about +5.5 GiB of anonymous host memory (2.7 to 8.1 GiB). **At 238K it did
  not** (re-run): A re-prefilled 241K tokens in 245 s, anonymous memory 9.7 GiB. A larger budget was not tested, so whether
  8192 MiB is simply too small for two 238K sessions is unknown.
- **GSQHalo holds both by default** (`--slot-prompt-similarity` 0.10, `--cache-ram` 8192 MiB, `--ctx-checkpoints` 32 all exist in
  this build and were left at default): repeats hit in 0.5-1.0 s, alternating turns 3.0-4.4 s. A *third* session took the least
  recently used slot and A re-prefilled in 163 s. No tuned llama row was run because the defaults already kept both.

Decode with both sessions generating at once (400-token replies). Only the second round is clean: both caches are warm and
both first tokens arrive within 20 s. The first round carries the re-prefill the eviction forces (ttft in the hundreds of
seconds). In the staggered round A's essay may end before 400 tokens (`short reply`, no rate) and B asks for one sentence.
Combined tok/s is tokens over the span from the first first-token to the last token, on one clock.

| row | round | stream A: decode tok/s | stream B: decode tok/s | combined tok/s |
|---|---:|---:|---:|---:|
| two128 | concurrent | 37.0 (ttft 220.0 s, 400 tok, length) | 6.5 (ttft 98.7 s, 400 tok, length) | 6.0 |
| two128 | concurrent | 21.3 (ttft 7.1 s, 400 tok, length) | 17.8 (ttft 3.3 s, 400 tok, length) | 35.5 |
| two128 | staggered | short reply (ttft 3.3 s, 249 tok, stop) | 19.7 (ttft 3.8 s, 64 tok, length) | - |
| two128-nobatch | not re-run (owner cut) | - | - | - |
| two128-mtp | not re-run (owner cut) | - | - | - |
| two128-park | not re-run (owner cut) | - | - | - |
| two256-park | concurrent | 18.9 (ttft 253.6 s, 400 tok, length) | 15.8 (ttft 249.3 s, 400 tok, length) | 31.5 |
| two256-park | concurrent | 18.5 (ttft 9.9 s, 400 tok, length) | 15.2 (ttft 5.2 s, 400 tok, length) | 30.5 |
| two256-park | staggered | 21.6 (ttft 5.3 s, 400 tok, length) | short reply (ttft 7.1 s, 11 tok, stop) | - |
| gsq-two128 | concurrent | 8.7 (ttft 16.3 s, 400 tok, length) | 8.6 (ttft 16.3 s, 400 tok, length) | 17.2 |
| gsq-two128 | concurrent | 9.5 (ttft 18.7 s, 400 tok, length) | 9.8 (ttft 18.7 s, 400 tok, length) | 19.0 |
| gsq-two128 | staggered | short reply (ttft 7.7 s, 353 tok, stop) | 10.3 (ttft 4.9 s, 64 tok, length) | - |

A single stream in the same row at the same depth: Strata `two128` 37.2-43.9 tok/s (about 40), Strata `two256-park` 33.6-38.4
(about 37), GSQHalo `gsq-two128` 20.7-23.6 (about 22).

| clean concurrent round | per stream tok/s | combined tok/s | peak GTT | combined vs one stream |
| --- | --- | ---: | ---: | ---: |
| Strata `--batch 2`, 2x107K | 21.3 / 17.8 | 35.5 | 70.6 GiB | 89 % |
| GSQHalo `-np 2`, 2x107K | 9.5 / 9.8 | 19.0 | 88.3 GiB | 86 % |
| Strata `--batch 2` + park, 2x238K | 18.5 / 15.2 | 30.5 | 76.1 GiB | 82 % |

2x238K was accepted: both slots came up at 262144, no error, the memory gate did not trip (peak GTT 76.1 GiB of 104; at the
end MemAvailable 28.8 GiB, anonymous RSS 9.7 GiB, 1.7 GiB of swap in use).

**Batching and MTP.** Strata's help says plain `--batch` slots do not verify MTP drafts (that is `--batch-mtp`), and the server
reports no draft counts for batch-slot requests, so acceptance is blank in the rounds. `--batch-mtp` was not re-run (owner cut),
so its effect is not reported. What the rows do show: two batched streams together (35.5) run at 89 % of one MTP stream (~40) and
1.2x the one-stream control without the MTP layer (30.0 in `nomtp-depth128`); llama.cpp's two slots hold 86 % of its one
stream. Both engines keep combined throughput level with one stream, which fits a decode bound by MoE expert reads: batching
shares that bandwidth between sessions instead of adding to it. I did not profile either engine.

## Recommendation

**Should halo's resident Flash-Next move to Strata?** Yes. Measured faster at every depth (prefill 1.3-1.4x, decode +27-31 %
at 192K-256K), 7-10 GiB lighter for one session and 17.7 GiB lighter for two, 256K accepted, a clean hour. Conditions: the lemond
shim keeps sampling defaults (done, #284); a fresh screenshot blocks the queue for about 4 s; without `--batch` Strata serialises
concurrent requests and keeps one resident conversation, so two agents need `--batch 2` and, for turn-taking, a conversation cache.

**Local agent lane: 1x256K or 2x128K (`--batch`)?**

| | 1x256K, Strata | 2x128K, Strata `--batch 2` | 2x128K, GSQHalo `-np 2` |
| --- | --- | --- | --- |
| decode per session | ~37-40 tok/s | 21 / 18 while both decode; ~40 when one is idle | 9.5 / 9.8 while both decode; ~22 alone |
| combined decode | ~37-40 | 35.5 | 19.0 |
| peak GTT (limit 104) | 68.8 GiB, **35 GiB headroom** | 70.6 GiB, 33 GiB | 88.3 GiB, **16 GiB** |
| second session arrives | waits behind the first; every switch re-prefills | evicts the first's cache unless parked (park fixed it at 110K) | both kept; a third evicts one (163 s) |

For the observed workload (a session of ~30K to ~110K tokens that compacts at 131K) take **2x128K with `--batch 2` and
`--conversation-cache-mib 8192`**: two agents each get ~20 tok/s while both decode and ~40 while the other waits, at the same memory as
one 256K session. Take **1x256K** only for a single agent whose context really passes ~128K (it decodes at ~37-40 with an agent
turn in about 3 s, and a second agent cannot share it without the 96-245 s switch cost). The parked-cache result at 110K comes
from a row run on the earlier harness and was not re-run: confirm it with one `two128-park` row before relying on it.

**Is 2x256K with cache tuning viable for two local agents?** For two agents that *decode at the same time*, yes on memory and
throughput: 76.1 GiB peak (28 GiB headroom, host MemAvailable 28.8 GiB at the end), 18.5 + 15.2 tok/s, 30.5 combined. For two
agents that *take turns*, not yet: the 8192 MiB cache did not hold a 238K session (245 s to re-prefill after the other's turn).
A larger budget was not tried; each parked 238K session costs host RAM, and 28.8 GiB is what was left.

**Any correctness or stability problem from the soak?** None found: no errors in 266 requests, no restart, canary without drift,
every tool-call turn ended `tool_calls`. Watch item: anonymous memory +1.3 GiB over the hour (cache warm-up or a slow leak; one
hour cannot tell). The loadavg of 17-30 during Strata rows is the engine's own threads, not a stall.

## Not measured

- A park budget above 8192 MiB, `--conversation-cache-slots`, or llama `-np 3` / `--cache-ram` changes.
- `--batch-mtp`, the parked cache at 110K, and the no-`--batch` control on the fixed harness (not re-run, owner cut).
- Thinking-on decode at 256K; the real pi agents' reasoning share; more than one soak hour; behaviour after days.
- MTP acceptance inside batch slots (the server does not report it); a profile of either engine's batch path.
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
python3 $D/test_depth.py                                   # offline tests of depth.py and tables.py
```

`depth.py` adds the `depth` and `twosession` groups to `probe.py` (for both engines); `probe.py` also records the server's `/slots`,
and `run.sh` takes `LLAMA_CTX` / `LLAMA_SLOTS`. The `soak`, `longsoak` and `bigimage` groups are #279's, run unchanged. The depth
rows ran with an earlier wording of the essay request that did not say "do not call any tool", which is why some stages ended as
tool calls and read `-`; the current wording is in `depth.py`.
