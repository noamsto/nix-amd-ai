# Qwen3.8-Flash-Next residency at long context and beside Qwen3.5-4B — halo, gfx1151 (#244)

Every number below is **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB
RAM, 104 GiB GTT), 2026-10-05**, and none of it transfers to gfx1150.

## Verdict

**Yes: Flash-Next (UD-IQ4_XS + MTP head) and Qwen3.5-4B (UD-Q4_K_XL) stay
resident together on halo, within the 104 GiB GTT budget and physical RAM, with
Flash-Next at 65536 context (q8_0 KV) and the 4B at 32768.** Total GTT in use was
**68.95 GiB** (66% of 104 GiB) and MemAvailable stayed at **21.3 GiB** of 123 GiB.
Flash-Next alone also fits at **131072 context**, q8_0 or f16 KV (GTT +67.0 /
+68.6 GiB after a decode over a ~130K-token prompt, MemAvailable ≥ 21.7 GiB), so
the ~8 GiB MemAvailable stop condition was never reached and no context limit
was found up to 131072. Co-residency at 131072 was **not measured** (see
below), but the 4B adds only ~4 GiB of GTT, which that gap would cover.

The 21.3 GiB MemAvailable left with both models loaded is the headroom for
everything else on halo: other services, agent sessions, and nix builds or lint
passes, which can each need many GiB. It was measured with halo otherwise idle,
so a large build running alongside both models is untested and could push the
host into swap.

The cost of sharing is throughput only when both decode at once: Flash-Next
drops from 41.6 to 37.2 t/s (−11%) and the 4B from 60.1 to 34.2 t/s (−43%).
With the 4B merely loaded and idle, Flash-Next decode is unchanged
(41.6 t/s). The stock-template tool-call round trip passes with both loaded.

## Run conditions

Stock llama.cpp **b11382** (`11fe021`), Vulkan (`.#llama-cpp-vulkan`),
standalone `llama-server` processes started and stopped by `probe.py`; the
system lemond and every other service were not touched (lemond had no model
loaded and no foreign `llama-bench`/`llama-server`/`benchmark-go` was running,
checked before every row). Flash-Next flags are #240's MTP preset: target
`unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ4_XS`, ggml-org MTP head
(`--spec-type draft-mtp --spec-draft-n-max 3`, no p-min), `--jinja`, `-fa on`,
`-ngl 99`, `-np 1`, `-t 8`, `-ctk`/`-ctv` as listed. The 4B: `-c 32768`, q8_0
KV, `-fa on`, `--jinja`, no draft model. Every row started from a fresh server
at MemAvailable ≥ 117 GiB (gate: ≥ 95 GiB) and loadavg < 2 (the `<2` gate held
on every row; the `<4 after 10 min` fallback was never needed).

**Context rows.** The prompt is built by `grid.py`'s corpus builder from
distinct tracked text files of this repo (no repeated 64-token n-gram),
sliced to `ctx − 1152` tokens, so the KV is filled to the requested depth and
the decode touches it. One prefill plus one 128-token decode per row; t/s is
that one decode (no warmup, no repeats). GTT/VRAM deltas are against the
amdgpu counters before the server started.

## Context residency (Flash-Next alone, MTP on)

| `-c` | KV | prompt tokens | loadavg | GTT Δ after load → after decode | VRAM Δ | RSS after load → decode | MemAvailable after load → decode | prefill t/s | decode t/s (MTP accept) |
|---|---|---|---|---|---|---|---|---|---|
| 32768 | q8_0 | 31616 | 1.92 | 64.0 → 64.3 GiB | 1.84 GiB | 27.1 → 27.7 GiB | 26.7 → 25.8 GiB | 335 | 35.5 (85/124) |
| 65536 | q8_0 | 64384 | 1.53 | 64.9 → 65.2 GiB | 1.84 GiB | 27.1 → 27.7 GiB | 26.0 → 24.9 GiB | 293 | 40.8 (94/98) |
| 131072 | q8_0 | 129920 | 1.97 | 66.5 → 67.0 GiB | 1.79 GiB | 27.1 → 17.9 GiB | 24.2 → 23.0 GiB | 236 | 29.4 (89/112) |
| 131072 | f16 | 129920 | 1.22 | 68.2 → 68.6 GiB | 1.85 GiB | 27.1 → 27.7 GiB | 22.8 → 21.7 GiB | 184 | 27.5 (84/128) |

