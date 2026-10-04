# Qwen3.8-Flash-Next MTP tuning — halo, gfx1151 (#237)

**Status: provisional.** Every number below is **halo (Ryzen AI MAX+ 395,
Radeon 8060S / gfx1151), 2026-10-04**, and none of it transfers to gfx1150. The
host was **not quiet**: the task requires a 1-min loadavg below 2 before each
row, but sibling workers kept it at 5–25 for the whole session. The first row
polled the full 30 minutes and proceeded; later rows polled 60 s and proceeded.
**Every row is therefore flagged `load_flag: true`** and its starting loadavg is
in the tables. No final winner is claimed. The clean re-take is scripted in
`retake.sh` (below).

Build: stock llama.cpp **b11382** (commit `11fe021`) from this flake
(`.#llama-cpp-vulkan`, `.#llama-cpp-rocm`). Target
`unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ4_XS`, draft head
`ggml-org/Qwen3.8-Flash-Next-GGUF:mtp-Qwen3.8-Flash-Next-Q8_0.gguf`
(`--spec-type draft-mtp`).

## Run conditions (all rows unless stated)

`-ngl 99`, `-ctk q8_0 -ctv q8_0` (the README preset's KV types), `-fa on`,
`--parallel 1`, `-t 8`, `-c` = prompt + 128 generated + 2048 (2816 at 512,
10496 at 8K, 35072 at 32K), one fresh `llama-server` per row, 1 warmup + 3
measured completions, 128 generated tokens, temperature 0, `ignore_eos`,
prompt cache off. `--spec-draft-p-min` defaults to 0.00 in b11382, so "none"
means 0.0 (the flag is passed only when above 0).

**Prompt.** `grid.py` builds it from distinct tracked text files of this repo
(sorted `git ls-files`, `.md/.nix/.go/.py/.sh`, bench-logs READMEs excluded),
tokenised by the server, sliced to exactly the depth, and checked for **zero
repeated 64-token n-grams** (`ngram64_dupes: 0` on every row). Unlike #137's
deep rows it never repeats a corpus. It is still structured docs and code, not
prose, so acceptance on it is not a prose figure.

**Differences from #137 / PR #231** (which measured 26.7 → 40.2 t/s, 1.51× at
n-max 3 on Vulkan): `-c` 2816 vs 2048, q8_0 KV vs the f16 default, `-t 8` vs
auto, and a different 512-token prompt (repo text vs the built-in passage). The
n-max 3 / no p-min row here reaches only 1.07–1.14× at 0.42 acceptance vs 0.63
in #231. I have **not** isolated which difference (or the host load) accounts
for it; the prompt is the most likely, because acceptance is content-driven, but
that is unmeasured. `retake.sh` is the place to bisect it.

## Grid — Vulkan, 512 prompt / 128 gen (halo, gfx1151)

MTP-off baseline in the same session: 26.2 ± 0.2 t/s (loadavg 6.0).

| n-max | p-min | decode t/s (± stdev) | acceptance | loadavg at start |
| ---: | ---: | ---: | ---: | ---: |
| 3 | none | 28.8 ± 2.5 | 0.42 | 7.0 |
| 3 | 0.6 | 28.9 ± 1.1 | 0.75 | 10.4 |
| 3 | 0.75 | 27.5 ± 1.3 | 0.91 | 8.5 |
| 3 | 0.85 | 27.0 ± 0.9 | 0.92 | 7.4 |
| 4 | none | 25.5 ± 4.0 | 0.34 | 7.8 |
| 4 | 0.6 | 26.5 ± 1.4 | 0.76 | 6.9 |
| 4 | 0.75 | 27.4 ± 0.4 | 0.89 | 13.0 |
| 4 | 0.85 | 25.9 ± 0.1 | 0.86 | 13.2 |
| 5 | none | 24.3 ± 1.4 | 0.30 | 16.0 |
| 5 | 0.6 | 27.6 ± 0.4 | 0.70 | 7.2 |
| 5 | 0.75 | 28.3 ± 1.5 | 0.83 | 7.3 |
| 5 | 0.85 | 27.4 ± 0.6 | 0.83 | 5.1 |

Two interleaved confirmation passes of the leading configs (loadavg 4.9–25.4):

| config | grid | confirm 1 | confirm 2 | mean of 3 |
| --- | ---: | ---: | ---: | ---: |
| MTP off | 26.2 | 25.8 | 25.0 | 25.7 |
| n-max 3, none | 28.8 | 29.3 | 28.2 | **28.8** |
| n-max 3, p-min 0.6 | 28.9 | 28.8 | 26.8 | 28.2 |
| n-max 4, p-min 0.75 | 27.4 | 27.9 | 27.4 | 27.6 |
| n-max 5, p-min 0.75 | 28.3 | 23.7 | 25.7 | 25.9 |

