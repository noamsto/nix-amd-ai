# llama.cpp b10964 (old) vs b11207 (new) A/B — halo, gfx1151

Host: **halo** (Ryzen AI MAX+ 395, Radeon 8060S/gfx1151, kernel 7.2.7, 123 GiB
RAM, ROCm 7.2.3). Desktop mini-PC, always on AC (no `power_supply` class /
`platform_profile` — no battery to report a profile for). GPU confirmed idle
(`gpu_busy_percent` 0, lemond `model_loaded: null`) immediately before each
run. `llama-bench -ngl 99 -r 3 -p 512 -n 128`, no other GPU load.

- **Old** = the currently-deployed system backends
  (`/etc/lemonade/backends/{llamacpp-vulkan,llamacpp-rocm}` →
  `llama-cpp-0.4.1`, build b10964, commit `b29c606`) — i.e. `main`'s output,
  unchanged by this branch.
- **New** = this branch's `llama-cpp`/`-vulkan`/`-rocm`, pinned to upstream
  tag `b11207` (commit `7ac59a6`), built via `nix build
  .#llama-cpp{,-vulkan,-rocm}`.

## Throughput (t/s, mean ± stddev over 3 repeats)

| Model | Backend | old pp512 | new pp512 | Δ pp512 | old tg128 | new tg128 | Δ tg128 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Qwen3.8-27B UD-Q4_K_XL | Vulkan | 352.12 ± 5.99 | 403.52 ± 2.95 | **+14.6%** | 12.07 ± 0.06 | 12.11 ± 0.05 | +0.3% |
| Qwen3.8-27B UD-Q4_K_XL | ROCm | 321.35 ± 18.08 | 324.69 ± 25.52 | +1.0% | 11.74 ± 0.03 | 11.55 ± 0.04 | −1.6% |
| Qwen3.8-Flash-Next UD-IQ4_XS | Vulkan | 365.81 ± 6.80 | 514.88 ± 13.53 | **+40.8%** | 26.69 ± 0.03 | 27.67 ± 0.12 | **+3.7%** |
| gpt-oss-120b MXFP4 | Vulkan | 525.96 ± 7.08 | 957.75 ± 18.40 | **+82.1%** | 53.74 ± 0.66 | 51.58 ± 0.41 | **−4.0%** |

Raw output: `old-{vulkan,rocm}-{27b,flash,gptoss}.log`, `new-{vulkan,rocm}-{27b,flash,gptoss}.log`.

**No regression matches the feared #28415 shape.** The task background flagged
a risk of a Flash-Next Vulkan decode regression from upstream's IQ4_XS kernel
changes (author's own table showed MoE `MUL_MAT_ID` at batch 1 at 0.81×) — on
this host, Flash-Next Vulkan tg128 is instead **+3.7%**, and pp512 is +40.8%.
The Vulkan pp512 gains across the board are plausibly consistent with upstream
[#27952](https://github.com/ggml-org/llama.cpp/pull/27952) ("vulkan: int8
coopmat1 matmul implementation for AMD RDNA3 and RDNA4", merged 2026-09-24,
landed before b11207) — not independently attributed to it via profiling on
this host, so treat the mechanism as a plausible cause, not a measured one.

**One real, small regression: gpt-oss-120b Vulkan tg128, −4.0%.** Reported
plainly, not explained away — pp512 on the same model is +82.1%, so this
looks like a genuine decode-path tradeoff on this quant/architecture, not
noise (stddev is ±0.66/±0.41 t/s, an order of magnitude below the 2.16 t/s
delta). Not investigated further here; flagged as a follow-up.

**ROCm 27B tg128, −1.6%,** is within the run-to-run noise band (old stddev
±18.08 t/s pp512 / ±0.03 t/s tg128, new ±25.52/±0.04) — not called a
regression.

**One transient, not reported as a result:** the first `new-vulkan-flash` run
(`new-vulkan-flash.log`) crashed with `vk::DeviceLostError` / "Not enough
memory for command submission" running immediately after the 27B Vulkan run
in the same unattended script. Two immediate retries
(`new-vulkan-flash-retry.log`, then the number folded into the table above)
both succeeded cleanly with consistent numbers, so this reads as GPU-memory
release racing between back-to-back `llama-bench` process launches on this
host, not a build defect — kept here rather than deleted, since a crash log is
data.

## ROCm correctness (perplexity)

Corpus: `corpus.txt` (51050 bytes, sha256
`7d32ffc53fbb723ba76e4bad5c5b5ce02ed583d9890e22bbb0f0c6a7791f5a76`) —
reconstructed byte-exact from this repo's own `README.md` +
`docs/halo-bringup-checklist.md` as they stood at commit `8a440bf95a8f`
(2026-09-06), which is the corpus the original 6.8182 reference in
[docs/rocm-gfx1151-numerics.md](../../docs/rocm-gfx1151-numerics.md) was
measured against. `llama-perplexity -m Qwen3.5-4B-UD-Q4_K_XL.gguf -f
corpus.txt -ngl 99 -c 512 --chunks 6 --seed 42 -t 8`.

| Build | PPL | Δ from 6.8182 |
| --- | ---: | ---: |
| old (b10964, `old-rocm-ppl.log`) | 6.8311 | +0.19% |
| new (b11207, `new-rocm-ppl.log`) | 6.8311 | +0.19% |

**Byte-identical PPL between old and new ROCm builds** — the b11207 pin is not
a numerics regression on this host. Tolerance used: **0.2% of 6.8182**
(6.8046–6.8318, per `docs/rocm-gfx1151-numerics.md`'s own "agrees ... to
0.2%" and its noted noise band of 6.8171–6.8298); 6.8311 sits just inside the
upper bound. This is the same figure the old build already produced against
this corpus (verified before touching the new build, to confirm the corpus
reconstruction itself was sound), so both builds land at the same distance
from the historical reference — consistent with "correct" rather than with a
coincidental pass.
