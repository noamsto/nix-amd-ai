# Flash-Next engine bake-off: Vulkan vs strix-llama.cpp HIP vs GSQHalo.cpp HIP — halo, gfx1151 (#249)

Every number is from **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT limit)**, measured
2026-10-05 and 2026-10-06. None of it transfers to gfx1150. The model is Qwen3.8-Flash-Next **UD-IQ4_XS** (unsloth,
snapshot `38bb39ee`) with the **ggml-org MTP Q8_0** head, n-max 3, for all three engines. Every row ran with the
1-min loadavg below 2 at start, so no row carries `load_flag`. The per-row loadavg is in the tables.

The comparison was prompted by the r/StrixHalo engine comparison by u/Southern_Capital_885, which reported the HIP
engines prefilling 3–4× faster than Vulkan with similar MTP decode.

## Verdict

**For hermes/pi on halo, GSQHalo.cpp (HIP) is the engine to run, at about 1.3× rather than 3–4×.** It is the only
engine with a real agent-turn win. Correctness passes and it costs about 7 GiB more GTT. Vulkan stays in lemond until
GSQHalo is packaged.

| | Vulkan b11382 (production) | strix-llama.cpp `4b2561e` | GSQHalo.cpp `5fc881b` |
| --- | ---: | ---: | ---: |
| **Agent replay, normalized** (8 turns, lower is better) | 185.6 s | 170.2 s (−8%) | **144.4 s (−22%)** |
| Agent replay, time to first token summed | 127.1 s | 104.7 s (−18%) | **83.5 s (−34%)** |
| Prefill 4K / 32K / 128K (t/s) | 453 / 392 / 266 | 437 / 491 / 277 | **702 / 613 / 316** |
| Decode with MTP, 512 / 32K / 128K depth (t/s) | 29.3 / 36.8 / **27.5** | 24.7 / 35.5 / 20.2 | 30.3 / 35.7 / 21.8 |
| Correctness | reference (sanity 10/10) | **pass** (10/10, 12/20 greedy exact) | **pass** (10/10, 12/20 greedy exact) |
| GTT after load / MemAvailable after replay | 70.8 GiB / 35.0 GiB | 74.9 GiB / 27.2 GiB | 77.8 GiB / 26.0 GiB |

- **The 3–4× prefill claim does not reproduce on halo with this quant.** GSQHalo prefills 1.55× faster at 4K and 32K
  and 1.19× at 128K. strix-llama.cpp only wins at 32K (1.25×). Without the MTP head, strix-llama's `llama-bench`
  pp4096 matched Vulkan (see the diagnostic section), so the MTP draft is not what hides the gap. The fork's HIP matmul
  tiles are quant-specific and its own figures come from other quants (GSQ-RCO IQ3_XXS). The 619 t/s it reached on
  UD-Q4_K_XL is consistent with that, but neither fork was tested on those quants with MTP here.
- **Decode is no better on HIP.** It is level at 512 and 32K. At 128K depth both HIP builds lose a fifth of Vulkan's
  decode (27.5 → 20.2 / 21.8 t/s, 3 runs each, stdev 2–3 t/s).
- **strix-llama.cpp does not justify packaging.** Its replay gain is 8%, it decodes slower at 512 and 128K depth, and
  it uses 4 GiB more GTT.
- **GSQHalo justifies a packaging trial, not a switch yet.** It already builds as a source override of this repo's
  `llama-cpp-rocm` (`strix-rocm.nix` here, no patches), so an opt-in lemond backend costs one overlay attribute.
  Before it replaces Vulkan it needs three things:
  - an agent replay with f16 KV, which measured faster still for it (row below);
  - a longer correctness and stability soak, since this is one replay run per engine;
  - a check that its 128K decode loss is acceptable for hermes's long sessions.

## Engines

