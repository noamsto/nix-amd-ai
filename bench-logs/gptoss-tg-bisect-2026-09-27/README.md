# gpt-oss-120b Vulkan tg128: b10964 vs b11207, interleaved — halo, gfx1151

Host: **halo** (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, kernel 7.2.8, ROCm
7.2.3, 123 GiB RAM, 32 cores). Mini-PC, always on AC. Measured 2026-09-27.

This run answers #162: is the −4.0% gpt-oss-120b Vulkan decode (tg128) drop
reported in `llamacpp-b11207-2026-09-27` real under interleaving? **It is not
reproducible.** Across 14 interleaved rounds the old-vs-new difference is
−0.04% (paired t = −0.045); under the quietest rounds the *new* build is
~1.4% faster (not significant). Details below.

## The claim under test

The #161 A/B ran old then new **once each**:

| Build | tg128 t/s | within-run stddev |
| --- | ---: | ---: |
| b10964 (old) | 53.74 | ±0.66 |
| b11207 (new) | 51.58 | ±0.41 |

Δ = −2.16 t/s = **−4.02%**, quoted against *within-run* stddev, not
run-to-run. That is the number this log re-tests.

## Method

- **Old** = `/nix/store/kw9ym27nvxsdgnh238222yv1ngw37hw6-llama-cpp-0.4.1`
  (`llama-bench`, `libggml-vulkan.so`), upstream tag b10964, commit `b29c606`.
- **New** = `/nix/store/rngpfzz5mgh3lrx6v0rhv9ycmbapp9qr-llama-cpp-11207`,
  upstream tag b11207, commit `7ac59a6`.
- **Model** = `gpt-oss-120b-MXFP4.gguf` (63,387,346,208 bytes),
  `/var/lib/models/hf/hub/models--ggml-org--gpt-oss-120b-GGUF/snapshots/238abdd290bb874b90a5da1b4549881b7d05c091/`.
- **Command per run** (tg only; pp512 not re-measured here, see *Not measured*):
  `llama-bench -m <model> -ngl 99 -p 0 -n 128 -r 5 -o json`
- **Guard before every run**: the wrapper waits up to 90 s for
  `gpu_busy_percent == 0` (all cards) and GPU temp ≤ 45 °C, then launches
  regardless. On this always-warm mini-PC the wait often timed out, so the
  committed start temps run 44-55 °C (`timeline.txt` per phase) — the 45 °C
  target is not a hard gate. Rounds 1-4 (and the warm-ups) additionally
  re-checked lemond `model_loaded == null`; rounds 5-14 did not. Every phase's
  `timeline.txt` records the start busy/temp; only `interleaved/` (rounds 1-4 +
  warm-ups) also records the end busy/temp and the `lemond` field. The
  model-load wall times in those files identify the host-load spikes below (a
  run that took ~2x its neighbours is a load-contaminated round).
