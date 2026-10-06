# Strix Halo inference engines for Qwen3.8-Flash-Next: desk survey

Desk research for #253, done 2026-10-06. **No GPU runs, no
downloads, nothing measured here.** Every number below is **claimed** by the linked source, on its own host, quant and
harness. The only numbers measured on halo are the #249 baselines (PR #254), quoted for comparison.

## Baseline to beat (measured on halo, #249)

Qwen3.8-Flash-Next UD-IQ4_XS, MTP Q8_0 head, client-timed, `-c 131072`. Source: PR #254's
`bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/README.md`.

| engine | prefill 4K / 32K / 128K (t/s) | decode with MTP 512 / 32K / 128K (t/s) | GTT after load |
| --- | --- | --- | --- |
| Vulkan b11382 (production) | 453 / 392 / 266 | 29.3 / 36.8 / 27.5 | 70.8 GiB |
| GSQHalo.cpp HIP, q8_0 KV | 702 / 613 / 316 | 30.3 / 35.7 / 21.8 | 77.8 GiB |
| GSQHalo.cpp HIP, f16 KV | 751 / 799 (4K / 32K) | 43.0 at 32K | 71.6 GiB |

"#249's best" below means the best row per column: prefill 751 / 799 / 316, decode 30.3 / 43.0 / 27.5.

## Ranking

Gain columns divide the claim by #249's best per column (decode against the best spec-on figure, 43.0 at 32K, unless a
context is named). They compare different harnesses (see the "How measured" notes), so read them as a ranking signal,
not a forecast.

| # | engine | claimed prefill | claimed decode (spec on) | expected gain vs #249 best | confidence in the claim | fit on halo | packaging cost |
| - | --- | --- | --- | --- | --- | --- | --- |
| 1 | **Strata** (Niko1221, MIT) | 1,159–1,299 t/s, 8K–128K | 50.7–53.8 t/s, 8K–128K | prefill ~1.5× at 4K–32K, ~4× at 128K; decode ~1.2× (vs 43.0), ~1.9× at 128K (vs 27.5) | medium: open code, same quant as ours, but one maintainer box, self-reported, "experimental" on gfx1151, about two weeks old | good on paper: its numbers use unsloth's UD-IQ4_XS GGUF (as a Strata pack; whether halo's existing file and MTP head load unchanged is unverified); vision via mmproj; tools; footprint unmeasured | medium: CMake + HIP, fetches ggml at configure, wants ROCm 7.14.1 |
| 2 | **Halogen 0.16.2** (Peonist, closed) | 1,517–1,584 t/s, 8K–128K | 34.1 serial / 46.0 spec at 32K; 52.5 mean over ten prompts | prefill ~2× at 4K–32K, ~4.8× at 128K; decode ~1.1× (serial 34.1 is below 43.0) | medium-high: detailed methodology, a rival independently measured it | good: own 62.1 GiB checkpoint, ~74 GiB total at 131K context; vision, tools, Messages API | cannot build from source; OCI image runs under podman as a sidecar to lemond |
| 3 | **Kyojin** (Yamz-Labs, MIT) | 1,367–1,486 t/s, 4K–128K | 32.7 plain / 44–53 spec at 4K | prefill ~1.9× at 32K, ~4.3× at 128K; decode ~1.0–1.2× (spec 44–53 at 4K; plain 32 is below baseline) | medium; its own card says Halogen is faster | poor as published: 95 GB pack needs ~113 GiB. Own ~3.5 bpw pack is unpublished | high: PyTorch-ROCm venv, SDK wheel, HSA preload |
| 4 | vLLM-ROCm (experimental fork) | ~400 t/s at 32K (81.04 s incl. first token) | 13.34 t/s at 512 | slower than #249 | high (a blog post with method) | poor: vision and MTP off, 32K max input, 95.4 GiB table on NVMe | high |
| 5 | llama.cpp Vulkan fork (drluoto `strix-halo-vulkan`) | 510 / 390 t/s, 8K / 32K | 58.1 short code; 30.1 prose @8K; 37.8 new code @32K | none on prefill | medium | good (llama.cpp) | low, but no gain |
| — | EngramHalo / strix-llama.cpp | — | — | measured in #249, not worth packaging | measured | — | — |
| — | SGLang, MLC-LLM | no gfx1151 results found | — | unknown | none | unknown | unknown |
| — | chlorine-server (Heretek-AI, AGPL-3.0) | none published | none | not applicable: targets Qwen 3.8-27B, per its README | n/a | n/a | n/a |