Reading, with the load caveat: p-min raises acceptance monotonically (0.42 →
0.75 → 0.91 at n-max 3) but did **not** raise decode t/s on this prompt — the
extra gating cost cancels the gain. n-max 3 held up best across the three
passes; n-max 4 and 5 did not beat it, in line with #137's n-max sweep. The
claim from other Strix Halo users that p-min 0.7–0.75 is essential and n-max 4
best is **not reproduced** here, but the spread between the top configs
(≈1 t/s) is inside the run-to-run noise at this load, so it is not refuted
either. **Provisional pick: n-max 3, no p-min.**

## Other rows (halo, gfx1151; all `load_flag: true`)

| Row | Backend | Conditions | MTP off | MTP on | accept | loadavg (off / on) |
| --- | --- | --- | ---: | ---: | ---: | --- |
| default slots (`--parallel` unset → 4 slots) | Vulkan | n-max 3, 512 | 25.0 | 28.3 | 0.42 | 8.8 / 10.2 |
| `--parallel 1` (grid row) | Vulkan | n-max 3, 512 | 26.2 | 28.8 | 0.42 | 6.0 / 7.0 |
| depth 32 768 (non-repeating) | Vulkan | n-max 3, `-c` 35072 | 23.3 | 35.6 | 0.93 | 6.4 / 9.1 |
| 512 | ROCm | n-max 3 | 21.6 | 24.0 | 0.41 | 10.8 / 4.6 |
| depth 8 192 | ROCm | n-max 3, `-c` 10496 | 19.8 | 29.6 | 0.57 | 7.7 / 7.6 |
| depth 32 768 | ROCm | MTP-off only | 16.5 | not taken | — | 5.8 |

- **Parallel slots:** the default allocates 4 slots in b11382. On a single
  request the MTP gain is the same within noise (1.13× vs 1.10×); the claim that
  concurrent requests disable MTP was **not tested** (it needs concurrent
  clients, not a single stream).
- **32K depth, Vulkan:** MTP-off decode fell 26.2 → 23.3 t/s (−11%). MTP-on
  decode was 35.6 t/s at 0.93 acceptance — higher than at 512. That acceptance
  is suspiciously high for a non-repeating prompt: the text has no repeated
  64-token run but is repetitive in structure (similar docs and code), so I do
  **not** read this as "MTP gains grow with depth". The "gain gone by ~26K"
  fork claim is not supported on this prompt, but this prompt is not prose.
  Re-take on prose is in `retake.sh`'s to-do list (swap the corpus).
- **ROCm at depth:** MTP-off decode is 21.6 → 19.8 → 16.5 t/s at 0.5K / 8K / 32K.
  No collapse to ~5 t/s past 1K context on this build, so the reported hipCUB
  cliff does **not** appear here at 8K or 32K (decode only; MTP-on at 32K not
  taken).

## Not measured yet (folded into `retake.sh`)

- `-fa off` vs `on` (Vulkan and ROCm): the first attempt failed — llama-server
  refuses a quantized V cache without flash attention. `grid.py` now defaults to
  f16 KV when `--fa off`. **No answer yet on which the preset should use.**
- ROCm 32K MTP-on, GTT/RSS residency, n-gram table GTT share, tool-call round
  trip. The batch was stopped by Claude Code's low-memory reaper while a ~94 GiB
  load was in flight (the system lemond keeps another model resident), so these
  are not measured. `grid.py` now refuses to start a row when `MemAvailable`
  cannot hold the target + draft + 6 GiB.
- Tool calling: planned as one request with a `tools` array against the shipped
  GGUF template through `llama-server --jinja` (not lemond's endpoint — no
  service reconfiguration); community template context is in
  [unsloth discussion #38](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/discussions/38)
  for #232. Result pending.

## Reproduce

- `grid.py row …` — one fresh `llama-server` per invocation, one JSON line out.
  Waits for loadavg < 2 (30 min cap, then `load_flag: true`), refuses foreign
  `llama-bench`/`llama-server`/`benchmark-go` processes (lemond excepted) and an
  insufficient `MemAvailable`.
- `retake.sh` — the full clean re-take (baseline, leading configs twice, then
  parallel / fa / depth / ROCm / residency / n-gram / tool-call rows). Needs a
  quiet host and the GPU free of other resident models.

Scripts only; no raw logs.