- **Design**: 14 interleaved rounds, each round = one run of each build
  back-to-back, plus 2 discarded warm-up runs. Run order was deliberately varied
  so the build effect is separable from run order / host drift:
  - `interleaved/` — rounds 1-4, order **old, new** (ABAB; the #161 order)
  - `interleaved-reversed/` — rounds 5-6, order **new, old**
  - `interleaved-balanced/` — rounds 7-10, mixed order
  - `interleaved-quiet/` — rounds 11-14, mixed order, lower host load
- **Host is shared and was under heavy sibling-worker load during part of the
  session.** Host load was sampled by hand, not per run: see `host-load.txt`.
  All disk and CPU work (the build trees, the model sha256) was kept off the
  GPU and away from the runs.

Raw per-run `llama-bench` JSON (stdout) and stderr logs are in each phase
directory; `analyze.py` regenerates the table and statistics below. No build
recipe is committed: the result uses the two nix-store Vulkan binaries above,
and no bisect build tree was used.

## Interleaved results

Per-run mean over the 5 in-process repetitions (`llama-bench` `avg_ts`):

| round | order | old t/s | old sd | new t/s | new sd | old−new | host |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | old,new | 51.611 | 0.91 | 52.743 | 0.97 | −1.132 | |
| 2 | old,new | 51.254 | 0.59 | 51.661 | 1.02 | −0.407 | |
| 3 | old,new | 52.498 | 0.56 | 50.909 | 0.83 | +1.589 | |
| 4 | old,new | 52.022 | 0.66 | 49.280 | 0.79 | +2.742 | |
| 5 | new,old | 53.483 | 0.67 | 52.127 | 0.38 | +1.356 | |
| 6 | new,old | 53.048 | 0.30 | 51.726 | 2.24 | +1.322 | |
| 7 | old,new | 41.385 | 0.41 | 39.843 | 0.92 | +1.542 | **load spike** |
| 8 | new,old | 50.724 | 3.04 | 53.469 | 0.34 | −2.744 | **load spike** |
| 9 | new,old | 53.229 | 0.49 | 52.903 | 0.36 | +0.326 | |
| 10 | old,new | 53.922 | 0.36 | 53.639 | 0.39 | +0.284 | |
| 11 | old,new | 50.254 | 2.72 | 53.393 | 0.89 | −3.139 | |
| 12 | new,old | 53.713 | 0.77 | 54.179 | 0.22 | −0.466 | |
| 13 | old,new | 53.211 | 1.10 | 54.339 | 0.51 | −1.128 | |
| 14 | new,old | 54.406 | 0.10 | 54.832 | 0.24 | −0.426 | |

(`old sd` / `new sd` are llama-bench's own stddev across the 5 repetitions
within that one process; they are **not** the run-to-run spread. The run-to-run
spread is what matters here and is several times larger — see the means.)

## Statistics

`python3 analyze.py`:

| subset | n pairs | old mean | new mean | unpaired Δ | paired Δ ± se | paired t |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| all rounds | 14 | 51.769 | 51.789 | −0.04% | −0.020 ± 0.449 | −0.045 |
| excl. load-spike r7-8 | 12 | 52.721 | 52.644 | +0.15% | +0.077 ± 0.450 | +0.170 |
| quiet rounds r9-14 | 6 | 53.123 | 53.881 | **−1.43%** | −0.758 ± 0.525 | −1.445 |

Over all 14 rounds the paired 95% CI for `old − new` is
**−0.99 .. +0.95 t/s**. The original −2.16 t/s point estimate lies well outside
it in the *opposite* direction from the all-rounds mean.

**Conclusion (AC2 "not reproducible" branch):** the −4.02% does not reproduce
under interleaving. The measured effect is indistinguishable from zero
(−0.04%, t = −0.045); if anything, under quiet host load the new build is
faster (1.43%, t = −1.45, not significant). No bisect was run, because the
first step's gate to bisect (a reproducible gap above noise) was not met.

## Why the single-shot −4.0% is not trustworthy — measured evidence

1. **Run-to-run spread swamps 4%.** Across the 12 non-spike rounds the per-build
   run-to-run stddev is 1.22 t/s (old) / 1.60 t/s (new) on means of 52.72 /
   52.64 t/s (≈2.3–3.0%); across all 14 rounds it is 3.24 / 3.75 t/s on means
   of 51.77 / 51.79. Either way the spread is several times larger than the
   within-run stddev #161 quoted (±0.41–0.66), so a 2.16 t/s single-shot
   difference sits inside it.
2. **The original order (old then new) is the one that drifts.** In the AB
   phase (r1-4, exactly #161's order), the new build declined monotonically
   52.74 → 51.66 → 50.91 → 49.28 t/s while old stayed flat; the paired sign
   even flipped from new-faster (r1-2) to old-faster (r3-4). When order is
   reversed or balanced (r5-14) that decline disappears and new is not slower.
   The mechanism behind the drift is **not isolated** here — this is a
   measured pattern, not an attributed cause.
3. **Host load moves these numbers far more than the build does.** Two rounds
   (r7-8) ran while sibling dispatcher workers saturated the host (load
   average **71.97** observed at 18:58; model-load wall time ~83-96 s vs ~40 s
   for the rest). They read **41.4/39.8 t/s**, ~24% below the quiet rounds
   (53.1/53.9), a swing six times the claimed effect. Under the same build and
   model, host load dominates. So a single old-then-new pair cannot support a
   4% claim without a load-controlled design.

## What was not measured (labelled, per repo convention)

- **pp512** was not re-measured in this run (tg-only). The `+82%` pp512 gain in
  `llamacpp-b11207-2026-09-27` is not re-verified here.
- **No first-bad upstream commit** — bisect was not run because the regression
  did not reproduce. The suspects that motivated the check (e.g. #28415 IQ4_XS
  MMQ/MMV kernels, #27952 int8 coopmat1) are therefore **not** attributed,
  exonerated, or investigated here.
- **No runtime knob was tested** (e.g. `GGML_VK_*`), for the same reason.
- The drift mechanism in point 2 above is observed but **not attributed** to
  any cause.
- Model file sha256 (computed after the runs, off the GPU), in `model.sha256`:
  `582bd40f6886200101f4c4ed9f25f3fe80cc14c86e9e2b37746cd8904a0c622d`,
  63,387,346,208 bytes.

## Follow-ups

- None from this run. If the pp512 gain or a decode regression is still a
  concern, it needs a load-controlled re-measurement on an idle host rather
  than a single-shot A/B.