Ranks 1 and 2 get a bench issue below. Kyojin stays with #251, with the amendments in that section. Ranks 4 and 5 do
not clear the bar for GPU time.

## Per-engine notes

### Strata: rank 1

- **Source / license / activity.** [Niko1221/Strata](https://github.com/Niko1221/Strata), MIT, created 2026-09-24 (12 days before this survey),
  commits landing daily (latest 2026-10-06), about 14.6k GitHub stars. Open source. Built on parts of llama.cpp/ggml
  (pinned `third_party/ggml`) with its own HIP kernels.
- **Model, quant, vision.** Runs packs built from unsloth's `UD-IQ4_XS` and `UD-Q4_K_XL` GGUFs of Flash-Next (the file family halo
  serves today; its own `mtp/` layer files and pack conversion are extra disk), plus MTP speculation. Vision through `mmproj-Qwen3.8-Flash-Next-BF16.gguf` and a `strata-vision` helper
  built from llama.cpp's `mtmd` ([DETAILS.md, Images](https://github.com/Niko1221/Strata/blob/main/docs/DETAILS.md)).
- **API.** `/v1/chat/completions` with tools, `/v1/messages` (Anthropic), `/v1/responses`
  ([README](https://github.com/Niko1221/Strata#readme)). Streaming tool calls. Fits behind lemond as an OpenAI backend.
- **Strix Halo status.** [docs/STRIX_HALO.md](https://github.com/Niko1221/Strata/blob/main/docs/STRIX_HALO.md): "Status:
  experimental", built and measured on one maintainer box (Ryzen AI Max+ 395, 128 GB, ROCm 7.14.1 from TheRock, kernel
  7.0, `amd_iommu=off`, 112 GiB GTT). `gfx1151` is "unvalidated" in the build's own wording. WMMA prefill kernels for gfx11 parts including gfx1151,
  a gfx1151 hipBLASLt tuning table, and a GDN prefill recurrence.
- **Published numbers (claimed).** From STRIX_HALO.md §6, UD-IQ4_XS, maintainers' fast configuration (`--spec 4 --mtp
  --lookup-chain 3 --mtp-q4 all --prefill 16384`, int8 KV, the opt-in bit-changing switches on), medians of 3 runs:
  prefill 1,293 / 1,320 t/s and output 53.8 / 51.4 t/s at 8K / 128K. Re-measured on the merged 0.1.40 code with only
  arch defaults: 1,159 / 1,299 prefill and 53.1 / 50.7 output at 8K / 128K. The founder separately posted 1,195 prefill and
  54.7 decode at 32K, quoted on the [Kyojin model card](https://huggingface.co/yamz-labs/Qwen3.8-Flash-Next-EXL3-Yamz).
- **How measured.** Engine-reported: prompt t/s is (prompt tokens − 1) / prompt time, output is tokens / decode time; one
  fresh process per run, one code-agent prompt. Speculation is on, including **prompt lookup**, which inflates decode on
  text that repeats the context. It is not a plain-MTP figure, and not client-timed HTTP like #249.
- **Memory.** The same GGUF in llama.cpp takes 70.8 GiB GTT at 131K context (#249, measured), a rough proxy only. Strata's own
  footprint on halo is **not published**; that is a bench-issue deliverable. "All experts in the unified memory" is the
  measured configuration. The Strata box boots a 112 GiB GTT, larger than halo's 104 GiB.
- **Packaging.** Linux build from source (about 25 min) needs the ROCm 7.14.1 tarball (this repo's `llama-cpp-rocm` is on
  7.2.3), CMake fetching ggml at configure time (Nix needs `STRATA_GGML_DIR` pinned offline), and a hipBLASLt table
  passed via `STRATA_HIPBLASLT_TUNING`. A source package is plausible; moderate effort.
- **Risks.** Two weeks old, gfx1151 flagged unvalidated, rapid churn, decode figure depends on lookup speculation.

### Halogen: rank 2

- **What it is.** [peonist-ai/halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server): **closed
  source**, proprietary terms in `LICENSE.md`, shipped as an OCI image
  (`ghcr.io/peonist-ai/halogen-flash-server:0.16.2`), gfx1151 only, one model family. "halogen" and "Peonist" are
  trademarks of Peonist, LLC. Weights: [peonist-ai/halogen-qwen3.8-flash-next](https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next),
  proprietary `.hgn` format. See also [halogen-flash-teardown.md](halogen-flash-teardown.md) for what 0.5.6 contains.
  Pushed 2026-10-03, about 860 stars.
- **"Halogen 0.16.2 (v2 checkpoint)"** in the comparison post therefore means this image with its default v2 checkpoint
  (62.1 GiB, 4.16 bits average, vs w4b 115.55 GiB). It also needs a 47.7 GiB n-gram table that is paged, not held.
- **chlorine-server** ([Heretek-AI](https://github.com/Heretek-AI/chlorine-server)) is a clean-room reimplementation of
  halogen **0.1.3**, "not affiliated with Peonist", AGPL-3.0, scaffolded and in progress, no performance numbers, and its
  README names Qwen 3.8-27B as its only model. It is **not** a way to run Flash-Next here.
- **Bring-your-own GGUF.** Since 0.7.0 it opens a llama.cpp GGUF of the model, losslessly repacked: this gives an
  **apples-to-apples arm on our quant**. Claimed on UD-IQ4_XS (0.12.1): 72 GiB held; prefill 1,237–1,239 (8K) /
  1,420–1,422 (32K); decode with draft head 27.9–30.2 t/s at short context, 45% accepted. Prefill roughly triples vs
  Vulkan on the same file, decode does not.
- **Published numbers (claimed), v2 / w4b checkpoint, reference machine (Ryzen AI Max+ 395, 128 GB, ROCm 7.14.0, ~85 W
  sustained, IOMMU off).** Prefill 1,584 / 1,567 / 1,517 t/s at 8K / 32K / 128K; serial greedy decode 37.6 / 34.1 at
  1.5K / 32K; spec decode 46.0 at 32K served, 52.5 mean over ten prompts, 55.7–56.3 on coding-agent turns with prompt
  lookup. Per the README these rows are w4b's, not re-measured on v2.
- **How measured.** Prefill: the engine's own bench is cold, prompt cache off; through HTTP the image's `sweep` mode
  reads 1,502 / 1,499 at 8K / 32K. Decode greedy at temperature 0, byte-identical to serial. The README warns that the
  **IOMMU setting moves prefill 13–16%** and a lower power envelope moves decode 11–12%; both are relevant because halo
  runs translated-mode IOMMU (see [halogen-flash-teardown.md](halogen-flash-teardown.md)).
- **Independent corroboration.** The Kyojin model card reports Halogen 0.16.2 measured on its own machine: plain decode
  39.8 t/s at 4K, prefill 1,450–1,477 (4K) and 1,674–1,774 (16K) client wall clock, and says Halogen is faster than
  Kyojin on those rows. That is a rival's measurement, not ours.
- **Fit.** v2: 62.1 GiB pinned weights; the README's sharing table lists ~74 GiB total at context 131,072, 2 slots,
  `MAX_TOK` 16384, ~89 GiB at the Quickstart defaults. Vision file 0.84 GiB. The weights are pinned and
  non-moveable; a co-tenant that asks for more than the host has left gets the server OOM-killed. That conflicts with
  builds sharing the box, which must be exercised in the bench.
- **API.** OpenAI chat and completions, Responses (Codex), Anthropic Messages (Claude Code), JSON-schema output, tool
  calls with reasoning blocks, vision, `/metrics`. Four slots, no batching with speculation.
- **Packaging.** Nothing to package from source. Realistic form: run the container under podman/oci-containers as an
  opt-in lemond backend, pinned by digest. Needs a kernel with AMD's gfx1151 KFD fixes and `CONFIG_HSA_AMD_SVM`. The
  EULA permits benchmarking and publishing figures without approval.

### Kyojin: rank 3, covered by #251

- [Yamz-Labs/kyojin](https://github.com/Yamz-Labs/kyojin), MIT, ExLlamaV3 fork, 29 commits, daily activity, 51 stars.
  Qwen3.8-Flash-Next serve script `tools/qwen/serve.py`: OpenAI chat with `tools`, images as `image_url` (the server loads a
  vision tower; `--no-vision` drops it), MTP + n-gram speculation, claimed token-identical.
- Claims on the 95 GB pack (HF card, server-reported unless noted): prefill 1,412 / 1,486 / 1,367 at 4K / 32K / 128K;
  plain decode 32.7 at 4K and 31.9 at 128K; speculative 44.3–52.9 at 4K; client wall-clock prefill 1,306 at 4K.
  Source: [model card](https://huggingface.co/yamz-labs/Qwen3.8-Flash-Next-EXL3-Yamz).
- **Notes for #251 from this survey:**
  - The model card's Limits section says **"The conversion tooling is not published"**; the issue's step 1 plans to
    quantize with Kyojin's `convert.py`. Check upstream ExLlamaV3's converter supports the Flash-Next architecture before
    committing GPU time, or the ~4 bpw pack may not be producible.
  - The 3.47 bpw pack in `tools/qwen/SERVE.md` (`qwen38-yamz-v1`) is described but **not published**: decode 27.3 plain
    / 38.7–54.7 speculative by prompt class, at `-c 65536`.
  - A third party's 3.05 bpw EXL3 recipe
    ([vcruz305](https://github.com/vcruz305/Qwen3.8-Flash-Next-EXL3-Framework-Strix-Halo-recipe), MIT scripts): ~80 GB
    pack, 57.8 GiB GPU-visible, decode mean 41.3 t/s with MTP, prefill only **450–500 t/s** (random tokens, chunk 512).
    A smaller pack may trade away the prefill advantage.
  - Kyojin's card measures Halogen faster on most rows, so a Kyojin win over Halogen is not the expectation.

### vLLM-ROCm, SGLang, MLC

- **vLLM.** [Soot / Silicon, 2026-09-16](https://www.soothill.io/blog/2026/09/16/qwen38-vllm-disk-ple-strix-halo/): an
  experimental AMD Flash-Next vLLM development commit (not a release) on ROCm 7.14 and gfx1151, AWQ W4A16, text backbone
  67.2 GiB with the 95.4 GiB embedding table on NVMe. Claimed: 32K prefill plus first token 81.04 s (~400 t/s; their Vulkan baseline, UD-Q4_K_XL, took 306.42 s, ~107 t/s); decode ~13.34 t/s at 512 input. Vision and MTP disabled, eager mode, 32K max
  input. Fails the resident requirements.
- **SGLang, MLC-LLM.** No gfx1151 or Strix Halo result for Flash-Next found. SGLang has a Flash-Next cookbook entry
  ([LMSYS blog](https://www.lmsys.org/blog/2026-08-26-qwen-flash-next)), unverified on this hardware. Unknown, not ruled
  out; revisit if a gfx1151 report appears.

### llama.cpp forks

Covered by #249: strix-llama.cpp (`halo-box`, which absorbed EngramHalo.cpp) and GSQHalo.cpp (Aristo94). GSQHalo's f16 KV
row is the strongest llama.cpp result so far. The [drluoto Vulkan branch](https://github.com/ggml-org/llama.cpp/discussions/28512)
claims 510 / 390 prefill at 8K / 32K, no better than production Vulkan.

## Reading the claims side by side

| | Strata | Halogen | Kyojin | #249 (measured) |
| --- | --- | --- | --- | --- |
| Timing of prefill | engine-reported | engine bench; `sweep` over HTTP within ~5% | server-reported, client lower by ~5% | client TTFT, server agreed within 2% |
| Warm / cold | one fresh process per run | cold, cache off | cold; kernels need warm-up | cold, unique prompts |
| Speculation | MTP + lookup chain | MTP (+ lookup for agent rows) | MTP + n-gram | MTP, n-max 3 |
| Quant | UD-IQ4_XS GGUF | claimed rows: w4b (0.14.x); shipped default v2 (4.16 bits); or the same GGUF | own EXL3 pack (95 GB) | UD-IQ4_XS GGUF |
| IOMMU / power | off, ROCm 7.14.1 | off, ~85 W, ROCm 7.14.0 | not stated | translated IOMMU, ROCm 7.2.3 |

Two honest caveats apply to all of them. (a) The Strata and Halogen hosts run IOMMU off (Kyojin's is not stated); Halogen's own data puts that at 13–16% of
prefill, so some of any gap is host configuration, not engine. (b) The decode gains are mostly speculation (lookup or
n-gram drafting on top of MTP) and depend on how repetitive the text is; #249's agent replay is the fairer yardstick.

## Proposed bench issues

Drafts only, not yet filed. #251 already covers Kyojin.

### A. bench: Strata on halo with the production UD-IQ4_XS GGUF (rank 1)

- **Scope.** Build Strata at a pinned commit for gfx1151 (ROCm 7.14.1 tarball, ggml pinned offline, hipBLASLt table). Run
  the #249 memory-gated harness, same prompts and same rows: prefill 4K / 32K / 128K, decode 512 / 32K / 128K, the
  8-turn agent replay, tool-call correctness, one vision request. Arms: Strata defaults; the maintainers' fast configuration. Each run twice: MTP only (lookup chain off,
  comparable to #249) and with the maintainers' spec settings (lookup chain on).
  Compare against Vulkan b11382 and GSQHalo f16-KV from #254, same session.
- **Quant.** The production `UD-IQ4_XS`. First step: establish whether Strata reads halo's existing GGUF and ggml-org MTP head or
  needs its own pack and MTP files (README lists ~6 GB for the MTP layer, +1 GB with images); budget the extra download. `UD-Q4_K_XL` only if memory allows.
- **Memory budget.** Resident target ≤ ~75 GiB GTT with vision and 131K context. Record peak GTT and host RSS, and
  headroom for a build plus a second small model. Halo's GTT is 104 GiB, Strata's box has 112 GiB: do not raise it.
- **Acceptance.** README under `bench-logs/` with a table vs #254's rows, a tool-call and vision pass/fail, the
  footprint, a Nix packaging note, and a recommendation on whether Strata replaces Vulkan or GSQHalo as the lemond
  backend. Check greedy output against the Vulkan reference.
- **Out of scope.** Changing lemond config or the resident model; the optional bit-changing switches' quality (report
  KL only if the maintainers' own harness exposes it).

### B. bench: Halogen 0.16.2 container on halo, v2 checkpoint and BYO-GGUF arm (rank 2)

- **Scope.** Run the pinned `0.16.2` image under podman (digest recorded) with lemond stopped and nothing else on the
  GPU. Same harness and rows as A. Arms: (1) v2 checkpoint (62.1 GiB, vision on); (2) the production UD-IQ4_XS GGUF via
  `HALOGEN_CHECKPOINT` plus the 1.4 GiB draft head for an apples-to-apples quant comparison. Report served throughput
  over HTTP (the `sweep`/`bench` modes and the #249 client-timed probe both).
- **Quant.** Arm 1 is Halogen's own format (~4.16 bits); arm 2 is `UD-IQ4_XS`.
- **Memory budget.** Claimed ~74 GiB total at 131K context, 2 slots, `MAX_TOK` 16384 (v2). The GGUF arm is larger: the README says
  a GGUF is sized like w4b (+6 GiB) plus 4 GiB for UD-IQ4_XS, so roughly 84 GiB or more, over the ~70 GiB target. Record peak GTT, RSS, `host memory left for everything else`, and what happens when a ~20 GiB build runs beside
  it (weights are pinned; the README documents OOM kills under co-tenancy). Verify the host kernel has the KFD fixes
  and `CONFIG_HSA_AMD_SVM`.
- **Acceptance.** README under `bench-logs/` with the table vs #254, tool-call and vision checks, the co-tenant result,
  and a recommendation on whether a closed, container-only backend is acceptable as an opt-in lemond backend. Keep the
  existing IOMMU A/B in [halo-bringup-checklist.md](halo-bringup-checklist.md) in view: report the host's IOMMU mode
  beside every row.
- **Out of scope.** Reverse engineering, redistributing the image, changing the resident model.

A third candidate does not clear the bar: hipBLASLt-in-llama.cpp (from the teardown doc) is a lead for an upstream
kernel experiment, not an engine, and nothing published says it pays on this hardware.
