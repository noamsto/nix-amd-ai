# Flash-Next `--lazy-mode`, `--spec-draft-p-min` and `-ub` — halo, gfx1151 (#246)

Every number is **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM), 2026-10-05**, stock
llama.cpp **b11382** (commit `11fe021`), Vulkan backend, and none of it transfers to gfx1150. The three
settings come from the r/StrixHalo post "I tested Qwen3.8-Flash-Next on my Bosgame M5" by
u/Southern_Capital_885 (lazy mode, p-min 0.60 and `-ub` hints); this run checks them on halo.

**Load caveat, read first.** Other sessions on this host kept 1-min loadavg at 6–20 for the first part of
the run, so rows 1 (lazy on), 2 and the first row 3 attempt carry `load_flag: true` (the gate waited its time
limit, then ran). Row 3 was redone later on a quiet host; its loadavg and flag are per row below. Run-to-run noise on decode is ±2–3 t/s
even in the quiet row. The host was also under memory pressure from other processes (swap in use,
MemAvailable 9–40 GiB between rows), which hurt the baseline row — see below.

## Verdict

| Setting | Add to halo's lemond preset? | Evidence |
| --- | --- | --- |
| `--lazy-mode on` | **Yes.** | llama-server host RSS after load **27.1 GiB → 0.31 GiB**. GTT is identical (66.5 GiB delta), decode and prefill are within noise (see table; the 512-depth cold decode was 30.4 → 29.4 t/s, load 42 → 26 s). MemAvailable after load 19.2 → 40.1 GiB, which is what a second resident model needs. The baseline's resident table is anonymous memory, so under host memory pressure it was pushed to swap (its RSS had fallen to 1.6 GiB by the end of the row and its 32K decode read 30.1 vs 38.4 t/s with lazy on) — lazy mode avoids that exposure rather than only saving RAM. Caveat: that 32K gap is confounded by swap and load, not a clean lazy-mode speedup. |
| `--spec-draft-p-min 0.6` | **No change recommended.** Not shown to help. | Prose, 512 tokens, temperature 0.7, n-max 3, lazy on: p-min 0 → 32.4 ± 2.2 t/s, acceptance 0.59; p-min 0.6 → 33.1 ± 3.1 t/s, acceptance 0.65. The 0.8 t/s gap is inside the spread (3 runs each, loadavg 10.9 and 13.6). Acceptance rises, throughput does not measurably. The earlier code/docs run found no clear p-min winner either. |
| `-ub` 2048 | **Yes, 2048 (not 4096).** | Prefill ~4K 394 → 465 t/s (+18%), 32K 331 → 385 t/s (+16%) at q8_0 KV; same direction at f16 KV (383 → 470, 304 → 367, the f16 default row ran at loadavg 7.5). Costs +4.3 GiB GTT (66.5 → 70.8) and −4.7 GiB MemAvailable after load. Decode is unchanged within noise (512: 30.4 vs 30.6 t/s). `-ub 4096`: smaller gain (+7% / +10%), +10.7 GiB GTT and −11.3 GiB MemAvailable — not worth it beside a second model. One run per config, so treat the percentages as ±5%. Open item: an earlier `-ub 2048` attempt died with `ErrorDeviceLost` (below); two clean reruns did not reproduce it. |

## Rows (host halo, build b11382 Vulkan, lemond's UD-IQ4_XS target + ggml-org MTP draft, n-max 3)

Run as a standalone `llama-server`: `-c 131072 -ctk q8_0 -ctv q8_0 -fa on --parallel 1 --jinja`, mmap on.
Decode is 128 tokens, temperature 0, 3 runs (mean ± stdev) on the code/docs corpus from
`../qwen38-flash-next-mtp-tuning-2026-10-04/grid.py` (no repeated 64-grams, built from the tree at
`96fe65e`). Prefill is `prompt_per_second`.

### 1. Lazy mode

| | baseline (no flag) | `--lazy-mode on` |
| --- | ---: | ---: |
| host, build | halo, b11382 | halo, b11382 |
| loadavg at start (`load_flag`) | 1.39 (false) | 6.01 (true) |
| load time | 42.0 s | 26.1 s |
| RSS after load | 27.13 GiB | 0.31 GiB |
| GTT delta after load | 66.5 GiB | 66.5 GiB |
| MemAvailable after load | 19.2 GiB | 40.1 GiB |
| RSS / MemAvailable after first decode | 27.36 GiB / 18.7 GiB | 0.58 GiB / 39.6 GiB |
| first decode after load, 512 depth | 30.4 t/s | 29.4 t/s |
| decode 512, then | 31.3 ± 2.3 t/s, acc 0.42 | 29.7 ± 2.4 t/s, acc 0.42 |
| prefill ~4K | 395 t/s | 377 t/s |
| prefill 32K | 268 t/s | 322 t/s |
| decode 32K | 30.1 ± 4.8 t/s, acc 0.83 | 38.4 ± 2.5 t/s, acc 0.83 |
| at row end: RSS (anon / file), MemAvailable | 1.57 GiB (1.57 / 0.01), 9.0 GiB | 2.12 GiB (0.86 / 1.26), 40.4 GiB |

