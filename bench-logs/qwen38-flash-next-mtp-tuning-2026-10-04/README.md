# Qwen3.8-Flash-Next MTP tuning — halo, gfx1151 (#237)

Every number below is **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151),
2026-10-04/05**, and none of it transfers to gfx1150. This is the **clean
re-take**: every row started at 1-min loadavg < 2 (0.92–1.97, listed per row)
with `load_flag: false`, on an otherwise idle host (no foreign
`llama-bench`/`llama-server`/`benchmark-go`, the system lemond with no model
loaded, MemAvailable ≥ 112 GiB). It replaces an earlier pass whose rows all ran
at loadavg 5–25 and were flagged.

It is a **shortened row set** (about 20 rows, ~1.5 h): one round, not two. Rows
**dropped for time budget** — not results, not failures:

- A: the n-max 3 / p-min 0.6 and n-max 5 / p-min 0.75 configs, and the reversed
  second round.
- C: ROCm `-fa off` / f16-KV rows and the ROCm 8K depth pair.
- D: the MTP-off residency row.
- **All of E**: Vulkan `--threads` auto (default) vs 8, MTP off and on.

Build: stock llama.cpp **b11382** (commit `11fe021`) from this flake
(`.#llama-cpp-vulkan`, `.#llama-cpp-rocm`). Target
`unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ4_XS`, draft head the **ggml-org**
`mtp-Qwen3.8-Flash-Next-Q8_0.gguf` (`--spec-type draft-mtp`). unsloth's `MTP/`
head aborts b11382 at load (`GGML_ASSERT(buffer)` while building the draft
context), see `../qwen38-flash-next-mtp-2026-10-04/README.md`; a first launch of
`retake.sh` with it failed on every MTP row before any measurement.

## Run conditions (all rows unless stated)

