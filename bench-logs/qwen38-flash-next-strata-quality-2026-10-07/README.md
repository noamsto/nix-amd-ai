# Strata's fast configuration on halo: quality, KV precision, MTP, image encode, two server quirks (#276)

#269 found Strata's fast configuration 28 % faster on agent turns than the tuned GSQHalo build, but it turns on
output-changing kernel switches and matched the Vulkan reference's greedy output on only 8 of 20 prompts. This measures
whether that speed costs quality.

Every number is from **halo (Ryzen AI MAX+ 395, Radeon 8060S / gfx1151, 123 GiB RAM, 104 GiB GTT limit, kernel 7.2.9)**,
measured 2026-10-07. Nothing here transfers to gfx1150. Model: Qwen3.8-Flash-Next **UD-IQ4_XS** (unsloth, snapshot
`38bb39ee`). Strata commit `82f46a8` (tag v0.1.40.1), ggml `3cf0325`, ROCm 7.14.1, built by `pkgs/strata`; GSQHalo.cpp
`5fc881b` (f16 KV); stock llama.cpp b11382, Vulkan and HIP builds. Every GPU row went through `run.sh`'s memory gate with
lemond unloaded for the row and restored after; every row's `load_flag` is false (loadavg 1.5–1.9 at row start).

## Verdict

1. **Quality: fast is not worse than defaults.** Against #260's Q8_0 reference, Strata `fast` has mean KLD 0.0897
   (`def` 0.0920, GSQHalo 0.0913 by the same estimator) and 91.5 % top-token agreement (`def` 91.4 %, GSQHalo 91.5 %).
   Paired on the same 65,472 positions, fast − def is −0.0023 ± 0.0006 KLD. Strata is level with the production GSQHalo
   and not better than stock llama.cpp (0.0876 full-vocabulary; its Strata-equivalent was not measured, see the
   estimator note). The earlier 8/20 greedy-exact figure is rounding-level divergence at near-ties, not a worse model.
2. **Where fast diverges: one switch, `STRATA_HC_Q8`.** Removing it makes fast bit-identical to defaults; removing the
   six prefill switches changes nothing. `HC_Q8` reads the hyper-connection projections from the GGUF's own Q8_0 instead
   of the pack's BF16 rounding, which Strata's docs name as the cause of a 6–9 % perplexity gap, so it moves quality the
   good way. The prefill switches could not be tested (below).
3. **Soak: deferred** (run in [`qwen38-flash-next-strata-soak-2026-10-08`](../qwen38-flash-next-strata-soak-2026-10-08/)). The owner trimmed the bench; the soak, concurrency and long-soak rows will run on whichever engine
   is chosen (acceptance item waived by the dispatcher). The harness for them is in this directory and was exercised
   only by the image and quirks groups.
4. **Vision: a 1,000-token screenshot costs 19.7 s of CPU encode, once, and the server queues behind it.** Cold time to
   first token 21.3 s, the same image again 1.6 s. The encode did not slow a text request that was already decoding,
   because the server runs it only after that request finishes; it blocks whatever arrives next.

Also: **int8 KV costs nothing measurable** at this context; **MTP is lossless** on the #249 prompts; **the literal
tool-call start token truncates a reply into a tool call when tools are enabled** (reproducible); and **strata-server
decodes greedily when a request omits sampling**, so the lemond shim must set defaults.

## 1. Quality vs the #260 reference

Reference: UD-Q8_0 on the CPU backend, 64 chunks × 2048 tokens of this repo's docs and code at `4166bc4`; the scored
positions are the second half of each chunk (1023 per chunk, 65,472 in all), as `llama-perplexity` scores them. Same file,
same tokens as #260. Q8_0's own distance from BF16 was not measured.