**Cold vs warm.** "First decode after load" is the first completion, before any other request; the
"decode 512, then" runs are after it. With lazy on the file-backed part grows from 0.07 GiB to 1.26 GiB as
the embedding rows touched by decoding are paged in; the first decode was 1 t/s slower than the later ones
in both configs, which is inside the noise. I did not drop the page cache (needs root), so a truly
cold-from-disk first decode was not measured. Whether `auto` already resolves to lazy for this model is
unmeasured: the baseline kept 27 GiB resident, and the server log had no lazy-mode line to say.

### 2. p-min on prose (lazy on, halo, b11382)

Prompt: the first 289 tokens of Pride and Prejudice chapter 1 (public domain, `prose.txt`), continued for
512 tokens at temperature 0.7, seeds 1–3 (plus one warmup), raw `/completion`.

| `--spec-draft-p-min` | loadavg at start | decode t/s | acceptance |
| --- | ---: | ---: | ---: |
| 0 (default) | 10.86 (flagged) | 32.4 ± 2.2 | 0.586 |
| 0.6 | 13.56 (flagged) | 33.1 ± 3.1 | 0.648 |

### 3. `-ub` (halo, b11382, lazy on)

Redone on a quiet host after a first attempt was disturbed (below). One run per config, `-b` = `-ub` for 2048
and 4096. "GTT" is the delta after load; "MemAvail" is after load. 3b repeats the sweep with f16 KV
(`-ctk f16 -ctv f16`).

| KV | `-ub` | loadavg (flag) | load | GTT | MemAvail | prefill 4K | prefill 32K | decode 512 | decode 32K (acc) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| q8_0 | default (512) | 1.00 (false) | 26 s | 66.5 GiB | 45.7 GiB | 394 | 331 | 30.6 ± 2.3 | 40.8 ± 0.4 (0.83) |
| q8_0 | 2048 | 1.01 (false) | 40 s | 70.8 GiB | 41.0 GiB | 465 | 385 | 30.4 ± 2.3 | 38.3 ± 2.1 (0.81) |
| q8_0 | 4096 | 1.98 (false) | 34 s | 77.2 GiB | 34.4 GiB | 421 | 363 | 30.1 ± 2.3 | 38.3 ± 1.9 (0.80) |
| f16 | default (512) | 7.52 (true) | 30 s | 68.3 GiB | 44.3 GiB | 383 | 304 | 30.1 ± 2.1 | 34.3 ± 6.6 (0.81) |
| f16 | 2048 | 1.68 (false) | 26 s | 72.0 GiB | 41.1 GiB | 470 | 367 | 31.7 ± 2.7 | 39.8 ± 1.8 (0.80) |
| f16 | 4096 | 1.66 (false) | 28 s | 77.9 GiB | 35.9 GiB | 421 | 343 | 31.6 ± 2.9 | 38.9 ± 1.3 (0.80) |

Prefill and decode in t/s. 32K decode acceptance falls slightly with larger `-ub` (0.83 → 0.80), and the 32K
decode figures carry ±2 t/s noise, so no decode change is claimed.

**First attempt and `ErrorDeviceLost`.** The first row 3 run (host loadavg 19.6, other sessions active)
completed the default row, then `-ub 2048` failed on its first `/completion` with
`decode() failed: vk::Queue::submit: ErrorDeviceLost` (HTTP 500), and the `-ub 4096` row was then refused by
the memory gate (MemAvailable 19.0 GiB, a reload racing in). Two quiet reruns of `-ub 2048` (q8_0 and f16 KV) and
of `-ub 4096` completed normally. The cause of the single device loss is undetermined: kernel amdgpu log lines
were not readable from the benchmark session, so a `-ub`-triggered fault under memory pressure is not excluded.

## Not measured

- `-ub` between 512 and 2048 (1024) or above 4096; repeated runs of each `-ub` (one run per config).
- The cause of the one `ErrorDeviceLost`.
- A decode with the page cache dropped or the embedding file explicitly warmed (no root).
- Whether `--lazy-mode auto` is already lazy for this model.
- Prose p-min with lazy off, other n-max values, or other temperatures.
- Any of this on gfx1150 or with the ROCm backend.
- A quiet-host repeat of row 1 (lazy on) and row 2 (p-min): both ran at loadavg 6–14, so small differences (≤ ~2 t/s) are noise.

## Reproduce

`run.sh` unloads `Qwen3.8-Flash-Next-MTP` through lemond's `POST /api/v1/unload`, runs the rows and reloads
it on every exit path (`POST /api/v1/load`); `probe.py` is one server configuration per call.