- The decode column is **not a context curve**. The acceptance rate differs by
  row (0.69, 0.96, 0.80, 0.66) and dominates a single 128-token decode, which is
  why 64K reads faster than 32K. Read it as "decode stays between 27 and 41 t/s
  through 130K", not as a ranking of depths.
- f16 KV was not faster at 131072 here (27.5 vs 29.4 t/s); #240's f16
  advantage was measured at a 512-token prompt and does not show up in this one
  decode, whose acceptance was lower (0.66 vs 0.80).
- RSS 17.9 GiB after the 131072 q8_0 decode is a drop from 27.1 GiB after load,
  unexplained; the other three rows kept 27.7 GiB. Not investigated.

## Co-residency (Flash-Next q8_0 KV `-c 65536` + Qwen3.5-4B `-c 32768`)

loadavg 0.37, gate `<2`, MemAvailable 118.3 GiB before load. Prompt: the first
3000 characters of `flake.nix` (a few hundred tokens), 128 generated tokens,
temperature 0, 1 warmup + 3 measured decodes per cell.

| state | GTT Δ | VRAM Δ | RSS | MemAvailable |
|---|---|---|---|---|
| Flash-Next loaded | 64.9 GiB | 1.81 GiB | 27.1 GiB | 26.2 GiB |
| + 4B loaded | **68.9 GiB** (+4.1) | 1.84 GiB | 27.9 + 0.2 GiB | **21.3 GiB** |
| after all decodes | 69.0 GiB | 1.84 GiB | 27.8 + 0.3 GiB | 21.0 GiB |

| decode | Flash-Next t/s | Qwen3.5-4B t/s |
|---|---|---|
| Flash-Next alone | 41.6 / 41.6 / 41.6 | — |
| 4B loaded (Flash-Next loaded too), each model in turn | 41.6 / 41.6 / 41.6 | 59.8 / 60.2 / 60.1 |
| both decoding at the same time (3 pairs) | 37.2 / 37.1 / 37.5 | 34.2 / 34.2 / 34.3 |

The 4B's RSS (0.2–0.3 GiB) is tiny next to its +4.1 GiB GTT; not investigated further.

## Tool call while co-resident

#240's round trip (`get_weather` with a `city` argument, `--jinja`, stock
template, temperature 0) against Flash-Next with the 4B loaded: **pass**,
`finish_reason: tool_calls` with parseable arguments containing `city`. It also
passed with Flash-Next alone, immediately before the 4B loaded.

## Not measured

- Co-residency at 131072 (or f16 KV): the co-residency row used 65536, which
  fit. The 4B was not tried above 32768 context.
- A long prompt in the concurrent decode: the pair ran on short prompts, so the
  slowdown at 64K+ context is unknown.
- Repeat runs of the context rows: one decode each, single prefill.
- ROCm; gfx1150; the system lemond serving both models (this used standalone
  servers, so lemond's own overhead is not included).

## Files

The rows above were taken with an earlier `probe.py`; review then hardened its
failure paths only (server cleanup while loading, concurrent-decode error
checks, lemond re-check after the load gate, a no-drafts check). The hardened
version was not re-run on the host.

- `probe.py` — one row per invocation (`context` or `coresident`), prints one
  JSON line; imports the load gate pieces, foreign-process refusal, corpus
  builder and GTT/RSS readers from `../qwen38-flash-next-mtp-tuning-2026-10-04/grid.py`.
  Exit 2 foreign process / lemond busy, 3 low memory, 4 host not quiet, 1 any other error.
