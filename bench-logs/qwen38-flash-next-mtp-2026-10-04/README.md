# Qwen3.8-Flash-Next MTP on stock llama.cpp — halo, gfx1151

Host: **halo** (Ryzen AI MAX+ 395, Radeon 8060S/gfx1151, 123 GiB RAM, ROCm 7.2.3).
Every number below is halo/gfx1151; none of it transfers to gfx1150 (see
`docs/halo-bringup-checklist.md`). GPU confirmed idle (`gpu_busy_percent` 0, no
foreign `llama-bench`/`llama-server`) before each run.

Stock upstream, no fork. Build under test: llama.cpp tag **b11382** (commit
`11fe021`), i.e. 52 commits past `c061df1` — the merge of
[ggml-org/llama.cpp#29761](https://github.com/ggml-org/llama.cpp/pull/29761)
("Qwen4Exp: add MTP"), the PR that superseded #28243 that #137 was waiting on.
Built through this flake (`nix build .#llama-cpp{,-vulkan,-rocm}`), so the
Vulkan backends carry #223's `withOwnVulkanDriver` wrapper and offload to the
GPU. Old arm = the same flake pinned back to **b11207** (commit `7ac59a6`).

## MTP A/B (MTP off vs `--spec-type draft-mtp`)

`nix run .#benchmark -- --mtp-ab Qwen3.8-Flash-Next-GGUF --mtp-draft <mtp head>`,
prompt 512 tokens, generate 128, 1 warmup + 3 measured, fresh `llama-server`
per arm, `--spec-draft-n-max 3`, target `unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ4_XS`.

| Backend | Build | MTP off (t/s) | MTP on (t/s) | Speedup |
| --- | --- | ---: | ---: | ---: |
| Vulkan | b11382 | 26.7 | 40.2 | **1.51×** |
| ROCm | b11382 | 19.0 | 33.0 | **1.74×** |

**MTP wins on halo.** The upstream author reported 28.4 → 43.9 t/s (1.55×) on a
DGX Spark; the speedup reproduces here, on a different host and backend.

### Draft-n-max sweep (Vulkan)

| `--spec-draft-n-max` | MTP off | MTP on | Speedup |
| ---: | ---: | ---: | ---: |
| 2 | 25.6 | 37.6 | 1.47× |
| 3 | 26.7 | 40.2 | **1.51×** |
| 4 | 25.5 | 30.6 | 1.20× |

`n-max 3` is the best of the three here, matching the upstream author's setting;
4 drafts regress below 3 (the extra draft work outruns the acceptance gain).

### Depth curve (Vulkan, single request, `depth-probe.py`)

Prompt built from real text, one `/completion` request, 128 generated tokens;
`prompt_n` is the server-reported token count.

| prompt_n | MTP off (t/s) | MTP on (t/s) | Speedup | Draft acceptance |
| ---: | ---: | ---: | ---: | ---: |
| 501 | 26.83 | 39.74 | 1.48× | 0.63 (83/132) |
| 30 870 | 24.52 | 29.28 | 1.19× | 0.54 (78/144) |
| 77 175 | 22.61 | 38.54 | 1.70× | see note |
| 123 480 | 20.77 | 34.38 | 1.66× | see note |

**No cliff through 123K.** MTP-off decode falls monotonically 26.8 → 20.8 t/s
across the curve — a −23% slope over 123K tokens, not the "severe degradation
after ~120K" the #135 report describes. MTP-on stays 1.2–1.7× off across the
range.

Caveat: the two deepest prompts repeat a shorter corpus, so MTP acceptance
rises toward 1.0 there and the on-arm speedup is optimistic; only the shallow
and 30.9K rows use a non-repeating prompt, and their acceptance (0.54–0.63) is
the representative figure. The off-arm slope is unaffected by the repetition.

### Run conditions (our rows)

From `mtp-ab.sh` / `depth-probe.py` and the `benchmark-go` defaults:

- **A/B and n-max sweep** (`--mtp-ab`): `--ctx-size 2048` (the `benchmark-go` default; `mtp-ab.sh` does not override it), `--parallel 1`, `--flash-attn on`, `--n-gpu-layers 99`.
- **Depth curve**: `--ctx-size` is set per row by `--ctx` and sized just above the prompt depth (the script's example is 82176 for a 78000-token prompt); the exact value per row is not recorded. Same `--parallel 1`, `--flash-attn on`, `--n-gpu-layers 99`.
- **KV cache type, `-t`, `-ub`, `-b`**: none are passed by either script, so llama-server defaults apply (KV f16, threads auto-detected, `-ub 512`, `-b 2048`). The values the server actually resolved are not recorded.

## Compared with external reports

Every row except the first is a third-party report on a Strix Halo 395 and
predates the upstream MTP merge (#29761); those used forks or older builds. The
Reddit figures were read via a mirror, not reddit.com. "not stated" means the
source does not give it. All links were fetched and resolved (HTTP 200) on
2026-10-04 and the headline figure was found on the page; the HF discussion was
only confirmed to mention IQ4_XS, not the 20–23 figure, so treat that row as
unverified.

| Source (date) | Host | Engine + build | Quant | MTP | KV | Alloc. ctx | Depth | Decode t/s | Prefill t/s |
| --- | --- | --- | --- | --- | --- | --- | --- | ---: | ---: |
| [llama.cpp#29761](https://github.com/ggml-org/llama.cpp/pull/29761) (2026-09-30) | DGX Spark (not Strix Halo) | upstream | IQ4_XS | off / on, n-max 3 (accept 0.64) | not stated | not stated | not stated | 28.36 / 43.88 | not stated |
| [Framework forum](https://community.frame.work/t/qwen3-8-please-share-your-t-s-any-quant/84405), Guest209 (2026-09-02) | Strix Halo | llama.cpp, build not stated | UD-IQ4_XS | off | not stated | not stated | tg128 / pp512 | 27.47 | 405 |
| same, Martin_Roth (2026-08-28) | Strix Halo | ROCm, build not stated | IQ4_XS | off | not stated | not stated | ~16K | ~21 | not stated |
| [HF unsloth discussion #3](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/discussions/3) | Strix Halo | not stated | IQ4_XS | off | not stated | not stated | not stated | 20–23 | not stated |
| [r/LocalLLM, u/emptyharddrive](https://reddit.sentinel-team.org/posts/1w5xaqt/snapshots/2026-09-04T21%3A20%3A12.3645Z) (≤2026-09-04, mirror) | Strix Halo | Vulkan RADV, unsloth b10715-mix | UD-Q3_K_XL | off / on, n-max 4, p-min 0.7 | not stated | not stated | short; 121K | 16–17 off; on 37–43 code, 25–31 prose; 22.0 at 121K (MTP state unclear) | ~300 (short) |
| [sleepingrobots](https://sleepingrobots.com/dreams/engramhalo-qwen38-flash-next-strix-halo/) (2026-08-29) | Strix Halo | ROCm 7.14, EngramHalo | AD-4.27bpw | off / draft-mtp+ngram-mod n4 | not stated | not stated | 3.4K | 20.9 / 38.5 peak | 391–453 |
| [EasiiX card](https://huggingface.co/EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF) | Strix Halo | EngramHalo | UD-IQ3_XXS | off / on | not stated | not stated | 156K for the +49% | 23.5 / 35.7 | not stated |
| [julianmb/haloq38flash](https://github.com/julianmb/haloq38flash) | Strix Halo | Vulkan llama.cpp fork | IQ4_XS | on, n-max 6 | not stated | not stated | 0 / 32K / 128K | 48.1 / 29.6 / 11.8 | 78 / 500 / 239 |
| [peonist-ai/halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) | Strix Halo | closed engine, ROCm 7.14 | native / UD-IQ4_XS | off 37.6 (native) / 25.4 (UD-IQ4_XS) at 1.5K; on 46.0 at 32K | not stated | not stated | 1.5K; 32K | see MTP column | ~1580 |
| [Atlas-Inf/atlas#143](https://github.com/Atlas-Inf/atlas/issues/143) (2026-09-28..30) | Strix Halo | reference llama.cpp, Linux | Q4_K_XL | off / on | not stated | not stated | 1.5K | 25.9 / 32.2 | not stated |

### Conclusions

Drawn only from depth-matched pairs; unknown context and KV settings limit
every comparison, and ours are 2048 allocated for the A/B and f16 KV.

- **Shallow, MTP off:** ours 26.8 @0.5K vs 27.47 (tg128), 25.9 and 25.4 @1.5K — in line.
- **~31–32K, MTP on:** ours 29.3 @31K vs haloq38flash 29.6 @32K (n-max 6) — in line.
- **~121–128K, MTP off only:** ours 20.8 vs 22.0 @121K (that report's MTP state is unclear). Our deep MTP-on rows (77K, 123K) use a repeated corpus that inflates acceptance, so they must not be compared with haloq38flash's 11.8 @128K.
- **ROCm:** our 19.0 @0.5K is not comparable to ~21 @16K; no ROCm-vs-others conclusion.

## What MTP needs (answers #137 step 2)

The existing `unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ4_XS` file **has no MTP
tensors** — parsing its three shards gives `qwen4exp.block_count = 48` and zero
tensor names matching `nextn|mtp`. That is expected: it was converted before
#29761, whose `conversion/qwen4exp.py` flips `supports_mtp_export` to `True`
(the old converter set `no_mtp = True`).

So MTP needs a **separate self-contained MTP head GGUF**, loaded with
`--model-draft` / `-md` — not a re-conversion of the target. Two heads exist and
they are **not** interchangeable on stock:

- `ggml-org/Qwen3.8-Flash-Next-GGUF:mtp-Qwen3.8-Flash-Next-Q8_0.gguf`
  (sha256 `6be8a94e…`) — **works**; every number above uses it.
- `unsloth/Qwen3.8-Flash-Next-GGUF:MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf`
  (sha256 `cd87e5d1…`) — **aborts** on stock b11382 with
  `GGML_ASSERT(buffer) failed` in `llama_kv_cache::set_input_k_idxs` (via
  `llama_model_qwen4exp::llm_graph_input_kpool::set_input`), on Vulkan, ROCm and
  CPU alike. It was built for the unsloth/#28243 fork, not mainline.

Use the self-contained `-Q8_0` head (3.85 GB, carries its own `token_embd` and
`output`); the `shared-*` variants rely on cross-model embedding borrowing that
#29761 does not implement.

## ROCm correctness (perplexity)

`llama-perplexity -m Qwen3.5-4B-UD-Q4_K_XL.gguf -f corpus.txt -ngl 99 -c 512
--chunks 6 --seed 42 -t 8`, corpus sha256
`7d32ffc53fbb723ba76e4bad5c5b5ce02ed583d9890e22bbb0f0c6a7791f5a76`.

| Build | PPL | Δ from 6.8182 |
| --- | ---: | ---: |
| b11207 (old) | 6.8311 | +0.19% |
| b11382 (new) | 6.8311 | +0.19% |

Byte-identical to the old pin and inside the 0.2% tolerance in
`docs/rocm-gfx1151-numerics.md` — the MTP bump is not a ROCm numerics
regression.

## Old vs new throughput (b11207 → b11382)

`llama-bench -ngl 99 -r 3 -p 512 -n 128`, same models as
`bench-logs/llamacpp-b11207-2026-09-27`. Both arms built through this flake
(wrapped); the deployed `/etc/lemonade/backends` binaries are **not** used,
because they are the unwrapped pre-#215 ELFs that silently CPU-fall-back.

| Model | Backend | old pp512 | new pp512 | Δ pp512 | old tg128 | new tg128 | Δ tg128 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Qwen3.8-27B UD-Q4_K_XL | Vulkan | 345.10 ± 6.74 | 363.04 ± 22.44 | +5.2% | 11.91 ± 0.03 | 11.89 ± 0.03 | −0.2% |
| Qwen3.8-27B UD-Q4_K_XL | ROCm | 297.62 ± 11.68 | 322.03 ± 0.46 | +8.2% | 11.44 ± 0.11 | 11.47 ± 0.05 | +0.3% |
| Qwen3.8-Flash-Next UD-IQ4_XS | Vulkan | 470.71 ± 2.86 | 443.6–494.9 | noisy | 24.01 ± 0.12 | 24.5–27.0 | noisy |
| Qwen3.8-Flash-Next UD-IQ4_XS | ROCm | 462.52 ± 19.66 | 472.19 ± 5.94 | +2.1% | 22.78 ± 0.44 | 21.82 ± 0.43 | −4.2% |
| gpt-oss-120b MXFP4 | Vulkan | 985.82 ± 1.04 | 916.52 ± 4.79 | −7.0% | 53.98 ± 0.19 | 46.26 ± 0.15 | **−14.3%** |

The gpt-oss-120b Vulkan row is the one apparent regression, so it was re-run
**interleaved** (old/new alternating, three rounds each) the way the earlier
`gptoss-tg-bisect-2026-09-27` did. Split by direction:

- tg128 does not reproduce: median old 48.32 / new 50.08 (**+3.6%**); paired
  means 47.07 / 49.83 (+5.9%).
- pp512 remains **below** in the interleaved re-run, same direction as the
  single-run −7.0%: median old 831.1 / new 801.8 (−3.5%); paired means 823.5 /
  780.1 (−5.3%). The three-round spread is large (old 679–960, new 690–848), so
  this is **unresolved, not exonerated** — reported plainly as a possible
  prefill regression that needs more rounds on a quieter host to call.

Flash-Next Vulkan is noisy in the same way (new pp512 ranged 443.6–494.9 across
runs): interleaved medians old 423.4 / new 480.3 and tg128 old 26.36 / new 27.19,
i.e. no regression. The 27B and Flash-Next ROCm rows are stable and within a few
percent.

## Reproduce

- `mtp-ab.sh` — the MTP A/B and n-max sweep (`nix run .#benchmark -- --mtp-ab`,
  paths via env: `TARGET`, `MTP_HEAD`, `LEMONADE_LLAMACPP_{VULKAN,ROCM}_BIN`).
- `depth-probe.py` — the depth curve: starts `llama-server`, sends one long
  `/completion`, prints server timings and draft acceptance.
- `old-vs-new.sh` — the `llama-bench` matrix for both pins.

Probe scripts, not raw logs. Each script reads its binary and model paths from
arguments or the environment, so nothing below hardcodes a store or model path.