`-ngl 99`, `-ctk q8_0 -ctv q8_0` (the README preset's KV types), `-fa on`,
`--parallel 1`, `-t 8`, `-c` = prompt + 128 generated + 2048 (2816 at 512,
35072 at 32K), one fresh `llama-server` per row, 1 warmup + 3 measured
completions, 128 generated tokens, temperature 0, `ignore_eos`, prompt cache
off. `--spec-draft-p-min` defaults to 0.00 in b11382, so "none" means 0.0.

**Prompt.** `grid.py` builds it from distinct tracked text files of this repo
(`.md/.nix/.go/.py/.sh`, bench-logs READMEs excluded), tokenised by the server
and sliced to exactly the depth, with **zero repeated 64-token n-grams**
(`ngram64_dupes: 0` on every row). It is structured docs and code, not prose, so
acceptance on it is not a prose figure.

## A. Vulkan n-max / p-min, 512 prompt / 128 gen (halo, gfx1151)

Each config is preceded by its own MTP-off baseline. One round, so stdev is
across the 3 measured completions of one server only.

| config | MTP off t/s | MTP on t/s (± stdev) | speedup | acceptance | loadavg (off / on) |
| --- | ---: | ---: | ---: | ---: | --- |
| n-max 3, no p-min | 27.07 | 30.69 ± 2.25 | 1.13× | 0.42 | 1.70 / 1.64 |
| n-max 3, p-min 0.75 | 27.38 | 29.62 ± 1.25 | 1.08× | 0.91 | 1.75 / 1.57 |
| n-max 4, p-min 0.75 | 27.36 | 30.32 ± 0.39 | 1.11× | 0.89 | 1.97 / 1.67 |

## B. Vulkan, n-max 3 / no p-min (halo, gfx1151)

| row | MTP off t/s | MTP on t/s (± stdev) | speedup | acceptance | loadavg (off / on) |
| --- | ---: | ---: | ---: | ---: | --- |
| `--parallel` unset (auto slots), q8_0 KV | 27.44 | 31.38 ± 2.28 | 1.14× | 0.42 | 1.57 / 1.92 |
| `-fa off`, f16 KV | 27.27 | 32.86 ± 0.05 | 1.20× | 0.48 | 1.74 / 1.96 |
| `-fa on`, f16 KV | 27.40 | 33.32 ± 1.41 | 1.22× | 0.47 | 1.72 / 1.97 |
| depth 32 768, q8_0 KV, `-c` 35072 | 24.63 | 37.12 ± 1.06 | 1.51× | 0.82 | 1.77 / 0.92 |

## C. ROCm, n-max 3 / no p-min (halo, gfx1151)

| row | MTP off t/s | MTP on t/s (± stdev) | speedup | acceptance | loadavg (off / on) |
| --- | ---: | ---: | ---: | ---: | --- |
| 512 | 22.83 | 28.02 ± 0.83 | 1.23× | 0.41 | 1.13 / 1.56 |
| depth 32 768 | 17.04 | 30.62 ± 1.18 | 1.80× | 0.77 | 1.87 / 1.65 |

## D. Residency and tool call (Vulkan, halo, gfx1151)

| row | result | loadavg |
| --- | --- | ---: |
| MTP n-max 3, residency, after warmup | GTT +63.4 GiB, VRAM +1.8 GiB, RSS 27.3 GiB (HWM 27.3 GiB) | 1.78 |
| + `ngram-mod`, residency | GTT +63.4 GiB (unchanged to <1 MiB), VRAM +1.8 GiB, RSS 27.3 GiB (+20 MiB vs MTP only) | 1.85 |
| tool-call round trip (`--jinja`, stock GGUF template) | **pass**: `finish_reason: tool_calls`, parseable `tool_calls[0]` with a `city` argument | 1.87 |

## The four questions

**1. MTP here was ~1.1×; #231 measured 1.51× at n-max 3. Host load or setup?**
Not host load. Clean (loadavg < 2) n-max 3 / no p-min is 1.13×, inside the
1.07–1.14× the loaded pass gave; the MTP-off baseline moved only
26.2 → 27.1 t/s. The setup differences are only partly resolved:

- **KV type: yes, part of it.** Switching q8_0 → f16 KV takes the same config
  from 1.13× to 1.20× (`-fa off`) / 1.22× (`-fa on`), and acceptance from 0.42
  to 0.47–0.48. MTP-on goes 30.7 → 33.3 t/s with the MTP-off baseline unchanged
  (27.1 vs 27.4).
- **Prompt: the likely remainder, not isolated.** #231 had acceptance 0.63 and
  40.2 t/s MTP-on. Even at f16 KV acceptance here is 0.47 and MTP-on 33.3 t/s,
  with the MTP-off baseline matching #231's (26.7 vs 27.4). Acceptance is
  content-driven, and #231's prompt is not reproducible from this repo.
- **`-c` and `-t 8`: not tested** (row group E, dropped for time budget).
- `--parallel` auto (4 slots) gives the same gain (1.14× vs 1.13×).

At depth the picture changes: the speedup grows to 1.51× (Vulkan) / 1.80×
(ROCm) at 32K with acceptance 0.77–0.82. The prompt is repetitive in structure
(similar docs and code, though no repeated 64-token run), so do **not** read
this as "MTP gains grow with context" for prose.

**2. Winner.** **No clear winner.** MTP-on spans 29.6–30.7 t/s over the three
configs (a 1.1 t/s spread) against a within-run stdev of 0.4–2.3 t/s and a
single round. p-min 0.75 raises acceptance 0.42 → 0.89–0.91 but not t/s: the
gating cost cancels the gain. n-max 3 / no p-min is nominally highest and
matches #231's preset, so the README `customModels` example is **left
unchanged**; the clean rows do not justify changing it. The "p-min 0.7–0.75 is
essential, n-max 4 best" claim is not reproduced and not refuted. Also from B:
f16 KV beat q8_0 KV by ~2.5 t/s (MTP on); that is a KV-type effect, measured
with n-max 3 only.

**3. Tool-call round trip on the stock template.** **Yes.** `llama-server
--jinja` with the shipped GGUF template and MTP on, given an OpenAI-compatible
request with a `tools` array, returned `finish_reason: tool_calls` with a
parseable `tool_calls[0]` whose JSON arguments carried the requested `city`
(Vulkan, halo, gfx1151). One request, one tool, temperature 0: this clears the
gate on the template; it is not a multi-turn agent test or a hermes/pi
end-to-end run.

**4. Residency, and can it sit beside Qwen3.5-4B in 104 GiB of GTT?** With MTP
at ctx 2816: **63.4 GiB GTT + 1.8 GiB VRAM**, and **27.3 GiB RSS** (the rest of
the ~88 GiB of weights stays in host-mapped pages, not GTT). The n-gram share
is negligible: `ngram-mod` adds **0 GTT** (same figure to <1 MiB) and ~20 MiB
RSS. The GTT total is 104 GiB (106 496 MiB), so Flash-Next uses ~61% of it. The
Qwen3.5-4B UD-Q4_K_XL weights are 2.8 GiB (+0.6 GiB mmproj), so **on paper they
fit with ~37 GiB of GTT to spare**; physical RAM is the tighter budget
(~27 GiB RSS + 63 GiB GTT + the 4B model, out of 123 GiB). This was **not run
concurrently** and residency was **not measured at larger ctx** (only 2816),
so KV growth at hermes/pi context lengths is unmeasured.

`ngram-mod` throughput is not a result: that row reads 97.5 ± 37.9 t/s because
each measured request repeats the warmup request verbatim, so the n-gram table
sees the exact output it is about to propose. A real workload would not.

## Reproduce

- `grid.py row …` — one fresh `llama-server` per invocation, one JSON line out.
  Waits for loadavg < 2 (30 min cap, then `load_flag: true`), refuses foreign
  `llama-bench`/`llama-server`/`benchmark-go` processes (lemond excepted) and an
  insufficient `MemAvailable`.
- `retake.sh` — the shortened row set above (A–D). `DRAFT` must be the ggml-org
  head. Needs a quiet host and the GPU free of other resident models.

Scripts only; no raw logs.