**How Strata was scored.** Strata exposes no full logits on its serving paths (`--dump-logits` runs a per-token loop that
bypasses the prefill code under test). It does write the top-256 log-probabilities of every position it reads through its
verify windows (`STRATA_LOGPOS` with `STRATA_LOGPOS_TOPK=256`). `kl_strata.py` feeds each reference chunk's token ids to a
resident `strata --serve` engine in two requests: the first 1024 tokens (batched prefill, ending in a conversation
checkpoint), then the whole chunk, which resumes from that checkpoint and reads the second half through the windows, where
the rows are scored. The engine reports 1024 tokens reused on every chunk. Scored this way, quality is what the state left
by prefill gives the decode path, with MTP on, int8 KV, `--expert-cache 20000` and `--max-context 8192`.

**KL is over Strata's top 256 tokens plus one bucket for the rest**, taken as KL(reference ‖ candidate). That is a lower
bound on the full-vocabulary KL. To measure the gap, the same estimator was applied to GSQHalo's saved logits from #260:
0.0913 against 0.0960 full-vocabulary, so the Strata figures below read about 5 % under what a full-vocabulary KL would
give. Compare Strata rows with each other and with the GSQHalo row of the same estimator; the llama.cpp rows are
full-vocabulary and not directly comparable.

| row | estimator | mean KLD | median | 99 % | same top token | PPL (ratio to Q8_0) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Strata `def` | top-256 | 0.0920 ± 0.0011 | 0.0045 | 1.20 | 91.37 ± 0.11 % | 2.6631 (1.0227 ± 0.0023) |
| Strata `fast` (production preset) | top-256 | 0.0897 ± 0.0011 | 0.0044 | 1.15 | 91.48 ± 0.11 % | 2.6616 (1.0222 ± 0.0023) |
| Strata `fast`, `PF_SWITCH_MIN_T=0` | top-256 | 0.0897 ± 0.0011 | 0.0044 | 1.15 | 91.48 ± 0.11 % | 2.6616 (1.0222 ± 0.0023) |
| Strata `fast`, f16 KV | top-256 | 0.0897 ± 0.0011 | 0.0044 | 1.18 | 91.52 ± 0.11 % | 2.6638 (1.0230 ± 0.0023) |
| GSQHalo f16 KV (production engine; #260's logits) | top-256 | 0.0913 ± 0.0011 | 0.0047 | 1.18 | 91.52 ± 0.11 % | 2.6660 (1.0239 ± 0.0023) |
| GSQHalo f16 KV (#260's own run) | full vocabulary | 0.0960 ± 0.0012 | 0.0047 | 1.25 | 91.52 ± 0.11 % | 2.6680 (1.0247 ± 0.0023) |
| stock llama.cpp b11382, Vulkan | full vocabulary | 0.0876 ± 0.0011 | 0.0041 | 1.16 | 91.87 ± 0.11 % | 2.6434 (1.0152 ± 0.0022) |
| stock llama.cpp b11382, HIP | full vocabulary | 0.0882 ± 0.0011 | 0.0043 | 1.18 | 91.83 ± 0.11 % | 2.6467 (1.0165 ± 0.0022) |

The ± are standard errors over tokens, which treat neighbouring tokens as independent and so understate the uncertainty.
Neighbouring-token correlation does not affect the **paired** differences below as much, because both sides see the same
positions.

| paired, same 65,472 positions | ΔKLD | ΔNLL per token | top token differs |
| --- | ---: | ---: | ---: |
| Strata fast − def | −0.0023 ± 0.0006 | −0.0005 ± 0.0012 | 4.6 % |
| Strata fast with f16 KV − fast | +0.0001 ± 0.0005 | +0.0008 ± 0.0011 | 4.4 % |
| GSQHalo − Strata def | −0.0007 ± 0.0006 | +0.0011 ± 0.0012 | 4.6 % |

- Strata's distance from the reference (`def`: 8.6 % of positions with a different top token) is the same size as
  GSQHalo's (8.5 %) and stock llama.cpp's (8.1 %). Stock llama.cpp scores best in absolute terms, 0.0876 against GSQHalo's
  0.0960 full-vocabulary on the same file; Strata's full-vocabulary figure was not measured.
- ΔNLL is within noise everywhere: none of these arms is measurably better or worse at predicting the real next token.

## 2. Where fast diverges (bisect)

Two extra rows, 16 chunks (16,368 positions), both with `STRATA_PF_SWITCH_MIN_T=0`; paired against `def` on the same
positions (def and fast taken from their 64-chunk runs, first 16 chunks):

| row | mean KLD | ΔKLD vs def | top token differs from def |
| --- | ---: | ---: | ---: |
| def | 0.0620 ± 0.0016 | – | – |
| fast | 0.0615 ± 0.0015 | −0.0005 ± 0.0008 | 3.6 % |
| fast without the six prefill switches (`PF_FUSED PF_GEMM HC_UPMIX PA_FAST HIP_WMMA SELECT_WMMA`) | 0.0615 ± 0.0015 | −0.0005 ± 0.0008 | 3.6 % |
| fast without `HC_Q8` | 0.0620 ± 0.0016 | 0.0000 ± 0.0000 | 0.0 % |

- Fast without `HC_Q8` is **bit-identical** to defaults on every position; fast without the six prefill switches is
  bit-identical to fast. So at this prefill length the only active difference is `HC_Q8` (and `--mtp-q4 all`, which only
  affects drafts and cannot change verified output).
- **The six prefill switches were not exercised.** The preset's `STRATA_PF_SWITCH_MIN_T=4096` keeps prompt chunks under
  4096 tokens on the default numerics, and the scored chunks' prefill is 1024 tokens; setting it to 0 gave the same bits as
  4096, so these kernels either do not run on a 1024-token chunk or round identically there. Their effect on the chunks
  of 4096 tokens and more where production fast applies them is **not measured**: #260's reference only has 2048-token
  chunks, so there is nothing to score a longer prefill against. A paired def-vs-fast comparison on a long prefill without a
  reference would show how far they move the distribution, not whether it is for the better. Unresolved.
- Strata applies 18 further "exact" speed switches by default on gfx1151 (`STRATA_GFX1151_DEFAULTS`, printed at start); all
  rows here have them on.

## 3. KV precision (int8 vs f16)

Both Strata arms use `--kv int8`. `fast` with `--kv fp16` (Strata's higher-precision KV mode) on the same 64 chunks: ΔKLD
+0.0001 ± 0.0005, top-token agreement 91.52 % vs 91.48 %. **int8's cost is not measurable here.** Caveats: the scored
positions sit at most 2047 tokens into a context, where KV rounding has had the least time to accumulate; long-context
quality was not measured. GTT peak (the row's `exec` watchdog, `--max-context 8192`): 65.0 GiB int8, 65.1 GiB f16, 64.4 GiB
for `def`. At 8192 tokens the KV is small, so this says little about the difference at 131072; that was not measured.

## 4. MTP losslessness

`fast` arm, greedy, thinking off, the 20 #249 correctness prompts (256-token cap), MTP draft layer on vs off (`--mtp`
dropped; prompt-lookup drafting stays at its default in both): **20/20 token-identical**, no divergence position to report,
sanity 10/10 both ways. Two rows, scored with `probe.py analyze --ref <mtp on row>`.

## 5. Image through the CPU encoder

`fast` arm, vision on (BF16 mmproj, `--vision-max-tokens 1024`), a deterministic 1280×800 synthetic editor-and-terminal
screenshot (`screenshot.py`: text rendered from this repo's own scripts; a stand-in for a desktop screenshot, not one).
The picture became about 1,000 image tokens (prompt of 1,072; the text-only baseline had a slightly shorter wrapper, so the
image share is in the 1,000–1,034 range). Times are client-side, from the first run of the group; the encode window is the
span where the `strata-vision` process's CPU time rose (sampled every 50 ms).

| request (one at a time) | time to first token | wall | encoder CPU window | decode t/s |
| --- | ---: | ---: | --- | ---: |
| image, cold | 21.27 s | 22.5 s | 19.7 s, 298 CPU-seconds | 53.1 |
| the same image again (new prompt text, so only the encoder cache can hit) | 1.56 s | 2.9 s | none | 47.3 |

The repeat confirms the encode cache: no encoder activity, 19.7 s less to first token. Decode of a text-only request alone,
two runs: 45.5 and 44.4 t/s.

**Concurrent text request.** The text request (1,200 tokens) was sent first and the image 4 s later, twice:

| | image time to first token | encode window | text request decode t/s |
| --- | ---: | --- | ---: |
| run 1 | 44.4 s | 19.7 s | 45.5 |
| run 2 | 43.9 s | 19.8 s | 46.4 |

The image's encode started only after the text request finished (it waited about 23 s, encoded for 20 s, prefilled for
1.5 s): strata-server runs a request's encode when that request reaches the front of its single queue. So **an encode
cannot slow a decode already in progress, and a decode cannot start during an encode**: the cost of a big image is about
20 s of head-of-line blocking for whatever is queued behind it. The decode rate of the text request was unchanged
(45.5 and 46.4 against 44.4 and 45.5 alone). The measurement that would show the blocking directly (image first, text
request 3 s later) was added to the harness after this run and **has not been run**. No GPU or NPU encoder was tried.

## 6. The literal tool-call start token (`<tool_call>`)

The pin (82f46a8) is reported to cut a stream off when the model writes its own tool-call start token as text. Asked, with
thinking off, to explain the token in prose, to show an example reply in a fenced block, and to write a function that
splits a reply on it, T=0 and T=0.7 (two seeds), with and without tools:

| prompt | tools off | tools on |
| --- | --- | --- |
| explain it in prose and in a code span | 3/3 complete, token quoted 1–2× | **3/3 `finish_reason: tool_calls`, empty content, 26–38 tokens** |
| show an example reply in a fenced block | 3/3 complete, token quoted 2× | **3/3 `tool_calls`, empty content, 26 tokens** |
| write a function that splits on it | 3/3 complete, token quoted 3–5× | 3/3 `tool_calls`, 78–86 tokens, text before the call |

With tools on, the two prose prompts produced no text at all and a tool call the client did not ask for; with tools off the
same prompts answered normally. **Reproducible at this pin on all 6 prose and fenced requests.** The code prompt also
returned a tool call with tools on; whether that call is the model's own choice or the same parse was not distinguished.
This run did not record the content of the spurious call (the harness records it now; not rerun).

Minimal repro, one request to `/v1/chat/completions` with the replay's `read_file` / `grep` / `run_tests` function tools in
`tools`, `chat_template_kwargs.enable_thinking: false`, `temperature: 0`, `max_tokens: 700`, and as the only user message:

> Show me, in a fenced code block, an example reply that contains <tool_call> followed by a JSON call and its closing tag,
> then describe in two sentences how a client should parse it.

Expected: a text answer. Observed: `finish_reason: "tool_calls"`, empty `content`, 26 completion tokens. Not tried with other
tool sets, thinking on, or streaming off.

## 7. Sampling defaults

Read from `serve/server.py` and confirmed on the live server (7 checks, all as expected):

- A request that omits `temperature`, `top_p`, `top_k` and `min_p` sends the engine nothing, and the engine **decodes
  greedily**: two omitted requests are identical to each other and to `temperature: 0`.
- Values the request sends are honoured: `temperature: 0.7` with the same seed repeats exactly, different seeds differ, it
  differs from the omitted (greedy) answer, `top_k: 1` at 0.7 equals greedy, `temperature: 1.5` differs from greedy.
  `top_k` is clamped to 1–64 (0 and larger become 64); `min_p`, penalties and `seed` are passed through.
- The config's optional `sampling` block supplies defaults for fields a request leaves out (the request always wins).
- `pkgs/strata/lemond-shim.py` copies the settings' `config` through and does not add a `sampling` block. **A client that
  does not send sampling parameters gets greedy decoding through the shim**, which is wrong for Qwen's recommended settings
  (instruct: temperature 0.7, top_p 0.8, top_k 20, presence penalty 1.5; thinking: 0.6, 0.95, 20). The shim's settings
  should set `config.sampling`, or lemond's callers must send them.

## What went wrong on the host

- A first attempt at the stock-HIP row was interrupted: another benchmark's `run.sh` fit check reloaded the resident model
  beside it and the host ran low on memory. The row was rerun from scratch; its numbers are from the rerun.
- A fit-check refusal followed lemond's backend holding its weights in anonymous memory after a reload, which the check
  counted as 5.7 GiB of RSS until the model was exercised. The check now sums anonymous memory over lemond's whole process
  tree (`run.sh`, with `test_lemond_rss.sh`).

## Not measured

- The soak, concurrency and long-soak rows (deferred, above); the thinking-on and tool-call workloads under load.
- The six prefill switches on chunks of 4096 tokens or more; full-vocabulary KL for Strata; KL beyond 2048 tokens of
  context; Q8_0's distance from BF16.
- The text-queued-behind-an-encode case, other image sizes, a different image, the GPU encoder.
- Strata's `--batch` slots (opt-in, one more session's worth of VRAM each); the GTT difference of f16 KV at 131072.
- The content of the tool-call spurious call; the token with thinking on or streaming off.
- Anything on gfx1150.

## Reproduce

Builds, the Q8_0 reference logits and the eval text are #260's; the Strata build, pack, MTP files and mmproj are #257's.
From the repo root, with `W` (work dir), `REF` (the reference logits), `IQ4` (shard 1 of the UD-IQ4_XS file), `PY` (python with
numpy and Pillow), the `STRATA_*` variables of #257's README, and `STOCK_BIN`, `STOCK_HIP_BIN`, `GSQ_BIN` set:

```sh
D=bench-logs/qwen38-flash-next-strata-quality-2026-10-07
$D/rows.sh kl 64 def fast 'fast@0'                       # Strata top-256 rows; arms: def, fast, fast-<switch>, def+<switch>, fast+kvf16
$D/rows.sh kl 16 'fast-pf_fused,pf_gemm,hc_upmix,pa_fast,hip_wmma,select_wmma@0' 'fast-hc_q8@0'
$D/rows.sh kl 64 'fast+kvf16'
$D/rows.sh llama 64 stock stock-hip                      # full-vocabulary rows against the same reference
$PY $D/kl_strata.py compare --ref "$REF" --json cmp.json s-def=$W/kl/kl-def-64 s-fast=$W/kl/kl-fast-64 gsq=<GSQHalo logits>
python3 $D/tables.py kl cmp.json; python3 $D/tables.py llama $W/llama-*.log
$PY $D/screenshot.py "$W/screenshot.png"
SCREENSHOT_PNG=$W/screenshot.png $D/rows.sh probe fast qi quirks,bigimage --vision-max-tokens 1024
$D/rows.sh probe fast mtp-on-C correctness; NO_MTP=1 $D/rows.sh probe fast mtp-off-C correctness
$PY $D/test_kl_strata.py; bash bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/test_lemond_rss.sh
```

`kl_strata.py` runs behind `run.sh`'s `exec` preset (memory gate, lemond hand-off). `probe.py` gained the `soak`, `longsoak`,
`bigimage` and `quirks` groups (`soak.py`), `--vision-max-tokens` and `--soak-minutes`; `run.sh`'s fit check now counts the
anonymous memory of lemond's whole process tree. The `soak` and `longsoak` groups were written and reviewed but never run.