| id | build | weights | server flags beyond the shared ones |
| --- | --- | --- | --- |
| `vulkan` | stock llama.cpp b11382 (`11fe021`), `.#llama-cpp-vulkan` | UD-IQ4_XS + ggml-org MTP Q8_0 | `--lazy-mode on -ub 2048 -b 2048` (#248's winners) |
| `strix-hip` | halo-box/strix-llama.cpp `4b2561e487f2`, built by `strix-rocm.nix` | same | `-lzm on -ub 4096 -b 4096` (its recommended flags, as quoted by GSQHalo's README) |
| `gsq-hip` | Aristo94/GSQHalo.cpp `5fc881b114c1`, built by `strix-rocm.nix` | same | `-lzm on-direct -ub 8192 -b 8192 --spec-draft-p-min 0.3` (its README) |

Shared flags: `-c 131072 -fa on -ctk q8_0 -ctv q8_0 --parallel 1 --jinja --metrics --spec-type draft-mtp
--spec-draft-n-max 3`. Both HIP builds come from this repo's `llama-cpp-rocm` (ROCm 7.2.3, `-DGGML_HIP=ON`), with only
`src` replaced and the HIP architectures narrowed to gfx1151. Neither needed `HIP_LAUNCH_BLOCKING=1`: both passed
correctness without it. strix-llama.cpp's README documents that variable for a batched-output bug on gfx1151.
GSQHalo's README also sets `-t 4 --cache-ram 2048 -ctxcp 8`. Those flags were not used.

## Agent-turn replay (headline)

The replay is a deterministic 8-turn coding conversation over `/v1/chat/completions`, built from this repo's public
files at `4166bc4`:
- a 6,000-token system prompt (`AGENTS.md`, `CLAUDE.md`, `README.md`, `docs/*.md`) plus a fixed three-tool `tools`
  array;
- a fixed user task;
- per turn, a scripted assistant `read_file` call and a 2,000–8,000-token tool result (`flake.nix`,
  `modules/amd-npu.nix`, …).

Every engine gets byte-identical requests: the engine's own reply is dropped, so caching sees the same prefixes. Each
turn generates up to 300 tokens at temperature 0 with thinking disabled and `cache_prompt: true`.

**Normalized** turn time = time to first token + 300 / that turn's decode t/s. Turns that emitted fewer than 32 tokens
use the engine's 32K decode mean instead. An engine that stops early therefore gains nothing. The raw wall time sums
the actual turns.

| turn (prompt tokens, cached) | Vulkan TTFT / normalized | strix-hip TTFT / normalized | gsq-hip TTFT / normalized |
| --- | ---: | ---: | ---: |
| 1 (8,529, 0) | 19.75 / 27.90 s | 15.92 / 24.37 s | 12.53 / 20.95 s |
| 2 (11,590, 8,525) | 7.91 / 15.37 s | 5.78 / 12.91 s | 4.94 / 12.75 s |
| 3 (15,654, 11,586) | 10.84 / 16.78 s | 9.55 / 16.75 s | 6.77 / 13.39 s |
| 4 (20,753, 15,650) | 13.96 / 20.26 s | 11.11 / 18.35 s | 8.97 / 15.51 s |
| 5 (26,816, 20,749) | 17.08 / 23.97 s | 13.82 / 21.18 s | 11.34 / 18.10 s |
| 6 (33,891, 26,812) | 21.19 / 29.96 s | 18.43 / 26.95 s | 14.22 / 24.14 s |
| 7 (41,955, 33,887) | 26.89 / 33.88 s | 22.53 / 32.89 s | 18.09 / 25.35 s |
| 8 (44,516, 41,951) | 9.43 / 17.50 s | 7.56 / 16.77 s | 6.64 / 14.24 s |
| **total, normalized** | **185.6 s** | **170.2 s** | **144.4 s** |
| total, raw wall | 137.9 s | 120.8 s | 94.6 s |
| host, build, loadavg | halo, b11382, 1.16 | halo, `4b2561e`, 1.93 | halo, `5fc881b`, 1.43 |

All three engines reuse the cached prefix on every turn. The cached counts are identical across engines and stop
about 4 tokens short of the previous prompt. Time to first token dominates every turn, so prefill speed is what an
agent feels.

## Prefill and decode

The prompts come from the code/docs corpus built by `grid.py` at `4166bc4`: 41 files, no repeated 64-grams. The
corpus was tokenized once with the Vulkan server and sent to every engine as identical text, each prompt with a
unique first line so no prompt cache can hit. The probe checks the reported cached tokens.

- **Prefill** = prompt tokens / client-side time to first token, over a streamed `/v1/completions` request.
  llama-server's own `prompt_per_second` agreed within 5% on every 4K-and-longer prompt. On the 547-token prompts of
  the 512-depth decode runs the client figure reads up to 8% lower, because request overhead weighs more there.
- **Decode** = (tokens − 1) / time from first to last token, 128 tokens with `ignore_eos`: 3 runs at temperature 0.7
  (seeds 1–3, mean ± stdev) and one at temperature 0.
- **Acceptance** is llama-server's `draft_n_accepted / draft_n`, summed over the 4 runs.
- 4K prefill is 3 runs with 1 generated token. The 32K and 128K prefill figures are the prompt phase of the 4 decode
  runs. "128K" is 130,000 corpus tokens, so prompt plus generation fits `-c 131072`.

| engine (host, build) | loadavg | prefill 4K | prefill 32K | prefill 128K | decode 512 (T=0) | decode 32K (T=0) | decode 128K (T=0) | acceptance 512 / 32K / 128K |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Vulkan (halo, b11382) | 1.16 / 0.41 | 453 ± 13 | 392 ± 6 | 266 ± 5 | 29.3 ± 7.4 (27.5) | 36.8 ± 1.9 (40.0) | 27.5 ± 2.4 (28.3) | 0.36 / 0.77 / 0.73 |
| strix-hip (halo, `4b2561e`) | 1.93 / 1.71 | 437 ± 28 | 491 ± 4 | 277 ± 0.5 | 24.7 ± 8.4 (22.8) | 35.5 ± 2.6 (30.7) | 20.2 ± 3.2 (21.0) | 0.48 / 0.77 / 0.67 |
| gsq-hip (halo, `5fc881b`) | 1.43 / 1.73 | 702 ± 36 | 613 ± 11 | 316 ± 0.7 | 30.3 ± 5.4 (31.8) | 35.7 ± 1.0 (37.9) | 21.8 ± 2.6 (24.8) | 0.49 / 0.80 / 0.73 |

All values are t/s. The two loadavg values are for the row with prefill 4K–decode 32K and for the 128K row. Decode at
512 depth is noisy on every engine, with a ±5–8 t/s spread between seeds. At that depth the MTP acceptance swings
with the sampled text.

### GSQHalo with f16 KV (one row)

The same GSQHalo flags with `-ctk f16 -ctv f16` (halo, `5fc881b`, loadavg 1.72):

| | q8_0 KV | f16 KV |
| --- | ---: | ---: |
| prefill 4K | 702 ± 36 | **751 ± 11** |
| prefill 32K | 613 ± 11 | **799 ± 2** |
| decode 32K (T=0), acceptance | 35.7 ± 1.0 (37.9), 0.80 | **43.0 ± 1.3 (42.5)**, 0.82 |
| GTT after load | 77.8 GiB | 71.6 GiB |

On Vulkan, #248 found f16 KV no better. On GSQHalo, f16 KV is faster at 32K, by +30% prefill and +21% decode. It also
loaded with *less* GTT, though at `-c 131072` an f16 KV cache should be larger. The cause was not investigated, and
the GTT figure is a delta read right after load. No agent replay, 128K row or correctness run was done with f16 KV.

## Memory

GTT is the delta of the amdgpu card's `mem_info_gtt_used` from before the server started. RSS is the llama-server
process. "After load" is read straight after `/health`; "row end" is after the last request of the speed-and-replay
row.

| engine (host, build) | GTT after load | RSS after load | MemAvailable after load | GTT / RSS / MemAvailable after replay | peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Vulkan (halo, b11382) | 70.8 GiB | 0.39 GiB | 43.8 GiB | 71.4 / 11.2 / 35.0 GiB | 12.7 GiB |
| strix-hip (halo, `4b2561e`) | 74.9 GiB | 3.86 GiB | 37.4 GiB | 76.2 / 14.3 / 27.2 GiB | 16.1 GiB |
| gsq-hip (halo, `5fc881b`) | 77.8 GiB | 5.64 GiB | 35.1 GiB | 79.5 / 12.9 / 26.0 GiB | 14.1 GiB |

RSS grows by 9–12 GiB over a replay on every engine. That is the server's prompt-cache and checkpoint state, not the
weights, and the weights stay lazily mapped. MemAvailable depends on the rest of the host, so compare it within a
row, not across days.

## Tool call and correctness

- **Tool call:** one `/v1/chat/completions` request with a `get_weather` tool, thinking off. It passes when
  `finish_reason` is `tool_calls` and the arguments parse with a `city` key. All three engines pass.
- **Correctness:**
  - 20 fixed prompts (8 code, 6 math, 6 prose), greedy, 256 tokens, thinking off, MTP on. Outputs are tokenized
    with `llama-tokenize` and compared with Vulkan's.
  - Plus a 10-question arithmetic and code sanity set, scored by exact match.
  - Failure thresholds were fixed before running: sanity below Vulkan's minus 1; a degenerate output (U+FFFD, or
    one 8-gram covering ≥ 40% of tokens) where Vulkan's is not; or 0/20 exact with a median first divergence under
    10 tokens.

| engine (host, build, loadavg) | tool call | sanity | greedy exact vs Vulkan | median first divergence | degenerate | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Vulkan (halo, b11382, 1.97) | pass | 10/10 | — | — | 0 | reference |
| strix-hip (halo, `4b2561e`, 1.63) | pass | 10/10 | 12/20 | 52 tokens | 0 | **pass** |
| gsq-hip (halo, `5fc881b`, 1.54) | pass | 10/10 | 12/20 | 32.5 tokens | 0 | **pass** |

- **Where the outputs match:** all 8 code prompts match Vulkan token for token on both HIP builds. The one exception
  is GSQHalo's `code7`, which diverges at token 25.
- **Where they diverge:** math and prose mostly drift at the same positions on both HIP builds (prose1 at 4, prose4
  at 15, math3 at 32, …). That pattern points to HIP-vs-Vulkan rounding rather than a GSQHalo change.
- **Single-slot only:** no HIP output was garbled. The batched-output bug the fork documents was not reproduced at
  one slot. The concurrency rows were not checked for correctness.

## Concurrency (aggregate decode, 4 slots of 32,768 tokens)

Each engine was restarted with `-np 4 -c 131072 --no-kv-unified`, keeping its other flags. Then 2 and then 4
concurrent streams ran, each with a distinct 512-token prompt, 128 tokens, temperature 0.7 and MTP on. "Aggregate" is
total tokens / wall time; "Σ per-request" sums each stream's own decode rate.

| engine (host, build, loadavg) | 2 users: aggregate / Σ per-request | 4 users: aggregate / Σ per-request |
| --- | ---: | ---: |
| Vulkan (halo, b11382, 1.40) | 27.7 / 50.1 t/s | 21.9 / 32.0 t/s |
| strix-hip (halo, `4b2561e`, 0.53) | 30.8 / 47.1 t/s | 31.0 / 52.9 t/s |
| gsq-hip (halo, `5fc881b`, 1.66) | 30.7 / 46.1 t/s | 27.4 / 42.8 t/s |

None of the three scales past about 31 t/s aggregate with MTP. Vulkan gets *slower* at 4 users: each stream drops to
about 8 t/s. A single run per row, so the differences of a few t/s are within noise.

## Diagnostic: prefill without the MTP head (`llama-bench`, 2026-10-05)

| build (host halo) | quant | `-ub` | pp4096 | pp4096 @ d32768 |
| --- | --- | ---: | ---: | ---: |
| Vulkan b11382 | UD-IQ4_XS | 2048 | 544.7 ± 0.6 | 325.9 ± 2.0 |
| strix-llama `4b2561e` (`-lzm on`) | UD-IQ4_XS | 4096 | 560.3 ± 143.9 | 364.9 ± 14.0 |
| strix-llama `4b2561e` (`-lzm on`) | UD-Q4_K_XL | 4096 | 619.1 ± 1.2 | 367.4 ± 6.3 |

- **Method:** `llama-bench -fa on -ctk q8_0 -ctv q8_0`, `-r 2` for the IQ4_XS rows and `-r 3` for Q4_K_XL. The first
  strix IQ4_XS repetition was a slow outlier.
- **What it shows:** without the draft, strix-llama's IQ4_XS prefill equals Vulkan's. Its server prefill was slightly
  *slower* than Vulkan's at 4K, so the MTP head costs it a little more than it costs Vulkan.
- **What came next:** the Vulkan run on UD-Q4_K_XL is the one that wedged the GPU (next section).
- **How these were run:** directly, outside `run.sh`. After the wedge, every GPU run went through `run.sh`'s memory
  gate.

## Finding: a Vulkan load of UD-Q4_K_XL without lazy mode wedged amdgpu

**What ran.** Host halo, kernel 7.2.8, 2026-10-05 19:14. Stock llama.cpp b11382's `llama-bench` on Vulkan loaded
UD-Q4_K_XL (103.7 GiB of tensors, against the 104 GiB GTT limit) with `-ub 2048` and **no `--lazy-mode`**. Without
lazy mode the whole tensor set goes to the GPU.

**What the kernel did.**
1. amdgpu logged `[drm:amdgpu_gem_va_update_vm [amdgpu]] *ERROR* Couldn't update BO_VA (-12)`, which is ENOMEM.
2. The process then hung in `amdgpu_cs_ioctl → amdgpu_vm_bo_update → amdgpu_vm_sdma_prepare → amdgpu_ib_get →
   amdgpu_sa_bo_new`.
3. It stayed in uninterruptible sleep (`drm_suballoc_insert`), survived SIGKILL, and held 75 GiB of GTT.
4. A GPU reset did not recover it, and halo needed a reboot.

**What had worked.** The same file had loaded and run normally minutes earlier under strix-llama.cpp with `-lzm on`.

**What it means.** Any engine that maps the full tensor set needs a GTT fit check *before* loading, as `run.sh` does.
Exceeding the GTT can take the whole GPU down rather than fail the one load cleanly. Whether a smaller overshoot or
another driver version fails cleanly instead was not tested.

## Not measured

- **Gufo** (gufo-org/gufo v0.7.0, runtime image `sha256:b280a378…`).
  - The image was pulled and `gufo --version` ran in docker with the GPU devices passed through.
  - Gufo accepts only UD-Q4_K_XL plus unsloth's shared MTP head, and the only full load of that quant on halo
    wedged the GPU (above).
  - After the reboot the owner chose to skip Gufo rather than risk a second wedge. Gufo's own docs report an
    85.6 GiB HIP peak for that quant, which would fit, but this was not verified on halo. Its numbers here are
    therefore none.
- **The Vulkan UD-Q4_K_XL reference** (Gufo's quant-matched comparator) and **any HIP run on UD-Q4_K_XL or GSQ-RCO
  quants with MTP.** The forks' own speed claims come from those.
- **Agent replay, 128K rows, concurrency and correctness for GSQHalo with f16 KV.** Only prefill 4K and 32K and
  decode 32K were run.
- **Repeat runs.** Each replay and concurrency row is a single run.
- **Correctness under concurrency** (the batched path the fork's `HIP_LAUNCH_BLOCKING` note is about), and HIP rows
  with `HIP_LAUNCH_BLOCKING=1`. Neither was needed at one slot.
- **Perplexity**, thinking-on workloads, and other `-ub` or `--spec-draft-p-min` values for the forks. Each fork ran
  only its own recommended flags.
- **Day mix.** Vulkan and the strix-llama speed and correctness rows ran on 2026-10-05. strix-llama's concurrency row
  and all GSQHalo rows ran on 2026-10-06 after the reboot, with the same builds, files and corpus.
- **Anything on gfx1150.**

## Reproduce

From the repo root. `run.sh` checks that the engine fits the GTT and memory and waits for loadavg below 2. It then
unloads `Qwen3.8-Flash-Next-MTP` from lemond (`POST /api/v1/unload`), runs one `probe.py` row, and reloads lemond on
every exit path. `KEEP_OFFLINE=1` keeps lemond offline after a successful row so the next call can continue.

```sh
nix build .#llama-cpp-vulkan   # VULKAN_BIN=result/bin/llama-server
nix build --impure -f bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/strix-rocm.nix \
  --argstr owner halo-box --argstr repo strix-llama.cpp \
  --argstr rev 4b2561e487f21f7fd3ccd7c975612d2e038a7070 \
  --argstr hash sha256-7S9fCamsLMRQolptQjX7kfxnQlEmOnjhcjdBsSFLcmQ=        # STRIX_BIN
nix build --impure -f bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/strix-rocm.nix \
  --argstr owner Aristo94 --argstr repo GSQHalo.cpp \
  --argstr rev 5fc881b114c1ea130f5df6a30a98be2f8d397de6 \
  --argstr hash sha256-f3aoiICLmkSAY2wqfc1g3YznfhtRfeMOCvkMx561n1k=        # GSQ_BIN

export OUT=rows.jsonl CACHE=cache.json CORPUS_REV=4166bc461d7d4c0c10bac574f543a2a6cb912157
D=bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05
KEEP_OFFLINE=1 $D/run.sh corpus
KEEP_OFFLINE=1 $D/run.sh vulkan --label vulkan-A --do toolcall,prefill4k,decode512,decode32k,replay
KEEP_OFFLINE=1 $D/run.sh vulkan --label vulkan-B --do decode128k
KEEP_OFFLINE=1 $D/run.sh vulkan --label vulkan-C --do correctness
KEEP_OFFLINE=1 $D/run.sh vulkan --label vulkan-D --slots 4 --do concurrency
# … the same four groups with the strix-hip and gsq-hip presets, then:
EXTRA_ARGS="-ctk f16 -ctv f16" $D/run.sh gsq-hip --label gsq-hip-F16 --do prefill4k,decode32k
python3 $D/probe.py analyze --rows rows.jsonl --ref vulkan-C \
  --tokenizer-bin <llama-tokenize> --vocab <UD-IQ4_XS first shard>
```

Model paths default to the HF cache under `/var/lib/models`. Override them with `MODELS`, `IQ4` or `DRAFT_GGML`.
